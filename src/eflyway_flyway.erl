%% @doc Facade: connection lifecycle and command wiring.
-module(eflyway_flyway).

-include("eflyway.hrl").

-export([migrate/1, validate/1, info/1, baseline/1, clean/1, repair/1,
         with_connection/2]).

-spec migrate(#eflyway_config{}) -> map().
migrate(Config) ->
    with_connection(Config, fun(Conn, Dialect, Builtins) ->
        Resolved = eflyway_resolver:resolve(Config, Dialect, Builtins),
        eflyway_cmd_migrate:migrate(Conn, Config, Resolved)
    end).

-spec validate(#eflyway_config{}) -> map().
validate(Config) ->
    with_connection(Config, fun(Conn, Dialect, Builtins) ->
        Resolved = eflyway_resolver:resolve(Config, Dialect, Builtins),
        Result = eflyway_cmd_validate:validate(Conn, Config, Resolved),
        case {maps:get(validation_successful, Result),
              Config#eflyway_config.clean_on_validation_error} of
            {false, true} ->
                _ = eflyway_cmd_clean:clean(Conn, Config),
                Result;
            {false, false} ->
                eflyway_error:raise(validate_error, format_errors(maps:get(errors, Result)));
            _ ->
                Result
        end
    end).

-spec info(#eflyway_config{}) -> [#migration_info{}].
info(Config) ->
    with_connection(Config, fun(Conn, Dialect, Builtins) ->
        Resolved = eflyway_resolver:resolve(Config, Dialect, Builtins),
        eflyway_cmd_info:info(Conn, Config, Resolved)
    end).

-spec baseline(#eflyway_config{}) -> map().
baseline(Config) ->
    with_connection(Config, fun(Conn, _Dialect, _Builtins) ->
        eflyway_cmd_baseline:baseline(Conn, Config)
    end).

-spec clean(#eflyway_config{}) -> map().
clean(Config) ->
    with_connection(Config, fun(Conn, _Dialect, _Builtins) ->
        eflyway_cmd_clean:clean(Conn, Config)
    end).

-spec repair(#eflyway_config{}) -> map().
repair(Config) ->
    with_connection(Config, fun(Conn, Dialect, Builtins) ->
        Resolved = eflyway_resolver:resolve(Config, Dialect, Builtins),
        eflyway_cmd_repair:repair(Conn, Config, Resolved)
    end).

format_errors(Errors) ->
    iolist_to_binary(lists:join(<<"\n" >>,
        [io_lib:format("~s: ~s", [Code, Msg]) || {Code, Msg} <- Errors])).

-spec with_connection(#eflyway_config{}, fun((term(), map(), map()) -> R)) -> R.
with_connection(Config, Fun) ->
    case eflyway_url:parse(Config#eflyway_config.url) of
        {ok, Url0} ->
            Url = apply_credentials(Url0, Config),
            case connect_with_retries(Url, Config) of
                {ok, Conn} ->
                    try
                        maybe_print_database_info(Conn, Config),
                        Builtins = builtins(Conn, Config),
                        Fun(Conn, eflyway_db:dialect(Conn), Builtins)
                    after
                        eflyway_db:disconnect(Conn)
                    end;
                {error, {database_does_not_exist, Db}} ->
                    eflyway_error:raise(database_does_not_exist,
                        ["Database ", Db, " does not exist. Create it first."],
                        #{database => Db});
                {error, Reason} ->
                    eflyway_error:raise(connection_failed,
                        ["Unable to connect to ", filter_url(Config#eflyway_config.url),
                         ": ", format_reason(Reason)],
                        #{reason => Reason})
            end;
        {error, Reason} ->
            eflyway_error:raise(invalid_url,
                [Config#eflyway_config.url], #{reason => Reason})
    end.

%% Prints the connection banner once per process, mirroring Flyway's
%% DatabaseType.createDatabase(..., printInfo=true).
maybe_print_database_info(Conn, Config) ->
    case get(eflyway_db_info_printed) of
        true -> ok;
        _ ->
            put(eflyway_db_info_printed, true),
            {Product, Version} = eflyway_db:server_info(Conn),
            Url = filter_url(Config#eflyway_config.url),
            Description = case Version of
                              <<>> -> Product;
                              _ -> <<Product/binary, " ", Version/binary>>
                          end,
            eflyway_log:info("Database: ~s (~s)", [Url, Description])
    end.

%% Strip credentials and query parameters from a URL for display.
filter_url(Url) ->
    NoQuery = case binary:split(Url, <<"?">>) of
                  [U, _] -> U;
                  [U] -> U
              end,
    re:replace(NoQuery, <<"://[^@/]*@">>, <<"://">>, [{return, binary}]).

%% Turn a driver error term into a short human readable message.
format_reason({mysql_connect_failed, Reason}) -> format_reason(Reason);
format_reason({sqlite_open_failed, _Path, Reason}) -> format_reason(Reason);
format_reason({sqlite_directory_does_not_exist, Dir}) ->
    ["Directory ", Dir, " does not exist. Create it first"];
format_reason({Code, _SqlState, Message}) when is_integer(Code), is_binary(Message) ->
    [Message, " (", integer_to_binary(Code), ")"];
format_reason(Reason) -> io_lib:format("~p", [Reason]).

apply_credentials(Url, Config) ->
    Url1 = case Config#eflyway_config.user of
               undefined -> Url;
               U -> Url#db_url{user = U}
           end,
    case Config#eflyway_config.password of
        undefined -> Url1;
        P -> Url1#db_url{password = P}
    end.

connect_with_retries(Url, Config) ->
    connect_with_retries(Url, Config#eflyway_config.connect_retries, Config).

connect_with_retries(Url, Retries, Config) ->
    case eflyway_db:connect(Url, Config) of
        {ok, Conn} -> {ok, Conn};
        {error, {database_does_not_exist, _} = Reason} -> {error, Reason};
        {error, _Reason} when Retries > 0 ->
            eflyway_log:warn("Connection failed, retrying in 1 sec ..."),
            timer:sleep(1000),
            connect_with_retries(Url, Retries - 1, Config);
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
