%% @doc Placeholder replacement ("${key}") for SQL scripts and config metadata.
-module(eflyway_placeholder).

-include("eflyway.hrl").

-export([replace/3, builtins/1, map/2]).

%% @doc Replace placeholders in Bin. Builtins/1 supplies the flyway:* values.
-spec replace(binary(), #eflyway_config{}, map()) -> binary().
replace(Bin, #eflyway_config{placeholder_prefix = Prefix, placeholder_suffix = Suffix,
                             placeholders = UserPlaceholders, placeholder_replacement = Enabled},
        Builtins) ->
    case Enabled of
        false -> Bin;
        true ->
            Placeholders = maps:merge(Builtins, UserPlaceholders),
            do_replace(Bin, Prefix, Suffix, Placeholders, [])
    end.

do_replace(Bin, <<>>, _Suffix, _Placeholders, Acc) ->
    iolist_to_binary(lists:reverse([Bin | Acc]));
do_replace(Bin, Prefix, Suffix, Placeholders, Acc) ->
    case binary:match(Bin, Prefix) of
        nomatch ->
            iolist_to_binary(lists:reverse([Bin | Acc]));
        {Pos, PLen} ->
            Before = binary:part(Bin, 0, Pos),
            AfterPrefix = binary:part(Bin, Pos + PLen, byte_size(Bin) - Pos - PLen),
            case binary:match(AfterPrefix, Suffix) of
                nomatch ->
                    iolist_to_binary(lists:reverse([Bin, Before | Acc]));
                {SPos, SLen} ->
                    Key = binary:part(AfterPrefix, 0, SPos),
                    Rest = binary:part(AfterPrefix, SPos + SLen,
                                       byte_size(AfterPrefix) - SPos - SLen),
                    Replacement = case maps:find(Key, Placeholders) of
                                      {ok, Value} -> Value;
                                      error -> <<Prefix/binary, Key/binary, Suffix/binary>>
                                  end,
                    do_replace(Rest, Prefix, Suffix, Placeholders,
                               [Replacement, Before | Acc])
            end
    end.

%% @doc Build the built-in flyway:* placeholder map.
-spec builtins(map()) -> map().
builtins(Ctx) when is_map(Ctx) ->
    maps:fold(fun(K, V, Acc) ->
        case V of
            undefined -> Acc;
            _ -> maps:put(<<"flyway:", K/binary>>, to_bin(V), Acc)
        end
    end, #{}, Ctx).

%% @doc Replace using only the configured placeholders (no built-ins).
-spec map(binary(), #eflyway_config{}) -> binary().
map(Bin, Config) ->
    replace(Bin, Config, #{}).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
