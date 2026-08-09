%%%-------------------------------------------------------------------
%% Smoke suite: the application starts, the ALSA NIFs load, and the
%% supervision tree comes up in the shape we expect.
%%%-------------------------------------------------------------------

-module(sh0tcaller_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
         app_starts/1,
         alsa_pcm_nif_loads/1,
         alsa_ctl_nif_loads/1,
         supervision_tree_is_inert/1,
         stop_monitor_without_monitor/1,
         monitor_starts_and_stops/1
        ]).

all() ->
    [app_starts,
     alsa_pcm_nif_loads,
     alsa_ctl_nif_loads,
     supervision_tree_is_inert,
     stop_monitor_without_monitor,
     monitor_starts_and_stops].

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
%% raises undef here rather than returning a handle. Deliberately not
%% mecked: mocking alsa_pcm would leave this asserting nothing at all.
%% It skips where there is no sound hardware, such as a CI runner.
alsa_pcm_nif_loads(_Config) ->
    case has_alsa() of
        false ->
            {skip, no_alsa_hardware};
        true ->
            {ok, Pcm} = alsa_pcm:open("default", playback),
            _ = alsa_pcm:close(Pcm),
            ok
    end.

alsa_ctl_nif_loads(_Config) ->
    case has_alsa() of
        false ->
            {skip, no_alsa_hardware};
        true ->
            {ok, Ctl} = alsa_ctl:open("hw:0"),
            _ = alsa_ctl:close(Ctl),
            ok
    end.

has_alsa() ->
    filelib:is_dir("/proc/asound") andalso
        sh0tcaller_alsa:list_capture_cards() =/= [].

%% Starting the application must not start capturing: that would seize
%% the radio from whatever else is using it. The monitor supervisor is
%% present but empty until asked.
supervision_tree_is_inert(_Config) ->
    [{sh0tcaller_ft8_sup, Sup, supervisor, _}] =
        supervisor:which_children(sh0tcaller_sup),
    true = is_pid(Sup),
    [] = supervisor:which_children(sh0tcaller_ft8_sup),
    undefined = whereis(sh0tcaller_ft8_monitor),
    ok.

stop_monitor_without_monitor(_Config) ->
    {error, not_running} = sh0tcaller_ft8_sup:stop_monitor(),
    ok.

%% Runs anywhere: starting and stopping is supervisor bookkeeping, and a
%% capturer that cannot find a radio reports it rather than failing to
%% start. simple_one_for_one children report an id of undefined.
monitor_starts_and_stops(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "cycles"),
    {ok, Pid} = sh0tcaller_ft8_sup:start_monitor(Dir),
    Pid = whereis(sh0tcaller_ft8_monitor),
    [{undefined, Pid, worker, _}] =
        supervisor:which_children(sh0tcaller_ft8_sup),
    ok = sh0tcaller_ft8_sup:stop_monitor(),
    undefined = whereis(sh0tcaller_ft8_monitor),
    [] = supervisor:which_children(sh0tcaller_ft8_sup),
    ok.
