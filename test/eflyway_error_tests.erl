-module(eflyway_error_tests).

-include_lib("eunit/include/eunit.hrl").

format_validation_single_test() ->
    Msg = <<"Version 1: migration checksum mismatch">>,
    ?assertEqual(Msg, eflyway_error:format_validation([{checksum_mismatch, Msg}])).

format_validation_multiple_test() ->
    Out = eflyway_error:format_validation(
        [{checksum_mismatch,
          <<"Version 1: migration checksum mismatch\n-> Applied to database : 1">>},
         {resolved_versioned_migration_not_applied,
          <<"Version 3: detected resolved migration not applied to database">>}]),
    ?assertEqual(
        <<"2 validation errors\n"
          "- Version 1: migration checksum mismatch\n"
          "  -> Applied to database : 1\n"
          "- Version 3: detected resolved migration not applied to database">>,
        Out).
