%% @doc info command.
-module(eflyway_cmd_info).

-include("eflyway.hrl").

-export([info/3]).

-spec info(term(), #eflyway_config{}, [#resolved{}]) -> [#migration_info{}].
info(Conn, Config, Resolved) ->
    Applied = eflyway_schema_history:all_applied(Conn, Config),
    eflyway_info_service:refresh(Resolved, Applied, opts(Config)).

opts(Config) ->
    #{out_of_order => Config#eflyway_config.out_of_order,
      pending => true, missing => true, ignored => true, future => true,
      target => target(Config)}.

target(#eflyway_config{target = undefined}) -> undefined;
target(#eflyway_config{target = T}) -> eflyway_migration_version:from_version(T).
