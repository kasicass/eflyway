-module(eflyway_migrate_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

migrate_sqlite_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        write(Dir, "V2__add_b.sql", <<"CREATE TABLE b (id INTEGER);">>),
        write(Dir, "R__view.sql", <<"CREATE VIEW v AS SELECT id FROM a;">>),
        Config = config(Dir, Db),

        Result = eflyway_flyway:migrate(Config),
        ?assertEqual(3, maps:get(migrations_executed, Result)),

        with_conn(Config, fun(Conn) ->
            ?assert(eflyway_db:table_exists(Conn, <<"a">>)),
            ?assert(eflyway_db:table_exists(Conn, <<"b">>)),
            ?assertEqual(3, count(Conn, <<"flyway_schema_history">>))
        end),

        %% Idempotent
        Result2 = eflyway_flyway:migrate(Config),
        ?assertEqual(0, maps:get(migrations_executed, Result2)),

        %% Changed repeatable migration is re-applied
        write(Dir, "R__view.sql", <<"CREATE VIEW v2 AS SELECT id FROM a;">>),
        Result3 = eflyway_flyway:migrate(Config),
        ?assertEqual(1, maps:get(migrations_executed, Result3)),

        with_conn(Config, fun(Conn) ->
            ?assertEqual(4, count(Conn, <<"flyway_schema_history">>))
        end)
    end).

ensure_history_on_first_migrate_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        Config = config(Dir, Db),
        ?assertNot(history_exists(Config)),
        eflyway_flyway:migrate(Config),
        ?assert(history_exists(Config))
    end).

%% helpers

config(Dir, Db) ->
    (eflyway_config:defaults())#eflyway_config{
        url = <<"sqlite3://", (to_bin(Db))/binary>>,
        locations = [<<"filesystem:", (to_bin(Dir))/binary>>]
    }.

history_exists(Config) ->
    with_conn(Config, fun(Conn) ->
        eflyway_db:table_exists(Conn, <<"flyway_schema_history">>)
    end).

with_conn(Config, Fun) ->
    {ok, Url} = eflyway_url:parse(Config#eflyway_config.url),
    {ok, Conn} = eflyway_db:connect(Url),
    try Fun(Conn)
    after eflyway_db:disconnect(Conn)
    end.

count(Conn, Table) ->
    {ok, Rows} = eflyway_db:query(Conn,
        iolist_to_binary(["SELECT count(*) AS cnt FROM ", eflyway_db:quote(Conn, Table)])),
    [Row] = Rows,
    maps:get(<<"cnt">>, Row).

write(Dir, Name, Content) ->
    ok = file:write_file(filename:join(Dir, Name), Content).

with_env(Fun) ->
    Dir = filename:join("/tmp", "eflyway_mig_src_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    Db = filename:join("/tmp", "eflyway_mig_db_"
                       ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    ok = file:make_dir(Dir),
    eflyway_log:set_level(warn),
    try Fun(Dir, Db)
    after
        file:del_dir_r(Dir),
        file:delete(Db),
        eflyway_log:set_level(info)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
