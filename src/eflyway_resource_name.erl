%% @doc Migration file name parser.
-module(eflyway_resource_name).

-include("eflyway.hrl").

-export([parse/2, parse/3, is_valid/1]).

-spec parse(binary(), #eflyway_config{}) -> #resource_name{}.
parse(Filename, Config) ->
    parse(Filename, Config, Config#eflyway_config.suffixes).

-spec parse(binary(), #eflyway_config{}, [binary()]) -> #resource_name{}.
parse(Filename, Config, Suffixes) ->
    {NameWithoutSuffix, Suffix} = strip_suffix(Filename, Suffixes),
    Separator = Config#eflyway_config.separator,
    Prefixes = prefixes(Config),
    case find_prefix(NameWithoutSuffix, Prefixes) of
        none ->
            invalid(Filename, <<"Unrecognised migration name format: ", Filename/binary>>);
        {Prefix, ResourceType} ->
            Name = binary:part(NameWithoutSuffix, byte_size(Prefix),
                               byte_size(NameWithoutSuffix) - byte_size(Prefix)),
            {Left, Right} = split_at_separator(Name, Separator),
            {Valid, Message, Version} = validate(ResourceType, Prefix, Separator, Filename, Left, Right, Suffix),
            #resource_name{
                valid = Valid,
                prefix = Prefix,
                version = Version,
                separator = Separator,
                description = binary:replace(Right, <<"_">>, <<" ">>, [global]),
                raw_description = Right,
                suffix = Suffix,
                filename = Filename,
                validation_message = Message
            }
    end.

-spec is_valid(#resource_name{}) -> boolean().
is_valid(#resource_name{valid = V}) -> V.

%% internal

prefixes(#eflyway_config{} = Config) ->
    P = [{Config#eflyway_config.sql_migration_prefix, versioned},
         {Config#eflyway_config.repeatable_prefix, repeatable}],
    lists:sort(fun({A, _}, {B, _}) -> byte_size(A) >= byte_size(B) end, P).

strip_suffix(Filename, Suffixes) ->
    strip_suffix(Filename, Suffixes, Filename).

strip_suffix(_Filename, [], Original) -> {Original, <<>>};
strip_suffix(Filename, [Suffix | Rest], Original) ->
    SLen = byte_size(Suffix),
    case byte_size(Filename) >= SLen
         andalso binary:part(Filename, byte_size(Filename) - SLen, SLen) =:= Suffix of
        true -> {binary:part(Filename, 0, byte_size(Filename) - SLen), Suffix};
        false -> strip_suffix(Filename, Rest, Original)
    end.

find_prefix(_Name, []) -> none;
find_prefix(Name, [{Prefix, Type} | Rest]) ->
    PLen = byte_size(Prefix),
    case Prefix =/= <<>> andalso byte_size(Name) >= PLen
         andalso binary:part(Name, 0, PLen) =:= Prefix of
        true -> {Prefix, Type};
        false -> find_prefix(Name, Rest)
    end.

split_at_separator(Name, Separator) ->
    case binary:match(Name, Separator) of
        {Pos, Len} ->
            {binary:part(Name, 0, Pos),
             binary:part(Name, Pos + Len, byte_size(Name) - Pos - Len)};
        nomatch ->
            {Name, <<>>}
    end.

validate(repeatable, _, _Separator, Filename, Left, _Right, _Suffix) ->
    case Left of
        <<>> -> {true, <<>>, undefined};
        _ ->
            {false, <<"Invalid repeatable migration name format: ", Filename/binary,
                      " (It cannot contain a version.)">>, undefined}
    end;
validate(versioned, _Prefix, _Separator, Filename, Left, _Right, _Suffix) ->
    case Left of
        <<>> ->
            {false, <<"Invalid versioned migration name format: ", Filename/binary,
                      " (It must contain a version.)">>, undefined};
        _ ->
            try eflyway_migration_version:from_version(Left) of
                Version -> {true, <<>>, Version}
            catch
                error:{eflyway_error, _, _, _} ->
                    {false, <<"Invalid versioned migration name format: ", Filename/binary,
                              " (could not recognise version number ", Left/binary, ")">>, undefined}
            end
    end.

invalid(Filename, Message) ->
    #resource_name{valid = false, filename = Filename, validation_message = Message}.
