# eflyway 设计文档

> 基于 `flyway-flyway-7.5.0`（Flyway 7.5.0，Community Edition）源码，用 Erlang/OTP 复刻其核心数据库迁移逻辑。
> 支持 **MySQL** 与 **SQLite3**，通过 `-url` 参数在两者之间切换。
> 本文档只描述**重新设计后**的架构；仓库中原有的 `src/eflyway.erl` 桩代码全部废弃。

---

## 1. 背景与目标

Flyway 是一个数据库版本迁移工具，核心思想是：

- 用文件名约定版本（`V1__init.sql`、`R__view.sql`）。
- 用一张 **schema history 表** 记录已应用的迁移及其校验和。
- 通过 `migrate / validate / info / baseline / clean / repair` 等命令管理迁移生命周期。
- 保证「同一份迁移脚本在不同环境可重复执行且结果一致」。

本项目（eflyway）的目标：

1. **逻辑等价**：对 SQL 迁移（versioned / repeatable），在 MySQL 与 SQLite3 上复刻 Flyway 7.5.0 的行为，包括：
   - 文件名解析、版本比较、校验和计算；
   - SQL 语句解析（分隔符、注释、字符串、块结构）；
   - schema history 表的读写；
   - 迁移状态机（Pending / Success / Missing / Ignored / Future / Failed / Baseline / Outdated / Superseded …）；
   - `migrate / validate / info / baseline / clean / repair` 命令。
2. **单一可执行入口**：打包成 escript `eflyway`，CLI 形式与官方 `flyway` 接近。
3. **多数据库**：通过 `-url` 自动选择适配器，采用行为（behaviour）抽象隔离数据库差异。
4. **可测试**：MySQL 与 SQLite3 都可用真实数据库做端到端测试。

### 1.1 明确的范围边界（不实现）

以下属于 Flyway Teams / 企业版或与 Java 运行时强绑定的能力，**不在本期范围**：

| 功能 | 说明 |
|------|------|
| Java migration / `JavaMigration` | 明确不实现（无 JVM 运行时） |
| Callback（`beforeMigrate` 等） | 首期不实现，预留 hook 点 |
| `undo` | Teams 专属 |
| `cherryPick`、`skipExecutingMigrations`、`dryRunOutput`、`errorOverrides`、`stream`、`batch` | Teams 专属 |
| `group`、mixed 多语句复杂事务 | 首期可简化，见 §13 |
| Oracle / PostgreSQL / SQL Server 等 | 仅 MySQL、SQLite3 |
| JAR/classpath/云端（S3/GCS）资源 | 仅本地文件系统资源 |
| Maven / Gradle 插件 | Java 专属的构建集成，不做；只提供独立的 escript CLI |

---

## 2. 总体架构

```
                        +--------------------------------------+
                        |            escript: eflyway          |
                        |  eflyway:main/1 -> eflyway_cli       |
                        +------------------+-------------------+
                                           |
                        +------------------v-------------------+
                        |           eflyway_config             |
                        |  默认值 / flyway.conf / 环境变量 / CLI |
                        +------------------+-------------------+
                                           |
                        +------------------v-------------------+
                        |           eflyway_flyway             |
                        |  Facade：加载配置、打开连接、调度命令   |
                        +----+-----------+-----------+---------+
                             |           |           |
              +--------------v--+   +----v-------+  +v-----------------+
              | eflyway_resolver |  | schema    |  | eflyway_db (behaviour) |
              | 资源发现/命名/校验和|  | history   |  |  mysql | sqlite        |
              +--------+---------+  +-----+-----+  +-----------------------+
                       |                  |
              +--------v---------+  +-----v------------------------------+
              | eflyway_sql      |  | eflyway_info_service               |
              | parser + script  |  | 状态机 / 排序 / validate            |
              +------------------+  +------------------------------------+
```

分层职责：

1. **CLI 层**（`eflyway`, `eflyway_cli`）：解析 `-key=value` 与命令，打印 usage、日志、结果表格，决定进程退出码。
2. **配置层**（`eflyway_config`）：合并四层来源，产出不可变配置记录。
3. **引擎层**（`eflyway_flyway` + `eflyway_cmd_*`）：命令编排，生命周期（连接、锁、事务、收尾）。
4. **迁移服务层**：
   - `eflyway_resolver`：扫描资源、解析文件名、计算校验和；
   - `eflyway_parser*`：把 SQL 文件切成语句流；
   - `eflyway_schema_history`：schema history 表的 CRUD；
   - `eflyway_info_service`：融合「已解析」与「已应用」，得到每个迁移的状态。
5. **数据库适配层**（`eflyway_db`, `eflyway_db_mysql`, `eflyway_db_sqlite`）：连接、执行、事务、锁、DDL、clean。

---

## 3. 模块划分

