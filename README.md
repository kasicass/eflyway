eflyway
=======

An Erlang database migration tool for MySQL and SQLite3. The database is
selected via `-url`.

Documentation
-------------

- [Design](doc/design.md) — architecture, modules, state machine, parser.

Build
-----

    $ rebar3 compile
    $ rebar3 escriptize
    $ rebar3 eunit

Run
---

    $ _build/default/bin/eflyway -url=sqlite3:///tmp/demo.db -locations=filesystem:sql migrate
    $ _build/default/bin/eflyway -url=mysql://user:pass@localhost/demo info

The SQLite driver is a NIF (`esqlite`) which cannot be loaded from inside an
escript archive. The escript therefore adds the sibling `_build/default/lib`
directory to the code path at startup. When moving the escript elsewhere,
either keep the `lib` directory next to it or point `ERL_LIBS` at it.

Commands
--------

`migrate`, `validate`, `info`, `baseline`, `clean`, `repair`.
