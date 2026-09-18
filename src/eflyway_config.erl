%% @doc Configuration loading and merging.
%%
%% Priority (low to high): built-in defaults < default flyway.conf files
%% < explicit config files < environment variables < command line options.
-module(eflyway_config).

-include("eflyway.hrl").

-export([defaults/0, load/1, apply_map/2, to_binary/1]).

-type config_map() :: #{binary() => binary()}.

-spec defaults() -> #eflyway_config{}.
defaults() ->
    #eflyway_config{}.

%% @doc Build a configuration from a map of command line options
%% (keys WITHOUT the "flyway." prefix).
-spec load(config_map()) -> {ok, #eflyway_config{}} | {error, term()}.
load(CliOpts) when is_map(CliOpts) ->
    Env = env_map(),
    Conf = load_configuration(CliOpts, Env),
    Merged = maps:merge(maps:merge(Conf, Env), CliOpts),
    {ok, apply_map(defaults(), Merged)}.

-spec apply_map(#eflyway_config{}, config_map()) -> #eflyway_config{}.
apply_map(Config, Map) ->
    maps:fold(fun apply_one/3, Config, Map).

apply_one(Key, Value, Config) ->
    set_field(Config, Key, to_binary(Value)).

%% ---------------------------------------------------------------------
%% Field application
%% ---------------------------------------------------------------------

set_field(C, <<"url">>, V) -> C#eflyway_config{url = V};
set_field(C, <<"user">>, V) -> C#eflyway_config{user = V};
set_field(C, <<"password">>, V) -> C#eflyway_config{password = V};
set_field(C, <<"locations">>, V) -> C#eflyway_config{locations = split_list(V)};
set_field(C, <<"table">>, V) -> C#eflyway_config{table = V};
set_field(C, <<"schemas">>, V) -> C#eflyway_config{schemas = split_list(V)};
set_field(C, <<"defaultSchema">>, V) -> C#eflyway_config{default_schema = V};
set_field(C, <<"encoding">>, V) -> C#eflyway_config{encoding = parse_encoding(V)};
set_field(C, <<"placeholderReplacement">>, V) -> C#eflyway_config{placeholder_replacement = parse_bool(V)};
set_field(C, <<"placeholderPrefix">>, V) -> C#eflyway_config{placeholder_prefix = V};
set_field(C, <<"placeholderSuffix">>, V) -> C#eflyway_config{placeholder_suffix = V};
set_field(C, <<"baselineVersion">>, V) -> C#eflyway_config{baseline_version = V};
set_field(C, <<"baselineDescription">>, V) -> C#eflyway_config{baseline_description = V};
set_field(C, <<"baselineOnMigrate">>, V) -> C#eflyway_config{baseline_on_migrate = parse_bool(V)};
set_field(C, <<"target">>, V) -> C#eflyway_config{target = non_empty(V)};
set_field(C, <<"outOfOrder">>, V) -> C#eflyway_config{out_of_order = parse_bool(V)};
set_field(C, <<"ignoreMissingMigrations">>, V) -> C#eflyway_config{ignore_missing_migrations = parse_bool(V)};
set_field(C, <<"ignoreIgnoredMigrations">>, V) -> C#eflyway_config{ignore_ignored_migrations = parse_bool(V)};
set_field(C, <<"ignorePendingMigrations">>, V) -> C#eflyway_config{ignore_pending_migrations = parse_bool(V)};
set_field(C, <<"ignoreFutureMigrations">>, V) -> C#eflyway_config{ignore_future_migrations = parse_bool(V)};
set_field(C, <<"validateOnMigrate">>, V) -> C#eflyway_config{validate_on_migrate = parse_bool(V)};
set_field(C, <<"validateMigrationNaming">>, V) -> C#eflyway_config{validate_migration_naming = parse_bool(V)};
set_field(C, <<"cleanOnValidationError">>, V) -> C#eflyway_config{clean_on_validation_error = parse_bool(V)};
set_field(C, <<"cleanDisabled">>, V) -> C#eflyway_config{clean_disabled = parse_bool(V)};
set_field(C, <<"createSchemas">>, V) -> C#eflyway_config{create_schemas = parse_bool(V)};
set_field(C, <<"mixed">>, V) -> C#eflyway_config{mixed = parse_bool(V)};
set_field(C, <<"group">>, V) -> C#eflyway_config{group = parse_bool(V)};
set_field(C, <<"installedBy">>, V) -> C#eflyway_config{installed_by = non_empty(V)};
set_field(C, <<"connectRetries">>, V) -> C#eflyway_config{connect_retries = parse_int(V)};
set_field(C, <<"lockRetryCount">>, V) -> C#eflyway_config{lock_retry_count = parse_int(V)};
set_field(C, <<"configFiles">>, V) -> C#eflyway_config{config_files = split_list(V)};
set_field(C, <<"configFileEncoding">>, V) -> C#eflyway_config{config_file_encoding = parse_encoding(V)};
set_field(C, <<"placeholders.", Rest/binary>>, V) ->
    C#eflyway_config{placeholders = maps:put(Rest, V, C#eflyway_config.placeholders)};
set_field(C, _Unknown, _V) ->
    C.

%% ---------------------------------------------------------------------
%% Environment variables
%% ---------------------------------------------------------------------

env_map() ->
    lists:foldl(fun env_entry/2, #{}, os:getenv()).

env_entry(Entry, Acc) ->
    case string:split(Entry, "=", leading) of
        ["FLYWAY_" ++ Rest, Value] ->
            Norm = normalize(string:lowercase(Rest)),
            case find_known(Norm) of
                {ok, Key} -> maps:put(Key, unicode:characters_to_binary(Value), Acc);
                error -> Acc
            end;
        _ ->
            Acc
    end.

find_known(Norm) ->
    case [K || K <- known_keys(), normalize(binary_to_list(K)) =:= Norm] of
        [Key | _] -> {ok, Key};
        [] -> error
    end.

normalize(Str) ->
    string:replace(Str, "_", "", all).

known_keys() ->
    [<<"url">>, <<"user">>, <<"password">>, <<"locations">>, <<"table">>,
     <<"schemas">>, <<"defaultSchema">>, <<"encoding">>,
     <<"placeholderReplacement">>, <<"placeholderPrefix">>, <<"placeholderSuffix">>,
     <<"baselineVersion">>, <<"baselineDescription">>, <<"baselineOnMigrate">>,
     <<"target">>, <<"outOfOrder">>,
     <<"ignoreMissingMigrations">>, <<"ignoreIgnoredMigrations">>,
     <<"ignorePendingMigrations">>, <<"ignoreFutureMigrations">>,
     <<"validateOnMigrate">>, <<"validateMigrationNaming">>,
     <<"cleanOnValidationError">>, <<"cleanDisabled">>, <<"createSchemas">>,
     <<"mixed">>, <<"group">>, <<"installedBy">>,
     <<"connectRetries">>, <<"lockRetryCount">>,
     <<"configFiles">>, <<"configFileEncoding">>].

%% ---------------------------------------------------------------------
%% Config files
%% ---------------------------------------------------------------------

load_configuration(CliOpts, Env) ->
    Effective = maps:merge(Env, CliOpts),
    Encoding = parse_encoding(maps:get(<<"configFileEncoding">>, Effective, <<"UTF-8">>)),
    Default = load_paths(default_conf_paths()),
    Explicit = load_paths(binary_list_to_strings(explicit_conf_paths(Effective))),
    _ = Encoding,
    maps:merge(Default, Explicit).

default_conf_paths() ->
    [filename:join([exe_dir(), "conf", "flyway.conf"]),
     filename:join([home_dir(), ".flyway.conf"]),
     "flyway.conf"].

explicit_conf_paths(Map) ->
    case maps:get(<<"configFiles">>, Map, undefined) of
        undefined -> [];
        V -> [P || P <- split_list(V), P =/= <<>>]
    end.

exe_dir() ->
    try
        filename:dirname(filename:absname(escript:script_name()))
    catch
        _:_ ->
            case file:get_cwd() of
                {ok, Cwd} -> Cwd;
                _ -> "."
            end
    end.

home_dir() ->
    case os:getenv("HOME") of
        false -> ".";
        "" -> ".";
        Home -> Home
    end.

load_paths(Paths) ->
    lists:foldl(fun(Path, Acc) -> maps:merge(Acc, read_conf_file(Path)) end, #{}, Paths).

read_conf_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> parse_conf(Bin);
        {error, _} -> #{}
    end.

parse_conf(Bin) ->
    Lines = binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global]),
    lists:foldl(fun parse_conf_line/2, #{}, Lines).

parse_conf_line(Line0, Acc) ->
    Line = string:trim(Line0),
    case Line of
        <<>> -> Acc;
        <<"#", _/binary>> -> Acc;
        <<";", _/binary>> -> Acc;
        _ ->
            case split_first(Line, <<"=">>) of
                {Key0, Value0} ->
                    Key = strip_flyway_prefix(string:trim(Key0)),
                    Value = string:trim(Value0),
                    case Key of
                        <<>> -> Acc;
                        _ -> maps:put(Key, Value, Acc)
                    end;
                nomatch -> Acc
            end
    end.

split_first(Bin, Sep) ->
    case binary:match(Bin, Sep) of
        {Pos, Len} ->
            {binary:part(Bin, 0, Pos),
             binary:part(Bin, Pos + Len, byte_size(Bin) - Pos - Len)};
        nomatch ->
            nomatch
    end.

strip_flyway_prefix(<<"flyway.", Rest/binary>>) -> Rest;
strip_flyway_prefix(Key) -> Key.

%% ---------------------------------------------------------------------
%% Value helpers
%% ---------------------------------------------------------------------

split_list(Bin) ->
    [string:trim(P) || P <- binary:split(Bin, <<",">>, [global]), string:trim(P) =/= <<>>].

binary_list_to_strings(List) ->
    [binary_to_list(B) || B <- List].

parse_bool(V) ->
    case string:lowercase(V) of
        <<"true">> -> true;
        <<"1">> -> true;
        <<"false">> -> false;
        <<"0">> -> false;
        _ -> false
    end.

parse_int(V) ->
    case string:to_integer(binary_to_list(V)) of
        {Int, _} when is_integer(Int) -> Int;
        _ -> 0
    end.

parse_encoding(V) ->
    case string:lowercase(V) of
        <<"utf-8">> -> utf8;
        <<"utf8">> -> utf8;
        <<"latin1">> -> latin1;
        <<"iso-8859-1">> -> latin1;
        _ -> utf8
    end.

non_empty(<<>>) -> undefined;
non_empty(V) -> V.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I).