```
eflyway/
├── rebar.config
├── doc/
│   ├── design.md
│   └── user_guide.md
├── src/
│   ├── eflyway.app.src
│   ├── eflyway.erl                 %% escript 入口，main/1
│   ├── eflyway_cli.erl             %% 参数解析、usage、输出、退出码
│   ├── eflyway_config.erl          %% 配置记录、默认值、conf/env/CLI 合并
│   ├── eflyway_url.erl             %% URL 解析 -> {Adapter, ConnParams}
│   ├── eflyway_log.erl             %% 分级日志（debug/info/warn/error）
│   ├── eflyway_error.erl           %% 异常构造与格式化
│   ├── eflyway_flyway.erl          %% Facade：execute/2，命令调度
│   ├── eflyway_migration_version.erl
│   ├── eflyway_migration_type.erl
│   ├── eflyway_migration_state.erl
│   ├── eflyway_migration_info.erl  %% resolved + applied 的聚合视图
│   ├── eflyway_resource.erl        %% 文件扫描（locations）
│   ├── eflyway_resource_name.erl   %% 文件名 -> {prefix,version,desc,suffix}
│   ├── eflyway_resolver.erl        %% 解析出 ResolvedMigration 列表
│   ├── eflyway_checksum.erl        %% CRC32（按行、UTF-8、忽略换行/BOM）
│   ├── eflyway_placeholder.erl     %% ${...} 替换
│   ├── eflyway_parser.erl          %% 通用 tokenizer / 语句切分
│   ├── eflyway_parser_mysql.erl
│   ├── eflyway_parser_sqlite.erl
│   ├── eflyway_sql_script.erl      %% 语句流、executeInTransaction
│   ├── eflyway_schema_history.erl  %% schema history 表操作
│   ├── eflyway_info_service.erl    %% refresh/state/validate/pending/failed...
│   ├── eflyway_cmd_migrate.erl
│   ├── eflyway_cmd_validate.erl
│   ├── eflyway_cmd_info.erl
│   ├── eflyway_cmd_baseline.erl
│   ├── eflyway_cmd_clean.erl
│   ├── eflyway_cmd_repair.erl
│   ├── eflyway_db.erl              %% behaviour 定义
│   ├── eflyway_db_mysql.erl
│   └── eflyway_db_sqlite.erl
└── test/
    ├── eflyway_version_tests.erl
    ├── eflyway_parser_tests.erl
    ├── eflyway_checksum_tests.erl
    ├── eflyway_resolver_tests.erl
    ├── eflyway_state_tests.erl
    ├── eflyway_sqlite_SUITE.erl
    └── eflyway_mysql_SUITE.erl
```

### 3.1 与 Flyway Java 类的对应关系

| Flyway 7.5.0 | eflyway |
|--------------|---------|
| `org.flywaydb.core.Flyway` | `eflyway_flyway` |
| `internal.command.DbMigrate` | `eflyway_cmd_migrate` |
| `internal.command.DbValidate` | `eflyway_cmd_validate` |
| `internal.command.DbInfo` | `eflyway_cmd_info` |
| `internal.command.DbBaseline` | `eflyway_cmd_baseline` |
| `internal.command.DbClean` | `eflyway_cmd_clean` |
| `internal.command.DbRepair` | `eflyway_cmd_repair` |
| `internal.command.DbSchemas` | `eflyway_schema_history`（create schemas 部分） |
| `internal.info.MigrationInfoServiceImpl` | `eflyway_info_service` |
| `internal.info.MigrationInfoImpl` | `eflyway_migration_info` |
| `internal.schemahistory.JdbcTableSchemaHistory` | `eflyway_schema_history` |
| `internal.resolver.sql.SqlMigrationResolver` | `eflyway_resolver` |
| `internal.resolver.ChecksumCalculator` | `eflyway_checksum` |
| `internal.resource.ResourceNameParser` | `eflyway_resource_name` |
| `internal.parser.Parser` | `eflyway_parser` |
| `internal.database.mysql.MySQLParser` | `eflyway_parser_mysql` |
| `internal.database.sqlite.SQLiteParser` | `eflyway_parser_sqlite` |
| `internal.sqlscript.ParserSqlScript` | `eflyway_sql_script` |
| `internal.database.base.Database` 及子类 | `eflyway_db` + `eflyway_db_mysql/sqlite` |
| `api.MigrationVersion` | `eflyway_migration_version` |
| `api.MigrationState` | `eflyway_migration_state` |
| `api.MigrationType` | `eflyway_migration_type` |
| `api.configuration.ClassicConfiguration` | `eflyway_config` |
| `flyway-commandline.Main/CommandLineArguments` | `eflyway`, `eflyway_cli` |

---

## 4. 配置模型

### 4.1 配置来源与优先级

优先级由低到高：

1. **内置默认值**（与 Flyway 7.5.0 `ClassicConfiguration` 对齐）。
2. **默认配置文件**（与 Flyway CLI 一致，后加载覆盖先加载）：
   - `<安装目录>/conf/flyway.conf`
   - `~/.flyway.conf`
   - `<工作目录>/flyway.conf`
3. **显式配置文件**：`-configFiles=a.conf,b.conf`（或环境变量 `FLYWAY_CONFIG_FILES`），在默认文件之后加载并覆盖之；编码由 `-configFileEncoding` 指定（默认 UTF-8），`-configFiles=-` 表示从标准输入读取。
4. **环境变量**：`FLYWAY_URL`、`FLYWAY_USER`、`FLYWAY_PASSWORD`、`FLYWAY_LOCATIONS`、`FLYWAY_CONFIG_FILES` 等（变量名由配置键大写、`.`→`_` 得到）。
5. **命令行**：`-key=value`，优先级最高。

配置在 `eflyway_config:load/1` 中一次性合并，得到不可变记录 `#eflyway_config{}`。

### 4.2 支持的配置项（与 Flyway 7.5.0 默认值一致）

| 配置键 | 默认值 | 说明 |
|--------|--------|------|
| `url` | — | 必填，见 §5 |
| `user` | — | 数据库用户 |
| `password` | — | 数据库密码 |
| `locations` | `filesystem:sql`（本设计使用本地目录 `sql`，等价 `db/migration`） | 迁移脚本目录，逗号分隔；支持 `filesystem:` 前缀 |
| `table` | `flyway_schema_history` | schema history 表名 |
| `schemas` | 空 | 受管 schema（MySQL 用 database 名；SQLite 用 `main`） |
| `defaultSchema` | 空 | 默认 schema，缺省取 `schemas` 第一个或连接当前 schema |
| `encoding` | `UTF-8` | 脚本编码 |
| `sqlMigrationPrefix` | `V` | 版本化迁移前缀 |
| `repeatableSqlMigrationPrefix` | `R` | 可重复迁移前缀 |
| `sqlMigrationSeparator` | `__` | 前缀与描述之间的分隔符 |
| `sqlMigrationSuffixes` | `.sql` | 后缀，逗号分隔 |
| `placeholderReplacement` | `true` | 是否替换占位符 |
| `placeholderPrefix` | `${` | 占位符前缀 |
| `placeholderSuffix` | `}` | 占位符后缀 |
| `placeholders.*` | — | 自定义占位符键值 |
| `baselineVersion` | `1` | baseline 版本 |
| `baselineDescription` | `<< Flyway Baseline >>` | baseline 描述 |
| `baselineOnMigrate` | `false` | 非空库自动 baseline |
| `target` | 空（latest） | 迁移目标版本 |
| `outOfOrder` | `false` | 允许乱序迁移 |
| `ignoreMissingMigrations` | `false` | validate 忽略本地缺失 |
| `ignoreIgnoredMigrations` | `false` | validate 忽略 ignored |
| `ignorePendingMigrations` | `false` | validate 忽略 pending |
| `ignoreFutureMigrations` | `true` | validate 忽略 future |
| `validateOnMigrate` | `true` | migrate 前自动 validate |
| `validateMigrationNaming` | `false` | 校验文件名 |
| `cleanOnValidationError` | `false` | validate 失败自动 clean |
| `cleanDisabled` | `false` | 禁用 clean |
| `createSchemas` | `true` | 自动创建 schema |
| `mixed` | `false` | 允许同一迁移混合事务/非事务语句 |
| `group` | `false` | 是否成组迁移（首期仅支持 false 的语义，见 §13） |
| `installedBy` | 空 | 写入 `installed_by`，缺省取数据库当前用户 |
| `connectRetries` | `0` | 连接重试次数 |
| `lockRetryCount` | `50` | 获取锁重试次数 |
| `configFiles` | — | 显式配置文件列表，逗号分隔（覆盖默认配置文件） |
| `configFileEncoding` | `UTF-8` | 配置文件编码 |

