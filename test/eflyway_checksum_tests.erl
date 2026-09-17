-module(eflyway_checksum_tests).

-include_lib("eunit/include/eunit.hrl").

checksum(Content) ->
    Path = tmp(),
    ok = file:write_file(Path, Content),
    try eflyway_checksum:of_file(Path)
    after file:delete(Path)
    end.

simple_test() ->
    ?assertEqual(signed(erlang:crc32(<<"abc">>)), checksum(<<"abc">>)).

line_endings_independent_test() ->
    ?assertEqual(checksum(<<"a\nb\n">>), checksum(<<"a\r\nb\r\n">>)),
    ?assertEqual(checksum(<<"a\nb">>), checksum(<<"a\rb">>)),
    ?assertEqual(signed(erlang:crc32(<<"ab">>)), checksum(<<"a\nb\n">>)).

trailing_newline_test() ->
    %% A trailing terminator does not add an empty line.
    ?assertEqual(checksum(<<"a">>), checksum(<<"a\n">>)).

bom_test() ->
    ?assertEqual(checksum(<<"a">>), checksum(<<16#EF, 16#BB, 16#BF, "a">>)).

empty_test() ->
    ?assertEqual(0, checksum(<<>>)).

binary_test() ->
    ?assertEqual(signed(erlang:crc32(<<"hello">>)), eflyway_checksum:of_binary(<<"hello">>)).

signed(N) when N >= 16#80000000 -> N - 16#100000000;
signed(N) -> N.

tmp() ->
    filename:join("/tmp", "eflyway_crc_" ++ integer_to_list(erlang:unique_integer([positive]))).
