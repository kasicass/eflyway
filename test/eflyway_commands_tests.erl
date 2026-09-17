-module(eflyway_commands_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

validate_after_migrate_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        Config = config(Dir, Db),
        eflyway_flyway:migrate(Config),
        Result = eflyway_flyway:validate(Config),
        ?assert(maps:get(validation_successful, Result))
    end).

repair_fixes_checksum_mismatch_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        Config = config(Dir, Db),
        eflyway_flyway:migrate(Config),
        %% tamper with the applied script
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER, x TEXT);">>),
        ?assertError({eflyway_error, validate_error, _, _},
                     eflyway_flyway:validate(Config)),
        Repair = eflyway_flyway:repair(Config),
        ?assert(maps:get(aligned, Repair) >= 1),
        Result = eflyway_flyway:validate(Config),
        ?assert(maps:get(validation_successful, Result))
    end).

baseline_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        Config = config(Dir, Db),
        %% Pre-existing, non-empty schema with no history table.
        with_conn(Config, fun(Conn) ->
            ok = eflyway_db:execute(Conn, <<"CREATE TABLE legacy (id INTEGER)">>)
        end),
        ?assertError({eflyway_error, non_empty_schema_no_history, _, _},
                     eflyway_flyway:migrate(Config)),
        BaselineResult = eflyway_flyway:baseline(Config),
        ?assert(maps:get(successfully_baselined, BaselineResult)),
        %% V1 <= baselineVersion 1, so nothing is applied.
        Migrate = eflyway_flyway:migrate(Config),
        ?assertEqual(0, maps:get(migrations_executed, Migrate))
    end).

clean_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        Config = config(Dir, Db),
        eflyway_flyway:migrate(Config),
        with_conn(Config, fun(Conn) ->
            ?assert(eflyway_db:table_exists(Conn, <<"a">>))
        end),
        Clean = eflyway_flyway:clean(Config),
        ?assertEqual([<<"main">>], maps:get(schemas_cleaned, Clean)),
        with_conn(Config, fun(Conn) ->
            ?assertNot(eflyway_db:table_exists(Conn, <<"a">>)),
            ?assertNot(eflyway_db:table_exists(Conn, <<"flyway_schema_history">>))
        end)
    end).

clean_disabled_test() ->
    with_env(fun(Dir, Db) ->
        Config = (config(Dir, Db))#eflyway_config{clean_disabled = true},
        ?assertError({eflyway_error, clean_disabled, _, _},
                     eflyway_flyway:clean(Config))
    end).

info_states_test() ->
    with_env(fun(Dir, Db) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        write(Dir, "V2__more.sql", <<"CREATE TABLE b (id INTEGER);">>),
        Config = config(Dir, Db),
        eflyway_flyway:migrate(Config),
        Infos = eflyway_flyway:info(Config),
        States = [eflyway_info_service:state(I) || I <- Infos],
        ?assertEqual([success, success], States)
    end).

%% helpers

config(Dir, Db) ->
    (eflyway_config:defaults())#eflyway_config{
        url = <<"sqlite3://", (to_bin(Db))/binary>>,
        locations = [<<"filesystem:", (to_bin(Dir))/binary>>]
    }.

with_conn(Config, Fun) ->
    {ok, Url} = eflyway_url:parse(Config#eflyway_config.url),
    {ok, Conn} = eflyway_db:connect(Url),
    try Fun(Conn)
    after eflyway_db:disconnect(Conn)
    end.

write(Dir, Name, Content) ->
    ok = file:write_file(filename:join(Dir, Name), Content).

with_env(Fun) ->
    Dir = filename:join("/tmp", "eflyway_cmd_src_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    Db = filename:join("/tmp", "eflyway_cmd_db_"
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
