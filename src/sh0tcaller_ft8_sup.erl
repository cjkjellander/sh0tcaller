-module(sh0tcaller_ft8_sup).

-moduledoc """
Supervises FT8 monitors.

`simple_one_for_one` so that monitoring is an explicit action: starting
the application must not start capturing, because that would seize the
radio from anything else using it — and the test suite starts the
application.
""".

-behaviour(supervisor).

-export([start_link/0, start_monitor/0, start_monitor/1, stop_monitor/0]).
-export([init/1]).

-define(SERVER, ?MODULE).
-define(MONITOR, sh0tcaller_ft8_monitor).

-doc false.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc #{equiv => start_monitor(sh0tcaller_ft8:wav_dir())}.
-spec start_monitor() -> {ok, pid()} | {error, term()}.
start_monitor() ->
    start_monitor(sh0tcaller_ft8:wav_dir()).

-doc """
Start continuously capturing and decoding FT8 cycles, printing each
decode to stdout as it is produced.
""".
-spec start_monitor(file:name_all()) -> {ok, pid()} | {error, term()}.
start_monitor(Dir) ->
    supervisor:start_child(?SERVER, [Dir]).

-doc "Stop the running monitor.".
-spec stop_monitor() -> ok | {error, term()}.
stop_monitor() ->
    case whereis(?MONITOR) of
        undefined -> {error, not_running};
        Pid -> supervisor:terminate_child(?SERVER, Pid)
    end.

-doc false.
init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 3,
                 period => 60},
    Monitor = #{id => ?MONITOR,
                start => {?MONITOR, start_link, []},
                restart => transient,
                shutdown => 5000,
                type => worker},
    {ok, {SupFlags, [Monitor]}}.
