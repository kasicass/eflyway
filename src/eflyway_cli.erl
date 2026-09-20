%% @doc Command line interface: argument parsing, dispatch and output.
-module(eflyway_cli).

-include("eflyway.hrl").

-export([run/1]).

%% Exported for testing.
-export([render_table/2, info_row/1, version/0]).

-spec run([string()]) -> non_neg_integer().
run(Args) ->
    erase(eflyway_db_info_printed),
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

run_command(Command, Config) ->
    print_banner(),
    execute_command(Command, Config).

execute_command(<<"migrate">>, Config) ->
    eflyway_flyway:migrate(Config),
    ok;
execute_command(<<"validate">>, Config) ->
    eflyway_flyway:validate(Config),
    ok;
execute_command(<<"info">>, Config) ->
    Infos = eflyway_flyway:info(Config),
    print_info(Infos),
    ok;
execute_command(<<"baseline">>, Config) ->
    eflyway_flyway:baseline(Config),
    ok;
execute_command(<<"clean">>, Config) ->
    eflyway_flyway:clean(Config),
    ok;
execute_command(<<"repair">>, Config) ->
    eflyway_flyway:repair(Config),
    ok;
execute_command(Other, _Config) ->
    eflyway_error:raise(unknown_command, [Other]).

%% Print the version banner at the start of every command.
print_banner() ->
    eflyway_log:info("eFlyway Version: ~s", [version()]).

%% Read the version from the application spec (eflyway.app, generated from
%% eflyway.app.src). Falls back to "unknown" if the app cannot be loaded.
-spec version() -> string().
version() ->
    case application:get_key(eflyway, vsn) of
        {ok, Vsn} -> Vsn;
        undefined ->
            _ = application:load(eflyway),
            case application:get_key(eflyway, vsn) of
                {ok, Vsn} -> Vsn;
                _ -> "unknown"
            end
    end.

%% ---------------------------------------------------------------------
%% info table
%% ---------------------------------------------------------------------

print_info(Infos) ->
    io:format("Schema version: ~s~n~n", [current_version_display(Infos)]),
    Headers = [<<"Category">>, <<"Version">>, <<"Description">>, <<"Type">>,
               <<"Installed On">>, <<"State">>],
    Rows = [info_row(I) || I <- Infos],
    io:format("~s~n", [render_table(Headers, Rows)]).

current_version_display(Infos) ->
    case eflyway_info_service:current(Infos) of
        undefined -> <<"<< Empty Schema >>">>;
        Info ->
            case info_version(Info) of
                undefined -> <<"<< Empty Schema >>">>;
                V -> eflyway_migration_version:display(V)
            end
    end.

info_version(#migration_info{resolved = undefined, applied = A}) -> A#applied.version;
info_version(#migration_info{resolved = R}) -> R#resolved.version.

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
        V -> truncate_seconds(V)
    end.

%% Render Installed On as an ISO timestamp without sub-second part.
truncate_seconds(V) when is_binary(V), byte_size(V) >= 19 -> binary:part(V, 0, 19);
truncate_seconds(V) -> to_bin(V).

%% ASCII table rendering.
render_table(Columns, Rows) ->
    Widths = column_widths(Columns, Rows),
    Ruler = ruler_content(Widths),
    Header = header_line(Columns, Widths),
    Body = case Rows of
               [] -> empty_line(byte_size(Ruler), <<"No migrations found">>);
               _ -> [row_line(R, Widths) || R <- Rows]
           end,
    iolist_to_binary([Ruler, "\n", Header, Ruler, "\n", Body, Ruler, "\n"]).

column_widths(Columns, Rows) ->
    [lists:max([string:length(C) | [string:length(cell(R, I)) || R <- Rows]])
     || {C, I} <- lists:zip(Columns, lists:seq(1, length(Columns)))].

cell(Row, I) -> to_bin(lists:nth(I, Row)).

ruler_content(Widths) ->
    iolist_to_binary([<<"+">>,
        [[<<"-">>, lists:duplicate(W, $-), <<"-+">>] || W <- Widths]]).

header_line(Columns, Widths) ->
    Cells = [pad_cell(C, W) || {C, W} <- lists:zip(Columns, Widths)],
    iolist_to_binary([<<"|">>, [[<<" ">>, Cell, <<" |">>] || Cell <- Cells], <<"\n">>]).

row_line(Row, Widths) ->
    Cells = [pad_cell(to_bin(lists:nth(I, Row)), W)
             || {W, I} <- lists:zip(Widths, lists:seq(1, length(Widths)))],
    iolist_to_binary([<<"|">>, [[<<" ">>, Cell, <<" |">>] || Cell <- Cells], <<"\n">>]).

%% Empty row: "| " + trimOrPad(emptyText, ruler.length() - 5) + " |\n", where
%% ruler.length() includes the trailing newline; RulerLen here excludes it.
empty_line(RulerLen, EmptyText) ->
    iolist_to_binary([<<"| ">>, pad_cell(EmptyText, RulerLen - 4), <<" |\n">>]).

pad_cell(Cell, Width) ->
    CellBin = to_bin(Cell),
    Pad = Width - string:length(CellBin),
    iolist_to_binary([CellBin, lists:duplicate(erlang:max(Pad, 0), $\s)]).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

%% ---------------------------------------------------------------------
%% Usage
%% ---------------------------------------------------------------------

print_version() ->
    io:format("eFlyway Version: ~s~n", [version()]).

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
        "target               : Target version up to which migrations should be applied~n"
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
        "-v  : Print the version and exit~n"
        "-?  : Print this usage info and exit~n~n"
        "Example~n"
        "-------~n"
        "eflyway -url=sqlite3:///tmp/app.db -locations=filesystem:sql migrate~n").
