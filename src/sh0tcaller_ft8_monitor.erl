-module(sh0tcaller_ft8_monitor).

-moduledoc """
Continuously capture FT8 cycles and print decodes to stdout.

Capturing blocks for a whole 15 second cycle and decoding takes seconds
more, so neither runs in the server process: a linked capturer loops over
cycles and hands back paths, and each decode runs in its own short-lived
process. The server only routes results and prints, so it stays
responsive, no cycle is missed while a decode is in flight, and a decoder
that crashes takes nothing with it.
""".

-behaviour(gen_server).

-export([start_link/1, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-doc "Start monitoring, writing cycle recordings into `Dir`.".
-spec start_link(file:name_all()) -> {ok, pid()} | {error, term()}.
start_link(Dir) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Dir, []).

-doc "Stop monitoring.".
-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

%%====================================================================
%% gen_server
%%====================================================================

-doc false.
init(Dir) ->
    process_flag(trap_exit, true),
    Server = self(),
    Capturer = spawn_link(fun() -> capture_loop(Server, Dir) end),
    io:format("~nMonitoring FT8, recordings in ~ts~n", [Dir]),
    io:format("   UTC   dB    DT    Hz  message~n"),
    {ok, #{dir => Dir, capturer => Capturer, decoders => #{}}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info({captured, Path}, #{decoders := Decoders} = State) ->
    Server = self(),
    {_Pid, Ref} = spawn_monitor(fun() ->
        Server ! {decoded, Path, sh0tcaller_ft8:decode(Path)}
    end),
    {noreply, State#{decoders := Decoders#{Ref => Path}}};

handle_info({decoded, Path, {ok, Decodes}}, State) ->
    print(Path, Decodes),
    {noreply, State};

handle_info({decoded, Path, {error, Reason}}, State) ->
    io:format("~s  decode failed: ~p~n", [label(Path), Reason]),
    {noreply, State};

handle_info({capture_failed, Reason}, State) ->
    io:format("capture failed: ~p~n", [Reason]),
    {noreply, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #{decoders := Decoders} = State) ->
    case maps:take(Ref, Decoders) of
        {Path, Remaining} ->
            report_decoder_exit(Path, Reason),
            {noreply, State#{decoders := Remaining}};
        error ->
            {noreply, State}
    end;

handle_info({'EXIT', Capturer, Reason}, #{capturer := Capturer} = State) ->
    {stop, {capturer_stopped, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, _State) ->
    io:format("Stopped monitoring FT8~n"),
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% capture/1 waits for the next cycle boundary before recording, so a
%% failing radio paces this loop at one attempt per cycle rather than
%% spinning.
capture_loop(Server, Dir) ->
    case sh0tcaller_ft8:capture(Dir) of
        {ok, Path} -> Server ! {captured, Path};
        {error, Reason} -> Server ! {capture_failed, Reason}
    end,
    capture_loop(Server, Dir).

print(Path, []) ->
    io:format("~s  --- no decodes ---~n", [label(Path)]);
print(_Path, Decodes) ->
    lists:foreach(fun(#{time := Time, snr := Snr, dt := Dt,
                        freq := Freq, message := Message}) ->
        io:format("~6s ~4b ~5.1f ~5b  ~ts~n", [Time, Snr, Dt, Freq, Message])
    end, Decodes).

report_decoder_exit(_Path, normal) ->
    ok;
report_decoder_exit(Path, Reason) ->
    io:format("~s  decoder crashed: ~p~n", [label(Path), Reason]).

label(Path) ->
    filename:basename(Path, ".wav").
