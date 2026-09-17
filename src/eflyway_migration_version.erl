%% @doc Migration version semantics, replicating org.flywaydb.core.api.MigrationVersion.
-module(eflyway_migration_version).

-include("eflyway.hrl").

-export([from_version/1,
         empty/0, latest/0, current/0,
         is_empty/1, is_latest/1, is_current/1,
         compare/2, max/2, at_least/2, newer_than/2,
         display/1, storage/1, major/1, parts/1]).

-export_type([version/0]).

-type version() :: #mversion{}.

-spec empty() -> version().
empty() -> #mversion{kind = empty, parts = [], display = <<"<< Empty Schema >>">>}.

-spec latest() -> version().
latest() -> #mversion{kind = latest, parts = [-1], display = <<"<< Latest Version >>">>}.

-spec current() -> version().
current() -> #mversion{kind = current, parts = [-2], display = <<"<< Current Version >>">>}.

-spec from_version(binary() | string() | undefined) -> version().
from_version(undefined) -> empty();
from_version(<<>>) -> empty();
from_version(V) when is_list(V) ->
    from_version(unicode:characters_to_binary(V));
from_version(V) when is_binary(V) ->
    case string:lowercase(V) of
        <<"current">> -> current();
        <<"latest">> -> latest();
        <<"9223372036854775807">> -> latest();
        _ -> parse_numeric(V)
    end.

parse_numeric(V) ->
    Normalized = binary:replace(V, <<"_">>, <<".">>, [global]),
    Parts0 = binary:split(Normalized, <<".">>, [global]),
    Parts1 = [to_part(Normalized, P) || P <- Parts0],
    Parts = strip_trailing_zeros(Parts1),
    #mversion{kind = numeric, parts = Parts, display = Normalized}.

to_part(Version, Part) ->
    try binary_to_integer(Part)
    catch
        error:badarg ->
            eflyway_error:raise(invalid_version,
                ["Version may only contain 0..9 and . (dot). Invalid version: ", Version])
    end.

strip_trailing_zeros([_] = Parts) -> Parts;
strip_trailing_zeros(Parts) ->
    case lists:last(Parts) of
        0 -> strip_trailing_zeros(lists:droplast(Parts));
        _ -> Parts
    end.

-spec is_empty(version()) -> boolean().
is_empty(#mversion{kind = empty}) -> true;
is_empty(_) -> false.

-spec is_latest(version()) -> boolean().
is_latest(#mversion{kind = latest}) -> true;
is_latest(_) -> false.

-spec is_current(version()) -> boolean().
is_current(#mversion{kind = current}) -> true;
is_current(_) -> false.

-spec compare(version(), version()) -> lt | eq | gt.
compare(#mversion{kind = KA} = A, #mversion{kind = KB} = B) ->
    case {KA, KB} of
        {empty, empty} -> eq;
        {empty, _} -> lt;
        {current, current} -> eq;
        {current, _} -> lt;
        {latest, latest} -> eq;
        {latest, _} -> gt;
        {_, empty} -> gt;
        {_, current} -> gt;
        {_, latest} -> lt;
        {numeric, numeric} -> compare_parts(A#mversion.parts, B#mversion.parts)
    end.

compare_parts(P1, P2) ->
    N = erlang:max(length(P1), length(P2)),
    compare_parts(P1, P2, 0, N).

compare_parts(_P1, _P2, I, N) when I >= N -> eq;
compare_parts(P1, P2, I, N) ->
    A = get_or_zero(P1, I),
    B = get_or_zero(P2, I),
    if
        A < B -> lt;
        A > B -> gt;
        true -> compare_parts(P1, P2, I + 1, N)
    end.

get_or_zero(Parts, I) ->
    case I < length(Parts) of
        true -> lists:nth(I + 1, Parts);
        false -> 0
    end.

-spec max(version(), version()) -> version().
max(A, B) ->
    case compare(A, B) of
        lt -> B;
        _ -> A
    end.

-spec at_least(version(), version() | binary()) -> boolean().
at_least(A, B) when is_binary(B) -> at_least(A, from_version(B));
at_least(A, B) -> compare(A, B) =/= lt.

-spec newer_than(version(), version() | binary()) -> boolean().
newer_than(A, B) when is_binary(B) -> newer_than(A, from_version(B));
newer_than(A, B) -> compare(A, B) =:= gt.

-spec display(version()) -> binary().
display(#mversion{display = D}) -> D.

%% Value stored in the schema history table (null for the empty schema).
-spec storage(version() | undefined) -> binary() | undefined.
storage(undefined) -> undefined;
storage(#mversion{kind = empty}) -> undefined;
storage(#mversion{display = D}) -> D.

-spec major(version()) -> non_neg_integer().
major(#mversion{parts = [P | _]}) when is_integer(P), P >= 0 -> P;
major(_) -> 0.

-spec parts(version()) -> [integer()].
parts(#mversion{parts = Parts}) -> Parts.
