-module(eflyway).

%% API exports
-export([main/1]).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main([]) ->
    getopt:usage(option_spec_list(), escript:script_name());
main(Args) ->
    OptSpecList = option_spec_list(),
    case getopt:parse(OptSpecList, Args) of
        {ok, {Options, NonOptArgs}} ->
            io:format("Options: ~p~n", [Options]),
            io:format("Non-option args: ~p~n", [NonOptArgs]),
            deal_options(Options);
        {error, {Reason, Data}} ->
            io:format("Error: ~s ~p~n", [Reason, Data]),
            getopt:usage(OptSpecList, escript:script_name())
    end.

%%====================================================================
%% Internal functions
%%====================================================================

option_spec_list() ->
    [
        {help, $h, "help", undefined, "Show usage"},
        {user, $u, "user", {string, no_user}, "User to use to connect to the database"}
    ].

deal_options([]) ->
    ok;
deal_options([help|T]) ->
    io:format("Oh! I need help!~n"),
    deal_options(T);
deal_options([_|T]) ->
    deal_options(T).

