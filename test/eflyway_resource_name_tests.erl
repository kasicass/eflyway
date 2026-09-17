-module(eflyway_resource_name_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

cfg() -> eflyway_config:defaults().

versioned_test() ->
    N = eflyway_resource_name:parse(<<"V1__init.sql">>, cfg()),
    ?assert(N#resource_name.valid),
    ?assertEqual(<<"V">>, N#resource_name.prefix),
    ?assertEqual(<<"init">>, N#resource_name.description),
    ?assertEqual(eq, eflyway_migration_version:compare(
        N#resource_name.version, eflyway_migration_version:from_version(<<"1">>))).

versioned_dotted_test() ->
    N = eflyway_resource_name:parse(<<"V2.1.3__add_index.sql">>, cfg()),
    ?assert(N#resource_name.valid),
    ?assertEqual(eq, eflyway_migration_version:compare(
        N#resource_name.version, eflyway_migration_version:from_version(<<"2.1.3">>))).

versioned_underscore_test() ->
    N = eflyway_resource_name:parse(<<"V1_1__create_user.sql">>, cfg()),
    ?assert(N#resource_name.valid),
    ?assertEqual(<<"create user">>, N#resource_name.description).

repeatable_test() ->
    N = eflyway_resource_name:parse(<<"R__create_view.sql">>, cfg()),
    ?assert(N#resource_name.valid),
    ?assertEqual(<<"R">>, N#resource_name.prefix),
    ?assertEqual(undefined, N#resource_name.version),
    ?assertEqual(<<"create view">>, N#resource_name.description).

invalid_missing_version_test() ->
    N = eflyway_resource_name:parse(<<"V__init.sql">>, cfg()),
    ?assertNot(N#resource_name.valid).

invalid_unrecognised_test() ->
    N = eflyway_resource_name:parse(<<"foo.sql">>, cfg()),
    ?assertNot(N#resource_name.valid).

invalid_version_test() ->
    N = eflyway_resource_name:parse(<<"V1.a__init.sql">>, cfg()),
    ?assertNot(N#resource_name.valid).
