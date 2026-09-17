%% @doc SQL script parser.
%%
%% Splits a SQL file into statements, honouring database specific delimiters,
%% comments, string literals, parenthesis depth and block depth.
%%
%% A dialect is a map with the following keys:
%%   default_delimiter    :: binary()
%%   alt_string_quote     :: undefined | byte()
%%   backslash_escapes    :: boolean()
%%   line_comment_hash    :: boolean()
%%   delimiter_directive  :: boolean()  (MySQL "DELIMITER x")
%%   sqlite_blocks        :: boolean()  (SQLite BEGIN/CASE/END)
%%   stored_programs      :: boolean()  (MySQL CREATE PROCEDURE/...)
-module(eflyway_parser).

-include("eflyway.hrl").

-export([parse/2]).

-record(tok, {
    type :: keyword | identifier | string | numeric | comment | blank_lines
          | symbol | delimiter | new_delimiter | eof,
    text = <<>> :: binary(),
    start = 0 :: non_neg_integer(),
    stop = 0 :: non_neg_integer(),
    line = 1 :: non_neg_integer(),
    col = 1 :: non_neg_integer(),
    parens = 0 :: non_neg_integer()
}).

-spec parse(binary(), map()) -> [#statement{}].
parse(Bin, Dialect) ->
    Tokens = tokenize(Bin, Dialect),
    split(Tokens, Bin, Dialect).

%% ---------------------------------------------------------------------
%% Tokenizer
%% ---------------------------------------------------------------------

tokenize(Bin, Dialect) ->
    Delim = maps:get(default_delimiter, Dialect, <<";">>),
    tokenize(Bin, 0, 1, 1, 0, Delim, Dialect, []).

tokenize(Bin, I, Line, Col, Parens, Delim, D, Acc) ->
    case I >= byte_size(Bin) of
        true ->
            lists:reverse([#tok{type = eof, start = I, stop = I, line = Line,
                                col = Col, parens = Parens} | Acc]);
        false ->
            case Delim =/= <<>> andalso matches_at(Bin, I, Delim) of
                true ->
                    Stop = I + byte_size(Delim),
                    Tok = #tok{type = delimiter, text = Delim, start = I, stop = Stop,
                               line = Line, col = Col, parens = Parens},
                    {NL, NC} = advance(Delim, Line, Col),
                    tokenize(Bin, Stop, NL, NC, Parens, Delim, D, [Tok | Acc]);
                false ->
                    scan_token(Bin, I, Line, Col, Parens, Delim, D, Acc)
            end
    end.

