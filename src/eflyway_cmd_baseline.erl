%% @doc baseline command.
-module(eflyway_cmd_baseline).

-include("eflyway.hrl").

-export([baseline/2]).

-spec baseline(term(), #eflyway_config{}) -> map().
baseline(Conn, Config) ->
    Version = eflyway_migration_version:from_version(Config#eflyway_config.baseline_version),
    Description = Config#eflyway_config.baseline_description,
    case eflyway_schema_history:exists(Conn, Config) of
        false ->
            do_create(Conn, Config, Version),
            #{successfully_baselined => true,
              baseline_version => eflyway_migration_version:display(Version)};
        true ->
            case eflyway_schema_history:baseline_marker(Conn, Config) of
                undefined -> existing_history(Conn, Config, Version);
                Marker ->
                    MarkerVersion = Marker#applied.version,
                    SameVersion = MarkerVersion =/= undefined
                        andalso eflyway_migration_version:compare(MarkerVersion, Version) =:= eq,
                    case SameVersion andalso Marker#applied.description =:= Description of
                        true ->
                            eflyway_log:info("Schema history table already initialized with (~s, ~s). Skipping.",
                                             [eflyway_migration_version:display(Version), Description]),
                            #{successfully_baselined => true,
                              baseline_version => eflyway_migration_version:display(Version)};
                        false ->
                            eflyway_error:raise(baseline_failed,
                                ["Unable to baseline schema history table with (",
                                 eflyway_migration_version:display(Version), ",", Description,
                                 ") as it has already been baselined with (",
                                 maybe_display(Marker), ",", Marker#applied.description, ")"])
                    end
            end
    end.

do_create(Conn, Config, Version) ->
    InstalledBy = eflyway_db:installed_by(Conn, Config),
    Baseline = #{version => eflyway_migration_version:storage(Version),
                 description => Config#eflyway_config.baseline_description,
                 installed_by => InstalledBy},
    ok = eflyway_schema_history:create(Conn, Config, Baseline),
    eflyway_log:info("Successfully baselined schema with version: ~s",
                     [eflyway_migration_version:display(Version)]).

existing_history(Conn, Config, Version) ->
    Table = eflyway_schema_history:table_name(Config),
    Zero = eflyway_migration_version:compare(Version,
               eflyway_migration_version:from_version(<<"0">>)) =:= eq,
    case eflyway_schema_history:has_schemas_marker(Conn, Config) andalso Zero of
        true ->
            eflyway_error:raise(baseline_failed,
                ["Unable to baseline schema history table ", Table,
                 " with version 0 as this version was used for schema creation"]);
        false ->
            case eflyway_schema_history:has_non_synthetic(Conn, Config) of
                true ->
                    eflyway_error:raise(baseline_failed,
                        ["Unable to baseline schema history table ", Table,
                         " as it already contains migrations"]);
                false ->
                    case eflyway_schema_history:all_applied(Conn, Config) of
                        [] ->
                            eflyway_error:raise(baseline_failed,
                                ["Unable to baseline schema history table ", Table,
                                 " as it already exists, and is empty. Delete the schema history table with clean, and run baseline again."]);
                        _ ->
                            eflyway_error:raise(baseline_failed,
                                ["Unable to baseline schema history table ", Table,
                                 " as it already contains migrations. Delete the schema history table with clean, and run baseline again."])
                    end
            end
    end.

maybe_display(undefined) -> <<"null">>;
maybe_display(#applied{version = V}) -> eflyway_migration_version:display(V).
