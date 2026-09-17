%% @doc MySQL dialect for eflyway_parser.
-module(eflyway_parser_mysql).

-export([dialect/0, parse/1]).

-spec dialect() -> map().
dialect() ->
    #{default_delimiter => <<";">>,
      alt_string_quote => $",
      backslash_escapes => true,
      line_comment_hash => true,
      delimiter_directive => true,
      sqlite_blocks => false,
      stored_programs => true}.

-spec parse(binary()) -> [tuple()].
parse(Bin) ->
    eflyway_parser:parse(Bin, dialect()).
