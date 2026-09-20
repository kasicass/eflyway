-module(eflyway_error_tests).

-include_lib("eunit/include/eunit.hrl").

format_validation_single_test() ->
    Msg = <<"V1: migration checksum mismatch">>,
    ?assertEqual(<<"1 validation error\n- V1: migration checksum mismatch">>,
                 eflyway_error:format_validation([{checksum_mismatch, Msg}])).

format_validation_multiple_test() ->
    Out = eflyway_error:format_validation(
        [{checksum_mismatch,
          <<"V1: migration checksum mismatch\n-> Applied to database : 1">>},
         {resolved_versioned_migration_not_applied,
          <<"V3: detected resolved migration not applied to database">>}]),
    ?assertEqual(
        <<"2 validation errors\n"
          "- V1: migration checksum mismatch\n"
          "  -> Applied to database : 1\n"
          "- V3: detected resolved migration not applied to database">>,
        Out).
