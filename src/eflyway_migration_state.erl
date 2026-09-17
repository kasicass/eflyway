%% @doc Migration state metadata.
-module(eflyway_migration_state).

-export([display/1, is_applied/1, is_resolved/1, is_failed/1]).

-spec display(atom()) -> binary().
display(pending) -> <<"Pending">>;
display(above_target) -> <<"Above Target">>;
display(below_baseline) -> <<"Below Baseline">>;
display(baseline) -> <<"Baseline">>;
display(ignored) -> <<"Ignored">>;
display(missing_success) -> <<"Missing">>;
display(missing_failed) -> <<"Failed (Missing)">>;
display(success) -> <<"Success">>;
display(undone) -> <<"Undone">>;
display(available) -> <<"Available">>;
display(failed) -> <<"Failed">>;
display(out_of_order) -> <<"Out of Order">>;
display(future_success) -> <<"Future">>;
display(future_failed) -> <<"Failed (Future)">>;
display(outdated) -> <<"Outdated">>;
display(superseded) -> <<"Superseded">>;
display(deleted) -> <<"Deleted">>;
display(Other) -> atom_to_binary(Other, utf8).

-spec is_resolved(atom()) -> boolean().
is_resolved(State) ->
    lists:member(State, [pending, above_target, below_baseline, baseline, ignored,
                         missing_success, missing_failed, success, undone, available,
                         failed, out_of_order, future_success, future_failed,
                         outdated, superseded, deleted]).

-spec is_applied(atom()) -> boolean().
is_applied(State) ->
    lists:member(State, [baseline, missing_success, missing_failed, success, undone,
                         available, failed, out_of_order, future_success, future_failed,
                         outdated, superseded, deleted]).

-spec is_failed(atom()) -> boolean().
is_failed(State) ->
    lists:member(State, [failed, missing_failed, future_failed]).