scan_token(Bin, I, Line, Col, Parens, Delim, D, Acc) ->
    C = binary:at(Bin, I),
    Size = byte_size(Bin),
    AltQuote = maps:get(alt_string_quote, D, undefined),
    Backslash = maps:get(backslash_escapes, D, false),
    Hash = maps:get(line_comment_hash, D, false),
    Directive = maps:get(delimiter_directive, D, false),
    Next = case I + 1 < Size of true -> binary:at(Bin, I + 1); false -> undefined end,
    IsWord = is_word_start(C),
    IsDigit = (C >= $0 andalso C =< $9),
    IsSpace = is_space(C),
    if
        C =:= $' ->
            emit_quoted(Bin, I, $', Backslash, string, Line, Col, Parens, Delim, D, Acc);
        AltQuote =/= undefined, C =:= AltQuote ->
            emit_quoted(Bin, I, C, Backslash, string, Line, Col, Parens, Delim, D, Acc);
        C =:= $[ ->
            emit_quoted(Bin, I, $], false, identifier, Line, Col, Parens, Delim, D, Acc);
        C =:= $" ->
            emit_quoted(Bin, I, $", false, identifier, Line, Col, Parens, Delim, D, Acc);
        C =:= $` ->
            emit_quoted(Bin, I, $`, false, identifier, Line, Col, Parens, Delim, D, Acc);
        C =:= $-, Next =:= $- ->
            emit(Bin, I, scan_to_eol(Bin, I), comment, Line, Col, Parens, Delim, D, Acc);
        C =:= $#, Hash =:= true ->
            emit(Bin, I, scan_to_eol(Bin, I), comment, Line, Col, Parens, Delim, D, Acc);
        C =:= $/, Next =:= $* ->
            emit(Bin, I, scan_block_comment(Bin, I + 2, 1), comment, Line, Col, Parens, Delim, D, Acc);
        C =:= $( ->
            emit_p(Bin, I, I + 1, symbol, Line, Col, Parens, Parens + 1, Delim, D, Acc);
        C =:= $) ->
            emit_p(Bin, I, I + 1, symbol, Line, Col, Parens, dec(Parens), Delim, D, Acc);
        IsDigit =:= true ->
            emit(Bin, I, scan_numeric(Bin, I), numeric, Line, Col, Parens, Delim, D, Acc);
        IsWord =:= true ->
            Stop = scan_word(Bin, I),
            Text = binary:part(Bin, I, Stop - I),
            case Directive andalso upper(Text) =:= <<"DELIMITER">> of
                true -> emit_delimiter_directive(Bin, I, Stop, Line, Col, Parens, D, Acc);
                false ->
                    Type = case is_keyword_text(Text) of true -> keyword; false -> identifier end,
                    emit(Bin, I, Stop, Type, Line, Col, Parens, Delim, D, Acc)
            end;
        IsSpace =:= true ->
            {NL, NC} = advance(<<C>>, Line, Col),
            tokenize(Bin, I + 1, NL, NC, Parens, Delim, D, Acc);
        true ->
            emit(Bin, I, I + 1, symbol, Line, Col, Parens, Delim, D, Acc)
    end.

emit(Bin, Start, Stop, Type, Line, Col, Parens, Delim, D, Acc) ->
    emit_p(Bin, Start, Stop, Type, Line, Col, Parens, Parens, Delim, D, Acc).

emit_p(Bin, Start, Stop, Type, Line, Col, TokParens, NewParens, Delim, D, Acc) ->
    Text = binary:part(Bin, Start, Stop - Start),
    Tok = #tok{type = Type, text = Text, start = Start, stop = Stop,
               line = Line, col = Col, parens = TokParens},
    {NL, NC} = advance(Text, Line, Col),
    tokenize(Bin, Stop, NL, NC, NewParens, Delim, D, [Tok | Acc]).

emit_quoted(Bin, Start, Close, Backslash, Type, Line, Col, Parens, Delim, D, Acc) ->
    Stop = scan_quoted(Bin, Start + 1, Close, Backslash),
    emit(Bin, Start, Stop, Type, Line, Col, Parens, Delim, D, Acc).

emit_delimiter_directive(Bin, Start, WordStop, Line, Col, Parens, D, Acc) ->
    ColAfterWord = Col + (WordStop - Start),
    {EolPos, _L} = read_eol(Bin, WordStop, Line, ColAfterWord),
    NewDelim0 = string:trim(binary:part(Bin, WordStop, EolPos - WordStop)),
    NewDelim = case NewDelim0 of <<>> -> <<";">>; _ -> NewDelim0 end,
    Tok = #tok{type = new_delimiter, text = NewDelim, start = Start, stop = EolPos,
               line = Line, col = Col, parens = Parens},
    tokenize(Bin, EolPos, Line, ColAfterWord + (EolPos - WordStop), Parens, NewDelim, D, [Tok | Acc]).

dec(N) when N > 0 -> N - 1;
dec(_) -> 0.

scan_quoted(Bin, Pos, _Close, _Backslash) when Pos >= byte_size(Bin) ->
    byte_size(Bin);
scan_quoted(Bin, Pos, Close, Backslash) ->
    C = binary:at(Bin, Pos),
    HasNext = Pos + 1 < byte_size(Bin),
    if
        Backslash, C =:= $\\, HasNext ->
            scan_quoted(Bin, Pos + 2, Close, Backslash);
        C =:= Close ->
            Dbl = HasNext andalso Close =/= $] andalso binary:at(Bin, Pos + 1) =:= Close,
            case Dbl of
                true -> scan_quoted(Bin, Pos + 2, Close, Backslash);
                false -> Pos + 1
            end;
        true ->
            scan_quoted(Bin, Pos + 1, Close, Backslash)
    end.

scan_to_eol(Bin, Pos) when Pos >= byte_size(Bin) -> byte_size(Bin);
scan_to_eol(Bin, Pos) ->
    case binary:at(Bin, Pos) of
        $\n -> Pos;
        $\r -> Pos;
        _ -> scan_to_eol(Bin, Pos + 1)
    end.

scan_block_comment(Bin, Pos, _Depth) when Pos >= byte_size(Bin) ->
    byte_size(Bin);