> 与 Flyway 的差异：不存在 `driver`、`jarDirs`、`callbacks`、`resolvers`、`javaMigrations`、`dryRunOutput`、`licenseKey`、`cherryPick`、`stream`、`batch`、`errorOverrides` 等与 JVM/Teams 绑定的键。

### 4.3 配置记录

```erlang
-record(eflyway_config, {
    url                  :: binary(),
    user                 :: binary() | undefined,
    password             :: binary() | undefined,
    locations            :: [binary()],
    table                :: binary(),
    schemas              :: [binary()],
    default_schema       :: binary() | undefined,
    encoding             :: atom(),                 %% utf8 | latin1
    sql_migration_prefix :: binary(),
    repeatable_prefix    :: binary(),
    separator            :: binary(),
    suffixes             :: [binary()],
    placeholder_replacement :: boolean(),
    placeholder_prefix   :: binary(),
    placeholder_suffix   :: binary(),
    placeholders         :: #{binary() => binary()},
    baseline_version     :: eflyway_migration_version:version(),
    baseline_description :: binary(),
    baseline_on_migrate  :: boolean(),
    target               :: eflyway_migration_version:version() | undefined,
    out_of_order         :: boolean(),
    ignore_missing_migrations :: boolean(),
    ignore_ignored_migrations :: boolean(),
    ignore_pending_migrations :: boolean(),
    ignore_future_migrations  :: boolean(),
    validate_on_migrate  :: boolean(),
    validate_migration_naming :: boolean(),
    clean_on_validation_error :: boolean(),
    clean_disabled       :: boolean(),
    create_schemas       :: boolean(),
    mixed                :: boolean(),
    group                :: boolean(),
    installed_by         :: binary() | undefined,
    connect_retries      :: non_neg_integer(),
    lock_retry_count     :: non_neg_integer()
}).
```

---

## 5. URL 方案与数据库适配

### 5.1 URL 约定

`-url` 决定使用哪个适配器：

| 数据库 | URL 示例 |
|--------|----------|
| MySQL | `mysql://user:pass@127.0.0.1:3306/mydb` |
| MySQL（省略端口） | `mysql://user:pass@localhost/mydb` |
| SQLite3 | `sqlite3:///abs/path/app.db` |
| SQLite3（相对路径） | `sqlite3:./data/app.db` 或 `sqlite3://data/app.db` |

> SQLite 仅支持**文件库**；不支持 `:memory:` 内存库（生命周期等于连接、无法持久化历史表，对迁移工具无意义）。

解析规则（`eflyway_url:parse/1`）：

1. 先去掉可选的 `jdbc:` 前缀（兼容 `jdbc:mysql://...`、`jdbc:sqlite:...`），再取 `scheme`，必须是 `mysql`、`sqlite3`（或 `sqlite`），否则报错 `unsupported_url_scheme`。
2. MySQL：解析 `userinfo`、`host`、`port`、`path`（数据库名）、`query`（扩展参数）。
   - URL 中的 user/password 作为默认值；显式 `-user` / `-password` 覆盖。
3. SQLite3：path 即文件路径；`path` 为空或为 `:memory:` 时直接报错 `in_memory_not_supported`。
   - SQLite 的 schema 固定为 `main`。

### 5.2 数据库适配 behaviour

```erlang
-module(eflyway_db).
-callback connect(ConnParams)                          -> {ok, Conn} | {error, term()}.
-callback disconnect(Conn)                             -> ok.
-callback execute(Conn, Sql :: binary())               -> {ok, Result} | {error, term()}.
-callback query(Conn, Sql :: binary(), Args :: list()) -> {ok, [map()]} | {error, term()}.
-callback transaction(Conn, fun((Conn) -> Result))     -> Result.
-callback lock(Conn, Table :: binary(), fun(() -> R))  -> R.
-callback supports_ddl_transactions()                  -> boolean().
-callback supports_changing_current_schema()           -> boolean().
-callback catalog(Conn)                                -> binary().
-callback current_user(Conn)                           -> binary().
-callback quote(Binary)                                -> binary().
-callback boolean_true()                               -> binary().
-callback boolean_false()                              -> binary().
-callback create_history_ddl(Table, Baseline :: boolean()) -> [Sql].
-callback all_tables(Conn, Schema)                     -> [binary()].
-callback clean_schema(Conn, Schema)                   -> ok.
-callback schema_exists(Conn, Schema)                  -> boolean().
-callback schema_empty(Conn, Schema)                   -> boolean().
-callback create_schema(Conn, Schema)                  -> ok.
-callback drop_schema(Conn, Schema)                    -> ok.
```

### 5.3 MySQL 适配（`eflyway_db_mysql`）

