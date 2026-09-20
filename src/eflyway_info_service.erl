%% @doc Builds the aggregated migration view and computes states.
-module(eflyway_info_service).

-include("eflyway.hrl").

-export([refresh/3, state/1,
         all/1, current/1, pending/1, failed/1,
         validate/1, is_applied_state/1]).

-type opts() :: #{out_of_order => boolean(),
                  pending => boolean(),
                  missing => boolean(),
                  ignored => boolean(),
                  future => boolean(),
                  target => #mversion{} | undefined}.

-spec refresh([#resolved{}], [#applied{}], opts()) -> [#migration_info{}].
refresh(ResolvedList, AppliedList, Opts) ->
    {VersionedMap, RepeatableMap, LastResolved} = index_resolved(ResolvedList),
    {AppliedVersioned, AppliedRepeatable, DeletedMap, Schema, Baseline} = index_applied(AppliedList),
    {LastApplied, OutOfOrderMap} = compute_last_applied(AppliedVersioned, DeletedMap),
    Target0 = maps:get(target, Opts, undefined),
    Target = case Target0 of
                 #mversion{kind = current} -> LastApplied;
                 _ -> Target0
             end,
    Runs = latest_repeatable_runs(AppliedRepeatable, DeletedMap),
    Ctx = #mi_context{
        out_of_order = maps:get(out_of_order, Opts, false),
        pending = maps:get(pending, Opts, true),
        missing = maps:get(missing, Opts, true),
        ignored = maps:get(ignored, Opts, true),
        future = maps:get(future, Opts, true),
        target = Target,
        baseline = Baseline,
        schema = Schema,
        last_resolved = LastResolved,
        last_applied = LastApplied,
        latest_repeatable_runs = Runs
    },
    Infos1 = build_versioned_infos(AppliedVersioned, VersionedMap, DeletedMap, OutOfOrderMap),
    Infos2 = build_repeatable_infos(AppliedRepeatable, RepeatableMap, DeletedMap, Runs, Infos1),
    Infos3 = [I#migration_info{context = Ctx} || I <- Infos2],
    lists:sort(fun(A, B) -> compare_info(A, B) =/= gt end, Infos3).

%% ---------------------------------------------------------------------
%% Indexing
%% ---------------------------------------------------------------------

index_resolved(ResolvedList) ->
    lists:foldl(fun(R, {VM, RM, LR}) ->
        case R#resolved.version of
            undefined -> {VM, maps:put(R#resolved.description, R, RM), LR};
            V -> {maps:put(key(V), R, VM), RM, eflyway_migration_version:max(LR, V)}
        end
    end, {#{}, #{}, eflyway_migration_version:empty()}, ResolvedList).

index_applied(AppliedList) ->
    lists:foldl(fun(A, {AV, AR, DM, Schema, Baseline}) ->
        Type = A#applied.type,
        IsDelete = Type =:= delete andalso A#applied.success,
        case A#applied.version of
            undefined ->
                DM1 = case IsDelete of
                          true -> mark_repeatable_deleted(A, AR, DM);
                          false -> DM
                      end,
                {AV, AR ++ [A], DM1, Schema, Baseline};
            V ->
                Schema1 = case Type of schema -> V; _ -> Schema end,
                Baseline1 = case Type of baseline -> V; _ -> Baseline end,
                DM1 = case IsDelete of
                          true -> mark_deleted(V, AV, DM);
                          false -> DM
                      end,
                {AV ++ [A], AR, DM1, Schema1, Baseline1}
        end
    end, {[], [], #{}, eflyway_migration_version:empty(), eflyway_migration_version:empty()},
    AppliedList).

mark_deleted(_Version, [], DM) -> DM;
mark_deleted(Version, AppliedVersioned, DM) ->
    %% Search from the end for the latest matching, non-deleted entry.
    Rev = lists:reverse(AppliedVersioned),
    case find_version(Version, Rev, []) of
        {A, _Prefix} ->
            Rank = A#applied.installed_rank,
            case maps:is_key(Rank, DM) of
                true -> eflyway_error:raise(duplicate_deleted_migration,
                            [eflyway_migration_version:display(Version)]);
                false -> maps:put(Rank, true, DM)
            end;
        none -> DM
    end.

find_version(_Version, [], _Acc) -> none;
find_version(Version, [A | Rest], Acc) ->
    case eflyway_migration_type:is_synthetic(A#applied.type) of
        true -> find_version(Version, Rest, [A | Acc]);
        false ->
            case eflyway_migration_version:compare(A#applied.version, Version) of
                eq -> {A, Acc};
                _ -> find_version(Version, Rest, [A | Acc])
            end
    end.

mark_repeatable_deleted(_Applied, [], DM) -> DM;
mark_repeatable_deleted(Applied, AppliedRepeatable, DM) ->
    Desc = Applied#applied.description,
    Rev = lists:reverse(AppliedRepeatable),
    case find_description(Desc, Rev) of
        {A, _} -> maps:put(A#applied.installed_rank, true, DM);
        none -> DM
    end.

find_description(_Desc, []) -> none;
find_description(Desc, [A | Rest]) ->
    case eflyway_migration_type:is_synthetic(A#applied.type) of
        true -> find_description(Desc, Rest);
        false ->
            case A#applied.description =:= Desc of
                true -> {A, Rest};
                false -> find_description(Desc, Rest)
            end
    end.

compute_last_applied(AppliedVersioned, DeletedMap) ->
    lists:foldl(fun(A, {LA, OO}) ->
        V = A#applied.version,
        Deleted = maps:is_key(A#applied.installed_rank, DeletedMap),
        case eflyway_migration_version:compare(V, LA) of
            gt ->
                case A#applied.type =/= delete andalso not Deleted of
                    true -> {V, OO};
                    false -> {LA, OO}
                end;
            _ ->
                {LA, maps:put(A#applied.installed_rank, true, OO)}
        end
    end, {eflyway_migration_version:empty(), #{}}, AppliedVersioned).

latest_repeatable_runs(AppliedRepeatable, DeletedMap) ->
    lists:foldl(fun(A, Runs) ->
        Deleted = maps:is_key(A#applied.installed_rank, DeletedMap),
        case Deleted andalso A#applied.type =:= delete of
            true -> Runs;
            false ->
                Desc = A#applied.description,
                Rank = A#applied.installed_rank,
                case maps:get(Desc, Runs, undefined) of
                    undefined -> maps:put(Desc, Rank, Runs);
                    Current when Rank > Current -> maps:put(Desc, Rank, Runs);
                    _ -> Runs
                end
        end
    end, #{}, AppliedRepeatable).

%% ---------------------------------------------------------------------
%% Info construction
%% ---------------------------------------------------------------------

build_versioned_infos(AppliedVersioned, VersionedMap, DeletedMap, OutOfOrderMap) ->
    {Infos, Pending} = lists:foldl(fun(A, {Acc, Pend}) ->
        Key = key(A#applied.version),
        Resolved = maps:get(Key, VersionedMap, undefined),
        Deleted = maps:is_key(A#applied.installed_rank, DeletedMap),
        OoO = maps:is_key(A#applied.installed_rank, OutOfOrderMap),
        Pend1 = case Resolved =/= undefined andalso not Deleted
                     andalso A#applied.type =/= delete of
                    true -> maps:remove(Key, Pend);
                    false -> Pend
                end,
        Info = #migration_info{resolved = Resolved, applied = A,
                               out_of_order = OoO, deleted = Deleted},
        {[Info | Acc], Pend1}
    end, {[], VersionedMap}, AppliedVersioned),
    PendingInfos = [#migration_info{resolved = R} || R <- maps:values(Pending)],
    Infos ++ PendingInfos.

build_repeatable_infos(AppliedRepeatable, RepeatableMap, DeletedMap, Runs, Infos0) ->
    {Infos, Pending} = lists:foldl(fun(A, {Acc, Pend}) ->
        Desc = A#applied.description,
        Rank = A#applied.installed_rank,
        Resolved = maps:get(Desc, RepeatableMap, undefined),
        Deleted = maps:is_key(Rank, DeletedMap),
        LatestRank = maps:get(Desc, Runs, undefined),
        Pend1 = case not Deleted andalso A#applied.type =/= delete
                     andalso Resolved =/= undefined andalso Rank =:= LatestRank
                     andalso checksum_match(Resolved, A#applied.checksum) of
                    true -> maps:remove(Desc, Pend);
                    false -> Pend
                end,
        Info = #migration_info{resolved = Resolved, applied = A, deleted = Deleted},
        {[Info | Acc], Pend1}
    end, {[], RepeatableMap}, AppliedRepeatable),
    PendingInfos = [#migration_info{resolved = R} || R <- maps:values(Pending)],
    Infos0 ++ Infos ++ PendingInfos.

%% ---------------------------------------------------------------------
%% State
%% ---------------------------------------------------------------------

-spec state(#migration_info{}) -> atom().
state(#migration_info{deleted = true}) -> deleted;
state(#migration_info{applied = undefined, resolved = R, context = Ctx}) ->
    state_pending(R, Ctx);
state(#migration_info{applied = A, resolved = R, context = Ctx, out_of_order = OO}) ->
    state_applied(A, R, OO, Ctx).

state_pending(R, Ctx) ->
    case R#resolved.version of
        undefined -> pending;
        V ->
            case eflyway_migration_version:compare(V, Ctx#mi_context.baseline) of
                lt -> below_baseline;
                _ ->
                    AboveTarget = case Ctx#mi_context.target of
                                      undefined -> false;
                                      T -> eflyway_migration_version:compare(V, T) =:= gt
                                  end,
                    case AboveTarget of
                        true -> above_target;
                        false ->
                            Ignored = eflyway_migration_version:compare(
                                          V, Ctx#mi_context.last_applied) =:= lt
                                      andalso not Ctx#mi_context.out_of_order,
                            case Ignored of
                                true -> ignored;
                                false -> pending
                            end
                    end
            end
    end.

state_applied(A, R, OO, Ctx) ->
    case A#applied.type of
        delete -> success;
        baseline -> baseline;
        _ ->
            case R =:= undefined andalso is_repeatable_latest(A, Ctx) of
                true -> missing_or_future(A, Ctx);
                false -> normal_applied(A, R, OO, Ctx)
            end
    end.

is_repeatable_latest(#applied{version = V}, _Ctx) when V =/= undefined -> true;
is_repeatable_latest(A, Ctx) ->
    LatestRank = maps:get(A#applied.description, Ctx#mi_context.latest_repeatable_runs,
                          undefined),
    LatestRank =:= undefined orelse A#applied.installed_rank =:= LatestRank.

missing_or_future(A, Ctx) ->
    case A#applied.type of
        schema -> success;
        _ ->
            IsMissing = A#applied.version =:= undefined
                orelse eflyway_migration_version:compare(A#applied.version,
                        Ctx#mi_context.last_resolved) =:= lt,
            case {IsMissing, A#applied.success} of
                {true, true} -> missing_success;
                {true, false} -> missing_failed;
                {false, true} -> future_success;
                {false, false} -> future_failed
            end
    end.

normal_applied(#applied{success = false}, _R, _OO, _Ctx) ->
    failed;
normal_applied(A, R, OO, Ctx) ->
    case A#applied.version of
        undefined ->
            LatestRank = maps:get(A#applied.description,
                                  Ctx#mi_context.latest_repeatable_runs, undefined),
            case A#applied.installed_rank =:= LatestRank of
                true ->
                    case checksum_match(R, A#applied.checksum) of
                        true -> success;
                        false -> outdated
                    end;
                false -> superseded
            end;
        _ ->
            case OO of
                true -> out_of_order;
                false -> success
            end
    end.

%% ---------------------------------------------------------------------
%% Queries
%% ---------------------------------------------------------------------

-spec all([#migration_info{}]) -> [#migration_info{}].
all(Infos) -> Infos.

-spec pending([#migration_info{}]) -> [#migration_info{}].
pending(Infos) -> [I || I <- Infos, state(I) =:= pending].

-spec failed([#migration_info{}]) -> [#migration_info{}].
failed(Infos) ->
    [I || I <- Infos, lists:member(state(I), [failed, missing_failed, future_failed])].

-spec current([#migration_info{}]) -> #migration_info{} | undefined.
current(Infos) ->
    Versioned = lists:foldl(fun(I, Acc) ->
        case applied_versioned(I) of
            {ok, V} ->
                case Acc of
                    undefined -> I;
                    _ ->
                        case eflyway_migration_version:compare(V, applied_version(Acc)) of
                            gt -> I;
                            _ -> Acc
                        end
                end;
            no -> Acc
        end
    end, undefined, Infos),
    case Versioned of
        undefined -> latest_repeatable(Infos);
        _ -> Versioned
    end.

applied_version(#migration_info{applied = A}) -> A#applied.version.

applied_versioned(I) ->
    S = state(I),
    case I of
        #migration_info{applied = A} when A =/= undefined ->
            case lists:member(S, applied_states()) andalso S =/= deleted
                 andalso A#applied.type =/= delete andalso A#applied.version =/= undefined of
                true -> {ok, A#applied.version};
                false -> no
            end;
        _ -> no
    end.

latest_repeatable(Infos) ->
    Rev = lists:reverse(Infos),
    Candidates = lists:filter(fun(I) ->
        S = state(I),
        A = I#migration_info.applied,
        lists:member(S, applied_states()) andalso S =/= deleted
            andalso A =/= undefined andalso A#applied.type =/= delete
    end, Rev),
    case Candidates of
        [I | _] -> I;
        [] -> undefined
    end.

is_applied_state(S) -> lists:member(S, applied_states()).

applied_states() ->
    [baseline, missing_success, missing_failed, success, undone, available,
     failed, out_of_order, future_success, future_failed, outdated, superseded, deleted].

%% ---------------------------------------------------------------------
%% Validation
%% ---------------------------------------------------------------------

-spec validate([#migration_info{}]) -> [{atom(), binary()}].
validate(Infos) ->
    lists:filtermap(fun validate_one/1, Infos).

validate_one(Info) ->
    State = state(Info),
    Ctx = Info#migration_info.context,
    case State of
        above_target -> false;
        deleted -> false;
        _ ->
            case State of
                S when S =:= failed; S =:= missing_failed; S =:= future_failed ->
                    if S =:= future_failed andalso Ctx#mi_context.future -> false;
                       true -> {true, failed_error(Info, S)}
                    end;
                _ ->
                    case missing_error(Info, State, Ctx) of
                        {error, E} -> {true, E};
                        ok -> ignored_pending_error(Info, State, Ctx)
                    end
            end
    end.

failed_error(#migration_info{resolved = undefined, applied = A}, _S) ->
    Desc = A#applied.description,
    case A#applied.version of
        undefined -> {failed_repeatable_migration, <<"Detected failed repeatable migration: ",
                        Desc/binary, ". Please remove any half-completed changes then run repair to fix the schema history.">>};
        V -> {failed_versioned_migration, <<"Detected failed migration to version ",
                 (eflyway_migration_version:display(V))/binary, " (", Desc/binary, ")" >>}
    end.

missing_error(#migration_info{resolved = undefined, applied = A}, State, Ctx) ->
    Synthetic = eflyway_migration_type:is_synthetic(A#applied.type),
    case not Synthetic andalso State =/= superseded
         andalso (not Ctx#mi_context.missing
                  orelse (State =/= missing_success andalso State =/= missing_failed))
         andalso (not Ctx#mi_context.future
                  orelse (State =/= future_success andalso State =/= future_failed)) of
        true ->
            case A#applied.version of
                undefined -> {error, {applied_repeatable_migration_not_resolved,
                    <<"Detected applied migration not resolved locally: ", (A#applied.description)/binary>>}};
                V -> {error, {applied_versioned_migration_not_resolved,
                    <<"Detected applied migration not resolved locally: ",
                      (eflyway_migration_version:display(V))/binary>>}}
            end;
        false -> ok
    end;
missing_error(_Info, _State, _Ctx) ->
    ok.

ignored_pending_error(Info, ignored, Ctx) ->
    case Ctx#mi_context.ignored of
        true -> false;
        false ->
            R = Info#migration_info.resolved,
            case R#resolved.version of
                undefined -> {true, {resolved_repeatable_migration_not_applied,
                    <<"Detected resolved repeatable migration not applied to database: ",
                      (R#resolved.description)/binary>>}};
                V -> {true, {resolved_versioned_migration_not_applied,
                    <<"Detected resolved migration not applied to database: ",
                      (eflyway_migration_version:display(V))/binary>>}}
            end
    end;
ignored_pending_error(Info, pending, Ctx) ->
    case Ctx#mi_context.pending of
        true -> false;
        false ->
            R = Info#migration_info.resolved,
            case R#resolved.version of
                undefined -> {true, {resolved_repeatable_migration_not_applied,
                    <<"Detected resolved repeatable migration not applied to database: ",
                      (R#resolved.description)/binary>>}};
                V -> {true, {resolved_versioned_migration_not_applied,
                    <<"Detected resolved migration not applied to database: ",
                      (eflyway_migration_version:display(V))/binary>>}}
            end
    end;
ignored_pending_error(Info, outdated, Ctx) ->
    case Ctx#mi_context.pending of
        true -> false;
        false ->
            R = Info#migration_info.resolved,
            {true, {outdated_repeatable_migration,
                <<"Detected outdated resolved repeatable migration that should be re-applied to database: ",
                  (R#resolved.description)/binary>>}}
    end;
ignored_pending_error(Info, _State, _Ctx) ->
    mismatch_error(Info).

mismatch_error(#migration_info{resolved = R, applied = A}) when R =/= undefined, A =/= undefined ->
    case eflyway_migration_type:is_synthetic(A#applied.type) of
        true -> false;
        false ->
            case R#resolved.type =/= A#applied.type of
                true -> {true, {type_mismatch, type_mismatch_message(A, R)}};
                false ->
                    case checksum_match(R, A#applied.checksum) of
                        false -> {true, {checksum_mismatch, checksum_mismatch_message(A, R)}};
                        true ->
                            case description_match(R, A#applied.description) of
                                true -> false;
                                false ->
                                    {true, {description_mismatch,
                                            description_mismatch_message(A, R)}}
                            end
                    end
            end
    end;
mismatch_error(_) ->
    false.

type_mismatch_message(A, R) ->
    mismatch_message(<<"type">>, migration_identifier(A),
        eflyway_migration_type:to_string(A#applied.type),
        eflyway_migration_type:to_string(R#resolved.type)).

checksum_mismatch_message(A, R) ->
    mismatch_message(<<"checksum">>, migration_identifier(A),
        i2b(A#applied.checksum), i2b(R#resolved.checksum)).

description_match(#resolved{description = D}, Applied) ->
    abbreviation(D) =:= Applied.

abbreviation(Bin) when byte_size(Bin) =< 200 -> Bin;
abbreviation(Bin) -> binary:part(Bin, 0, 200).

description_mismatch_message(A, R) ->
    mismatch_message(<<"description">>, migration_identifier(A),
        A#applied.description, R#resolved.description).

%% Same layout as Flyway 7.5.0's MigrationInfoImpl#createMismatchMessage.
mismatch_message(Kind, Identifier, Applied, Resolved) ->
    <<"Migration ", Kind/binary, " mismatch for migration ", Identifier/binary, "\n",
      "-> Applied to database : ", Applied/binary, "\n",
      "-> Resolved locally    : ", Resolved/binary,
      ". Either revert the changes to the migration, or run repair to update the schema history.">>.

migration_identifier(#applied{version = undefined, script = S}) -> S;
migration_identifier(#applied{version = V}) -> <<"version ", (eflyway_migration_version:display(V))/binary>>.

%% ---------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------

checksum_match(undefined, _Applied) -> false;
checksum_match(R, Applied) ->
    Applied =:= R#resolved.checksum
        orelse (R#resolved.equivalent_checksum =/= undefined
                andalso Applied =:= R#resolved.equivalent_checksum).

key(#mversion{parts = Parts}) -> list_to_tuple(Parts).

%% Sorting of migration infos.
compare_info(A, B) ->
    RankA = rank_of(A),
    RankB = rank_of(B),
    case {RankA, RankB} of
        {X, Y} when X =/= undefined, Y =/= undefined -> compare(X, Y);
        _ ->
            SA = state(A),
            SB = state(B),
            AA = is_applied_state(SA),
            AB = is_applied_state(SB),
            if
                SA =:= below_baseline, AB -> lt;
                AA, SB =:= below_baseline -> gt;
                SA =:= ignored, AB -> compare_versions_or(A, B, lt);
                AA, SB =:= ignored -> compare_versions_or(A, B, gt);
                RankA =/= undefined -> lt;
                RankB =/= undefined -> gt;
                true -> compare_uninstalled(A, B)
            end
    end.

rank_of(#migration_info{applied = undefined}) -> undefined;
rank_of(#migration_info{applied = A}) -> A#applied.installed_rank.

compare_versions_or(A, B, Default) ->
    VA = version_of(A),
    VB = version_of(B),
    case {VA, VB} of
        {undefined, _} -> Default;
        {_, undefined} -> Default;
        _ -> eflyway_migration_version:compare(VA, VB)
    end.

compare_uninstalled(A, B) ->
    VA = version_of(A),
    VB = version_of(B),
    case {VA, VB} of
        {undefined, undefined} -> cmp_bin(description_of(A), description_of(B));
        {undefined, _} -> gt;
        {_, undefined} -> lt;
        _ ->
            case eflyway_migration_version:compare(VA, VB) of
                eq -> cmp_bin(description_of(A), description_of(B));
                C -> C
            end
    end.

version_of(#migration_info{resolved = undefined, applied = A}) -> A#applied.version;
version_of(#migration_info{resolved = R}) -> R#resolved.version.

description_of(#migration_info{resolved = undefined, applied = A}) -> A#applied.description;
description_of(#migration_info{resolved = R}) -> R#resolved.description.

compare(A, B) when A < B -> lt;
compare(A, B) when A > B -> gt;
compare(_, _) -> eq.

cmp_bin(A, B) when A < B -> lt;
cmp_bin(A, B) when A > B -> gt;
cmp_bin(_, _) -> eq.

i2b(undefined) -> <<"null">>;
i2b(N) when is_integer(N) -> integer_to_binary(N).