scan_block_comment(Bin, Pos, Depth) ->
    HasNext = Pos + 1 < byte_size(Bin),
    C1 = binary:at(Bin, Pos),
    C2 = case HasNext of true -> binary:at(Bin, Pos + 1); false -> undefined end,
    if
        HasNext, C1 =:= $*, C2 =:= $/ ->
            case Depth - 1 of
                0 -> Pos + 2;
                D2 -> scan_block_comment(Bin, Pos + 2, D2)
            end;
        HasNext, C1 =:= $/, C2 =:= $* ->
            scan_block_comment(Bin, Pos + 2, Depth + 1);
        true ->
            scan_block_comment(Bin, Pos + 1, Depth)
    end.

scan_numeric(Bin, Pos) when Pos >= byte_size(Bin) -> byte_size(Bin);
scan_numeric(Bin, Pos) ->
    C = binary:at(Bin, Pos),
    case (C >= $0 andalso C =< $9) orelse C =:= $. of
        true -> scan_numeric(Bin, Pos + 1);
        false -> Pos
    end.

scan_word(Bin, Pos) when Pos >= byte_size(Bin) -> byte_size(Bin);
scan_word(Bin, Pos) ->
    case is_word_char(binary:at(Bin, Pos)) of
        true -> scan_word(Bin, Pos + 1);
        false -> Pos
    end.

read_eol(Bin, Pos, Line, _Col) when Pos >= byte_size(Bin) ->
    {Pos, Line};
read_eol(Bin, Pos, Line, Col) ->
    case binary:at(Bin, Pos) of
        $\n -> {Pos, Line};
        $\r -> {Pos, Line};
        _ -> read_eol(Bin, Pos + 1, Line, Col + 1)
    end.

matches_at(Bin, I, Pattern) ->
    PLen = byte_size(Pattern),
    I + PLen =< byte_size(Bin) andalso binary:part(Bin, I, PLen) =:= Pattern.

