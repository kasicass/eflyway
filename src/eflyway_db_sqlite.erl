%% @doc SQLite3 database adapter (esqlite driver).
-module(eflyway_db_sqlite).
-behaviour(eflyway_db).

-include("eflyway.hrl").

-export([connect/1, disconnect/1,
         execute/2, query/2, query/3,
         transaction/2, lock/3,
         supports_ddl_transactions/0, supports_changing_current_schema/0,
         catalog/1, current_user/1,
         quote/1, boolean_true/0, boolean_false/0,
         create_history_ddl/2,
         dialect/0,
         table_exists/2, all_tables/2,
         schema_exists/2, schema_empty/2,
         create_schema/2, drop_schema/2, clean_schema/2]).

-define(SYSTEM_TABLES, [<<"sqlite_sequence">>, <<"android_metadata">>]).

%% ---------------------------------------------------------------------
%% Connection
%% ---------------------------------------------------------------------

connect(#db_url{path = Path}) ->
    case esqlite3:open(binary_to_list(Path)) of
        {ok, Db} -> {ok, Db};
        {error, Reason} -> {error, {sqlite_open_failed, Path, Reason}}
    end.

disconnect(Db) ->
    _ = catch esqlite3:close(Db),
    ok.

%% ---------------------------------------------------------------------
%% Execution
%% ---------------------------------------------------------------------

execute(Db, Sql) ->
    case esqlite3:exec(Db, sql(Sql)) of
        ok -> ok;
        {error, Reason} -> {error, {sqlite_error, Reason, Sql}}
    end.

query(Db, Sql) ->
    query(Db, Sql, []).

query(Db, Sql, Args) ->
    case esqlite3:prepare(Db, sql(Sql)) of
        {ok, Stmt} ->
            try
                case bind(Stmt, Args) of
                    ok ->
                        Cols = normalize_columns(esqlite3:column_names(Stmt)),
                        case esqlite3:fetchall(Stmt) of
                            {error, Reason} -> {error, {sqlite_error, Reason, Sql}};
                            Rows -> {ok, rows_to_maps(Cols, Rows)}
                        end;
                    {error, Reason} ->
                        {error, {sqlite_error, Reason, Sql}}
                end
            after
                _ = catch esqlite3:reset(Stmt)
            end;
        {error, Reason} ->
            {error, {sqlite_error, Reason, Sql}}
    end.

bind(_Stmt, []) -> ok;
bind(Stmt, Args) -> esqlite3:bind(Stmt, Args).

normalize_columns(Cols) ->
    [to_binary(C) || C <- Cols].

rows_to_maps(Cols, Rows) ->
    [maps:from_list(lists:zip(Cols, Row)) || Row <- Rows].

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L).

sql(B) when is_binary(B) -> B;
sql(L) when is_list(L) -> iolist_to_binary(L).

%% ---------------------------------------------------------------------
%% Transactions and locking
%% ---------------------------------------------------------------------

transaction(Db, Fun) ->
    run(Db, <<"BEGIN">>),
    try
        Result = Fun(),
        run(Db, <<"COMMIT">>),
        Result
    catch
        Class:Reason:Stacktrace ->
            _ = (catch run(Db, <<"ROLLBACK">>)),
            erlang:raise(Class, Reason, Stacktrace)
    end.

run(Db, Sql) ->
    case esqlite3:exec(Db, sql(Sql)) of
        ok -> ok;
        {error, Reason} -> erlang:error({sqlite_error, Reason, Sql})
    end.

%% SQLite has no table level locking; concurrent writes are serialized by the
%% storage engine. Flyway's SQLiteTable.doLock() is likewise a no-op.
lock(_Db, _Table, Fun) ->
    Fun().

%% ---------------------------------------------------------------------
%% Capabilities and metadata
%% ---------------------------------------------------------------------

supports_ddl_transactions() -> true.
supports_changing_current_schema() -> false.

catalog(_Db) -> <<"main">>.
current_user(_Db) -> <<>>.

quote(Identifier) -> <<"\"", Identifier/binary, "\"">>.

boolean_true() -> <<"1">>.
boolean_false() -> <<"0">>.

