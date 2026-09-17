%% @doc Schema history table access.
-module(eflyway_schema_history).

-include("eflyway.hrl").

-export([exists/2, create/3, all_applied/2, add_applied/9,
         add_schemas_marker/3, lock/3, next_rank/2, table_name/1,
         remove_failed/2, update_applied/4, delete_applied/3,
         baseline_marker/2, has_schemas_marker/2, has_non_synthetic/2]).

-spec exists(term(), #eflyway_config{}) -> boolean().
exists(Conn, #eflyway_config{table = Table}) ->
    eflyway_db:table_exists(Conn, Table).

-spec create(term(), #eflyway_config{}, none | map()) -> ok.
create(Conn, #eflyway_config{table = Table}, Baseline) ->
    Statements = eflyway_db:create_history_ddl(Conn, Table, Baseline),
    lists:foreach(fun(Sql) -> ok = expect_ok(Conn, Sql) end, Statements),
    ok.

-spec all_applied(term(), #eflyway_config{}) -> [#applied{}].
all_applied(Conn, #eflyway_config{table = Table} = Config) ->
    case exists(Conn, Config) of
        false -> [];
        true -> all_applied_query(Conn, Table)
    end.

all_applied_query(Conn, Table) ->
    Q = fun(Id) -> eflyway_db:quote(Conn, Id) end,
    Columns = [<<"installed_rank">>, <<"version">>, <<"description">>, <<"type">>,
               <<"script">>, <<"checksum">>, <<"installed_on">>, <<"installed_by">>,
               <<"execution_time">>, <<"success">>],
    Sql = iolist_to_binary([
        "SELECT ", join([Q(C) || C <- Columns], <<", ">>),
        " FROM ", Q(Table),
        " WHERE ", Q(<<"installed_rank">>), " > ?",
        " ORDER BY ", Q(<<"installed_rank">>)
    ]),
    case eflyway_db:query(Conn, Sql, [-1]) of
        {ok, Rows} -> [row_to_applied(R) || R <- Rows];
        {error, Reason} ->
            eflyway_error:raise(schema_history_read_failed, [Table], #{reason => Reason})
    end.

-spec add_applied(term(), #eflyway_config{}, #mversion{} | undefined, binary(),
                  atom(), binary(), integer() | undefined, non_neg_integer(), boolean()) -> ok.
add_applied(Conn, #eflyway_config{table = Table} = Config, Version, Description, Type,
            Script, Checksum, ExecutionTime, Success) ->
    Rank = case Type of
               schema -> 0;
               _ -> next_rank(Conn, Config)
           end,
    InstalledBy = eflyway_db:installed_by(Conn, Config),
    Q = fun(Id) -> eflyway_db:quote(Conn, Id) end,
    Sql = iolist_to_binary([
        "INSERT INTO ", Q(Table), " (",
        Q(<<"installed_rank">>), ", ", Q(<<"version">>), ", ", Q(<<"description">>), ", ",
        Q(<<"type">>), ", ", Q(<<"script">>), ", ", Q(<<"checksum">>), ", ",
        Q(<<"installed_by">>), ", ", Q(<<"execution_time">>), ", ", Q(<<"success">>),
        ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ]),
    Args = [Rank,
            eflyway_migration_version:storage(Version),
            abbreviate(Description, 200),
            eflyway_migration_type:to_string(Type),
            abbreviate(Script, 1000),
            Checksum,
            InstalledBy,
            ExecutionTime,
            bool_int(Success)],
    case eflyway_db:query(Conn, Sql, Args) of
        {ok, _} -> ok;
        {error, Reason} ->
            eflyway_error:raise(schema_history_write_failed, [Table], #{reason => Reason})
    end.

-spec add_schemas_marker(term(), #eflyway_config{}, [binary()]) -> ok.
add_schemas_marker(Conn, Config, Schemas) ->
    Script = join(Schemas, <<",">>),
    add_applied(Conn, Config, undefined, <<"<< Flyway Schema Creation >>">>,
                schema, Script, undefined, 0, true).

-spec lock(term(), #eflyway_config{}, fun(() -> R)) -> R.
lock(Conn, #eflyway_config{table = Table}, Fun) ->
    eflyway_db:lock(Conn, Table, Fun).

-spec next_rank(term(), #eflyway_config{}) -> pos_integer().
next_rank(Conn, Config) ->
    case all_applied(Conn, Config) of
        [] -> 1;
        Applied -> (lists:last(Applied))#applied.installed_rank + 1
    end.

-spec table_name(#eflyway_config{}) -> binary().
table_name(#eflyway_config{table = Table}) -> Table.

-spec remove_failed(term(), #eflyway_config{}) -> boolean().
remove_failed(Conn, #eflyway_config{table = Table} = Config) ->
    case [A || A <- all_applied(Conn, Config), not A#applied.success] of
        [] -> false;
        _ ->
            Q = fun(Id) -> eflyway_db:quote(Conn, Id) end,
            Sql = iolist_to_binary(["DELETE FROM ", Q(Table), " WHERE ",
                                    Q(<<"success">>), " = ", eflyway_db:boolean_false(Conn)]),
            ok = expect_ok(Conn, Sql),
            true
    end.

-spec update_applied(term(), #eflyway_config{}, #applied{}, #resolved{}) -> ok.
update_applied(Conn, #eflyway_config{table = Table}, Applied, Resolved) ->
    Q = fun(Id) -> eflyway_db:quote(Conn, Id) end,
    Sql = iolist_to_binary(["UPDATE ", Q(Table), " SET ",
        Q(<<"description">>), "=?, ", Q(<<"type">>), "=?, ", Q(<<"checksum">>), "=?",
        " WHERE ", Q(<<"installed_rank">>), "=?"]),
    Args = [abbreviate(Resolved#resolved.description, 200),
            eflyway_migration_type:to_string(Resolved#resolved.type),
            Resolved#resolved.checksum,
            Applied#applied.installed_rank],
    case eflyway_db:query(Conn, Sql, Args) of
        {ok, _} -> ok;
        {error, Reason} -> eflyway_error:raise(schema_history_write_failed, [Table], #{reason => Reason})
    end.

-spec delete_applied(term(), #eflyway_config{}, #applied{}) -> ok.
delete_applied(Conn, #eflyway_config{table = Table} = Config, Applied) ->
    Rank = next_rank(Conn, Config),
    InstalledBy = eflyway_db:installed_by(Conn, Config),
    Q = fun(Id) -> eflyway_db:quote(Conn, Id) end,
    Sql = iolist_to_binary([
        "INSERT INTO ", Q(Table), " (",
        Q(<<"installed_rank">>), ", ", Q(<<"version">>), ", ", Q(<<"description">>), ", ",
        Q(<<"type">>), ", ", Q(<<"script">>), ", ", Q(<<"checksum">>), ", ",
        Q(<<"installed_by">>), ", ", Q(<<"execution_time">>), ", ", Q(<<"success">>),
        ") VALUES (?, ?, ?, 'DELETE', ?, ?, ?, 0, ?)"]),
    Args = [Rank,
            eflyway_migration_version:storage(Applied#applied.version),
            abbreviate(Applied#applied.description, 200),
            abbreviate(Applied#applied.script, 1000),
            Applied#applied.checksum,
            InstalledBy,
            bool_int(Applied#applied.success)],
    case eflyway_db:query(Conn, Sql, Args) of
        {ok, _} -> ok;
        {error, Reason} -> eflyway_error:raise(schema_history_write_failed, [Table], #{reason => Reason})
    end.

-spec baseline_marker(term(), #eflyway_config{}) -> #applied{} | undefined.
baseline_marker(Conn, Config) ->
    Applied = all_applied(Conn, Config),
    Candidates = lists:sublist(Applied, 2),
    case [A || A <- Candidates, A#applied.type =:= baseline] of
        [Marker | _] -> Marker;
        [] -> undefined
    end.

-spec has_schemas_marker(term(), #eflyway_config{}) -> boolean().
has_schemas_marker(Conn, Config) ->
    case all_applied(Conn, Config) of
        [#applied{type = schema} | _] -> true;
        _ -> false
    end.

-spec has_non_synthetic(term(), #eflyway_config{}) -> boolean().
has_non_synthetic(Conn, Config) ->
    lists:any(fun(#applied{type = T}) -> not eflyway_migration_type:is_synthetic(T) end,
              all_applied(Conn, Config)).

%% internal

row_to_applied(Row) ->
    #applied{
        installed_rank = maps:get(<<"installed_rank">>, Row),
        version = case get_val(<<"version">>, Row) of
                      undefined -> undefined;
                      V -> eflyway_migration_version:from_version(to_bin(V))
                  end,
        description = to_bin(get_val(<<"description">>, Row)),
        type = eflyway_migration_type:from_string(to_bin(get_val(<<"type">>, Row))),
        script = to_bin(get_val(<<"script">>, Row)),
        checksum = case get_val(<<"checksum">>, Row) of
                       undefined -> undefined;
                       C -> C
                   end,
        installed_on = maybe_bin(get_val(<<"installed_on">>, Row)),
        installed_by = maybe_bin(get_val(<<"installed_by">>, Row)),
        execution_time = case get_val(<<"execution_time">>, Row) of
                             undefined -> 0;
                             T -> T
                         end,
        success = to_bool(get_val(<<"success">>, Row))
    }.

get_val(Key, Row) ->
    case maps:get(Key, Row, undefined) of
        undefined -> undefined;
        null -> undefined;
        V -> V
    end.

maybe_bin(undefined) -> undefined;
maybe_bin({{Y, Mo, D}, {H, Mi, S}}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                                   [Y, Mo, D, H, Mi, S]));
maybe_bin({{Y, Mo, D}, {H, Mi, S, _Micro}}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                                   [Y, Mo, D, H, Mi, S]));
maybe_bin({Y, Mo, D}) ->
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, Mo, D]));
maybe_bin(V) -> to_bin(V).

to_bool(true) -> true;
to_bool(false) -> false;
to_bool(1) -> true;
to_bool(0) -> false;
to_bool(<<"1">>) -> true;
to_bool(<<"0">>) -> false;
to_bool(<<"true">>) -> true;
to_bool(<<"false">>) -> false;
to_bool(_) -> false.

bool_int(true) -> 1;
bool_int(false) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

abbreviate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
abbreviate(Bin, Max) -> binary:part(Bin, 0, Max).

join([], _Sep) -> <<>>;
join([H | T], Sep) ->
    iolist_to_binary([H | [[Sep, X] || X <- T]]).

expect_ok(Conn, Sql) ->
    case eflyway_db:execute(Conn, Sql) of
        ok -> ok;
        {error, Reason} ->
            eflyway_error:raise(schema_history_ddl_failed, [Sql], #{reason => Reason})
    end.
