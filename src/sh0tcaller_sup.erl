-module(sh0tcaller_sup).

-moduledoc "Top level supervisor.".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-doc false.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc false.
init([]) ->
    %% The generated defaults were one_for_all with intensity 0, meaning
    %% any child crash brought the whole application down. Now that real
    %% workers live here, restart the failing subtree instead.
    SupFlags = #{strategy => one_for_one,
                 intensity => 3,
                 period => 60},
    ChildSpecs = [#{id => sh0tcaller_ft8_sup,
                    start => {sh0tcaller_ft8_sup, start_link, []},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor}],
    {ok, {SupFlags, ChildSpecs}}.
