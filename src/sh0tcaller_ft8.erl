-module(sh0tcaller_ft8).

-moduledoc """
Capture FT8 cycles from the radio and decode them with jt9.

FT8 transmits in 15 second cycles aligned to the UTC minute, so a capture
is only decodable if it starts on a cycle boundary. Recording happens at
12 kHz mono, which is what jt9 expects, and files are named
`YYMMDD_HHMMSS.wav` after the cycle start because jt9 takes the UTC time it
reports from the filename.
""".

-export([
         capture/0,
         capture/1,
         decode/1,
         capture_and_decode/1,
         monitor_cycles/1,
         monitor_cycles/2,
         cycle_filename/1,
         wav_dir/0
        ]).

-define(CYCLE_MS, 15000).
-define(RATE, 12000).
-define(CHANNELS, 1).

%% How late we are still willing to join a cycle already in progress.
%% A capture ends exactly on the next boundary, so without this every
%% other cycle is dropped while the device is reopened. Kept well under
%% the 0.5 s at which an FT8 transmission starts, so nothing of the
%% signal is lost.
-define(LATE_TOLERANCE_MS, 250).

-doc "One decoded transmission, as reported by jt9.".
-type decode() :: #{
    time := string(),
    snr := integer(),
    dt := float(),
    freq := integer(),
    message := string()
}.

-export_type([decode/0]).

%%====================================================================
%% Capture
%%====================================================================

-doc #{equiv => capture(wav_dir())}.
-spec capture() -> {ok, file:filename()} | {error, term()}.
capture() ->
    capture(wav_dir()).

-doc """
Wait for the next FT8 cycle boundary, record 15 seconds into `Dir` and
return the path written.
""".
-spec capture(file:name_all()) -> {ok, file:filename()} | {error, term()}.
capture(Dir) ->
    case filelib:ensure_path(Dir) of
        ok ->
            {Start, Duration} = wait_for_cycle(),
            Path = filename:join(Dir, cycle_filename(Start)),
            case sh0tcaller_alsa:capture_radio(Duration, params()) of
                {ok, Audio} ->
                    case sh0tcaller_alsa:write_wav(Path, Audio, params()) of
                        ok -> {ok, Path};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {cannot_create, Dir, Reason}}
    end.

%% Returns {CycleStart, DurationMs}. Normally sleeps until the next
%% multiple of 15 s and records a whole cycle; if a cycle has only just
%% begun, joins it and records the remainder rather than waiting for the
%% next one. Trimming instead of overrunning is what keeps the following
%% capture on the boundary, so the recording never drifts.
wait_for_cycle() ->
    Now = os:system_time(millisecond),
    Elapsed = Now rem ?CYCLE_MS,
    if
        Elapsed =< ?LATE_TOLERANCE_MS ->
            {Now - Elapsed, ?CYCLE_MS - Elapsed};
        true ->
            Next = Now - Elapsed + ?CYCLE_MS,
            timer:sleep(Next - Now),
            {Next, ?CYCLE_MS}
    end.

-doc """
WSJT-X names recordings after the UTC cycle start, and jt9 parses that name
to timestamp its decodes — without it every decode is reported as 000000.
""".
-spec cycle_filename(integer()) -> string().
cycle_filename(Millis) ->
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(Millis, millisecond),
    lists:flatten(io_lib:format("~2..0b~2..0b~2..0b_~2..0b~2..0b~2..0b.wav",
                                [Y rem 100, Mo, D, H, Mi, S])).

%%====================================================================
%% Decode
%%====================================================================

-doc "Decode a 15 second 12 kHz wav file with jt9.".
-spec decode(file:name_all()) -> {ok, [decode()]} | {error, term()}.
decode(Path) ->
    Args = ["-8", "-p", "15",
            "-e", executable_dir(),
            "-a", data_dir(),
            "-t", temp_dir(),
            unicode:characters_to_list(Path)],
    case sh0tcaller_cmd:run(jt9(), Args) of
        {ok, 0, Output} -> {ok, parse(Output)};
        {ok, Status, Output} -> {error, {jt9_failed, Status, Output}};
        {error, _} = Error -> Error
    end.