%% ---------------------------------------------------------------------
%% Schema history DDL
%% ---------------------------------------------------------------------

create_history_ddl(Table, Baseline) ->
    TableQ = quote(Table),
    IndexQ = quote(<<Table/binary, "_s_idx">>),
    Create = iolist_to_binary([
        "CREATE TABLE ", TableQ, " (\n",
        "    \"installed_rank\" INT NOT NULL PRIMARY KEY,\n",
        "    \"version\" VARCHAR(50),\n",
        "    \"description\" VARCHAR(200) NOT NULL,\n",
        "    \"type\" VARCHAR(20) NOT NULL,\n",
        "    \"script\" VARCHAR(1000) NOT NULL,\n",
        "    \"checksum\" INT,\n",
        "    \"installed_by\" VARCHAR(100) NOT NULL,\n",
        "    \"installed_on\" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),\n",
        "    \"execution_time\" INT NOT NULL,\n",
        "    \"success\" BOOLEAN NOT NULL\n",
        ");"
    ]),
    CreateIndex = iolist_to_binary([
        "CREATE INDEX \"main\".", IndexQ, " ON ", TableQ, " (\"success\");"
    ]),
    [Create | baseline_statements(TableQ, Baseline)] ++ [CreateIndex].

baseline_statements(_TableQ, none) ->
    [];
baseline_statements(TableQ, #{version := Version, description := Description, installed_by := InstalledBy}) ->
    [iolist_to_binary([
        "INSERT INTO ", TableQ,
        " (\"installed_rank\", \"version\", \"description\", \"type\", \"script\",",
        " \"checksum\", \"installed_by\", \"execution_time\", \"success\") VALUES (",
        "1, '", escape(Version), "', '", escape(Description), "', 'BASELINE', '",
        escape(Description), "', NULL, '", escape(InstalledBy), "', 0, 1);"
    ])].

dialect() -> eflyway_parser_sqlite:dialect().

escape(Bin) ->
    binary:replace(Bin, <<"'">>, <<"''">>, [global]).

%% ---------------------------------------------------------------------
%% Schema introspection / clean
%% ---------------------------------------------------------------------

table_exists(Db, Table) ->
    Sql = <<"SELECT count(*) AS cnt FROM main.sqlite_master WHERE type='table' AND tbl_name=?">>,
    case query(Db, Sql, [Table]) of
        {ok, [#{<<"cnt">> := N}]} -> N > 0;
        _ -> false
    end.

all_tables(Db, Schema) ->
    Sql = iolist_to_binary(["SELECT tbl_name FROM ", quote(Schema), ".sqlite_master WHERE type='table'"]),
    case query(Db, Sql) of
        {ok, Rows} -> [T || #{<<"tbl_name">> := T} <- Rows];
        _ -> []
    end.

schema_exists(_Db, _Schema) ->
    true.

schema_empty(Db, Schema) ->
    Tables = all_tables(Db, Schema),
    [T || T <- Tables, not lists:member(T, ?SYSTEM_TABLES)] =:= [].

create_schema(_Db, Schema) ->
    eflyway_log:info("SQLite does not support creating schemas. Schema not created: ~s", [Schema]),
    ok.

drop_schema(_Db, Schema) ->
    eflyway_log:info("SQLite does not support dropping schemas. Schema not dropped: ~s", [Schema]),
    ok.

clean_schema(Db, Schema) ->
    SchemaQ = quote(Schema),
    ViewsSql = iolist_to_binary(["SELECT tbl_name FROM ", SchemaQ, ".sqlite_master WHERE type='view'"]),
    Views = case query(Db, ViewsSql) of
                {ok, Rows} -> [V || #{<<"tbl_name">> := V} <- Rows];
                _ -> []
            end,
    lists:foreach(fun(V) ->
        execute(Db, iolist_to_binary(["DROP VIEW ", SchemaQ, ".", quote(V)]))
    end, Views),
    lists:foreach(fun(T) ->
        case lists:member(T, ?SYSTEM_TABLES) of
            true -> ok;
            false -> execute(Db, iolist_to_binary(["DROP TABLE ", SchemaQ, ".", quote(T)]))
        end
    end, all_tables(Db, Schema)),
    ok.
