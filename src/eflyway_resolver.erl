%% @doc SQL migration resolver (file scanning, naming, checksum, parsing).
-module(eflyway_resolver).

-include("eflyway.hrl").

-export([resolve/2, resolve/3]).

-spec resolve(#eflyway_config{}, map()) -> [#resolved{}].
resolve(Config, Dialect) ->
    resolve(Config, Dialect, #{}).

-spec resolve(#eflyway_config{}, map(), map()) -> [#resolved{}].
resolve(Config, Dialect, Builtins) ->
    Resources = eflyway_resource:scan(Config),
    Resolved = lists:filtermap(fun(R) -> resolve_one(R, Config, Dialect, Builtins) end, Resources),
    sort(Resolved).

resolve_one(Resource, Config, Dialect, Builtins) ->
    #resource_name{} = Name = eflyway_resource_name:parse(Resource#resource.filename),
    case Name#resource_name.valid of
        false ->
            case Config#eflyway_config.validate_migration_naming of
                true -> eflyway_error:raise(invalid_migration_name,
                           [Name#resource_name.validation_message]);
                false -> false
            end;
        true ->
            Builtins1 = maps:put(<<"flyway:filename">>, Resource#resource.filename, Builtins),
            Repeatable = Name#resource_name.version =:= undefined,
            {Checksum, Equivalent} = checksums(Resource, Config, Builtins1, Repeatable),
            Script = eflyway_sql_script:parse(Resource, Config, Dialect, Builtins1),
            {true, #resolved{
                version = case Repeatable of true -> undefined; false -> Name#resource_name.version end,
                description = Name#resource_name.description,
                script = Resource#resource.relative,
                checksum = Checksum,
                equivalent_checksum = Equivalent,
                type = sql,
                physical_location = Resource#resource.absolute,
                sql_script = Script,
                resource = Resource
            }}
    end.

checksums(Resource, Config, Builtins, Repeatable) ->
    {ok, Bytes} = file:read_file(Resource#resource.absolute),
    Raw = eflyway_encoding:to_utf8(Bytes, Config#eflyway_config.encoding),
    Replaced = eflyway_placeholder:replace(Raw, Config, Builtins),
    case Repeatable of
        false ->
            {eflyway_checksum:of_binary(Raw), undefined};
        true ->
            case Config#eflyway_config.placeholder_replacement of
                true -> {eflyway_checksum:of_binary(Replaced), eflyway_checksum:of_binary(Raw)};
                false -> {eflyway_checksum:of_binary(Raw), eflyway_checksum:of_binary(Raw)}
            end
    end.

sort(Resolved) ->
    {Versioned, Repeatable} = lists:partition(
        fun(#resolved{version = V}) -> V =/= undefined end, Resolved),
    SortedVersioned = lists:sort(fun cmp_version/2, Versioned),
    SortedRepeatable = lists:sort(fun cmp_description/2, Repeatable),
    SortedVersioned ++ SortedRepeatable.

cmp_version(#resolved{version = A}, #resolved{version = B}) ->
    eflyway_migration_version:compare(A, B) =/= gt.

cmp_description(#resolved{description = A}, #resolved{description = B}) ->
    A =< B.
