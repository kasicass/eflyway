-module(eflyway_cli_tests).

-include_lib("eunit/include/eunit.hrl").

usage_test() ->
    ?assertEqual(0, eflyway_cli:run(["-?"])).

version_test() ->
    ?assertEqual(0, eflyway_cli:run(["-v"])).

no_command_shows_usage_test() ->
    ?assertEqual(0, eflyway_cli:run([])).

invalid_argument_test() ->
    ?assertEqual(2, eflyway_cli:run(["-bogus"])).

migrate_and_validate_via_cli_test() ->
    with_env(fun(Dir, Db) ->
        ok = file:write_file(filename:join(Dir, "V1__init.sql"), <<"CREATE TABLE a (id INTEGER);">>),
        Url = "sqlite3://" ++ Db,
        Loc = "filesystem:" ++ Dir,
        eflyway_log:set_level(warn),
        ?assertEqual(0, eflyway_cli:run(["-url=" ++ Url, "-locations=" ++ Loc, "migrate"])),
        ?assertEqual(0, eflyway_cli:run(["-url=" ++ Url, "-locations=" ++ Loc, "validate"])),
        ?assertEqual(0, eflyway_cli:run(["-url=" ++ Url, "-locations=" ++ Loc, "info"])),
        ?assertEqual(0, eflyway_cli:run(["-url=" ++ Url, "-locations=" ++ Loc, "clean"])),
        eflyway_log:set_level(info)
    end).

unknown_command_test() ->
    with_env(fun(Dir, Db) ->
        Url = "sqlite3://" ++ Db,
        Loc = "filesystem:" ++ Dir,
        eflyway_log:set_level(warn),
        ?assertEqual(1, eflyway_cli:run(["-url=" ++ Url, "-locations=" ++ Loc, "frobnicate"])),
        eflyway_log:set_level(info)
    end).

with_env(Fun) ->
    Dir = filename:join("/tmp", "eflyway_cli_src_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    Db = filename:join("/tmp", "eflyway_cli_db_"
                       ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    ok = file:make_dir(Dir),
    try Fun(Dir, Db)
    after
        file:del_dir_r(Dir),
        file:delete(Db)
    end.