is_word_start(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse C =:= $_.

is_word_char(C) ->
    is_word_start(C) orelse (C >= $0 andalso C =< $9).

is_keyword_text(<<>>) -> false;
is_keyword_text(Bin) -> is_keyword_text(Bin, false).

is_keyword_text(<<>>, _Seen) -> true;
is_keyword_text(<<C, Rest/binary>>, _Seen) ->
    case (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse C =:= $_ of
        true -> is_keyword_text(Rest, true);
        false -> false
    end.

is_space(C) -> C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r
    orelse C =:= $\f orelse C =:= $\v.

upper(Bin) -> string:uppercase(Bin).

advance(<<>>, L, C) -> {L, C};
advance(<<"\r\n", R/binary>>, L, _C) -> advance(R, L + 1, 1);
advance(<<"\n", R/binary>>, L, _C) -> advance(R, L + 1, 1);
advance(<<"\r", R/binary>>, L, _C) -> advance(R, L + 1, 1);
advance(<<_C, R/binary>>, L, C) -> advance(R, L, C + 1).

%% ---------------------------------------------------------------------
%% Statement splitting
%% ---------------------------------------------------------------------

-record(split, {
    bin :: binary(),
    dialect :: map(),
    cur_start = undefined :: undefined | non_neg_integer(),
    cur_line = 1 :: non_neg_integer(),
    block = 0 :: non_neg_integer(),
    inits = [] :: [binary()],
    stmt_type = unknown :: unknown | stored | term(),
    keywords = [] :: [binary()],
    last_sig = undefined :: undefined | #tok{},
    acc = [] :: [#statement{}]
}).

split(Tokens, Bin, Dialect) ->
    S0 = #split{bin = Bin, dialect = Dialect},
    S1 = lists:foldl(fun(Tok, S) -> step(Tok, S) end, S0, Tokens),
    #split{acc = Acc} = S1,
    lists:reverse(Acc).

step(#tok{type = eof} = Tok, S) ->
    case S#split.cur_start of
        undefined -> S;
        Start -> emit_statement(Tok#tok.start, Start, S)
    end;
step(#tok{type = delimiter} = Tok, S) ->
    S1 = mysql_end_adjust(S),
    case Tok#tok.parens =:= 0 andalso S1#split.block =:= 0 of
        true ->
            case S1#split.cur_start of
                undefined -> reset(S1);
                Start -> reset(emit_statement(Tok#tok.start, Start, S1))
            end;
        false ->
            S1#split{last_sig = Tok}
    end;
step(#tok{type = new_delimiter} = Tok, S) ->
    case S#split.cur_start of
        undefined -> reset(S#split{last_sig = Tok});
        _ -> eflyway_error:raise(delimiter_changed_in_statement,
                                 <<"Delimiter changed inside statement">>)
    end;
step(#tok{type = comment}, S) ->
    S;
step(#tok{type = blank_lines}, S) ->
    S;
step(Tok, S) ->
    S1 = ensure_start(Tok, S),
    S2 = update_type_and_block(Tok, S1),
    S2#split{last_sig = Tok}.

ensure_start(#tok{start = Start, line = Line}, #split{cur_start = undefined} = S) ->
    S#split{cur_start = Start, cur_line = Line};
ensure_start(_Tok, S) ->
    S.

reset(S) ->
    S#split{cur_start = undefined, block = 0, inits = [],
            stmt_type = unknown, keywords = [], last_sig = undefined}.

emit_statement(End, Start, S) ->
    Bin = S#split.bin,
    Sql = trim(binary:part(Bin, Start, End - Start)),
    CanTx = can_execute_in_transaction(S#split.keywords),
    Stmt = #statement{sql = Sql, line = S#split.cur_line,
                      can_execute_in_transaction = CanTx},
    S#split{acc = [Stmt | S#split.acc]}.

update_type_and_block(#tok{type = keyword, text = Text, parens = 0}, S) ->
    KWs = S#split.keywords ++ [upper(Text)],
    S1 = S#split{keywords = KWs},
    Stored = maps:get(stored_programs, S1#split.dialect, false),
    S2 = case Stored andalso S1#split.stmt_type =:= unknown andalso is_stored_program(KWs) of
             true -> S1#split{stmt_type = stored};
             false -> S1
         end,
    case maps:get(sqlite_blocks, S2#split.dialect, false) of
        true -> sqlite_block(Text, S2);
        false ->
            case S2#split.stmt_type of
                stored -> mysql_block(Text, S2);
                _ -> S2
            end
    end;
update_type_and_block(_Tok, S) ->
    S.

sqlite_block(Text, S) ->
    case upper(Text) of
        <<"BEGIN">> -> push_block(upper(Text), S);
        <<"CASE">> -> push_block(upper(Text), S);
        <<"END">> -> pop_block(S);
        _ -> S
    end.

push_block(Initiator, S) ->
    S#split{block = S#split.block + 1, inits = [Initiator | S#split.inits]}.

pop_block(S) ->
    case S#split.block > 0 of
        true -> S#split{block = S#split.block - 1, inits = safe_tail(S#split.inits)};
        false -> S
    end.

safe_tail([]) -> [];
safe_tail([_ | T]) -> T.

mysql_block(<<"BEGIN">>, S) ->
    push_block(<<>>, S);
mysql_block(Text0, S) ->
    Text = upper(Text0),
    LastIsEnd = case S#split.last_sig of
                    #tok{type = keyword, text = T} -> upper(T) =:= <<"END">>;
                    _ -> false
                end,
    case S#split.block > 0 andalso LastIsEnd
         andalso Text =/= <<"IF">> andalso Text =/= <<"LOOP">> of
        true ->
            Initiator = case S#split.inits of [I | _] -> I; [] -> <<>> end,
            case Initiator =:= <<>> orelse Initiator =:= Text orelse Text =:= <<"AS">> of
                true -> pop_block(S);
                false -> S
            end;
        false ->
            S
    end.

mysql_end_adjust(S) ->
    Stored = maps:get(stored_programs, S#split.dialect, false),
    case Stored andalso S#split.block > 0 of
        false -> S;
        true ->
            case S#split.last_sig of
                #tok{type = keyword, text = T} ->
                    case upper(T) of
                        <<"END">> -> pop_block(S);
                        _ -> S
                    end;
                _ -> S
            end
    end.

is_stored_program(KWs) ->
    case KWs of
        [<<"CREATE">> | _] ->
            lists:any(fun(K) ->
                lists:member(K, [<<"PROCEDURE">>, <<"FUNCTION">>, <<"EVENT">>, <<"TRIGGER">>])
            end, KWs);
        _ -> false
    end.

can_execute_in_transaction([<<"PRAGMA">>, <<"FOREIGN_KEYS">> | _]) -> false;
can_execute_in_transaction(_) -> true.

trim(Bin) -> string:trim(Bin).
