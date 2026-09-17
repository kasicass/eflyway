%% @doc clean command.
-module(eflyway_cmd_clean).

-include("eflyway.hrl").

-export([clean/2]).

-spec clean(term(), #eflyway_config{}) -> map().
clean(Conn, Config) ->
    case Config#eflyway_config.clean_disabled of
        true ->
            eflyway_error:raise(clean_disabled,
                <<"Unable to execute clean as it has been disabled with the \"flyway.cleanDisabled\" property.">>);
        false ->
            ok
    end,
    Schema = eflyway_db:schema_name(Conn, Config),
    DropSchemas = (catch eflyway_schema_history:has_schemas_marker(Conn, Config)) =:= true,
    eflyway_log:info("Cleaning schema ~s ...", [Schema]),
    case eflyway_db:schema_exists(Conn, Schema) of
        false ->
            eflyway_log:warn("Unable to clean unknown schema: ~s", [Schema]),
            #{schemas_cleaned => [], schemas_dropped => []};
        true ->
            case DropSchemas of
                true ->
                    ok = eflyway_db:drop_schema(Conn, Schema),
                    #{schemas_cleaned => [], schemas_dropped => [Schema]};
                false ->
                    ok = eflyway_db:clean_schema(Conn, Schema),
                    #{schemas_cleaned => [Schema], schemas_dropped => []}
            end
    end.
