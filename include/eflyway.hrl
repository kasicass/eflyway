%% Shared records and types for eflyway.

-ifndef(EFLYWAY_HRL).
-define(EFLYWAY_HRL, true).

%% Fixed migration naming convention (not configurable):
%%   V<version>__<description>.sql   (versioned)
%%   R__<description>.sql            (repeatable)
-define(SQL_MIGRATION_PREFIX, <<"V">>).
-define(REPEATABLE_PREFIX, <<"R">>).
-define(MIGRATION_SEPARATOR, <<"__">>).
-define(MIGRATION_SUFFIXES, [<<".sql">>]).

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

%% A migration version. kind: empty | latest | current | numeric.
-record(mversion, {
    kind = numeric :: empty | latest | current | numeric,
    parts = [] :: [non_neg_integer()],
    display = <<>> :: binary()
}).

%% A file discovered on disk.
-record(resource, {
    absolute :: binary(),
    relative :: binary(),
    filename :: binary()
}).

%% Result of parsing a migration file name.
-record(resource_name, {
    valid = false :: boolean(),
    prefix :: binary() | undefined,
    version :: #mversion{} | undefined,
    separator :: binary() | undefined,
    description = <<>> :: binary(),
    raw_description = <<>> :: binary(),
    suffix = <<>> :: binary(),
    filename = <<>> :: binary(),
    validation_message = <<>> :: binary()
}).

%% A single SQL statement produced by the parser.
-record(statement, {
    sql :: binary(),
    line = 1 :: non_neg_integer(),
    can_execute_in_transaction = true :: boolean()
}).

%% A parsed SQL script.
-record(sql_script, {
    resource :: #resource{} | undefined,
    statements = [] :: [#statement{}],
    executes_in_transaction = true :: boolean()
}).

%% A migration resolved from disk.
-record(resolved, {
    version :: #mversion{} | undefined,
    description = <<>> :: binary(),
    script = <<>> :: binary(),
    checksum :: integer() | undefined,
    equivalent_checksum :: integer() | undefined,
    type = sql :: atom(),
    physical_location = <<>> :: binary(),
    sql_script :: #sql_script{} | undefined,
    resource :: #resource{} | undefined
}).

%% A migration applied to the database (row in the schema history table).
-record(applied, {
    installed_rank :: integer(),
    version :: #mversion{} | undefined,
    description = <<>> :: binary(),
    type = sql :: atom(),
    script = <<>> :: binary(),
    checksum :: integer() | undefined,
    installed_on :: binary() | undefined,
    installed_by :: binary() | undefined,
    execution_time = 0 :: non_neg_integer(),
    success = true :: boolean()
}).

%% Context used to compute migration states.
-record(mi_context, {
    out_of_order = false :: boolean(),
    pending = true :: boolean(),
    missing = true :: boolean(),
    ignored = true :: boolean(),
    future = true :: boolean(),
    target :: #mversion{} | undefined,
    baseline :: #mversion{},
    schema :: #mversion{},
    last_resolved :: #mversion{},
    last_applied :: #mversion{},
    latest_repeatable_runs = #{} :: #{binary() => integer()}
}).

%% Aggregated view of one migration.
-record(migration_info, {
    resolved :: #resolved{} | undefined,
    applied :: #applied{} | undefined,
    out_of_order = false :: boolean(),
    deleted = false :: boolean(),
    context :: #mi_context{} | undefined
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
    placeholder_replacement = true :: boolean(),
    placeholder_prefix = <<"${">> :: binary(),
    placeholder_suffix = <<"}">> :: binary(),
    placeholders = #{} :: #{binary() => binary()},
    baseline_version = <<"1">> :: binary(),
    baseline_description = <<"<< Baseline >>">> :: binary(),
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
