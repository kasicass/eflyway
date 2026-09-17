%% @doc Migration type.
-module(eflyway_migration_type).

-export([is_synthetic/1, is_undo/1, to_string/1, from_string/1]).

-spec is_synthetic(atom()) -> boolean().
is_synthetic(Type) ->
    lists:member(Type, [schema, baseline, delete]).

-spec is_undo(atom()) -> boolean().
is_undo(Type) ->
    lists:member(Type, [undo_sql, undo_jdbc, undo_custom]).

-spec to_string(atom()) -> binary().
to_string(schema) -> <<"SCHEMA">>;
to_string(baseline) -> <<"BASELINE">>;
to_string(delete) -> <<"DELETE">>;
to_string(sql) -> <<"SQL">>;
to_string(undo_sql) -> <<"UNDO_SQL">>;
to_string(jdbc) -> <<"JDBC">>;
to_string(undo_jdbc) -> <<"UNDO_JDBC">>;
to_string(custom) -> <<"CUSTOM">>;
to_string(undo_custom) -> <<"UNDO_CUSTOM">>;
to_string(Type) when is_atom(Type) -> string:uppercase(atom_to_binary(Type, utf8)).

-spec from_string(binary() | string()) -> atom().
from_string(S) when is_list(S) -> from_string(unicode:characters_to_binary(S));
from_string(<<"SCHEMA">>) -> schema;
from_string(<<"BASELINE">>) -> baseline;
from_string(<<"DELETE">>) -> delete;
from_string(<<"SQL">>) -> sql;
from_string(<<"UNDO_SQL">>) -> undo_sql;
from_string(<<"JDBC">>) -> jdbc;
from_string(<<"SPRING_JDBC">>) -> jdbc;
from_string(<<"UNDO_JDBC">>) -> undo_jdbc;
from_string(<<"UNDO_SPRING_JDBC">>) -> undo_jdbc;
from_string(<<"CUSTOM">>) -> custom;
from_string(<<"UNDO_CUSTOM">>) -> undo_custom;
from_string(Other) -> binary_to_atom(string:lowercase(Other), utf8).
