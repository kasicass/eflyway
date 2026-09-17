%% @doc MySQL database adapter (mysql-otp driver).
-module(eflyway_db_mysql).
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
         server_info/1,
         table_exists/2, all_tables/2,
         schema_exists/2, schema_empty/2,
         create_schema/2, drop_schema/2, clean_schema/2]).

%% ---------------------------------------------------------------------
%% Connection
%% ---------------------------------------------------------------------

connect(#db_url{host = Host, port = Port, user = User, password = Password,
                database = Database}) ->
    Opts = [{host, host(Host)},
            {port, port(Port)},
            {user, str(User)},
            {password, str(Password)},
            {database, str(Database)},
            {connect_timeout, 10000}],
    case mysql:start_link(Opts) of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} -> {error, {mysql_connect_failed, Reason}};
        ignore -> {error, {mysql_connect_failed, ignore}}
    end.

disconnect(Conn) ->
    _ = catch mysql:stop(Conn),
    ok.

host(undefined) -> "localhost";
host(Bin) -> binary_to_list(Bin).

port(undefined) -> 3306;
port(P) -> P.

str(undefined) -> <<>>;
str(Bin) when is_binary(Bin) -> Bin.

%% ---------------------------------------------------------------------
%% Execution
%% ---------------------------------------------------------------------

execute(Conn, Sql) ->
    case mysql:query(Conn, Sql) of
        ok -> ok;
        {ok, _Cols, _Rows} -> ok;
        {error, Reason} -> {error, {mysql_error, Reason}}
    end.

query(Conn, Sql) ->
    query(Conn, Sql, []).

query(Conn, Sql, []) ->
    to_result(mysql:query(Conn, Sql));
query(Conn, Sql, Args) ->
    to_result(mysql:query(Conn, Sql, normalize_args(Args))).

%% mysql-otp encodes SQL NULL as the atom `null' (not `undefined').
normalize_args(Args) -> [normalize_arg(A) || A <- Args].

normalize_arg(undefined) -> null;
normalize_arg(A) -> A.

to_result(ok) -> {ok, []};
to_result({ok, Cols, Rows}) -> {ok, rows_to_maps(Cols, Rows)};
to_result({error, Reason}) -> {error, {mysql_error, Reason}}.

rows_to_maps(Cols, Rows) ->
    Bins = [to_bin(C) || C <- Cols],
    [maps:from_list(lists:zip(Bins, Row)) || Row <- Rows].

%% ---------------------------------------------------------------------
%% Transactions and locking
%% ---------------------------------------------------------------------

