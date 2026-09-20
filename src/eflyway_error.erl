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
%% A single error is rendered inline; several are rendered as an indented list
%% under a "N validation errors" header.
-spec format_validation([{atom(), binary()}]) -> binary().
format_validation([{Code, Msg}]) ->
    iolist_to_binary(io_lib:format("~s: ~s", [Code, Msg]));
format_validation(Errors) ->
    Items = [format_validation_item(Code, Msg) || {Code, Msg} <- Errors],
    iolist_to_binary([io_lib:format("~p validation errors", [length(Errors)]), "\n",
                      lists:join("\n", Items)]).

format_validation_item(Code, Msg) ->
    iolist_to_binary(["- ", io_lib:format("~s: ", [Code]),
                      binary:replace(Msg, <<"\n">>, <<"\n  ">>, [global])]).
