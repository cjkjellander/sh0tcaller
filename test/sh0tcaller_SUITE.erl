%%%-------------------------------------------------------------------
%% @doc Smoke suite: the application starts and the ALSA NIFs load.
%% @end
%%%-------------------------------------------------------------------

-module(sh0tcaller_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([app_starts/1, alsa_pcm_nif_loads/1, alsa_ctl_nif_loads/1]).

all() ->
    [app_starts, alsa_pcm_nif_loads, alsa_ctl_nif_loads].

init_per_suite(Config) ->
    {ok, Started} = application:ensure_all_started(sh0tcaller),
    [{started, Started} | Config].

end_per_suite(Config) ->
    _ = [application:stop(A)
         || A <- lists:reverse(proplists:get_value(started, Config, []))],
    ok.

%% The whole dependency chain comes up, not just the top application.
app_starts(Config) ->
    Started = proplists:get_value(started, Config),
    true = lists:member(sh0tcaller, Started),
    true = lists:member(alsa, Started),
    ok.

%% A successful open proves alsa_pcm_nif.so loaded — an unloaded NIF
%% raises undef here rather than returning a handle.
alsa_pcm_nif_loads(_Config) ->
    {ok, Pcm} = alsa_pcm:open("default", playback),
    _ = alsa_pcm:close(Pcm),
    ok.

alsa_ctl_nif_loads(_Config) ->
    {ok, Ctl} = alsa_ctl:open("hw:0"),
    _ = alsa_ctl:close(Ctl),
    ok.