- 驱动：[`mysql-otp`](https://hex.pm/packages/mysql)（hex 包名 `mysql`），API 使用 `mysql:start_link/1`、`mysql:query/3`、`mysql:transaction/3`。
- 连接：先不带 `database` 连到服务器（避免未知库导致连接进程 init 失败并把调用方拖死），再：
  - 库存在 -> `USE \`db\``；
  - 库不存在 -> 返回 `{error, {database_does_not_exist, Db}}`，由引擎转换为一行友好提示，**不自动创建数据库**；
  - `mysql:start_link` 失败时会 flush 链接的 `EXIT` 信号并临时降低 logger level，避免 OTP crash report。
- 标识符引用：反引号 `` ` ``。
- 布尔真/假：`1` / `0`。
- `supports_ddl_transactions() -> false`（DDL 隐式提交，失败无法回滚）。
- 锁：使用 MySQL 命名锁 `GET_LOCK('Flyway-<hash>', 10)` / `RELEASE_LOCK(...)`。
  - 锁名 discriminator 取 schema history 表全名（含 schema）字符串的 hash，与 Flyway 一致。
- 历史表 DDL（与 Flyway 7.5.0 `MySQLDatabase.getRawCreateScript` 对齐）：

```sql
CREATE TABLE `flyway_schema_history` (
    `installed_rank` INT NOT NULL,
    `version` VARCHAR(50),
    `description` VARCHAR(200) NOT NULL,
    `type` VARCHAR(20) NOT NULL,
    `script` VARCHAR(1000) NOT NULL,
    `checksum` INT,
    `installed_by` VARCHAR(100) NOT NULL,
    `installed_on` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `execution_time` INT NOT NULL,
    `success` BOOL NOT NULL,
    CONSTRAINT `flyway_schema_history_pk` PRIMARY KEY (`installed_rank`)
) ENGINE=InnoDB;
CREATE INDEX `flyway_schema_history_s_idx` ON `flyway_schema_history` (`success`);
```

- clean：关闭外键检查 `SET FOREIGN_KEY_CHECKS = 0`，删除 views / routines / events / sequences / tables，再恢复。
- 当前 schema：`SELECT DATABASE()`；切换用 `USE`。

### 5.4 SQLite3 适配（`eflyway_db_sqlite`）

- 驱动：[`esqlite`](https://hex.pm/packages/esqlite)（模块名 `esqlite3`）。
  - 连接：`esqlite3:open(Path)`；执行：`esqlite3:exec/2`、`esqlite3:q/2,3`；显式事务：`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`。
- 标识符引用：双引号 `"`（也接受反引号与方括号）。
- 布尔真/假：`1` / `0`。
- `supports_ddl_transactions() -> true`（SQLite 的 DDL 在事务内可回滚）。
- 锁：SQLite 不支持表级命名锁，`lock/3` 退化为直接执行（与 Flyway 的 `SQLiteTable.doLock` 一致）；并发写由 SQLite 文件锁与 `BEGIN IMMEDIATE` 保障。
- 历史表 DDL（与 Flyway 7.5.0 `SQLiteDatabase.getRawCreateScript` 对齐）：

```sql
CREATE TABLE "flyway_schema_history" (
    "installed_rank" INT NOT NULL PRIMARY KEY,
    "version" VARCHAR(50),
    "description" VARCHAR(200) NOT NULL,
    "type" VARCHAR(20) NOT NULL,
    "script" VARCHAR(1000) NOT NULL,
    "checksum" INT,
    "installed_by" VARCHAR(100) NOT NULL,
    "installed_on" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    "execution_time" INT NOT NULL,
    "success" BOOLEAN NOT NULL
);
CREATE INDEX "main"."flyway_schema_history_s_idx" ON "flyway_schema_history" ("success");
```

- schema 固定为 `main`；`schema_exists` 通过查询 `main.sqlite_master` 判断；`create_schema` / `drop_schema` 为 no-op 并打印提示。
- 仅支持文件库，不支持内存库（见 §5.1）。库文件不存在时由 SQLite 自动创建；但**父目录必须已存在**，否则返回友好提示且不自动建目录。
- clean：
  1. 记录 `PRAGMA foreign_keys` 原值；
  2. 删除所有 view（`DROP VIEW "main"."<name>"`）；
  3. 删除所有表（`DROP TABLE "main"."<name>"`，必要时临时关闭外键）；
  4. 清空 `sqlite_sequence`；
  5. 系统表 `sqlite_sequence`、`android_metadata` 不参与 empty 判定、不可 drop。

---

## 6. 迁移发现、命名与校验和

### 6.1 资源扫描（`eflyway_resource`）

- `locations` 仅支持 `filesystem:<dir>`（以及裸路径，视为 filesystem）。
- 递归扫描目录，返回 `#resource{path, relative_path, filename}` 列表。
- 只保留后缀匹配 `suffixes` 的文件。

### 6.2 文件名解析（`eflyway_resource_name`）

复刻 `ResourceNameParser` 的算法：

1. 从右去掉后缀，得到 `name_without_suffix` 与 `suffix`。
2. 在前缀集合（按长度降序）中找第一个匹配的前缀：`V`（versioned）、`R`（repeatable）。
3. 去掉前缀后，按 `separator`（默认 `__`）切分：
   - versioned：分隔符左边必须是合法版本号，右边是描述；
   - repeatable：分隔符左边必须为空，分隔符及右边是描述。
4. 描述中的 `_` 替换为空格。
5. 返回 `valid` 标志与错误消息；非法文件在 `validateMigrationNaming=true` 时报错，否则忽略。

示例：

| 文件名 | prefix | version | description |
|--------|--------|---------|-------------|
| `V1__init.sql` | V | 1 | init |
| `V1_1__create_user.sql` | V | 1.1 | create user |
| `V2.1.3__add_index.sql` | V | 2.1.3 | add index |
| `R__create_view.sql` | R | (null) | create view |

### 6.3 版本模型（`eflyway_migration_version`）

复刻 `MigrationVersion`：

- 版本由 `.` 分割为若干非负整数段，逐段数值比较，缺省段按 0 处理；`_` 等价于 `.`。
- 特殊标记：
  - `<< Empty Schema >>`（EMPTY）：小于一切真实版本；
  - `<< Current Version >>`（CURRENT）：仅作 target 标记，表示「当前已应用版本」；
  - `<< Latest Version >>`（LATEST）：大于一切真实版本。
- `from_version/1` 支持字符串 `current` / `latest`。
- 版本仅允许 `0..9` 与 `.`（及作为分隔的 `_`），否则报 `invalid_version`。

### 6.4 校验和（`eflyway_checksum`）

复刻 `ChecksumCalculator`：

1. 以文本行方式读取文件（UTF-8）。
2. 去掉第一行的 UTF-8 BOM。
3. 对每一行（**不含换行符**）的 UTF-8 字节更新 CRC32。
4. 结果取 32 位有符号整数（与 Java `int` 一致），写入 `checksum` 列。

要点：
- **换行符无关**：`\n` 与 `\r\n` 得到相同校验和。
- **编码无关**：按 UTF-8 读取。
- 可重复迁移若开启占位符替换，则校验和有两种：
  - `checksum`：替换后的校验和；
  - `equivalent_checksum`：替换前的校验和（用于 repair 对齐）。
- `checksumMatches`：数据库校验和等于 `checksum` 或 `equivalent_checksum` 即认为匹配。

Erlang 实现示例骨架：

```erlang
%% 伪代码
checksum(File) ->
    {ok, Bin} = file:read_file(File),
    Lines = binary:split(Bin, [<<"\n">>], [global]),
    Lines1 = [strip_cr(L) || L <- Lines],
    [First | Rest] = Lines1,
    First1 = strip_bom(First),
    signed32(erlang:crc32([First1 | Rest])).
```

（实现时需注意最后一行是否需要剔除空尾行，须与 Java `BufferedReader.readLine` 行为严格对齐：文件末尾多余的空行会被读成一条空字符串并参与校验和。）

---

## 7. SQL 解析器

解析器负责把 `V1__init.sql` 切成一条条语句，并判断每条语句能否在事务中执行。这是复刻中最难的部分，采用与 Flyway 相同的 **token 驱动 + 记录原文** 方案。

### 7.1 解析状态（`#pctx{}`）

```erlang
-record(pctx, {
    delimiter      = <<";">> :: binary(),
    parens_depth   = 0      :: non_neg_integer(),
    block_depth    = 0      :: non_neg_integer(),
    block_initiators = []   :: [binary()],
    statement_type = unknown:: unknown | generic | term(),
    ...
}).
```

### 7.2 词法单元（token）

| Token | 说明 |
|-------|------|
| `keyword` | 字母/下划线组成的词 |
| `identifier` | 引号包裹或含点的标识符（`"a.b"`、`` `x` ``） |
| `string` | 单引号字符串；MySQL 额外支持双引号、`\'` 转义；前缀 `B'`/`E'`/`X'`/`U&'` |
| `numeric` | 数字 |
| `comment` | `--`、`#`（MySQL）、`/* ... */`（可嵌套） |
| `comment_directive` | MySQL `/*! ... */` |
| `blank_lines` | 连续两个以上换行 |
| `symbol` | 其他单字符 |
| `delimiter` | 当前分隔符 |
| `new_delimiter` | MySQL `DELIMITER xxx` 指令 |
| `eof` | 文件结束 |

### 7.3 语句切分算法

```
get_next_statement(Reader, Ctx):
    tokens = [], keywords = [], recorder.start()
    loop:
        Tok = read_token(Reader, Ctx)
        case Tok:
          null -> continue
          new_delimiter ->
              if 已收集非注释内容 -> error("delimiter changed inside statement")
              Ctx.delimiter = Tok.text; tokens = []; recorder.start(); continue
          _ ->
              if token_type == eof
                 or (token_type == delimiter and parens_depth == 0 and block_depth == 0):
                  sql = recorder.stop()
                  if eof and (sql 为空 or tokens 为空) -> return null
                  return create_statement(..., Ctx.delimiter, sql, can_exec_in_tx)
              tokens += Tok
              if keyword and parens_depth == 0:
                  detect_statement_type(关键词前缀)
                  adjust_delimiter()
                  can_exec_in_tx = detect_can_execute_in_transaction(关键词前缀, keywords)
```

关键点：
- 只有 `parens_depth == 0 && block_depth == 0` 的分隔符才终止语句。
- 只有 `eof` 时若 `parens_depth > 0 || block_depth > 0`，报「incomplete statement」。
- 前导注释/空行在遇到分隔符前会被丢弃（`shouldDiscard`）。
- 原文通过 `Recorder` 从语句非注释起点开始记录，保证注释后的 SQL 原样保留。

### 7.4 方括号深度与块深度

- `(` / `)` 增减 `parens_depth`。
- 数据库特定 `adjust_block_depth/4`：
  - **SQLite**（`eflyway_parser_sqlite`）：`BEGIN` / `CASE` 增加块深度，`END` 减少块深度。
  - **MySQL**（`eflyway_parser_mysql`）：仅对存储程序（`CREATE PROCEDURE/FUNCTION/EVENT/TRIGGER`）生效；遇到 `BEGIN` 增加块深度；遇到 `END` 后需判断且 `IF`/`LOOP` 等控制关键字不计入；同时处理 `END IF`、`END LOOP` 收尾。
- `should_adjust_block_depth` 仅对 `parens_depth == 0` 的关键字生效（MySQL 还对 `;`/`DELIMITER`/`EOF` 特殊处理）。

### 7.5 分隔符

- 默认 `;`。
- MySQL 支持脚本内 `DELIMITER $$` 指令，且分隔符变更会跨语句保留（Flyway 的 `resetDelimiter` 被覆写为空操作）。
- 其他数据库每条语句前重置为默认分隔符。

### 7.6 事务可执行性

`detect_can_execute_in_transaction`：
- 默认 `true`。
- **SQLite**：`PRAGMA FOREIGN_KEYS` 判定为非事务语句。
- MySQL：默认 `true`（MySQL 的 DDL 语义另由 `supports_ddl_transactions=false` 处理）。
- 迁移级：只有全部语句都可事务执行，整段迁移才在事务中执行；否则按非事务处理（`mixed=false` 时若同一迁移混用两种语句则报错）。

### 7.7 占位符替换（`eflyway_placeholder`）

- 在读取脚本字符流阶段进行（`PlaceholderReplacingReader`）。
- 语法：`${key}`，可配置前后缀。
- 内置占位符：
  - `${flyway:defaultSchema}`、`${flyway:user}`、`${flyway:database}`、`${flyway:timestamp}`、`${flyway:filename}`。
- 自定义 `placeholders.<key>=<value>`。
- 替换发生在校验和计算之后（因此 `checksum` 记录替换后的值，`equivalent_checksum` 记录替换前的值）。

---

## 8. Schema History 表

### 8.1 列定义

| 列 | 类型 | 说明 |
|----|------|------|
| `installed_rank` | INT PK | 应用顺序，从 1 递增；SCHEMA 标记固定为 0 |
| `version` | VARCHAR(50) | 版本号，可重复迁移为 NULL |
| `description` | VARCHAR(200) | 描述，空描述在某些库用 `<< no description >>` |
| `type` | VARCHAR(20) | `SQL` / `BASELINE` / `SCHEMA` / `DELETE` 等 |
| `script` | VARCHAR(1000) | 相对路径 |
| `checksum` | INT | CRC32，可空 |
| `installed_by` | VARCHAR(100) | 安装者 |
| `installed_on` | TIMESTAMP/TEXT | 安装时间 |
| `execution_time` | INT | 执行毫秒数 |
| `success` | BOOL | 是否成功 |

### 8.2 操作

- `exists/1`：查询元数据/`sqlite_master` 判断表是否存在。
- `create/3`：创建表；`baseline=true` 时附带插入 baseline 行（MySQL 用 `CREATE TABLE ... AS SELECT`，SQLite 用 `CREATE TABLE` + `INSERT`）。
- `all_applied/1`：先判断表是否存在；不存在时返回空列表（与 Flyway 一致），否则 `SELECT ... FROM <table> WHERE installed_rank > ? ORDER BY installed_rank`。因此 **`info` / `validate` / `repair` 不会创建历史表**，只有 `migrate`（空 schema 路径）与 `baseline` 会创建。
- `add_applied/...`：计算 `installed_rank = max+1`（SCHEMA 固定 0），插入一行。
- `lock/3`：MySQL 命名锁；SQLite 直通。
- `update/2`：repair 时按 `installed_rank` 更新 description/type/checksum。
- `delete/1`：repair 时插入一条 `type='DELETE'` 的标记行。
- `remove_failed/2`：删除 `success = false` 的行。
- `add_schemas_marker/1`：插入 `type='SCHEMA'` 的 schema 创建标记。

### 8.3 类型兼容

读取时把历史遗留类型归一化：`SPRING_JDBC -> JDBC`、`UNDO_SPRING_JDBC -> UNDO_JDBC`。

---

## 9. 迁移状态机

`eflyway_info_service:refresh/1` 是状态计算核心，复刻 `MigrationInfoServiceImpl.refresh()` 的流程：

```
输入:
  ResolvedMigrations = [resolved(...)]   %% 本地解析得到
  AppliedMigrations  = [applied(...)]    %% 数据库读取得到
  Context = #migration_info_context{
      out_of_order, pending, missing, ignored, future,
      target, baseline = EMPTY, schema = EMPTY,
      last_resolved = EMPTY, last_applied = EMPTY,
      latest_repeatable_runs = #{}
  }

步骤:
1. 把 resolved 分为 versioned / repeatable；更新 last_resolved。
2. 遍历 applied:
   - version == null -> 加入 applied_repeatable；若是成功的 DELETE，则把同描述的最近一条标记为 deleted。
   - type == SCHEMA -> context.schema = version
   - type == BASELINE -> context.baseline = version
   - type == DELETE 且成功 -> mark_as_deleted(version)
   - 加入 applied_versioned
3. 计算 last_applied / out_of_order:
   - 若 version > last_applied 且不是 DELETE 且未 deleted -> last_applied = version
   - 否则该条 out_of_order = true
4. 若 target == CURRENT -> target = last_applied
5. 生成 versioned 视图:
   - applied_versioned 每条: 找 resolved；若匹配则从 pending_resolved 移除；生成 MigrationInfo
   - 剩余 pending_resolved 生成 MigrationInfo（applied=null）
6. 校验 target 存在（若 target 非 current/latest 且找不到则报错）。
7. 计算 latest_repeatable_runs（每个 description 的最大 installed_rank）。
8. 生成 repeatable 视图:
   - 若 rank == latest 且 checksum 匹配 -> 从 pending 移除
   - 生成 MigrationInfo
   - 剩余 pending_repeatable 生成 MigrationInfo
9. 按 MigrationInfo:compare/2 排序。
```

### 9.1 状态判定（`eflyway_migration_info:state/2`）

状态集合与 Flyway `MigrationState` 一致（名称/display/resolved/applied/failed）：

```
PENDING / ABOVE_TARGET / BELOW_BASELINE / BASELINE / IGNORED /
MISSING_SUCCESS / MISSING_FAILED / SUCCESS / UNDONE / AVAILABLE /
FAILED / OUT_OF_ORDER / FUTURE_SUCCESS / FUTURE_FAILED /
OUTDATED / SUPERSEDED / DELETED
```

判定顺序（简化自 `MigrationInfoImpl.getState`）：

```
state(Info, Ctx):
  if deleted                          -> DELETED
  if applied == null:                 %% 仅本地解析
      if should_not_execute           -> IGNORED
      if version != null:
          if version < baseline       -> BELOW_BASELINE
          if target != null and version > target -> ABOVE_TARGET
          if version < last_applied and not out_of_order -> IGNORED
      -> PENDING
  if type == DELETE                   -> SUCCESS
  if type == BASELINE                 -> BASELINE
  if resolved == null and is_repeatable_latest:
      if type == SCHEMA               -> SUCCESS
      if version == null or version < last_resolved:
          success -> MISSING_SUCCESS | MISSING_FAILED
      else:
          success -> FUTURE_SUCCESS | FUTURE_FAILED
  if not success                      -> FAILED
  if version == null:                 %% repeatable
      if installed_rank == latest_rank:
          checksum 匹配 -> SUCCESS | OUTDATED
      else -> SUPERSEDED
  if out_of_order                     -> OUT_OF_ORDER
  -> SUCCESS
```

### 9.2 排序（`compare/2`）

1. 两者都有 `installed_rank` 时按 rank 升序。
2. `BELOW_BASELINE` 排在 applied 之前。
3. `IGNORED` 与 applied 之间按版本比较。
4. 已安装（有 rank）排在 pending 之前。
5. 两个 versioned 之间按版本比较。
6. versioned 排在 repeatable 之前。
7. 两个 repeatable 按描述字典序。

### 9.3 校验规则（`validate/2`）

逐条产出错误（与 `MigrationInfoImpl.validate` 对齐）：

- `ABOVE_TARGET`、`DELETED`：跳过。
- failed（且非 future）：`FAILED_VERSIONED_MIGRATION` / `FAILED_REPEATABLE_MIGRATION`。
- applied 但本地无解析：`APPLIED_*_MIGRATION_NOT_RESOLVED`（受 missing 开关影响）。
- `IGNORED` 且未允许：`RESOLVED_*_MIGRATION_NOT_APPLIED`。
- `PENDING` 且未允许：`RESOLVED_*_MIGRATION_NOT_APPLIED`。
- `OUTDATED` 且未允许：`OUTDATED_REPEATABLE_MIGRATION`。
- type / checksum / description 不匹配：对应 `TYPE_MISMATCH` / `CHECKSUM_MISMATCH` / `DESCRIPTION_MISMATCH`。

---

## 10. 命令流程

所有命令由 `eflyway_cli:run_command/2` 分发到 `eflyway_flyway` 的对应函数（`migrate/1`、`validate/1`、`info/1`、`baseline/1`、`clean/1`、`repair/1`），统一流程：

```
1. 打印版本横幅 eFlyway Version: <vsn>（版本号取自 eflyway.app 的 vsn，即
   eflyway.app.src 单一来源；对应 Flyway 的 VersionPrinter.printVersion，
   每条命令一次，-q 时抑制）。
2. 校验配置（至少 url；必要时 user/password）。
3. 解析 URL，选择 DB 适配器，建立连接（connectRetries 重试）。
4. 确定 schema：schemas / defaultSchema / 当前 schema。
5. 准备 resource provider（扫描 locations）。
6. 解析所有迁移（resolver）。
7. 构造 schema_history。
8. callback hook（本期为空）。
9. 分发到具体命令模块。
10. finally：关闭连接。
```

### 10.1 `migrate`

复刻 `Flyway.migrate()` + `DbMigrate`：

```
1. 若 validateOnMigrate = true:
       先 doValidate(..., pending=true)
       失败且 cleanOnValidationError=false -> 抛 FlywayValidateException
       失败且 cleanOnValidationError=true -> doClean
2. 若 schema history 不存在:
       若非空 schema:
           baselineOnMigrate=true -> doBaseline
           否则 -> 报错 "Found non-empty schema(s) ... but no schema history table"
       否则:
           createSchemas=true -> 创建 schema
           schema_history:create(baseline=false)
3. 循环 migrateAll:
       loop:
           count = schema_history:lock(fun() -> migrateGroup(firstRun) end)
           total += count
           if count == 0 -> break
4. migrateGroup:
       info_service:refresh()
       current = info_service:current()
       打印当前版本 / 警告（outOfOrder、future）
       若存在 failed 迁移 -> 报错
       选择 pending 迁移:
           默认每次只取 1 条（group=false）
           pending 组按顺序
       applyMigrations(group)
5. applyMigrations:
       判断组内是否在事务中执行
       执行每条:
           restore_original_state / change_current_schema
           before each hook
           执行迁移的 SQL 语句流
           after each hook
           记录 execution_time
           schema_history:add_applied(... success=true)
       失败:
           若是 DDL 事务库且组事务 -> 回滚
           否则 -> 记录一条 success=false 的 applied
           抛出异常
6. logSummary：打印成功条数与耗时。
```

### 10.2 `validate`

复刻 `DbValidate`：

```
1. schema 不存在:
       若存在本地迁移且 pending=false -> SCHEMA_DOES_NOT_EXIST 错误
       否则 -> 成功（0 条）
2. info_service(refresh)   （历史表不存在时 all_applied 返回空）
3. info_service:validate() -> 错误列表
4. 空 -> 成功；否则 -> 失败（cleanOnValidationError 时触发 clean）
```

### 10.3 `info`

复刻 `DbInfo` 与命令行 `Main.executeOperation("info")` 的输出：

- 连接时（进程内首次）打印 `Database: <url> (<产品名> <主.次>)`，对应 Flyway `DatabaseType.createDatabase(..., printInfo=true)`；
- 以 pending/missing/ignored/future 全 `true` 刷新 info service；
- 打印 `Schema version: <当前版本>`（空库为 `<< Empty Schema >>`）与一个空行；
- 用 `AsciiTable` 渲染表格：`Category | Version | Description | Type | Installed On | State`，无行时显示 `No migrations found`（横跨整表）；
- `Category`：synthetic 为空；repeatable 为 `Repeatable`；versioned 为 `Versioned`。

### 10.4 `baseline`

复刻 `DbBaseline`：

```
1. schema history 不存在 -> create(baseline=true)，成功。
2. 已存在:
       - 有 baseline 标记:
             版本+描述一致 -> 跳过（成功）
             不一致 -> 报错
       - 有 SCHEMA 标记且 baselineVersion == 0 -> 报错
       - 有非 synthetic 迁移 -> 报错
       - 表为空 -> 报错，提示先 clean
```

### 10.5 `clean`

复刻 `DbClean`：

```
1. cleanDisabled=true -> 报错
2. 判断历史表是否有 SCHEMA 标记（决定 drop schema 还是 clean schema）
3. cleanPreSchemas
4. 对每个 schema:
       schema 不存在 -> warn 跳过
       有 SCHEMA 标记 -> drop_schema
       否则 -> clean_schema
5. cleanPostSchemas
6. schema_history:clear_cache()
```

### 10.6 `repair`

复刻 `DbRepair`：

```
1. remove_failed_migrations（删除 success=false 的行）
2. refresh
3. delete_missing_migrations（MISSING/FUTURE -> 插入 DELETE 标记）
4. align_applied_migrations:
       versioned: checksum/description/type 任一不一致 -> update
       repeatable: equivalent_checksum 匹配但 checksum 不同 -> update
5. 输出 removed / deleted / aligned 列表
```

---

## 11. 并发与锁

| 数据库 | 表锁 | 说明 |
|--------|------|------|
| MySQL | `GET_LOCK('Flyway-<discriminator>', 10)` + `RELEASE_LOCK` | 命名锁，discriminator 为历史表限定名的 hash |
| SQLite | 无显式锁 | 依赖 `BEGIN IMMEDIATE` 与文件锁；`lock/3` 直接执行 |

`lock/3` 的语义与 Flyway 一致：进入时获取，回调结束后释放；`migrateAll` 中每条迁移获取一次锁，`group=false` 时逐条加锁。

---

## 12. 事务语义

- **MySQL**：`supports_ddl_transactions = false`。DDL 会隐式提交，迁移失败**不会**回滚，需要人工清理，并由 `repair` 删除失败记录。
- **SQLite**：`supports_ddl_transactions = true`。整个迁移可包在事务里，失败自动回滚（包括历史表写入）。
- 判断某条迁移是否可事务执行：见 §7.6。若可，则 `transaction/2` 包裹整条迁移；否则直接执行。
- `mixed=true` 时允许同一迁移混用事务/非事务语句；`mixed=false` 时报错。

---

## 13. 差异与简化说明

1. `group` 配置保留，但首期等价于单条迁移处理（`group=false` 语义）；成组事务可作为后续增强。
2. 不实现 callbacks，但 `eflyway_flyway` 中预留 `before/after` hook 调用点，便于后续扩展。
3. 不实现 Java migration、undo、cherryPick、dryRun、errorOverrides、stream、batch。
4. 资源只支持本地文件系统。
5. 迁移脚本 `.conf` 元数据（`executeInTransaction` / `encoding` / `shouldExecute`）可作为增强项，首期默认全部执行且编码固定 UTF-8。

---

## 14. 错误处理

统一错误结构：

```erlang
{eflyway_error, Code :: atom(), Message :: binary(), Details :: map()}
```

抛出用 `erlang:error/1`，CLI 顶层捕获并打印，返回非 0 退出码。错误码与 Flyway `ErrorCode` 对齐的部分：

| Code | 含义 |
|------|------|
| `unsupported_url_scheme` | URL scheme 不是 mysql/sqlite3 |
| `connection_failed` | 连接失败 |
| `schema_does_not_exist` | validate 时 schema 不存在 |
| `failed_versioned_migration` | 版本化迁移失败 |
| `failed_repeatable_migration` | 可重复迁移失败 |
| `applied_versioned_migration_not_resolved` | applied 但本地缺失 |
| `resolved_versioned_migration_not_applied` | resolved 但未应用 |
| `checksum_mismatch` / `type_mismatch` / `description_mismatch` | 不一致 |
| `outdated_repeatable_migration` | 可重复迁移过期 |
| `validate_error` | 校验失败汇总 |
| `non_empty_schema_no_history` | 非空库无历史表且未开启 baselineOnMigrate |
| `clean_disabled` | clean 被禁用 |

---

## 15. 测试方案

1. **纯函数单测**（EUnit）
   - `eflyway_migration_version`：版本比较、`_`/`.`、current/latest、非法版本。
   - `eflyway_checksum`：换行无关、BOM、空行。
   - `eflyway_resource_name`：命名解析、合法/非法。
   - `eflyway_parser`：多语句、注释、字符串内分隔符、`BEGIN...END`、`DELIMITER`。
   - `eflyway_info_service`：用构造的 resolved/applied 覆盖所有状态与校验分支。
2. **SQLite 端到端**（Common Test，使用临时文件库）
   - migrate -> info -> 再次 migrate（幂等）-> validate。
   - 篡改脚本 -> validate 失败 -> repair -> validate 通过。
   - baseline / clean / repair 全流程。
3. **MySQL 端到端**（Common Test，Docker 或本地实例）
   - 同上，并额外验证命名锁、DDL 失败记录、DELETE 标记。
4. **属性测试**（可选，PropEr）：任意分隔符/引号组合的语句切分与原文还原。

---

## 16. 实施路线图

| 阶段 | 内容 | 产出 |
|------|------|------|
| M1 | 项目骨架、配置、URL、DB behaviour、SQLite 适配 | 可连接 SQLite |
| M2 | 版本/命名/校验和/资源扫描/通用解析器 | 纯函数可用 |
| M3 | schema history + info service + migrate | SQLite 上可迁移 |
| M4 | validate / info / baseline / clean / repair | SQLite 全命令 |
| M5 | MySQL 适配（连接、锁、DDL、clean） | MySQL 全命令 |
| M6 | 文档、CLI 打磨、测试补全 | 发布 |

---

## 17. 关键结论

- Flyway 的本质是「**文件约定 + 历史表 + 状态机**」，其复杂度集中在 **SQL 解析** 与 **状态判定** 两处，设计上应把它们做成无副作用的纯函数模块，便于测试。
- MySQL 与 SQLite 的差异被收敛到 `eflyway_db` behaviour，尤其是 DDL 事务、表锁、schema 语义、clean 策略四点。
- 首期以「逻辑等价」为目标，Teams 能力与 JVM 相关能力明确排除。
- escript + `mysql-otp` / `esqlite` 的组合无需引入 JVM，单文件即可运行。
