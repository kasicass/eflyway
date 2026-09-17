%% @doc Command line interface: argument parsing, dispatch and output.
-module(eflyway_cli).

-include("eflyway.hrl").

-export([run/1]).

-define(VERSION, "0.1.0").

-spec run([string()]) -> non_neg_integer().
run(Args) ->
    case parse(Args, [], #{}, []) of
        {ok, Flags, Options, Commands} ->
            eflyway_log:set_level(level(Flags)),
            case special(Flags, Commands) of
                {exit, Code} -> Code;
                continue ->
                    case Commands of
                        [] -> print_usage(), 0;
                        _ -> run_commands(Commands, Options)
                    end
            end;
        {error, Message} ->
            io:format(standard_error, "ERROR: ~s~n", [Message]),
            2
    end.

%% ---------------------------------------------------------------------
%% Argument parsing
%% ---------------------------------------------------------------------

parse([], Flags, Options, Commands) ->
    {ok, lists:reverse(Flags), Options, lists:reverse(Commands)};
parse([Arg | Rest], Flags, Options, Commands) ->
    case Arg of
        "-?" -> parse(Rest, [help | Flags], Options, Commands);
        "-v" -> parse(Rest, [version | Flags], Options, Commands);
        "-X" -> parse(Rest, [debug | Flags], Options, Commands);
        "-q" -> parse(Rest, [quiet | Flags], Options, Commands);
        "-n" -> parse(Rest, [noprompt | Flags], Options, Commands);
        "-json" -> parse(Rest, [json | Flags], Options, Commands);
        "-community" -> parse(Rest, Flags, Options, Commands);
        [$- | _] ->
            case string:split(Arg, "=", leading) of
                [Key0, Value] ->
                    Key = strip_dash(Key0),
                    parse(Rest, Flags,
                          maps:put(unicode:characters_to_binary(Key),
                                   unicode:characters_to_binary(Value), Options),
                          Commands);
                _ ->
                    {error, "Invalid argument: " ++ Arg}
            end;
        _ ->
            parse(Rest, Flags, Options,
                  [unicode:characters_to_binary(Arg) | Commands])
    end.

strip_dash([$- | Rest]) -> Rest;
strip_dash(Other) -> Other.

level(Flags) ->
    case {lists:member(quiet, Flags), lists:member(debug, Flags)} of
        {true, _} -> warn;
        {false, true} -> debug;
        _ -> info
    end.

special(Flags, Commands) ->
    case lists:member(help, Flags) of
        true -> print_usage(), {exit, 0};
        false ->
            case lists:member(version, Flags) of
                true -> print_version(), {exit, 0};
                false ->
                    case Commands of
                        [] -> print_usage(), {exit, 0};
                        _ -> continue
                    end
            end
    end.

%% ---------------------------------------------------------------------
%% Command execution
%% ---------------------------------------------------------------------

run_commands(Commands, Options) ->
    {ok, Config} = eflyway_config:load(Options),
    try
        lists:foreach(fun(Command) -> run_command(Command, Config) end, Commands),
        0
    catch
        error:{eflyway_error, Code, Message, _Details} ->
            io:format(standard_error, "ERROR: ~s: ~s~n", [Code, Message]),
            1;
        Class:Reason:Stacktrace ->
            io:format(standard_error, "ERROR: ~p~n", [{Class, Reason, Stacktrace}]),
            1
    end.

run_command(<<"migrate">>, Config) ->
    eflyway_flyway:migrate(Config),
    ok;
run_command(<<"validate">>, Config) ->
    eflyway_flyway:validate(Config),
    ok;
run_command(<<"info">>, Config) ->
    Infos = eflyway_flyway:info(Config),
    print_info(Infos),
    ok;
run_command(<<"baseline">>, Config) ->
    eflyway_flyway:baseline(Config),
    ok;
run_command(<<"clean">>, Config) ->
    eflyway_flyway:clean(Config),
    ok;
run_command(<<"repair">>, Config) ->
    eflyway_flyway:repair(Config),
    ok;
run_command(Other, _Config) ->
    eflyway_error:raise(unknown_command, [Other]).

%% ---------------------------------------------------------------------
%% info table
%% ---------------------------------------------------------------------

print_info(Infos) ->
    Headers = [<<"Category">>, <<"Version">>, <<"Description">>, <<"Type">>,
               <<"Installed On">>, <<"State">>],
    Rows = [info_row(I) || I <- Infos],
    io:format("~s~n", [render_table(Headers, Rows)]).

info_row(Info) ->
    [category(Info),
     version_str(Info),
     description(Info),
     type_str(Info),
     installed_on(Info),
     eflyway_migration_state:display(eflyway_info_service:state(Info))].

category(#migration_info{resolved = undefined, applied = A}) ->
    category_type(A#applied.type, A#applied.version);
category(#migration_info{resolved = R}) ->
    category_type(R#resolved.type, R#resolved.version).

category_type(Type, Version) ->
    case eflyway_migration_type:is_synthetic(Type) of
        true -> <<>>;
        false ->
            case Version of
                undefined -> <<"Repeatable">>;
                _ -> <<"Versioned">>
            end
    end.

version_str(#migration_info{resolved = undefined, applied = A}) ->
    version_display(A#applied.version);
version_str(#migration_info{resolved = R}) ->
    version_display(R#resolved.version).

version_display(undefined) -> <<>>;
version_display(V) -> eflyway_migration_version:display(V).

description(#migration_info{resolved = undefined, applied = A}) -> A#applied.description;
description(#migration_info{resolved = R}) -> R#resolved.description.

type_str(#migration_info{resolved = undefined, applied = A}) ->
    eflyway_migration_type:to_string(A#applied.type);
type_str(#migration_info{resolved = R}) ->
    eflyway_migration_type:to_string(R#resolved.type).

installed_on(#migration_info{applied = undefined}) -> <<>>;
installed_on(#migration_info{applied = A}) ->
    case A#applied.installed_on of
        undefined -> <<>>;
        V -> V
    end.

render_table(Headers, []) ->
    render_table(Headers, [[<<"No migrations found">>]]);
render_table(Headers, Rows) ->
    AllRows = [Headers | Rows],
    Widths = column_widths(AllRows, length(Headers)),
    Sep = separator(Widths),
    Lines = [row_line(Headers, Widths), Sep | [row_line(R, Widths) || R <- Rows]],
    lists:join(<<"\n">>, Lines).

column_widths(Rows, N) ->
    [lists:max([cell_width(R, I) || R <- Rows]) || I <- lists:seq(1, N)].

cell_width(Row, I) ->
    case length(Row) >= I of
        true -> string:length(lists:nth(I, Row));
        false -> 0
    end.

row_line(Row, Widths) ->
    Cells = lists:zip(Widths, pad_row(Row, length(Widths))),
    iolist_to_binary([<<"| ">>,
        lists:join(<<" | ">>, [pad_cell(Cell, W) || {W, Cell} <- Cells]),
        <<" |">>]).

pad_row(Row, N) when length(Row) >= N -> Row;
pad_row(Row, N) -> Row ++ lists:duplicate(N - length(Row), <<>>).

pad_cell(Cell, Width) ->
    CellBin = to_bin(Cell),
    Pad = Width - string:length(CellBin),
    iolist_to_binary([CellBin, lists:duplicate(max(Pad, 0), $\s)]).

separator(Widths) ->
    iolist_to_binary([<<"+">>,
        lists:join(<<"+">>, [lists:duplicate(W + 2, $-) || W <- Widths]),
        <<"+">>]).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

%% ---------------------------------------------------------------------
%% Usage
%% ---------------------------------------------------------------------

print_version() ->
    io:format("eflyway ~s~n", [?VERSION]).

print_usage() ->
    io:format(
        "Usage~n"
        "=====~n~n"
        "eflyway [options] command~n~n"
        "Commands~n"
        "--------~n"
        "migrate  : Migrates the database~n"
        "clean    : Drops all objects in the configured schemas~n"
        "info     : Prints the information about applied, current and pending migrations~n"
        "validate : Validates the applied migrations against the ones on disk~n"
        "baseline : Baselines an existing database at the baselineVersion~n"
        "repair   : Repairs the schema history table~n~n"
        "Options (Format: -key=value)~n"
        "-------~n"
        "url                  : Database URL (mysql://... or sqlite3://...)~n"
        "user                 : User to use to connect to the database~n"
        "password             : Password to use to connect to the database~n"
        "locations            : Comma-separated locations to scan for migrations~n"
        "table                : Name of the schema history table~n"
        "schemas              : Comma-separated list of managed schemas~n"
        "baselineVersion      : Version to tag schema with when executing baseline~n"
        "baselineOnMigrate    : Baseline on migrate against uninitialized non-empty schema~n"
        "target               : Target version up to which Flyway should use migrations~n"
        "outOfOrder           : Allows migrations to be run \"out of order\"~n"
        "placeholderReplacement : Whether placeholders should be replaced~n"
        "placeholders.*       : Custom placeholders (e.g. -placeholders.env=dev)~n"
        "configFiles          : Comma-separated list of config files to use~n"
        "validateOnMigrate    : Validate when running migrate~n"
        "cleanDisabled        : Whether to disable clean~n~n"
        "Flags~n"
        "-----~n"
        "-X  : Print debug output~n"
        "-q  : Suppress all output, except for errors and warnings~n"
        "-n  : Suppress prompting for a user and password~n"
        "-v  : Print the version and exit~n"
        "-?  : Print this usage info and exit~n~n"
        "Example~n"
        "-------~n"
        "eflyway -url=sqlite3:///tmp/app.db -locations=filesystem:sql migrate~n").
