%% @doc validate command.
-module(eflyway_cmd_validate).

-include("eflyway.hrl").

-export([validate/3]).

-spec validate(term(), #eflyway_config{}, [#resolved{}]) -> map().
validate(Conn, Config, Resolved) ->
    Schema = eflyway_db:schema_name(Conn, Config),
    case eflyway_db:schema_exists(Conn, Schema) of
        false ->
            case Resolved =/= [] andalso not Config#eflyway_config.ignore_pending_migrations of
                true ->
                    #{validation_successful => false, count => 0,
                      errors => [{schema_does_not_exist,
                                  <<"Schema ", Schema/binary, " doesn't exist yet">>}]};
                false ->
                    #{validation_successful => true, count => 0, errors => []}
            end;
        true ->
            Applied = eflyway_schema_history:all_applied(Conn, Config),
            Infos = eflyway_info_service:refresh(Resolved, Applied, opts(Config)),
            Errors = eflyway_info_service:validate(Infos),
            Successful = Errors =:= [],
            case Successful of
                true ->
                    N = length(Infos),
                    case N of
                        1 -> eflyway_log:info("Successfully validated 1 migration");
                        _ -> eflyway_log:info("Successfully validated ~p migrations", [N])
                    end;
                false ->
                    eflyway_log:error("Migrations have failed validation")
            end,
            #{validation_successful => Successful, count => length(Infos), errors => Errors}
    end.

opts(Config) ->
    #{out_of_order => Config#eflyway_config.out_of_order,
      pending => Config#eflyway_config.ignore_pending_migrations,
      missing => Config#eflyway_config.ignore_missing_migrations,
      ignored => Config#eflyway_config.ignore_ignored_migrations,
      future => Config#eflyway_config.ignore_future_migrations,
      target => target(Config)}.

target(#eflyway_config{target = undefined}) -> undefined;
target(#eflyway_config{target = T}) -> eflyway_migration_version:from_version(T).
