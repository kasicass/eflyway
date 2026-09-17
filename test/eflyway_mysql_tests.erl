-module(eflyway_mysql_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

create_ddl_test() ->
    Ddl = eflyway_db_mysql:create_history_ddl(<<"flyway_schema_history">>, none),
    ?assertEqual(2, length(Ddl)),
    [Create, Index] = Ddl,
    ?assertMatch({_, _}, binary:match(Create, <<"ENGINE=InnoDB">>)),
    ?assertMatch({_, _}, binary:match(Create, <<"`flyway_schema_history_pk`">>)),
    ?assertMatch({_, _}, binary:match(Index, <<"flyway_schema_history_s_idx">>)).

create_ddl_with_baseline_test() ->
    Baseline = #{version => <<"1">>, description => <<"base">>, installed_by => <<"me">>},
    [Create, Insert, Index] = eflyway_db_mysql:create_history_ddl(<<"t">>, Baseline),
    ?assertMatch({_, _}, binary:match(Create, <<"CREATE TABLE">>)),
    ?assertMatch({_, _}, binary:match(Insert, <<"BASELINE">>)),
    ?assertMatch({_, _}, binary:match(Insert, <<"'base'">>)),
    ?assertMatch({_, _}, binary:match(Index, <<"CREATE INDEX">>)).

quote_test() ->
    ?assertEqual(<<"`a`">>, eflyway_db_mysql:quote(<<"a">>)),
    ?assertEqual(<<"1">>, eflyway_db_mysql:boolean_true()),
    ?assertEqual(<<"0">>, eflyway_db_mysql:boolean_false()),
    ?assertEqual(false, eflyway_db_mysql:supports_ddl_transactions()).

dialect_test() ->
    D = eflyway_db_mysql:dialect(),
    ?assertEqual($", maps:get(alt_string_quote, D)),
    ?assertEqual(true, maps:get(backslash_escapes, D)),
    ?assertEqual(true, maps:get(delimiter_directive, D)).

%% Integration tests only run when EFLYWAY_MYSQL_URL is set, e.g.
%%   EFLYWAY_MYSQL_URL=mysql://root:secret@127.0.0.1:3306/eflyway_test
mysql_integration_test_() ->
    case os:getenv("EFLYWAY_MYSQL_URL") of
        false -> [];
        UrlStr ->
            {setup,
             fun() -> setup_integration(UrlStr) end,
             fun cleanup_integration/1,
             fun({Dir, Config}) -> [?_test(run_integration(Dir, Config))] end}
    end.

setup_integration(UrlStr) ->
    Dir = filename:join("/tmp", "eflyway_mysql_src_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "V1__init.sql"), <<"CREATE TABLE a (id INT);">>),
    ok = file:write_file(filename:join(Dir, "V2__more.sql"), <<"CREATE TABLE b (id INT);">>),
    Config = (eflyway_config:defaults())#eflyway_config{
        url = unicode:characters_to_binary(UrlStr),
        locations = [<<"filesystem:", (unicode:characters_to_binary(Dir))/binary>>]
    },
    _ = (catch eflyway_flyway:clean(Config)),
    {Dir, Config}.

cleanup_integration({Dir, Config}) ->
    _ = (catch eflyway_flyway:clean(Config)),
    file:del_dir_r(Dir),
    ok.

run_integration(_Dir, Config) ->
    eflyway_log:set_level(warn),
    try
        Result = eflyway_flyway:migrate(Config),
        ?assertEqual(2, maps:get(migrations_executed, Result)),
        Validate = eflyway_flyway:validate(Config),
        ?assert(maps:get(validation_successful, Validate)),
        Again = eflyway_flyway:migrate(Config),
        ?assertEqual(0, maps:get(migrations_executed, Again))
    after
        eflyway_log:set_level(info)
    end.
