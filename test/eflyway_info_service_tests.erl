-module(eflyway_info_service_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

-define(EMPTY, eflyway_migration_version:empty()).

resolved(V, Desc) -> resolved(V, Desc, undefined).
resolved(V, Desc, Checksum) ->
    #resolved{version = ver(V), description = Desc,
              checksum = Checksum, type = sql}.

applied(Rank, V, Desc, Type, Checksum, Success) ->
    #applied{installed_rank = Rank, version = ver(V), description = Desc,
             type = Type, checksum = Checksum, success = Success}.

ver(undefined) -> undefined;
ver(V) -> eflyway_migration_version:from_version(V).

refresh(Resolved, Applied) -> refresh(Resolved, Applied, #{}).
refresh(Resolved, Applied, Opts) ->
    eflyway_info_service:refresh(Resolved, Applied, Opts).

version_of(#migration_info{resolved = undefined, applied = A}) -> A#applied.version;
version_of(#migration_info{resolved = R}) -> R#resolved.version.

rank_of(#migration_info{applied = A}) -> A#applied.installed_rank.

pending_when_not_applied_test() ->
    [I] = refresh([resolved(<<"1">>, <<"init">>)], []),
    ?assertEqual(pending, eflyway_info_service:state(I)).

success_when_applied_test() ->
    [I] = refresh([resolved(<<"1">>, <<"init">>, 100)],
                  [applied(1, <<"1">>, <<"init">>, sql, 100, true)]),
    ?assertEqual(success, eflyway_info_service:state(I)).

pending_next_version_test() ->
    Infos = refresh([resolved(<<"1">>, <<"a">>, 1), resolved(<<"2">>, <<"b">>, 2)],
                    [applied(1, <<"1">>, <<"a">>, sql, 1, true)]),
    States = [{version_of(I), eflyway_info_service:state(I)} || I <- Infos],
    ?assertEqual([{ver(<<"1">>), success}, {ver(<<"2">>), pending}], States).

ignored_test() ->
    %% v1 resolved locally but v2 already applied and outOfOrder disabled
    [I] = [I0 || I0 <- refresh([resolved(<<"1">>, <<"a">>, 1)],
                               [applied(1, <<"2">>, <<"b">>, sql, 2, true)]),
                version_of(I0) =:= ver(<<"1">>)],
    ?assertEqual(ignored, eflyway_info_service:state(I)).

missing_success_test() ->
    %% v1 applied, local resolvers know about v3 -> last resolved 3
    Infos = refresh([resolved(<<"3">>, <<"c">>, 3)],
                    [applied(1, <<"1">>, <<"a">>, sql, 1, true)]),
    [I] = [I0 || I0 <- Infos, version_of(I0) =:= ver(<<"1">>)],
    ?assertEqual(missing_success, eflyway_info_service:state(I)).

future_success_test() ->
    %% v2 applied, local resolvers only know v1 -> last resolved 1
    Infos = refresh([resolved(<<"1">>, <<"a">>, 1)],
                    [applied(1, <<"2">>, <<"b">>, sql, 2, true)]),
    [I] = [I0 || I0 <- Infos, version_of(I0) =:= ver(<<"2">>)],
    ?assertEqual(future_success, eflyway_info_service:state(I)).

below_baseline_test() ->
    Infos = refresh([resolved(<<"0.5">>, <<"pre">>, 1)],
                    [applied(1, <<"1">>, <<"baseline">>, baseline, undefined, true)]),
    [I] = [I0 || I0 <- Infos, version_of(I0) =:= ver(<<"0.5">>)],
    ?assertEqual(below_baseline, eflyway_info_service:state(I)).

above_target_test() ->
    Infos = refresh([resolved(<<"3">>, <<"c">>, 3)], [],
                    #{target => eflyway_migration_version:from_version(<<"2">>)}),
    [I] = [I0 || I0 <- Infos, version_of(I0) =:= ver(<<"3">>)],
    ?assertEqual(above_target, eflyway_info_service:state(I)).

repeatable_outdated_test() ->
    Infos = refresh([resolved(undefined, <<"view">>, 200)],
                    [applied(1, undefined, <<"view">>, sql, 100, true)]),
    %% The applied (outdated) info and a pending info for the changed repeatable.
    Applied = [I || I <- Infos, I#migration_info.applied =/= undefined],
    Pending = [I || I <- Infos, I#migration_info.applied =:= undefined],
    ?assertEqual(1, length(Applied)),
    ?assertEqual(outdated, eflyway_info_service:state(hd(Applied))),
    ?assertEqual(1, length(Pending)),
    ?assertEqual(pending, eflyway_info_service:state(hd(Pending))).

repeatable_superseded_test() ->
    Infos = refresh([resolved(undefined, <<"view">>, 200)],
                    [applied(1, undefined, <<"view">>, sql, 100, true),
                     applied(2, undefined, <<"view">>, sql, 200, true)]),
    Ranked = [{rank_of(I), eflyway_info_service:state(I)} || I <- Infos],
    ?assertEqual([{1, superseded}, {2, success}], Ranked).

failed_test() ->
    [I] = refresh([resolved(<<"1">>, <<"a">>, 1)],
                  [applied(1, <<"1">>, <<"a">>, sql, 1, false)]),
    ?assertEqual(failed, eflyway_info_service:state(I)).

failed_detection_test() ->
    Infos = refresh([resolved(<<"1">>, <<"a">>, 1)],
                    [applied(1, <<"1">>, <<"a">>, sql, 1, false)]),
    ?assertEqual(1, length(eflyway_info_service:failed(Infos))).

current_test() ->
    Infos = refresh([resolved(<<"1">>, <<"a">>, 1), resolved(<<"2">>, <<"b">>, 2)],
                    [applied(1, <<"1">>, <<"a">>, sql, 1, true),
                     applied(2, <<"2">>, <<"b">>, sql, 2, true)]),
    Current = eflyway_info_service:current(Infos),
    ?assertEqual(ver(<<"2">>), version_of(Current)).