transaction(Conn, Fun) ->
    case mysql:transaction(Conn, Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> erlang:error({mysql_transaction_aborted, Reason})
    end.

lock(Conn, Table, Fun) ->
    Name = "Flyway-" ++ integer_to_list(erlang:phash2(Table)),
    acquire(Conn, Name),
    try
        Fun()
    after
        _ = query(Conn, <<"SELECT RELEASE_LOCK(?) AS r">>, [list_to_binary(Name)])
    end.

acquire(Conn, Name) ->
    Sql = <<"SELECT GET_LOCK(?, 10) AS l">>,
    case query(Conn, Sql, [list_to_binary(Name)]) of
        {ok, [#{<<"l">> := 1}]} -> ok;
        _ ->
            timer:sleep(100),
            acquire(Conn, Name)
    end.

%% ---------------------------------------------------------------------
%% Capabilities and metadata
%% ---------------------------------------------------------------------

supports_ddl_transactions() -> false.
supports_changing_current_schema() -> true.

catalog(Conn) ->
    case query(Conn, <<"SELECT DATABASE() AS db">>) of
        {ok, [#{<<"db">> := Db}]} when Db =/= null -> to_bin(Db);
        _ -> <<>>
    end.

current_user(Conn) ->
    case query(Conn, <<"SELECT SUBSTRING_INDEX(USER(),'@',1) AS u">>) of
        {ok, [#{<<"u">> := U}]} -> to_bin(U);
        _ -> <<>>
    end.

quote(Identifier) -> <<"`", Identifier/binary, "`">>.
boolean_true() -> <<"1">>.
boolean_false() -> <<"0">>.

dialect() -> eflyway_parser_mysql:dialect().

%% Flyway reports the MySQL product name even when connected to MariaDB.
server_info(Conn) ->
    case query(Conn, <<"SELECT VERSION() AS v">>) of
        {ok, [#{<<"v">> := V}]} -> {<<"MySQL">>, major_minor(to_bin(V))};
        _ -> {<<"MySQL">>, <<>>}
    end.

major_minor(Bin) ->
    case re:run(Bin, "^([0-9]+)\\.([0-9]+)", [{capture, [1, 2], binary}]) of
        {match, [Maj, Min]} -> <<Maj/binary, ".", Min/binary>>;
        _ -> <<>>
    end.

%% ---------------------------------------------------------------------
%% Schema history DDL
%% ---------------------------------------------------------------------

create_history_ddl(Table, Baseline) ->
    TableQ = quote(Table),
    Constraint = <<"`", Table/binary, "_pk`">>,
    Create = iolist_to_binary([
        "CREATE TABLE ", TableQ, " (\n",
        "    `installed_rank` INT NOT NULL,\n",
        "    `version` VARCHAR(50),\n",
        "    `description` VARCHAR(200) NOT NULL,\n",
        "    `type` VARCHAR(20) NOT NULL,\n",
        "    `script` VARCHAR(1000) NOT NULL,\n",
        "    `checksum` INT,\n",
        "    `installed_by` VARCHAR(100) NOT NULL,\n",
        "    `installed_on` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,\n",
        "    `execution_time` INT NOT NULL,\n",
        "    `success` BOOL NOT NULL,\n",
        "    CONSTRAINT ", Constraint, " PRIMARY KEY (`installed_rank`)\n",
        ") ENGINE=InnoDB;"
    ]),
    CreateIndex = iolist_to_binary([
        "CREATE INDEX `", Table, "_s_idx` ON ", TableQ, " (`success`);"
    ]),
    [Create | baseline_statements(TableQ, Baseline)] ++ [CreateIndex].

baseline_statements(_TableQ, none) ->
    [];
baseline_statements(TableQ, #{version := Version, description := Description, installed_by := InstalledBy}) ->
    [iolist_to_binary([
        "INSERT INTO ", TableQ,
        " (`installed_rank`, `version`, `description`, `type`, `script`,",
        " `checksum`, `installed_by`, `execution_time`, `success`) VALUES (",
        "1, '", escape(Version), "', '", escape(Description), "', 'BASELINE', '",
        escape(Description), "', NULL, '", escape(InstalledBy), "', 0, 1);"
    ])].

escape(Bin) -> binary:replace(Bin, <<"'">>, <<"''">>, [global]).

%% ---------------------------------------------------------------------
%% Schema introspection / clean
%% ---------------------------------------------------------------------

table_exists(Conn, Table) ->
    Sql = <<"SELECT count(*) AS cnt FROM information_schema.tables"
            " WHERE table_schema = DATABASE() AND table_name = ?">>,
    case query(Conn, Sql, [Table]) of
        {ok, [#{<<"cnt">> := N}]} -> N > 0;
        _ -> false
    end.

all_tables(Conn, Schema) ->
    Sql = <<"SELECT table_name AS t FROM information_schema.tables"
            " WHERE table_schema = ? AND table_type IN ('BASE TABLE', 'SYSTEM VERSIONED')">>,
    case query(Conn, Sql, [Schema]) of
        {ok, Rows} -> [T || #{<<"t">> := T} <- Rows];
        _ -> []
    end.

schema_exists(Conn, Schema) ->
    Sql = <<"SELECT count(*) AS cnt FROM information_schema.schemata WHERE schema_name = ?">>,
    case query(Conn, Sql, [Schema]) of
        {ok, [#{<<"cnt">> := N}]} -> N > 0;
        _ -> false
    end.

schema_empty(Conn, Schema) ->
    Sql = <<"SELECT ("
            "(SELECT count(*) FROM information_schema.tables WHERE table_schema = ?) + "
            "(SELECT count(*) FROM information_schema.views WHERE table_schema = ?) + "
            "(SELECT count(*) FROM information_schema.routines WHERE routine_schema = ?) + "
            "(SELECT count(*) FROM information_schema.triggers WHERE event_object_schema = ?)"
            ") AS cnt">>,
    case query(Conn, Sql, [Schema, Schema, Schema, Schema]) of
        {ok, [#{<<"cnt">> := N}]} -> N =:= 0;
        _ -> true
    end.

create_schema(Conn, Schema) ->
    expect_ok(Conn, iolist_to_binary(["CREATE SCHEMA ", quote(Schema)])).

drop_schema(Conn, Schema) ->
    expect_ok(Conn, iolist_to_binary(["DROP SCHEMA ", quote(Schema)])).

clean_schema(Conn, Schema) ->
    clean_views(Conn, Schema),
    clean_routines(Conn, Schema),
    ok = expect_ok(Conn, <<"SET FOREIGN_KEY_CHECKS = 0">>),
    try
        lists:foreach(fun(T) ->
            expect_ok(Conn, iolist_to_binary(["DROP TABLE ", quote(Schema), ".", quote(T)]))
        end, all_tables(Conn, Schema))
    after
        _ = expect_ok(Conn, <<"SET FOREIGN_KEY_CHECKS = 1">>)
    end.

clean_views(Conn, Schema) ->
    Sql = <<"SELECT table_name AS t FROM information_schema.views WHERE table_schema = ?">>,
    case query(Conn, Sql, [Schema]) of
        {ok, Rows} ->
            lists:foreach(fun(#{<<"t">> := V}) ->
                expect_ok(Conn, iolist_to_binary(["DROP VIEW ", quote(Schema), ".", quote(V)]))
            end, Rows);
        _ -> ok
    end.

clean_routines(Conn, Schema) ->
    Sql = <<"SELECT routine_name AS n, routine_type AS t FROM information_schema.routines"
            " WHERE routine_schema = ?">>,
    case query(Conn, Sql, [Schema]) of
        {ok, Rows} ->
            lists:foreach(fun(#{<<"n">> := N, <<"t">> := T}) ->
                expect_ok(Conn, iolist_to_binary(["DROP ", T, " ", quote(Schema), ".", quote(N)]))
            end, Rows);
        _ -> ok
    end.

expect_ok(Conn, Sql) ->
    case execute(Conn, Sql) of
        ok -> ok;
        {error, Reason} -> eflyway_error:raise(mysql_ddl_failed, [Sql], #{reason => Reason})
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
