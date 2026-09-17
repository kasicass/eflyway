%% @doc eflyway escript entry point.
%%
%% Full CLI wiring lands in a later phase; for now this exposes the version
%% and usage so the escript can be built and smoke tested.
-module(eflyway).

-export([main/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    case Args of
        [] ->
            print_usage(),
            halt(0);
        ["-?"] ->
            print_usage(),
            halt(0);
        ["-v"] ->
            io:format("eflyway 0.1.0~n"),
            halt(0);
        _ ->
            io:format(standard_error, "eflyway: CLI not implemented yet: ~p~n", [Args]),
            halt(2)
    end.

print_usage() ->
    io:format("Usage~n"),
    io:format("=====~n~n"),
    io:format("eflyway [options] command~n~n"),
    io:format("Commands~n"),
    io:format("--------~n"),
    io:format("migrate  : Migrates the database~n"),
    io:format("clean    : Drops all objects in the configured schemas~n"),
    io:format("info     : Prints the information about applied, current and pending migrations~n"),
    io:format("validate : Validates the applied migrations against the ones on disk~n"),
    io:format("baseline : Baselines an existing database at the baselineVersion~n"),
    io:format("repair   : Repairs the schema history table~n").
