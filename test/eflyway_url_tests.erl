-module(eflyway_url_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

mysql_basic_test() ->
    {ok, Url} = eflyway_url:parse(<<"mysql://user:pass@127.0.0.1:3306/mydb">>),
    ?assertEqual(mysql, Url#db_url.type),
    ?assertEqual(<<"127.0.0.1">>, Url#db_url.host),
    ?assertEqual(3306, Url#db_url.port),
    ?assertEqual(<<"mydb">>, Url#db_url.database),
    ?assertEqual(<<"user">>, Url#db_url.user),
    ?assertEqual(<<"pass">>, Url#db_url.password).

mysql_default_port_test() ->
    {ok, Url} = eflyway_url:parse(<<"mysql://user:pass@localhost/mydb">>),
    ?assertEqual(3306, Url#db_url.port),
    ?assertEqual(<<"mydb">>, Url#db_url.database).

mysql_no_credentials_test() ->
    {ok, Url} = eflyway_url:parse(<<"mysql://localhost:3307/db">>),
    ?assertEqual(undefined, Url#db_url.user),
    ?assertEqual(undefined, Url#db_url.password).

sqlite_absolute_test() ->
    {ok, Url} = eflyway_url:parse(<<"sqlite3:///abs/path/app.db">>),
    ?assertEqual(sqlite, Url#db_url.type),
    ?assertEqual(<<"/abs/path/app.db">>, Url#db_url.path).

sqlite_relative_test() ->
    {ok, Url} = eflyway_url:parse(<<"sqlite3:./data/app.db">>),
    ?assertEqual(<<"./data/app.db">>, Url#db_url.path).

sqlite_host_path_test() ->
    {ok, Url} = eflyway_url:parse(<<"sqlite3://data/app.db">>),
    ?assertEqual(<<"data/app.db">>, Url#db_url.path).

sqlite_memory_rejected_test() ->
    ?assertMatch({error, {in_memory_not_supported, _}},
                 eflyway_url:parse(<<"sqlite3::memory:">>)).

unsupported_scheme_test() ->
    ?assertEqual({error, {unsupported_url_scheme, <<"postgres">>}},
                 eflyway_url:parse(<<"postgres://host/db">>)).
