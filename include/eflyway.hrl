%% Shared records and types for eflyway.

-ifndef(EFLYWAY_HRL).
-define(EFLYWAY_HRL, true).

%% Parsed database URL.
-record(db_url, {
    type :: mysql | sqlite,
    host :: binary() | undefined,
    port :: non_neg_integer() | undefined,
    database :: binary() | undefined,
    path :: binary() | undefined,
    user :: binary() | undefined,
    password :: binary() | undefined,
    query = #{} :: #{binary() => binary()}
}).

%% Runtime connection handle.
-record(conn, {
    adapter :: module(),
    handle :: term(),
    url :: #db_url{},
    state = #{} :: map()
}).

%% Merged, immutable configuration.
-record(eflyway_config, {
    url :: binary() | undefined,
    user :: binary() | undefined,
    password :: binary() | undefined,
    locations = [<<"filesystem:sql">>] :: [binary()],
    table = <<"flyway_schema_history">> :: binary(),
    schemas = [] :: [binary()],
    default_schema = undefined :: binary() | undefined,
    encoding = utf8 :: utf8 | latin1,
    sql_migration_prefix = <<"V">> :: binary(),
    repeatable_prefix = <<"R">> :: binary(),
    separator = <<"__">> :: binary(),
    suffixes = [<<".sql">>] :: [binary()],
    placeholder_replacement = true :: boolean(),
    placeholder_prefix = <<"${">> :: binary(),
    placeholder_suffix = <<"}">> :: binary(),
    placeholders = #{} :: #{binary() => binary()},
    baseline_version = <<"1">> :: binary(),
    baseline_description = <<"<< Flyway Baseline >>">> :: binary(),
    baseline_on_migrate = false :: boolean(),
    target = undefined :: binary() | undefined,
    out_of_order = false :: boolean(),
    ignore_missing_migrations = false :: boolean(),
    ignore_ignored_migrations = false :: boolean(),
    ignore_pending_migrations = false :: boolean(),
    ignore_future_migrations = true :: boolean(),
    validate_on_migrate = true :: boolean(),
    validate_migration_naming = false :: boolean(),
    clean_on_validation_error = false :: boolean(),
    clean_disabled = false :: boolean(),
    create_schemas = true :: boolean(),
    mixed = false :: boolean(),
    group = false :: boolean(),
    installed_by = undefined :: binary() | undefined,
    connect_retries = 0 :: non_neg_integer(),
    lock_retry_count = 50 :: non_neg_integer(),
    config_files = [] :: [binary()],
    config_file_encoding = utf8 :: utf8 | latin1
}).

-endif.
