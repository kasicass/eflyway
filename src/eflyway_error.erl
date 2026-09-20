%% @doc Unified error helpers.
-module(eflyway_error).

-export([raise/2, raise/3, format/1, format_validation/1, is_error/1]).

-export_type([error/0]).

-type error() :: {eflyway_error, atom(), binary(), map()}.

-spec raise(atom(), iodata()) -> no_return().
raise(Code, Message) ->
    raise(Code, Message, #{}).

-spec raise(atom(), iodata(), map()) -> no_return().
raise(Code, Message, Details) when is_map(Details) ->
    erlang:error({eflyway_error, Code, iolist_to_binary(Message), Details}).

-spec format(term()) -> iolist().
format({eflyway_error, Code, Message, Details}) ->
    case maps:size(Details) of
        0 -> io_lib:format("~s: ~s", [Code, Message]);
        _ -> io_lib:format("~s: ~s (~p)", [Code, Message, Details])
    end;
format(Other) ->
    io_lib:format("~p", [Other]).

-spec is_error(term()) -> boolean().
is_error({eflyway_error, _, _, _}) -> true;
is_error(_) -> false.

%% @doc Format a list of {Code, Message} validation errors.
%% Each message already carries its own "V1: ..." label; errors are rendered as
%% a list under a "N validation error(s)" header.
-spec format_validation([{atom(), binary()}]) -> binary().
format_validation(Errors) ->
    Items = [<<"- ", (indent(Msg))/binary>> || {_Code, Msg} <- Errors],
    iolist_to_binary([header(length(Errors)), "\n", lists:join("\n", Items)]).

header(1) -> <<"1 validation error">>;
header(N) -> io_lib:format("~p validation errors", [N]).

indent(Msg) ->
    binary:replace(Msg, <<"\n">>, <<"\n  ">>, [global]).
