-module(eflyway_config_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

defaults_test() ->
    C = eflyway_config:defaults(),
    ?assertEqual(<<"flyway_schema_history">>, C#eflyway_config.table),
    ?assertEqual(<<"V">>, C#eflyway_config.sql_migration_prefix),
    ?assertEqual(<<"R">>, C#eflyway_config.repeatable_prefix),
    ?assertEqual(<<"__">>, C#eflyway_config.separator),
    ?assertEqual([<<".sql">>], C#eflyway_config.suffixes),
    ?assertEqual(<<"1">>, C#eflyway_config.baseline_version),
    ?assertEqual(true, C#eflyway_config.validate_on_migrate),
    ?assertEqual(true, C#eflyway_config.placeholder_replacement),
    ?assertEqual(50, C#eflyway_config.lock_retry_count).

apply_basic_test() ->
    C = eflyway_config:apply_map(eflyway_config:defaults(), #{
        <<"url">> => <<"sqlite3:///tmp/x.db">>,
        <<"table">> => <<"my_history">>,
        <<"schemas">> => <<"a,b , c">>
    }),
    ?assertEqual(<<"sqlite3:///tmp/x.db">>, C#eflyway_config.url),
    ?assertEqual(<<"my_history">>, C#eflyway_config.table),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], C#eflyway_config.schemas).

apply_booleans_test() ->
    C = eflyway_config:apply_map(eflyway_config:defaults(), #{
        <<"outOfOrder">> => <<"true">>,
        <<"cleanDisabled">> => <<"TRUE">>,
        <<"baselineOnMigrate">> => <<"false">>
    }),
    ?assertEqual(true, C#eflyway_config.out_of_order),
    ?assertEqual(true, C#eflyway_config.clean_disabled),
    ?assertEqual(false, C#eflyway_config.baseline_on_migrate).

apply_placeholders_test() ->
    C = eflyway_config:apply_map(eflyway_config:defaults(), #{
        <<"placeholders.env">> => <<"dev">>,
        <<"placeholders.owner">> => <<"app">>
    }),
    ?assertEqual(#{<<"env">> => <<"dev">>, <<"owner">> => <<"app">>},
                 C#eflyway_config.placeholders).

load_cli_overrides_test() ->
    {ok, C} = eflyway_config:load(#{
        <<"url">> => <<"sqlite3:///tmp/y.db">>,
        <<"locations">> => <<"filesystem:sql,filesystem:extra">>
    }),
    ?assertEqual(<<"sqlite3:///tmp/y.db">>, C#eflyway_config.url),
    ?assertEqual([<<"filesystem:sql">>, <<"filesystem:extra">>], C#eflyway_config.locations).

parse_conf_test() ->
    %% exercise the internal parser through a temp config file
    Path = tmp_file("conf"),
    ok = file:write_file(Path, <<
        "# a comment\n"
        "flyway.url=mysql://u:p@h/db\n"
        "flyway.baselineVersion=2.1\n"
        "flyway.placeholders.env=prod\n"
        "flyway.cleanDisabled=true\n"
    >>),
    Conf = parse_file(Path),
    ?assertEqual(<<"mysql://u:p@h/db">>, maps:get(<<"url">>, Conf)),
    ?assertEqual(<<"2.1">>, maps:get(<<"baselineVersion">>, Conf)),
    ?assertEqual(<<"prod">>, maps:get(<<"placeholders.env">>, Conf)),
    ?assertEqual(<<"true">>, maps:get(<<"cleanDisabled">>, Conf)),
    file:delete(Path).

%% Read back through the public loader by pointing configFiles at the file.
parse_file(Path) ->
    {ok, C} = eflyway_config:load(#{<<"configFiles">> => list_to_binary(Path)}),
    %% Convert relevant fields back into a map for assertion convenience.
    #{<<"url">> => C#eflyway_config.url,
      <<"baselineVersion">> => C#eflyway_config.baseline_version,
      <<"placeholders.env">> => maps:get(<<"env">>, C#eflyway_config.placeholders, undefined),
      <<"cleanDisabled">> => atom_to_binary(C#eflyway_config.clean_disabled, utf8)}.

tmp_file(Suffix) ->
    filename:join("/tmp", "eflyway_conf_" ++ integer_to_list(erlang:unique_integer([positive])) ++ "." ++ Suffix).
