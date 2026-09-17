%% @doc SQLite dialect for eflyway_parser.
-module(eflyway_parser_sqlite).

-export([dialect/0, parse/1]).

-spec dialect() -> map().
dialect() ->
    #{default_delimiter => <<";">>,
      alt_string_quote => undefined,
      backslash_escapes => false,
      line_comment_hash => false,
      delimiter_directive => false,
      sqlite_blocks => true,
      stored_programs => false}.

-spec parse(binary()) -> [tuple()].
parse(Bin) ->
    eflyway_parser:parse(Bin, dialect()).
