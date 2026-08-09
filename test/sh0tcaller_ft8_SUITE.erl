%%%-------------------------------------------------------------------
%% Unit tests for the parts of the FT8 path that need no radio: the
%% WSJT-X filename convention and the jt9 output parser. Both are places
%% where a silent mistake is expensive — a wrong filename makes jt9
%% report every decode as 000000, and a parser that drops lines looks
%% exactly like a quiet band.
%%%-------------------------------------------------------------------

-module(sh0tcaller_ft8_SUITE).

-export([all/0, end_per_testcase/2]).
-export([
         cycle_filename_is_utc/1,
         cycle_filename_zero_pads/1,
         parse_extracts_fields/1,
         parse_ignores_non_decode_lines/1,
         parse_keeps_whole_message/1,
         parse_handles_negative_and_zero_dt/1,
         decode_invokes_jt9_in_ft8_mode/1,
         decode_reports_jt9_failure/1,
         capture_names_the_file_after_the_cycle/1
        ]).

all() ->
    [cycle_filename_is_utc,
     cycle_filename_zero_pads,
     parse_extracts_fields,
     parse_ignores_non_decode_lines,
     parse_keeps_whole_message,
     parse_handles_negative_and_zero_dt,
     decode_invokes_jt9_in_ft8_mode,
     decode_reports_jt9_failure,
     capture_names_the_file_after_the_cycle].

end_per_testcase(_Case, _Config) ->
    meck:unload(),
    ok.

%% 2026-08-08T21:54:00Z
cycle_filename_is_utc(_Config) ->
    "260808_215400.wav" = sh0tcaller_ft8:cycle_filename(1786226040000),
    ok.

%% 2026-01-02T03:04:05Z — every field needs padding to keep the fixed
%% width jt9 expects.
cycle_filename_zero_pads(_Config) ->
    "260102_030405.wav" = sh0tcaller_ft8:cycle_filename(1767323045000),
    ok.

parse_extracts_fields(_Config) ->
    Output =
        "215400   3  0.1 1669 ~  CQ UA4POO LO65                          \n"
        "215400 -14  0.2 1288 ~  CQ ON3ABR JO20                          \n"
        "<DecodeFinished>   0  12        0\n",
    [First, Second] = sh0tcaller_ft8:parse_jt9_output(Output),
    #{time := "215400", snr := 3, dt := 0.1, freq := 1669,
      message := "CQ UA4POO LO65"} = First,
    #{snr := -14, freq := 1288, message := "CQ ON3ABR JO20"} = Second,
    ok.

%% The summary line, blank lines and any stray output must not turn into
%% phantom decodes.
parse_ignores_non_decode_lines(_Config) ->
    Output =
        "\n"
        "<DecodeFinished>   0  12        0\n"
        "ALSA lib pcm.c:8743:(snd_pcm_recover) cannot recovery from overrun\n"
        "not a decode line at all\n",
    [] = sh0tcaller_ft8:parse_jt9_output(Output),
    ok.

%% Messages contain spaces and jt9 appends a confidence marker to some of
%% them; both belong to the message rather than being split off.
parse_keeps_whole_message(_Config) ->
    Output =
        "220630 -16  0.1 1289 ~  CQ ON3ABR JO20 a1\n"
        "224800 -14  0.0  887 ~  DH2RL RR73; PP2CS <...> -22\n",
    [#{message := "CQ ON3ABR JO20 a1"},
     #{message := "DH2RL RR73; PP2CS <...> -22"}] =
        sh0tcaller_ft8:parse_jt9_output(Output),
    ok.

parse_handles_negative_and_zero_dt(_Config) ->
    Output =
        "215415  -3 -0.0 1727 ~  IT9CMZ G7NPW R-16\n"
        "224815  -8 -0.4  512 ~  CR5VP IU8QTW JN70\n",
    [#{dt := First}, #{dt := Second}] = sh0tcaller_ft8:parse_jt9_output(Output),
    true = is_float(First),
    true = (Second < 0.0),
    ok.

%% jt9 is an external binary, so it is mecked here: what matters is that
%% we ask it for FT8 with a 15 second period and hand it the wav.
decode_invokes_jt9_in_ft8_mode(_Config) ->
    Output = "215400   3  0.1 1669 ~  CQ UA4POO LO65\n"
             "<DecodeFinished>   0   1        0\n",
    meck:new(sh0tcaller_cmd, [passthrough]),
    meck:expect(sh0tcaller_cmd, run, fun(_Jt9, Args) ->
        true = lists:member("-8", Args),
        true = lists:member("-p", Args),
        true = lists:member("15", Args),
        "/tmp/cycle.wav" = lists:last(Args),
        {ok, 0, Output}
    end),
    {ok, [#{snr := 3, message := "CQ UA4POO LO65"}]} =
        sh0tcaller_ft8:decode("/tmp/cycle.wav"),
    ok.

%% A non-zero exit carries jt9's own output, which is what explains the
%% failure — swallowing it leaves nothing to debug with.
decode_reports_jt9_failure(_Config) ->
    meck:new(sh0tcaller_cmd, [passthrough]),
    meck:expect(sh0tcaller_cmd, run,
                fun(_, _) -> {ok, 2, "cannot open wav\n"} end),
    {error, {jt9_failed, 2, "cannot open wav\n"}} =
        sh0tcaller_ft8:decode("/tmp/cycle.wav"),
    ok.

%% The name is what jt9 timestamps decodes from, and the cycle it names
%% must be a real FT8 boundary. Takes up to a cycle to run, since it
%% waits for one.
capture_names_the_file_after_the_cycle(Config) ->
    meck:new(sh0tcaller_alsa, [passthrough]),
    meck:expect(sh0tcaller_alsa, capture_radio, fun(DurationMs, _Opts) ->
        %% 12 kHz mono 16-bit is 24 bytes per ms.
        {ok, binary:copy(<<0, 0>>, DurationMs * 12)}
    end),
    Dir = filename:join(proplists:get_value(priv_dir, Config), "cycles"),
    {ok, Path} = sh0tcaller_ft8:capture(Dir),
    Name = filename:basename(Path),
    {match, [Seconds]} =
        re:run(Name, "^\\d{6}_\\d{4}(\\d{2})\\.wav$",
               [{capture, all_but_first, list}]),
    true = lists:member(Seconds, ["00", "15", "30", "45"]),
    true = filelib:is_regular(Path),
    ok.
