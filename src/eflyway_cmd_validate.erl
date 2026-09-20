%% @doc validate command.
-module(eflyway_cmd_validate).

-include("eflyway.hrl").

-export([validate/3, validate/4]).

-spec validate(term(), #eflyway_config{}, [#resolved{}]) -> map().
validate(Conn, Config, Resolved) ->
    validate(Conn, Config, Resolved, #{}).

%% @doc Validate with extra opts overrides.
%%
%% Used by migrate's pre-validation, which forces `pending => true` so that
%% migrations which are merely not applied yet (and outdated repeatable
%% migrations) do not count as validation errors.
-spec validate(term(), #eflyway_config{}, [#resolved{}], map()) -> map().
validate(Conn, Config, Resolved, Overrides) ->
    Opts = maps:merge(opts(Config), Overrides),
    Schema = eflyway_db:schema_name(Conn, Config),
    case eflyway_db:schema_exists(Conn, Schema) of
        false ->
            case Resolved =/= [] andalso not maps:get(pending, Opts) of
                true ->
                    #{validation_successful => false, count => 0,
                      errors => [{schema_does_not_exist,
                                  <<"Schema ", Schema/binary, " doesn't exist yet">>}],
                      results => []};
                false ->
                    #{validation_successful => true, count => 0, errors => [], results => []}
            end;
        true ->
            Applied = eflyway_schema_history:all_applied(Conn, Config),
            Infos = eflyway_info_service:refresh(Resolved, Applied, Opts),
            Results = [{Info, eflyway_info_service:validate_one(Info)} || Info <- Infos],
            Errors = [{Code, Msg} || {_Info, {true, {Code, Msg}}} <- Results],
            Successful = Errors =:= [],
            case Successful of
                true ->
                    N = length(Infos),
                    case N of
                        1 -> eflyway_log:info("Successfully validated 1 migration");
                        _ -> eflyway_log:info("Successfully validated ~p migrations", [N])
                    end;
                false ->
                    eflyway_log:error("Migrations have failed validation"),
                    print_table(Results)
            end,
            #{validation_successful => Successful, count => length(Infos),
              errors => Errors, results => Results}
    end.

%% Only printed when validation fails.
print_table(Results) ->
    Headers = [<<"Category">>, <<"Version">>, <<"Description">>, <<"Type">>,
               <<"Installed On">>, <<"State">>, <<"Valid">>, <<"Error Code">>],
    Rows = [eflyway_cli:info_row(Info) ++ [valid_label(R), error_code(R)]
            || {Info, R} <- Results],
    io:format(standard_error, "~s~n", [eflyway_cli:render_table(Headers, Rows)]).

valid_label(false) -> <<"OK">>;
valid_label({true, _}) -> <<"FAIL">>.

error_code(false) -> <<>>;
error_code({true, {Code, _Msg}}) -> atom_to_binary(Code, utf8).

opts(Config) ->
    #{out_of_order => Config#eflyway_config.out_of_order,
      pending => Config#eflyway_config.ignore_pending_migrations,
      missing => Config#eflyway_config.ignore_missing_migrations,
      ignored => Config#eflyway_config.ignore_ignored_migrations,
      future => Config#eflyway_config.ignore_future_migrations,
      target => target(Config)}.

target(#eflyway_config{target = undefined}) -> undefined;
target(#eflyway_config{target = T}) -> eflyway_migration_version:from_version(T).
