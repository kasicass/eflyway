%% @doc eflyway escript entry point.
-module(eflyway).

-export([main/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    %% Keep a crashing linked driver process from killing the CLI.
    process_flag(trap_exit, true),
    maybe_add_deps(),
    halt(eflyway_cli:run(Args)).

%% SQLite is provided by a NIF which cannot be loaded from inside an escript
%% archive. When running from the build tree, add the sibling lib/ directory
%% (containing esqlite and mysql) to the code path so code:priv_dir/1 resolves
%% to a real directory.
maybe_add_deps() ->
    try
        Script = escript:script_name(),
        Root = filename:dirname(filename:dirname(filename:absname(Script))),
        LibDir = filename:join(Root, "lib"),
        case filelib:is_dir(LibDir) of
            true ->
                case file:list_dir(LibDir) of
                    {ok, Apps} ->
                        Paths = [filename:join([LibDir, App, "ebin"])
                                 || App <- Apps,
                                    filelib:is_dir(filename:join([LibDir, App, "ebin"]))],
                        code:add_pathsa(Paths),
                        ok;
                    {error, _} -> ok
                end;
            false -> ok
        end
    catch
        _:_ -> ok
    end.
