-module(eflyway_version_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

v(S) -> eflyway_migration_version:from_version(S).

cmp(A, B) -> eflyway_migration_version:compare(v(A), v(B)).

numeric_order_test() ->
    ?assertEqual(lt, cmp(<<"1">>, <<"2">>)),
    ?assertEqual(lt, cmp(<<"1.9">>, <<"1.10">>)),
    ?assertEqual(lt, cmp(<<"2.0.1">>, <<"2.1">>)),
    ?assertEqual(lt, cmp(<<"1">>, <<"1.0.1">>)),
    ?assertEqual(gt, cmp(<<"10">>, <<"9">>)).

trailing_zeros_test() ->
    ?assertEqual(eq, cmp(<<"1">>, <<"1.0.0">>)),
    ?assertEqual(eq, cmp(<<"1.2">>, <<"1.2.0">>)).

underscore_test() ->
    ?assertEqual(eq, cmp(<<"1_1">>, <<"1.1">>)).

empty_test() ->
    ?assertEqual(lt, eflyway_migration_version:compare(
        eflyway_migration_version:empty(), v(<<"1">>))),
    ?assertEqual(gt, eflyway_migration_version:compare(
        v(<<"1">>), eflyway_migration_version:empty())),
    ?assertEqual(undefined, eflyway_migration_version:storage(
        eflyway_migration_version:empty())).

latest_test() ->
    ?assertEqual(gt, eflyway_migration_version:compare(
        eflyway_migration_version:latest(), v(<<"999999">>))),
    ?assert(eflyway_migration_version:is_latest(v(<<"latest">>))).

current_test() ->
    ?assertEqual(lt, eflyway_migration_version:compare(
        eflyway_migration_version:current(), v(<<"1">>))),
    ?assert(eflyway_migration_version:is_current(v(<<"current">>))).

storage_test() ->
    ?assertEqual(<<"1.2">>, eflyway_migration_version:storage(v(<<"1_2">>))).

invalid_test() ->
    ?assertError({eflyway_error, invalid_version, _, _},
                 eflyway_migration_version:from_version(<<"1.a">>)).
