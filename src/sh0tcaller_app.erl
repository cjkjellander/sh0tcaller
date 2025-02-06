%%%-------------------------------------------------------------------
%% @doc sh0tcaller public API
%% @end
%%%-------------------------------------------------------------------

-module(sh0tcaller_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    sh0tcaller_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
