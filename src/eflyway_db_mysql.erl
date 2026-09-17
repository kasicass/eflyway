%% @doc MySQL database adapter.
%%
%% NOTE: placeholder implementation (Phase M5 completes it).
-module(eflyway_db_mysql).
-behaviour(eflyway_db).

-include("eflyway.hrl").

-export([connect/1, disconnect/1,
         execute/2, query/2, query/3,
         transaction/2, lock/3,
         supports_ddl_transactions/0, supports_changing_current_schema/0,
         catalog/1, current_user/1,
         quote/1, boolean_true/0, boolean_false/0,
         create_history_ddl/2,
         dialect/0,
         table_exists/2, all_tables/2,
         schema_exists/2, schema_empty/2,
         create_schema/2, drop_schema/2, clean_schema/2]).

connect(#db_url{}) ->
    {error, mysql_not_implemented}.

disconnect(_) -> ok.

execute(_, _) -> {error, mysql_not_implemented}.
query(_, _) -> {error, mysql_not_implemented}.
query(_, _, _) -> {error, mysql_not_implemented}.
transaction(_, _) -> {error, mysql_not_implemented}.
lock(_, _, _) -> {error, mysql_not_implemented}.
supports_ddl_transactions() -> false.
supports_changing_current_schema() -> true.
catalog(_) -> <<>>.
current_user(_) -> <<>>.
quote(Identifier) -> <<"`", Identifier/binary, "`">>.
boolean_true() -> <<"1">>.
boolean_false() -> <<"0">>.
create_history_ddl(_, _) -> [].
dialect() -> eflyway_parser_mysql:dialect().
table_exists(_, _) -> false.
all_tables(_, _) -> [].
schema_exists(_, _) -> false.
schema_empty(_, _) -> true.
create_schema(_, _) -> ok.
drop_schema(_, _) -> ok.
clean_schema(_, _) -> ok.
