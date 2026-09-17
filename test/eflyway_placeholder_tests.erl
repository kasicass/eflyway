-module(eflyway_placeholder_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

cfg() ->
    eflyway_config:apply_map(eflyway_config:defaults(), #{
        <<"placeholders.env">> => <<"dev">>,
        <<"placeholders.owner">> => <<"app">>
    }).

replace_test() ->
    ?assertEqual(<<"t_dev">>, eflyway_placeholder:replace(<<"t_${env}">>, cfg(), #{})).

multiple_test() ->
    ?assertEqual(<<"dev-app">>, eflyway_placeholder:replace(<<"${env}-${owner}">>, cfg(), #{})).

unknown_kept_test() ->
    ?assertEqual(<<"${nope}">>, eflyway_placeholder:replace(<<"${nope}">>, cfg(), #{})).

builtins_test() ->
    B = #{<<"flyway:defaultSchema">> => <<"main">>},
    ?assertEqual(<<"main.t">>,
                 eflyway_placeholder:replace(<<"${flyway:defaultSchema}.t">>, cfg(), B)).

disabled_test() ->
    C = (eflyway_config:defaults())#eflyway_config{placeholder_replacement = false},
    ?assertEqual(<<"${env}">>, eflyway_placeholder:replace(<<"${env}">>, C, #{})).
