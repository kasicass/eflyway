%% @doc CRC32 checksum, replicating org.flywaydb.core.internal.resolver.ChecksumCalculator.
%%
%% The checksum is line-ending independent and BOM tolerant: every line
%% (without its terminator) is fed to CRC32 as UTF-8 bytes.
-module(eflyway_checksum).

-export([of_file/1, of_binary/1]).

-spec of_file(file:name_all()) -> integer().
of_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> of_binary(Bin);
        {error, Reason} ->
            eflyway_error:raise(checksum_read_failed, [Path, ": ", io_lib:format("~p", [Reason])])
    end.

-spec of_binary(binary()) -> integer().
of_binary(Bin) ->
    Lines = read_lines(Bin),
    case Lines of
        [] -> 0;
        [First | Rest] ->
            First1 = strip_bom(First),
            Crc = lists:foldl(fun(Line, Acc) -> erlang:crc32(Acc, Line) end,
                              erlang:crc32(First1), Rest),
            signed32(Crc)
    end.

%% Emulates java.io.BufferedReader.readLine/0 line splitting.
read_lines(Bin) ->
    Normalized0 = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    Normalized = binary:replace(Normalized0, <<"\r">>, <<"\n">>, [global]),
    case binary:split(Normalized, <<"\n">>, [global]) of
        [] -> [];
        Parts ->
            %% A trailing terminator does not create an extra empty line.
            case lists:last(Parts) of
                <<>> -> lists:droplast(Parts);
                _ -> Parts
            end
    end.

strip_bom(<<16#EF, 16#BB, 16#BF, Rest/binary>>) -> Rest;
strip_bom(Bin) -> Bin.

signed32(N) when N >= 16#80000000 -> N - 16#100000000;
signed32(N) -> N.
