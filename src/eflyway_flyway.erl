%% @doc Facade: connection lifecycle and command wiring.
-module(eflyway_flyway).

-include("eflyway.hrl").

-export([migrate/1, with_connection/2]).

-spec migrate(#eflyway_config{}) -> map().
migrate(Config) ->
    with_connection(Config, fun(Conn, Dialect, Builtins) ->
        Resolved = eflyway_resolver:resolve(Config, Dialect, Builtins),
        eflyway_cmd_migrate:migrate(Conn, Config, Resolved)
    end).

-spec with_connection(#eflyway_config{}, fun((term(), map(), map()) -> R)) -> R.
with_connection(Config, Fun) ->
    case eflyway_url:parse(Config#eflyway_config.url) of
        {ok, Url0} ->
            Url = apply_credentials(Url0, Config),
            case connect_with_retries(Url, Config#eflyway_config.connect_retries) of
                {ok, Conn} ->
                    try
                        Builtins = builtins(Conn, Config),
                        Fun(Conn, eflyway_db:dialect(Conn), Builtins)
                    after
                        eflyway_db:disconnect(Conn)
                    end;
                {error, Reason} ->
                    eflyway_error:raise(connection_failed,
                        [Config#eflyway_config.url], #{reason => Reason})
            end;
        {error, Reason} ->
            eflyway_error:raise(invalid_url,
                [Config#eflyway_config.url], #{reason => Reason})
    end.

apply_credentials(Url, Config) ->
    Url1 = case Config#eflyway_config.user of
               undefined -> Url;
               U -> Url#db_url{user = U}
           end,
    case Config#eflyway_config.password of
        undefined -> Url1;
        P -> Url1#db_url{password = P}
    end.

connect_with_retries(Url, Retries) ->
    case eflyway_db:connect(Url) of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} when Retries > 0 ->
            eflyway_log:warn("Connection failed, retrying in 1 sec ..."),
            timer:sleep(1000),
            connect_with_retries(Url, Retries - 1);
        {error, Reason} -> {error, Reason}
    end.

builtins(Conn, Config) ->
    Schema = eflyway_db:schema_name(Conn, Config),
    eflyway_placeholder:builtins(#{
        <<"defaultSchema">> => Schema,
        <<"user">> => eflyway_db:current_user(Conn),
        <<"database">> => eflyway_db:catalog(Conn),
        <<"timestamp">> => timestamp()
    }).

timestamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:local_time(),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                                   [Y, Mo, D, H, Mi, S])).
