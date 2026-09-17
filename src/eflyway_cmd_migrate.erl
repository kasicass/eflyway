%% @doc migrate command.
-module(eflyway_cmd_migrate).

-include("eflyway.hrl").

-export([migrate/3]).

-spec migrate(term(), #eflyway_config{}, [#resolved{}]) -> map().
migrate(Conn, Config, Resolved) ->
    ensure_history(Conn, Config),
    Total = migrate_all(Conn, Config, Resolved, 0),
    case Total of
        0 -> eflyway_log:info("Schema ~s is up to date. No migration necessary.",
                              [schema_name(Conn, Config)]);
        1 -> eflyway_log:info("Successfully applied 1 migration to schema ~s",
                              [schema_name(Conn, Config)]);
        N -> eflyway_log:info("Successfully applied ~p migrations to schema ~s",
                              [N, schema_name(Conn, Config)])
    end,
    #{migrations_executed => Total}.

%% ---------------------------------------------------------------------
%% History bootstrap
%% ---------------------------------------------------------------------

ensure_history(Conn, Config) ->
    case eflyway_schema_history:exists(Conn, Config) of
        true -> ok;
        false ->
            Schema = schema_name(Conn, Config),
            case eflyway_db:schema_empty(Conn, Schema) of
                true -> create_history(Conn, Config);
                false ->
                    case Config#eflyway_config.baseline_on_migrate of
                        true -> do_baseline(Conn, Config);
                        false ->
                            eflyway_error:raise(non_empty_schema_no_history,
                                ["Found non-empty schema \"", Schema,
                                 "\" but no schema history table. Use baseline() or set",
                                 " baselineOnMigrate to true to initialize the schema history table."])
                    end
            end
    end.

create_history(Conn, Config) ->
    case Config#eflyway_config.create_schemas of
        true -> ok; %% SQLite has no schemas; MySQL handled by the adapter
        false ->
            eflyway_log:warn("The configuration option 'createSchemas' is false. "
                             "The schema history table still needs a schema to reside in.")
    end,
    eflyway_log:info("Creating Schema History table ~s ...",
                     [eflyway_schema_history:table_name(Config)]),
    ok = eflyway_schema_history:create(Conn, Config, none).

do_baseline(Conn, Config) ->
    Version = eflyway_migration_version:from_version(Config#eflyway_config.baseline_version),
    InstalledBy = eflyway_db:installed_by(Conn, Config),
    Baseline = #{version => eflyway_migration_version:storage(Version),
                 description => Config#eflyway_config.baseline_description,
                 installed_by => InstalledBy},
    ok = eflyway_schema_history:create(Conn, Config, Baseline),
    eflyway_log:info("Successfully baselined schema with version: ~s",
                     [eflyway_migration_version:display(Version)]).

%% ---------------------------------------------------------------------
%% Migration loop
%% ---------------------------------------------------------------------

migrate_all(Conn, Config, Resolved, Total) ->
    Count = eflyway_schema_history:lock(Conn, Config,
        fun() -> migrate_group(Conn, Config, Resolved) end),
    case Count of
        0 -> Total;
        _ -> migrate_all(Conn, Config, Resolved, Total + Count)
    end.

migrate_group(Conn, Config, Resolved) ->
    Applied = eflyway_schema_history:all_applied(Conn, Config),
    Infos = eflyway_info_service:refresh(Resolved, Applied, opts(Config)),
    log_current(Conn, Config, Infos),
    case eflyway_info_service:failed(Infos) of
        [Failed | _] -> raise_failed(Conn, Config, Failed);
        [] -> ok
    end,
    case eflyway_info_service:pending(Infos) of
        [] -> 0;
        [First | _] ->
            apply_migration(Conn, Config, First),
            1
    end.

opts(Config) ->
    #{out_of_order => Config#eflyway_config.out_of_order,
      pending => true,
      missing => true,
      ignored => true,
      future => true,
      target => target(Config)}.

target(#eflyway_config{target = undefined}) -> undefined;
target(#eflyway_config{target = T}) -> eflyway_migration_version:from_version(T).

log_current(Conn, Config, Infos) ->
    case eflyway_info_service:current(Infos) of
        undefined ->
            eflyway_log:info("Current version of schema ~s: << Empty Schema >>",
                             [schema_name(Conn, Config)]);
        Info ->
            V = info_version(Info),
            eflyway_log:info("Current version of schema ~s: ~s",
                             [schema_name(Conn, Config), eflyway_migration_version:display(V)])
    end.

info_version(#migration_info{resolved = undefined, applied = A}) -> A#applied.version;
info_version(#migration_info{resolved = R}) -> R#resolved.version.

raise_failed(Conn, Config, #migration_info{applied = A}) ->
    case A#applied.version of
        undefined ->
            eflyway_error:raise(failed_repeatable_migration,
                ["Schema ", schema_name(Conn, Config), " contains a failed repeatable migration (",
                 A#applied.description, ") !"]);
        V ->
            eflyway_error:raise(failed_versioned_migration,
                ["Schema ", schema_name(Conn, Config), " contains a failed migration to version ",
                 eflyway_migration_version:display(V), " !"])
    end.

%% ---------------------------------------------------------------------
%% Applying a single migration
%% ---------------------------------------------------------------------

apply_migration(Conn, Config, #migration_info{resolved = R}) ->
    Script = R#resolved.sql_script,
    Text = migration_text(Conn, Config, R),
    InTx = eflyway_db:supports_ddl_transactions(Conn)
        andalso eflyway_sql_script:executes_in_transaction(Script),
    eflyway_log:info("Migrating ~s", [Text]),
    Start = erlang:monotonic_time(millisecond),
    try
        case InTx of
            true -> eflyway_db:transaction(Conn,
                        fun(C) -> eflyway_sql_script:execute(C, Script) end);
            false -> eflyway_sql_script:execute(Conn, Script)
        end,
        Elapsed = elapsed(Start),
        ok = eflyway_schema_history:add_applied(Conn, Config,
            R#resolved.version, R#resolved.description, R#resolved.type,
            R#resolved.script, R#resolved.checksum, Elapsed, true)
    catch
        Class:Reason:Stacktrace ->
            case InTx of
                true -> ok; %% transaction rolled back already
                false ->
                    FailureTime = elapsed(Start),
                    _ = catch eflyway_schema_history:add_applied(Conn, Config,
                        R#resolved.version, R#resolved.description, R#resolved.type,
                        R#resolved.script, R#resolved.checksum, FailureTime, false)
            end,
            erlang:raise(Class, Reason, Stacktrace)
    end.

elapsed(Start) ->
    erlang:monotonic_time(millisecond) - Start.

migration_text(Conn, Config, R) ->
    Schema = schema_name(Conn, Config),
    case R#resolved.version of
        undefined ->
            iolist_to_binary(["schema \"", Schema, "\" with repeatable migration \"",
                              R#resolved.description, "\""]);
        V ->
            iolist_to_binary(["schema \"", Schema, "\" to version \"",
                              eflyway_migration_version:display(V), " - ",
                              R#resolved.description, "\""])
    end.

schema_name(Conn, Config) ->
    eflyway_db:schema_name(Conn, Config).
