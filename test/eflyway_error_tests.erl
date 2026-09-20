-module(eflyway_error_tests).

-include_lib("eunit/include/eunit.hrl").

format_validation_single_test() ->
    ?assertEqual(<<"checksum_mismatch: boom">>,
                 eflyway_error:format_validation([{checksum_mismatch, <<"boom">>}])).

format_validation_multiple_test() ->
    Out = eflyway_error:format_validation(
        [{checksum_mismatch, <<"one\ntwo">>},
         {resolved_versioned_migration_not_applied, <<"three">>}]),
    ?assertEqual(
        <<"2 validation errors\n"
          "- checksum_mismatch: one\n"
          "  two\n"
          "- resolved_versioned_migration_not_applied: three">>,
        Out).
