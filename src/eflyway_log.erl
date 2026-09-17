%% @doc Minimal leveled logger.
%%
%% Levels: debug < info < warn < error. Warnings and errors go to stderr,
%% debug/info go to stdout.
-module(eflyway_log).

-export([set_level/1, level/0,
         debug/1, info/1, warn/1, error/1,
         debug/2, info/2, warn/2, error/2]).

-define(KEY, {?MODULE, level}).

-spec set_level(debug | info | warn | error) -> ok.
set_level(Level) when Level =:= debug; Level =:= info; Level =:= warn; Level =:= error ->
    persistent_term:put(?KEY, Level).

-spec level() -> debug | info | warn | error.
level() ->
    persistent_term:get(?KEY, info).

-spec debug(iodata()) -> ok.
debug(Msg) -> log(debug, Msg).
debug(Fmt, Args) -> log(debug, io_lib:format(Fmt, Args)).

-spec info(iodata()) -> ok.
info(Msg) -> log(info, Msg).
info(Fmt, Args) -> log(info, io_lib:format(Fmt, Args)).

-spec warn(iodata()) -> ok.
warn(Msg) -> log(warn, Msg).
warn(Fmt, Args) -> log(warn, io_lib:format(Fmt, Args)).

-spec error(iodata()) -> ok.
error(Msg) -> log(error, Msg).
error(Fmt, Args) -> log(error, io_lib:format(Fmt, Args)).

%% internal
log(Level, Msg) ->
    case rank(Level) >= rank(level()) of
        true ->
            Device = case Level of
                         L when L =:= warn; L =:= error -> standard_error;
                         _ -> standard_io
                     end,
            io:format(Device, "~s~n", [Msg]);
        false ->
            ok
    end.

rank(debug) -> 0;
rank(info) -> 1;
rank(warn) -> 2;
rank(error) -> 3.
