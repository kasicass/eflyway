%% @doc repair command.
-module(eflyway_cmd_repair).

-include("eflyway.hrl").

-export([repair/3]).

-spec repair(term(), #eflyway_config{}, [#resolved{}]) -> map().
repair(Conn, Config, Resolved) ->
    RemovedFailed = eflyway_schema_history:remove_failed(Conn, Config),
    Applied = eflyway_schema_history:all_applied(Conn, Config),
    Infos = eflyway_info_service:refresh(Resolved, Applied, opts()),
    Deleted = delete_missing(Conn, Config, Infos, 0),
    Aligned = align(Conn, Config, Infos, 0),
    eflyway_log:info("Successfully repaired schema history table ~s",
                     [eflyway_schema_history:table_name(Config)]),
    #{removed_failed => RemovedFailed, deleted_missing => Deleted, aligned => Aligned}.

opts() ->
    #{out_of_order => true, pending => true, missing => true, ignored => true,
      future => true, target => eflyway_migration_version:latest()}.

delete_missing(_Conn, _Config, [], Count) -> Count;
delete_missing(Conn, Config, [I | Rest], Count) ->
    A = I#migration_info.applied,
    S = eflyway_info_service:state(I),
    case A =/= undefined andalso not eflyway_migration_type:is_synthetic(A#applied.type)
         andalso lists:member(S, [missing_success, missing_failed,
                                  future_success, future_failed]) of
        true ->
            ok = eflyway_schema_history:delete_applied(Conn, Config, A),
            delete_missing(Conn, Config, Rest, Count + 1);
        false ->
            delete_missing(Conn, Config, Rest, Count)
    end.

align(_Conn, _Config, [], Count) -> Count;
align(Conn, Config, [I | Rest], Count) ->
    R = I#migration_info.resolved,
    A = I#migration_info.applied,
    S = eflyway_info_service:state(I),
    case R =/= undefined andalso A =/= undefined
         andalso not eflyway_migration_type:is_synthetic(A#applied.type)
         andalso S =/= ignored of
        true ->
            Update = case R#resolved.version of
                         undefined ->
                             checksum_matches_without_identical(R, A#applied.checksum);
                         _ ->
                             update_needed(R, A)
                     end,
            case Update of
                true ->
                    ok = eflyway_schema_history:update_applied(Conn, Config, A, R),
                    align(Conn, Config, Rest, Count + 1);
                false ->
                    align(Conn, Config, Rest, Count)
            end;
        false ->
            align(Conn, Config, Rest, Count)
    end.

update_needed(R, A) ->
    not checksum_matches(R, A#applied.checksum)
        orelse R#resolved.description =/= A#applied.description
        orelse R#resolved.type =/= A#applied.type.

checksum_matches(R, Applied) ->
    Applied =:= R#resolved.checksum
        orelse (R#resolved.equivalent_checksum =/= undefined
                andalso Applied =:= R#resolved.equivalent_checksum).

checksum_matches_without_identical(R, Applied) ->
    Applied =:= R#resolved.equivalent_checksum
        andalso Applied =/= R#resolved.checksum.
