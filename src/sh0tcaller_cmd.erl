-module(sh0tcaller_cmd).

-moduledoc """
Run an external command and collect its output.

Uses `open_port/2` with `spawn_executable` rather than `os:cmd/1`, so
arguments are passed as a list and never re-parsed by a shell, and so the
exit status is available.
""".

-export([run/2, run/3]).

-define(TIMEOUT, 60000).

-doc "Run `Command` with `Args`, waiting up to 60 seconds for it to finish.".
-spec run(string(), [string()]) ->
    {ok, non_neg_integer(), string()} | {error, term()}.
run(Command, Args) ->
    run(Command, Args, ?TIMEOUT).

-doc """
Run `Command` with `Args` and return `{ok, ExitStatus, Output}`.

`Command` may be an absolute path or a name to look up on PATH. Standard
error is folded into the output.
""".
-spec run(string(), [string()], timeout()) ->
    {ok, non_neg_integer(), string()} | {error, term()}.
run(Command, Args, Timeout) ->
    case executable(Command) of
        {ok, Path} ->
            Port = open_port({spawn_executable, Path},
                             [{args, Args}, binary, exit_status,
                              stderr_to_stdout, hide]),
            collect(Port, [], Timeout);
        {error, _} = Error ->
            Error
    end.

executable(Command) ->
    case filelib:is_regular(Command) of
        true ->
            {ok, Command};
        false ->
            case os:find_executable(Command) of
                false -> {error, {command_not_found, Command}};
                Path -> {ok, Path}
            end
    end.

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc], Timeout);
        {Port, {exit_status, Status}} ->
            Output = binary_to_list(iolist_to_binary(lists:reverse(Acc))),
            {ok, Status, Output}
    after Timeout ->
        try port_close(Port)
        catch error:badarg -> ok
        end,
        {error, timeout}
    end.