-doc "Capture one cycle and decode it.".
-spec capture_and_decode(file:name_all()) ->
    {ok, file:filename(), [decode()]} | {error, term()}.
capture_and_decode(Dir) ->
    case capture(Dir) of
        {ok, Path} ->
            case decode(Path) of
                {ok, Decodes} -> {ok, Path, Decodes};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc #{equiv => monitor_cycles(Cycles, wav_dir())}.
-spec monitor_cycles(pos_integer()) -> [term()].
monitor_cycles(Cycles) ->
    monitor_cycles(Cycles, wav_dir()).

-doc """
Capture and decode `Cycles` *consecutive* FT8 cycles.

jt9 takes a few seconds, which is long enough to miss the next cycle
boundary, so decoding runs in a separate process and the capture loop goes
straight back to waiting. Decoding inline here drops every other cycle.
""".
-spec monitor_cycles(pos_integer(), file:name_all()) -> [term()].
monitor_cycles(Cycles, Dir) ->
    [await(Pending) || Pending <- capture_all(Cycles, Dir, [])].

capture_all(0, _Dir, Acc) ->
    lists:reverse(Acc);
capture_all(Remaining, Dir, Acc) ->
    Pending =
        case capture(Dir) of
            {ok, Path} ->
                Self = self(),
                Ref = make_ref(),
                _ = spawn(fun() -> Self ! {Ref, decode(Path)} end),
                {Ref, Path};
            {error, _} = Error ->
                Error
        end,
    capture_all(Remaining - 1, Dir, [Pending | Acc]).

await({error, _} = Error) ->
    Error;
await({Ref, Path}) ->
    receive
        {Ref, {ok, Decodes}} -> {ok, Path, Decodes};
        {Ref, {error, _} = Error} -> Error
    after 60000 ->
        {error, {decode_timeout, Path}}
    end.

%%====================================================================
%% jt9 output
%%====================================================================

%% Decode lines look like:
%%   215400   3  0.1 1669 ~  CQ UA4POO LO65
%% and the run ends with a <DecodeFinished> summary line.
parse(Output) ->
    [Decode || Line <- string:split(Output, "\n", all),
               {ok, Decode} <- [parse_line(string:trim(Line))]].

parse_line(Line) ->
    case string:lexemes(Line, " ") of
        [Time, Snr, Dt, Freq, Sync | Words]
          when Words =/= [], (Sync =:= "~") orelse (Sync =:= "#") ->
            try
                {ok, #{time => Time,
                       snr => list_to_integer(Snr),
                       dt => to_float(Dt),
                       freq => list_to_integer(Freq),
                       message => lists:flatten(lists:join(" ", Words))}}
            catch
                error:badarg -> error
            end;
        _ ->
            error
    end.

to_float(Text) ->
    try list_to_float(Text)
    catch error:badarg -> float(list_to_integer(Text))
    end.

%%====================================================================
%% Configuration
%%====================================================================

params() ->
    #{rate => ?RATE, channels => ?CHANNELS}.

jt9() ->
    env(jt9, filename:join([home(), ".local", "bin", "jt9"])).

executable_dir() ->
    env(jt9_executable_dir, filename:dirname(jt9())).

data_dir() ->
    env(wsjtx_data_dir, filename:join([home(), ".local", "share", "WSJT-X"])).

temp_dir() ->
    env(temp_dir, wav_dir()).

-doc """
Where cycle recordings are written. Defaults to `$HOME/sh0tcaller-wav`,
overridable with the `wav_dir` application env.
""".
-spec wav_dir() -> file:filename().
wav_dir() ->
    env(wav_dir, filename:join(home(), "sh0tcaller-wav")).

env(Key, Default) ->
    case application:get_env(sh0tcaller, Key) of
        {ok, Value} -> Value;
        undefined -> Default
    end.

home() ->
    case os:getenv("HOME") of
        false -> "/tmp";
        Home -> Home
    end.
