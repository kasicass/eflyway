eflyway
=======

An Erlang database migration tool, replicating the core behaviour of
Flyway 7.5.0 for MySQL and SQLite3. The database is selected via `-url`.

Documentation
-------------

- [Design](doc/design.md) — architecture, modules, state machine, parser.
- [User Guide](doc/user_guide.md) — installation, CLI reference, usage.

Build
-----

    $ rebar3 escriptize

Run
---

    $ _build/default/bin/eflyway -url=sqlite3:///tmp/demo.db migrate
    $ _build/default/bin/eflyway -url=mysql://user:pass@localhost/demo info
