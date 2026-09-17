-module(eflyway_parser_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

sqlite(Bin) -> eflyway_parser_sqlite:parse(Bin).
mysql(Bin) -> eflyway_parser_mysql:parse(Bin).

sqls(Stmts) -> [S#statement.sql || S <- Stmts].

simple_two_statements_test() ->
    ?assertEqual([<<"SELECT 1">>, <<"SELECT 2">>], sqls(sqlite(<<"SELECT 1; SELECT 2;">>))).

no_trailing_delimiter_test() ->
    ?assertEqual([<<"SELECT 1">>], sqls(sqlite(<<"SELECT 1">>))).

semicolon_in_string_test() ->
    ?assertEqual([<<"INSERT INTO t VALUES ('a;b')">>],
                 sqls(sqlite(<<"INSERT INTO t VALUES ('a;b');">>))).

doubled_quote_test() ->
    ?assertEqual([<<"INSERT INTO t VALUES ('it''s ok')">>],
                 sqls(sqlite(<<"INSERT INTO t VALUES ('it''s ok');">>))).

line_comment_test() ->
    ?assertEqual([<<"SELECT 1">>], sqls(sqlite(<<"-- a comment\nSELECT 1;">>))).

block_comment_with_semicolon_test() ->
    ?assertEqual([<<"SELECT /* ; */ 1">>], sqls(sqlite(<<"SELECT /* ; */ 1;">>))).

comments_inside_statement_kept_test() ->
    ?assertEqual([<<"SELECT 1 -- trailing">>], sqls(sqlite(<<"SELECT 1 -- trailing\n;">>))).

parens_semicolon_test() ->
    ?assertEqual([<<"SELECT f(a;b)">>], sqls(sqlite(<<"SELECT f(a;b);">>))).

sqlite_trigger_block_test() ->
    Sql = <<"CREATE TRIGGER t AFTER INSERT ON x BEGIN\n  UPDATE y SET a = 1;\nEND;">>,
    ?assertEqual([<<"CREATE TRIGGER t AFTER INSERT ON x BEGIN\n  UPDATE y SET a = 1;\nEND">>],
                 sqls(sqlite(Sql))).

sqlite_case_end_test() ->
    Sql = <<"SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t;">>,
    ?assertEqual([<<"SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t">>], sqls(sqlite(Sql))).

pragma_not_transactional_test() ->
    [S] = sqlite(<<"PRAGMA foreign_keys = ON;">>),
    ?assertEqual(false, S#statement.can_execute_in_transaction).

pragma_read_test() ->
    [S] = sqlite(<<"PRAGMA foreign_keys;">>),
    ?assertEqual(false, S#statement.can_execute_in_transaction).

mysql_delimiter_test() ->
    Sql = <<"DELIMITER $$\n"
            "CREATE PROCEDURE p()\n"
            "BEGIN\n"
            "  SELECT 1;\n"
            "END$$\n"
            "DELIMITER ;\n"
            "SELECT 2;\n">>,
    ?assertEqual(2, length(mysql(Sql))).

mysql_hash_comment_test() ->
    ?assertEqual([<<"SELECT 1">>], sqls(mysql(<<"# comment\nSELECT 1;">>))).

mysql_backslash_escape_test() ->
    ?assertEqual([<<"SELECT 'a\\'b'">>], sqls(mysql(<<"SELECT 'a\\'b';">>))).

line_numbers_test() ->
    [S1, S2] = sqlite(<<"SELECT 1;\n\nSELECT 2;">>),
    ?assertEqual(1, S1#statement.line),
    ?assertEqual(3, S2#statement.line).
