%% @doc Database adapter behaviour and dispatch facade.
%%
%% All database specific differences are hidden behind the callbacks below.
-module(eflyway_db).

-include("eflyway.hrl").

-export([connect/1, connect/2, disconnect/1,
         execute/2, query/2, query/3,
         transaction/2, lock/3,
         supports_ddl_transactions/1, supports_changing_current_schema/1,
         catalog/1, current_user/1, installed_by/2, schema_name/2,
         server_info/1,
         quote/2, boolean_true/1, boolean_false/1,
         create_history_ddl/3,
         dialect/1,
         table_exists/2, all_tables/2,
         schema_exists/2, schema_empty/2,
         create_schema/2, drop_schema/2, clean_schema/2]).

%% ---------------------------------------------------------------------
%% Behaviour
%% ---------------------------------------------------------------------

-callback connect(Url :: #db_url{}, Config :: #eflyway_config{}) -> {ok, term()} | {error, term()}.
-callback disconnect(Conn :: term()) -> ok.
-callback execute(Conn :: term(), Sql :: binary()) -> ok | {error, term()}.
-callback query(Conn :: term(), Sql :: binary()) -> {ok, [map()]} | {error, term()}.
-callback query(Conn :: term(), Sql :: binary(), Args :: [term()]) -> {ok, [map()]} | {error, term()}.
-callback transaction(Conn :: term(), Fun :: fun((term()) -> Result)) -> Result.
-callback lock(Conn :: term(), Table :: binary(), Fun :: fun(() -> Result)) -> Result.
-callback supports_ddl_transactions() -> boolean().
-callback supports_changing_current_schema() -> boolean().
-callback catalog(Conn :: term()) -> binary().
-callback current_user(Conn :: term()) -> binary().
-callback quote(Identifier :: binary()) -> binary().
-callback boolean_true() -> binary().
-callback boolean_false() -> binary().
-callback create_history_ddl(Table :: binary(), Baseline :: none | map()) -> [binary()].
-callback dialect() -> map().
-callback table_exists(Conn :: term(), Table :: binary()) -> boolean().
-callback server_info(Conn :: term()) -> {binary(), binary()}.
-callback all_tables(Conn :: term(), Schema :: binary()) -> [binary()].
-callback schema_exists(Conn :: term(), Schema :: binary()) -> boolean().
-callback schema_empty(Conn :: term(), Schema :: binary()) -> boolean().
-callback create_schema(Conn :: term(), Schema :: binary()) -> ok.
-callback drop_schema(Conn :: term(), Schema :: binary()) -> ok.
-callback clean_schema(Conn :: term(), Schema :: binary()) -> ok.

%% ---------------------------------------------------------------------
%% Facade
%% ---------------------------------------------------------------------

-spec connect(#db_url{}) -> {ok, #conn{}} | {error, term()}.
connect(Url) ->
    connect(Url, eflyway_config:defaults()).

-spec connect(#db_url{}, #eflyway_config{}) -> {ok, #conn{}} | {error, term()}.
connect(#db_url{type = Type} = Url, Config) ->
    Mod = adapter(Type),
    case Mod:connect(Url, Config) of
        {ok, Handle} -> {ok, #conn{adapter = Mod, handle = Handle, url = Url}};
        {error, _} = Error -> Error
    end.

-spec disconnect(#conn{}) -> ok.
disconnect(#conn{adapter = Mod, handle = Handle}) ->
    Mod:disconnect(Handle).

execute(#conn{adapter = Mod, handle = H}, Sql) -> Mod:execute(H, Sql).

query(#conn{adapter = Mod, handle = H}, Sql) -> Mod:query(H, Sql).
query(#conn{adapter = Mod, handle = H}, Sql, Args) -> Mod:query(H, Sql, Args).

transaction(#conn{adapter = Mod, handle = H} = Conn, Fun) -> Mod:transaction(H, fun() -> Fun(Conn) end).

lock(#conn{adapter = Mod, handle = H}, Table, Fun) ->
    Mod:lock(H, Table, Fun).

supports_ddl_transactions(#conn{adapter = Mod}) -> Mod:supports_ddl_transactions().
supports_changing_current_schema(#conn{adapter = Mod}) -> Mod:supports_changing_current_schema().

catalog(#conn{adapter = Mod, handle = H}) -> Mod:catalog(H).
current_user(#conn{adapter = Mod, handle = H}) -> Mod:current_user(H).

%% The effective schema managed for this run.
schema_name(_Conn, #eflyway_config{schemas = [S | _]}) -> S;
schema_name(_Conn, #eflyway_config{default_schema = S}) when S =/= undefined -> S;
schema_name(Conn, _Config) -> catalog(Conn).

%% @doc {ProductName, "Major.Minor"} used for the connection info line.
server_info(#conn{adapter = Mod, handle = H}) -> Mod:server_info(H).

installed_by(#conn{adapter = Mod, handle = H}, #eflyway_config{installed_by = undefined}) ->
    Mod:current_user(H);
installed_by(_Conn, #eflyway_config{installed_by = InstalledBy}) ->
    InstalledBy.

quote(#conn{adapter = Mod}, Identifier) -> Mod:quote(Identifier).
boolean_true(#conn{adapter = Mod}) -> Mod:boolean_true().
boolean_false(#conn{adapter = Mod}) -> Mod:boolean_false().

create_history_ddl(#conn{adapter = Mod}, Table, Baseline) -> Mod:create_history_ddl(Table, Baseline).

dialect(#conn{adapter = Mod}) -> Mod:dialect().

table_exists(#conn{adapter = Mod, handle = H}, Table) -> Mod:table_exists(H, Table).
all_tables(#conn{adapter = Mod, handle = H}, Schema) -> Mod:all_tables(H, Schema).

schema_exists(#conn{adapter = Mod, handle = H}, Schema) -> Mod:schema_exists(H, Schema).
schema_empty(#conn{adapter = Mod, handle = H}, Schema) -> Mod:schema_empty(H, Schema).
create_schema(#conn{adapter = Mod, handle = H}, Schema) -> Mod:create_schema(H, Schema).
drop_schema(#conn{adapter = Mod, handle = H}, Schema) -> Mod:drop_schema(H, Schema).
clean_schema(#conn{adapter = Mod, handle = H}, Schema) -> Mod:clean_schema(H, Schema).

adapter(mysql) -> eflyway_db_mysql;
adapter(sqlite) -> eflyway_db_sqlite.
