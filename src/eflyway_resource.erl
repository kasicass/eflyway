%% @doc Recursively scan migration locations on the local filesystem.
-module(eflyway_resource).

-include("eflyway.hrl").

-export([scan/1, scan_location/1]).

-spec scan(#eflyway_config{}) -> [#resource{}].
scan(#eflyway_config{locations = Locations}) ->
    All = lists:flatmap(fun(Location) -> scan_location(Location) end, Locations),
    Filtered = [R || R <- All, has_suffix(R#resource.filename, ?MIGRATION_SUFFIXES)],
    dedup(Filtered).

-spec scan_location(binary()) -> [#resource{}].
scan_location(Location) ->
    Path = strip_prefix(Location),
    Root = filename:absname(binary_to_list(Path)),
    case filelib:is_dir(Root) of
        true -> lists:sort(walk(Root, Root, []));
        false -> []
    end.

strip_prefix(<<"filesystem:", Rest/binary>>) -> Rest;
strip_prefix(Other) -> Other.

walk(Dir, Root, Acc) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foldl(fun(Entry, A) ->
                Full = filename:join(Dir, Entry),
                case filelib:is_dir(Full) of
                    true -> walk(Full, Root, A);
                    false ->
                        case filelib:is_regular(Full) of
                            true -> [to_resource(Full, Root) | A];
                            false -> A
                        end
                end
            end, Acc, Entries);
        {error, _} ->
            Acc
    end.

to_resource(Full, Root) ->
    Abs = filename:absname(Full),
    Relative = relative_path(Abs, Root),
    #resource{absolute = unicode:characters_to_binary(Abs),
              relative = unicode:characters_to_binary(Relative),
              filename = unicode:characters_to_binary(filename:basename(Abs))}.

relative_path(Abs, Root) ->
    Prefix = Root ++ "/",
    case lists:prefix(Prefix, Abs) of
        true -> lists:nthtail(length(Prefix), Abs);
        false -> filename:basename(Abs)
    end.

has_suffix(Filename, Suffixes) ->
    lists:any(fun(Suffix) ->
        SLen = byte_size(Suffix),
        byte_size(Filename) >= SLen
            andalso binary:part(Filename, byte_size(Filename) - SLen, SLen) =:= Suffix
    end, Suffixes).

dedup(Resources) ->
    Map = lists:foldl(fun(R, Acc) -> maps:put(R#resource.absolute, R, Acc) end, #{}, Resources),
    lists:sort(maps:values(Map)).
