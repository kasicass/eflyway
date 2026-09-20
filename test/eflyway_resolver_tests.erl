-module(eflyway_resolver_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eflyway.hrl").

resolve_test() ->
    with_dir(fun(Dir) ->
        write(Dir, "V1__init.sql", <<"CREATE TABLE a (id INTEGER);">>),
        write(Dir, "V2__add_b.sql", <<"CREATE TABLE b (id INTEGER);">>),
        write(Dir, "R__view.sql", <<"CREATE VIEW v AS SELECT 1;">>),
        write(Dir, "notes.txt", <<"ignored">>),
        Config = config(Dir),
        Resolved = eflyway_resolver:resolve(Config, eflyway_parser_sqlite:dialect()),
        ?assertEqual(3, length(Resolved)),
        [V1, V2, R] = Resolved,
        ?assertEqual(true, V1#resolved.version =/= undefined),
        ?assertEqual(eq, eflyway_migration_version:compare(
            V1#resolved.version, eflyway_migration_version:from_version(<<"1">>))),
        ?assertEqual(<<"init">>, V1#resolved.description),
        ?assertEqual(eq, eflyway_migration_version:compare(
            V2#resolved.version, eflyway_migration_version:from_version(<<"2">>))),
        ?assertEqual(undefined, R#resolved.version),
        ?assertEqual(<<"view">>, R#resolved.description),
        ?assertEqual(<<"V1__init.sql">>, filename:basename(V1#resolved.script)),
        %% checksum of versioned migration is the raw file checksum
        ?assertEqual(eflyway_checksum:of_binary(<<"CREATE TABLE a (id INTEGER);">>),
                     V1#resolved.checksum)
    end).

order_test() ->
    with_dir(fun(Dir) ->
        write(Dir, "V10__ten.sql", <<"SELECT 10;">>),
        write(Dir, "V2__two.sql", <<"SELECT 2;">>),
        write(Dir, "V1__one.sql", <<"SELECT 1;">>),
        Resolved = eflyway_resolver:resolve(config(Dir), eflyway_parser_sqlite:dialect()),
        Versions = [eflyway_migration_version:display(R#resolved.version) || R <- Resolved],
        ?assertEqual([<<"1">>, <<"2">>, <<"10">>], Versions)
    end).

repeatable_checksum_test() ->
    with_dir(fun(Dir) ->
        write(Dir, "R__view.sql", <<"CREATE VIEW v AS SELECT ${env};">>),
        Config = (config(Dir))#eflyway_config{placeholders = #{<<"env">> => <<"1">>}},
        [R] = eflyway_resolver:resolve(Config, eflyway_parser_sqlite:dialect()),
        ?assertEqual(eflyway_checksum:of_binary(<<"CREATE VIEW v AS SELECT 1;">>),
                     R#resolved.checksum),
        ?assertEqual(eflyway_checksum:of_binary(<<"CREATE VIEW v AS SELECT ${env};">>),
                     R#resolved.equivalent_checksum)
    end).

%% A latin1 script is converted to UTF-8 on read, so its checksum matches
%% the equivalent UTF-8 file.
encoding_latin1_test() ->
    with_dir(fun(Dir) ->
        Latin1 = <<"CREATE TABLE caf", 16#E9, " (id INTEGER);">>,
        Utf8 = <<"CREATE TABLE caf", 16#C3, 16#A9, " (id INTEGER);">>,
        write(Dir, "V1__init.sql", Latin1),
        ConfigL1 = (config(Dir))#eflyway_config{encoding = latin1},
        [R1] = eflyway_resolver:resolve(ConfigL1, eflyway_parser_sqlite:dialect()),
        write(Dir, "V1__init.sql", Utf8),
        [R2] = eflyway_resolver:resolve(config(Dir), eflyway_parser_sqlite:dialect()),
        ?assertEqual(R2#resolved.checksum, R1#resolved.checksum)
    end).

%% helpers

config(Dir) ->
    Location = <<"filesystem:", (unicode:characters_to_binary(Dir))/binary>>,
    (eflyway_config:defaults())#eflyway_config{locations = [Location]}.

write(Dir, Name, Content) ->
    ok = file:write_file(filename:join(Dir, Name), Content).

with_dir(Fun) ->
    Dir = filename:join("/tmp", "eflyway_res_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    try Fun(Dir)
    after file:del_dir_r(Dir)
    end.
