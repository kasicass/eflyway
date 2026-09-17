%% @doc Parsed SQL script plus execution.
-module(eflyway_sql_script).

-include("eflyway.hrl").

-export([parse/3, parse/4, execute/2, statements/1, executes_in_transaction/1]).

-spec parse(#resource{}, #eflyway_config{}, map()) -> #sql_script{}.
parse(Resource, Config, Dialect) ->
    parse(Resource, Config, Dialect, #{}).

-spec parse(#resource{}, #eflyway_config{}, map(), map()) -> #sql_script{}.
parse(#resource{absolute = Path} = Resource, Config, Dialect, Builtins) ->
    Raw = read(Path),
    Content = eflyway_placeholder:replace(Raw, Config, Builtins),
    Statements = eflyway_parser:parse(Content, Dialect),
    Executes = lists:all(fun(#statement{can_execute_in_transaction = B}) -> B end, Statements),
    #sql_script{resource = Resource, statements = Statements,
                executes_in_transaction = Executes}.

-spec execute(term(), #sql_script{}) -> ok.
execute(Conn, #sql_script{statements = Statements}) ->
    lists:foreach(fun(#statement{sql = Sql}) ->
        case eflyway_db:execute(Conn, Sql) of
            ok -> ok;
            {error, Reason} ->
                eflyway_error:raise(migration_sql_failed,
                    ["Failed to execute SQL: ", Sql], #{reason => Reason})
        end
    end, Statements).

-spec statements(#sql_script{}) -> [#statement{}].
statements(#sql_script{statements = S}) -> S.

-spec executes_in_transaction(#sql_script{}) -> boolean().
executes_in_transaction(#sql_script{executes_in_transaction = E}) -> E.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} ->
            eflyway_error:raise(resource_read_failed, [Path], #{reason => Reason})
    end.
