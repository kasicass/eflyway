-module(eflyway_sqlite_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

sqlite_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun connect_and_execute/1,
      fun query_rows/1,
      fun parameterized_query/1,
      fun transaction_commit/1,
      fun transaction_rollback/1,
      fun history_ddl/1,
      fun schema_introspection/1,
      fun clean_schema/1]}.

setup() ->
    Path = filename:join("/tmp", "eflyway_sqlite_"
                         ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    PathBin = unicode:characters_to_binary(Path),
    {ok, Url} = eflyway_url:parse(<<"sqlite3://", PathBin/binary>>),
    {ok, Conn} = eflyway_db:connect(Url),
    {Conn, Path}.

cleanup({Conn, Path}) ->
    eflyway_db:disconnect(Conn),
    file:delete(Path),
    ok.

connect_and_execute({Conn, _}) ->
    fun() ->
        ?assertEqual(ok, eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER, name TEXT)">>)),
        ?assertEqual(ok, eflyway_db:execute(Conn, <<"INSERT INTO t VALUES (1, 'a')">>)),
        ?assertEqual(true, eflyway_db:table_exists(Conn, <<"t">>))
    end.

query_rows({Conn, _}) ->
    fun() ->
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER, name TEXT)">>),
        ok = eflyway_db:execute(Conn, <<"INSERT INTO t VALUES (1, 'a'), (2, 'b')">>),
        {ok, Rows} = eflyway_db:query(Conn, <<"SELECT id, name FROM t ORDER BY id">>),
        ?assertEqual([#{<<"id">> => 1, <<"name">> => <<"a">>},
                      #{<<"id">> => 2, <<"name">> => <<"b">>}], Rows)
    end.

parameterized_query({Conn, _}) ->
    fun() ->
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER, name TEXT)">>),
        ok = eflyway_db:execute(Conn, <<"INSERT INTO t VALUES (1, 'a'), (2, 'b')">>),
        {ok, Rows} = eflyway_db:query(Conn, <<"SELECT name FROM t WHERE id = ?">>, [2]),
        ?assertEqual([#{<<"name">> => <<"b">>}], Rows)
    end.

transaction_commit({Conn, _}) ->
    fun() ->
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER)">>),
        ok = eflyway_db:transaction(Conn, fun(C) ->
            ok = eflyway_db:execute(C, <<"INSERT INTO t VALUES (1)">>),
            ok
        end),
        {ok, [#{<<"cnt">> := 1}]} = eflyway_db:query(Conn, <<"SELECT count(*) AS cnt FROM t">>)
    end.

transaction_rollback({Conn, _}) ->
    fun() ->
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER)">>),
        ?assertThrow(boom, eflyway_db:transaction(Conn, fun(C) ->
            ok = eflyway_db:execute(C, <<"INSERT INTO t VALUES (1)">>),
            throw(boom)
        end)),
        {ok, [#{<<"cnt">> := 0}]} = eflyway_db:query(Conn, <<"SELECT count(*) AS cnt FROM t">>)
    end.

history_ddl({Conn, _}) ->
    fun() ->
        ?assertEqual(false, eflyway_db:table_exists(Conn, <<"flyway_schema_history">>)),
        lists:foreach(fun(S) ->
            ok = eflyway_db:execute(Conn, S)
        end, eflyway_db:create_history_ddl(Conn, <<"flyway_schema_history">>, none)),
        ?assertEqual(true, eflyway_db:table_exists(Conn, <<"flyway_schema_history">>))
    end.

schema_introspection({Conn, _}) ->
    fun() ->
        ?assertEqual(true, eflyway_db:schema_exists(Conn, <<"main">>)),
        ?assertEqual(true, eflyway_db:schema_empty(Conn, <<"main">>)),
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE t (id INTEGER)">>),
        ?assertEqual([<<"t">>], eflyway_db:all_tables(Conn, <<"main">>)),
        ?assertEqual(false, eflyway_db:schema_empty(Conn, <<"main">>))
    end.

clean_schema({Conn, _}) ->
    fun() ->
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE a (id INTEGER)">>),
        ok = eflyway_db:execute(Conn, <<"CREATE TABLE b (id INTEGER)">>),
        ok = eflyway_db:execute(Conn, <<"CREATE VIEW v AS SELECT id FROM a">>),
        ok = eflyway_db:clean_schema(Conn, <<"main">>),
        ?assertEqual([], eflyway_db:all_tables(Conn, <<"main">>))
    end.
