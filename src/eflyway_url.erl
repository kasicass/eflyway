%% @doc Parse eflyway database URLs.
%%
%% Supported forms:
%%   mysql://user:pass@host:port/database
%%   sqlite3:///absolute/path/app.db
%%   sqlite3:./relative/path/app.db
%%   sqlite3://relative/path/app.db   (host+path joined -> "relative/path/app.db")
%%
%% In-memory SQLite (":memory:") is intentionally not supported.
-module(eflyway_url).

-include("eflyway.hrl").

-export([parse/1, to_binary/1]).

-spec parse(binary() | string()) -> {ok, #db_url{}} | {error, term()}.
parse(Url) when is_list(Url) ->
    parse(unicode:characters_to_binary(Url));
parse(Url) when is_binary(Url) ->
    Clean = strip_jdbc(Url),
    case uri_string:parse(Clean) of
        Map when is_map(Map) ->
            case maps:get(scheme, Map, undefined) of
                <<"mysql">> -> parse_mysql(Map);
                <<"sqlite3">> -> parse_sqlite(Map);
                <<"sqlite">> -> parse_sqlite(Map);
                Other -> {error, {unsupported_url_scheme, Other}}
            end;
        {error, _, _} ->
            {error, {invalid_url, Url}}
    end.

%% Accept JDBC-style URLs as well (jdbc:mysql://..., jdbc:sqlite:...).
strip_jdbc(<<"jdbc:", Rest/binary>>) -> Rest;
strip_jdbc(Url) -> Url.

-spec to_binary(binary() | string() | atom()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% internal

parse_mysql(Map) ->
    {User, Pass} = split_userinfo(maps:get(userinfo, Map, undefined)),
    Db = strip_leading_slash(maps:get(path, Map, <<>>)),
    {ok, #db_url{type = mysql,
                 host = maps:get(host, Map, undefined),
                 port = maps:get(port, Map, 3306),
                 database = Db,
                 path = Db,
                 user = User,
                 password = Pass,
                 query = parse_query(maps:get(query, Map, undefined))}}.

parse_sqlite(Map) ->
    Host = maps:get(host, Map, <<>>),
    Path0 = maps:get(path, Map, <<>>),
    Path = combine(Host, Path0),
    case Path of
        <<>> -> {error, {in_memory_not_supported, <<>>}};
        <<":memory:">> -> {error, {in_memory_not_supported, Path}};
        _ -> {ok, #db_url{type = sqlite, path = Path, database = Path,
                          query = parse_query(maps:get(query, Map, undefined))}}
    end.

combine(<<>>, Path) -> Path;
combine(Host, Path) -> <<Host/binary, Path/binary>>.

split_userinfo(undefined) -> {undefined, undefined};
split_userinfo(<<>>) -> {undefined, undefined};
split_userinfo(UserInfo) ->
    case binary:match(UserInfo, <<":">>) of
        {Pos, 1} ->
            User = binary:part(UserInfo, 0, Pos),
            Pass = binary:part(UserInfo, Pos + 1, byte_size(UserInfo) - Pos - 1),
            {User, Pass};
        nomatch ->
            {UserInfo, undefined}
    end.

strip_leading_slash(<<"/", Rest/binary>>) -> Rest;
strip_leading_slash(Bin) -> Bin.

parse_query(undefined) -> #{};
parse_query(<<>>) -> #{};
parse_query(Query) ->
    try uri_string:dissect_query(Query) of
        Pairs -> maps:from_list([{Key, to_binary(Value)} || {Key, Value} <- Pairs])
    catch
        _:_ -> #{}
    end.
