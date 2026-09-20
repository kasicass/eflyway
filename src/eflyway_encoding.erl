%% @doc Normalise migration file bytes to UTF-8 according to the configured
%% `encoding'. eflyway works with UTF-8 internally; a non-UTF-8 script is
%% converted once, on read, before placeholder replacement, parsing and
%% checksum calculation.
-module(eflyway_encoding).

-export([to_utf8/2]).

-spec to_utf8(binary(), utf8 | latin1) -> binary().
to_utf8(Bin, utf8) -> Bin;
to_utf8(Bin, latin1) -> unicode:characters_to_binary(Bin, latin1, utf8).
