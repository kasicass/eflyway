# eflyway 用户指南

`eflyway` 是一个用 Erlang 编写的数据库迁移工具。
它通过 SQL 文件管理数据库版本，支持 **MySQL** 和 **SQLite3**，使用 `-url` 参数选择数据库。

> 架构与实现细节见 [`design.md`](./design.md)。

---

## 目录

1. [简介](#1-简介)
2. [安装与构建](#2-安装与构建)
3. [快速开始](#3-快速开始)
4. [迁移文件命名](#4-迁移文件命名)
5. [命令行参考](#5-命令行参考)
6. [命令详解](#6-命令详解)
7. [配置](#7-配置)
8. [占位符](#8-占位符)
9. [可重复迁移](#9-可重复迁移)
10. [校验和与验证](#10-校验和与验证)
11. [修复](#11-修复)
12. [SQL 解析规则与限制](#12-sql-解析规则与限制)
13. [退出码](#13-退出码)
14. [常见问题](#14-常见问题)
15. [功能范围与限制](#15-功能范围与限制)

---

## 1. 简介

eflyway 的核心工作方式：

- 在指定目录（默认 `sql/`）下放置迁移脚本，文件名约定版本与描述；
- 首次运行时创建一张 **schema history 表**（默认 `flyway_schema_history`），记录已执行的迁移；
- 每次 `migrate` 只执行尚未执行、且版本高于当前版本的迁移；
- `validate` 检查脚本是否被篡改（校验和）、是否有缺失/未应用迁移；
- `info` 展示全部迁移的状态；
- `clean` 清空数据库对象；`baseline` 为非空库打基线；`repair` 修复历史表。

数据库由 `-url` 决定：

| 数据库 | URL 示例 |
|--------|----------|
| MySQL | `mysql://user:password@127.0.0.1:3306/mydb` |
| SQLite3 | `sqlite3:///var/data/app.db` |

---

## 2. 安装与构建

### 2.1 依赖

- Erlang/OTP 24+（开发环境为 OTP 28）
- rebar3
- MySQL 驱动 [`mysql-otp`](https://hex.pm/packages/mysql)
- SQLite3 驱动 [`esqlite`](https://hex.pm/packages/esqlite)

### 2.2 构建

```bash
rebar3 escriptize
```

生成的可执行程序位于：

```
_build/default/bin/eflyway
```

直接运行（脚本会在启动时把同级的 `_build/default/lib` 加入代码路径，以便加载 SQLite 的 NIF 驱动）：

```bash
_build/default/bin/eflyway -?
```

> 注意：SQLite 驱动 `esqlite` 是一个 NIF，无法从 escript 归档内部加载。若要把 escript 移到其他位置，请同时保留 `lib` 目录（或设置 `ERL_LIBS` 指向它）。也可以直接用 `erl` 运行：
>
> ```bash
> erl -noshell -pa _build/default/lib/*/ebin -s eflyway main -- -url=... migrate
> ```

### 2.3 从源码运行

```bash
rebar3 shell -- eval 'eflyway:main(["-url=sqlite3:///tmp/test.db","info"]).'
```

---

## 3. 快速开始

### 3.1 SQLite3

准备迁移脚本：

```bash
mkdir -p sql
cat > sql/V1__create_person.sql <<'SQL'
CREATE TABLE person (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL
);
SQL

cat > sql/V2__add_email.sql <<'SQL'
ALTER TABLE person ADD COLUMN email TEXT;
SQL
```

执行迁移：

```bash
eflyway -url=sqlite3:///tmp/demo.db migrate
```

输出大致如下：

```
Database: sqlite (SQLite)
Schema history table: "main"."flyway_schema_history"
Creating Schema History table "main"."flyway_schema_history" ...
Migrating schema "main" to version "1 - create person"
Migrating schema "main" to version "2 - add email"
Successfully applied 2 migrations to schema "main" (execution time 00:00.012s)
```

查看状态：

```bash
eflyway -url=sqlite3:///tmp/demo.db info
```

### 3.2 MySQL

```bash
eflyway \
  -url=mysql://root:secret@127.0.0.1:3306/demo \
  migrate
```

也可以把用户名密码单独传入：

```bash
eflyway \
  -url=mysql://127.0.0.1:3306/demo \
  -user=root \
  -password=secret \
  migrate
```

> 提示：`-user` / `-password` 会覆盖 URL 中的凭据。

---

## 4. 迁移文件命名

### 4.1 版本化迁移（Versioned）

格式：

```
V<版本>__<描述>.sql
```

- 前缀：`V`
- 分隔符：`__`（两个下划线）
- 版本：数字，用 `.` 或 `_` 分隔，逐段数值比较
- 描述：可含下划线，展示时会替换为空格
- 后缀：`.sql`

示例：

| 文件 | 版本 | 描述 |
|------|------|------|
| `V1__init.sql` | 1 | init |
| `V1_1__create_user.sql` | 1.1 | create user |
| `V2.0.0__release.sql` | 2.0.0 | release |
| `V20240101__year_start.sql` | 20240101 | year start |

版本比较是**逐段数值**比较，因此 `V1.10` 大于 `V1.9`（不是字符串比较）。

### 4.2 可重复迁移（Repeatable）

格式：

```
R__<描述>.sql
```

- 前缀：`R`
- 没有版本号
- **每次校验和变化都会重新执行**，适合视图、存储过程、函数等。

示例：

```sql
-- R__create_active_person_view.sql
CREATE VIEW active_person AS
SELECT id, name FROM person WHERE active = 1;
```

### 4.3 未识别/非法文件

未被前缀匹配的文件会被忽略。开启 `-validateMigrationNaming=true` 后，形如 `V__missing_version.sql` 的非法文件会直接报错。

---

## 5. 命令行参考

### 5.1 语法

```
eflyway [options] command
```

- `options`：`-key=value` 或标志（如 `-X`、`-q`、`-n`、`-?`）
- `command`：见下表

### 5.2 命令

| 命令 | 说明 |
|------|------|
| `migrate` | 将所有待执行迁移按顺序应用 |
| `info` | 打印全部迁移的状态 |
| `validate` | 校验已应用迁移与本地脚本是否一致 |
| `baseline` | 为非空数据库设置基线版本 |
| `clean` | 删除配置 schema 中的所有对象 |
| `repair` | 修复 schema history 表 |

### 5.3 标志

| 标志 | 说明 |
|------|------|
| `-?` | 打印使用帮助 |
| `-v` | 打印版本号并退出 |
| `-X` | 打印调试日志 |
| `-q` | 静默，仅输出 warning / error |
| `-n` | 不提示输入用户名密码 |

### 5.4 核心配置选项（命令行形式）

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `-url` | — | 数据库 URL（必填） |
| `-user` | — | 数据库用户 |
| `-password` | — | 数据库密码 |
| `-locations` | `filesystem:sql` | 迁移脚本目录，逗号分隔 |
| `-table` | `flyway_schema_history` | 历史表名 |
| `-schemas` | — | 受管 schema（MySQL 的 database），逗号分隔 |
| `-defaultSchema` | — | 默认 schema；缺省取 `-schemas` 第一个 |
| `-baselineVersion` | `1` | baseline 版本 |
| `-baselineDescription` | `<< Baseline >>` | baseline 描述 |
| `-baselineOnMigrate` | `false` | 非空库自动 baseline |
| `-target` | latest | 迁移目标版本 |
| `-outOfOrder` | `false` | 允许乱序迁移 |
| `-validateOnMigrate` | `true` | migrate 前自动 validate |
| `-validateMigrationNaming` | `false` | 校验文件名合法性 |
| `-ignoreMissingMigrations` | `false` | validate 忽略缺失 |
| `-ignoreIgnoredMigrations` | `false` | validate 忽略 ignored |
| `-ignorePendingMigrations` | `false` | validate 忽略 pending |
| `-ignoreFutureMigrations` | `true` | validate 忽略 future |
| `-cleanDisabled` | `false` | 禁用 clean |
| `-cleanOnValidationError` | `false` | validate 失败后自动 clean |
| `-createSchemas` | `true` | 自动创建 schema |
| `-placeholderReplacement` | `true` | 是否替换占位符 |
| `-placeholderPrefix` | `${` | 占位符前缀 |
| `-placeholderSuffix` | `}` | 占位符后缀 |
| `-placeholders.<key>` | — | 自定义占位符 |
| `-encoding` | `UTF-8` | 脚本编码 |
| `-mixed` | `false` | 允许同一迁移混合事务/非事务语句 |
| `-installedBy` | — | 写入历史表的安装者 |
| `-connectRetries` | `0` | 连接重试次数 |
| `-lockRetryCount` | `50` | 获取锁重试次数 |
| `-configFiles` | — | 显式配置文件，逗号分隔 |
| `-configFileEncoding` | `UTF-8` | 配置文件编码 |

完整的选项与默认值见 `design.md` 第 4 节。

### 5.5 示例

```bash
# SQLite：指定脚本目录
eflyway -url=sqlite3:///tmp/demo.db -locations=filesystem:./migrations migrate

# MySQL：指定 schema 与历史表
eflyway -url=mysql://root:secret@localhost/demo \
        -schemas=demo -table=schema_version \
        migrate

# 只迁移到版本 2.0
eflyway -url=sqlite3:///tmp/demo.db -target=2.0 migrate

# 校验（允许 pending）
eflyway -url=sqlite3:///tmp/demo.db -ignorePendingMigrations=true validate

# 查看信息（调试日志）
eflyway -X -url=mysql://root:secret@localhost/demo info
```

---

## 6. 命令详解

### 6.1 migrate

将所有 **pending** 迁移按版本顺序应用。

```bash
eflyway -url=sqlite3:///tmp/demo.db migrate
```

行为要点：

1. `validateOnMigrate=true`（默认）时，先做一次校验。校验失败则中止（除非 `cleanOnValidationError=true`）。
2. 若历史表不存在：
   - 数据库为空：自动创建历史表；
   - 数据库非空且 `baselineOnMigrate=false`：报错，提示使用 `baseline` 或开启 `baselineOnMigrate`；
   - 数据库非空且 `baselineOnMigrate=true`：自动 baseline。
3. 已是最新版本时：`Schema "main" is up to date. No migration necessary.`。
4. 默认逐条执行（每条一个事务边界），MySQL 上 DDL 失败不会回滚，会写入一条 `success=false` 记录。

### 6.2 info

打印连接信息、当前 schema 版本与迁移状态表。

```bash
eflyway -url=mysql://root:secret@localhost/demo info
```

输出示例：

```
eFlyway Version: 0.1.0
Database: mysql://localhost:3306/demo (MySQL 8.0)
Schema version: 2

+------------+---------+----------------+------+---------------------+---------+
| Category   | Version | Description    | Type | Installed On        | State   |
+------------+---------+----------------+------+---------------------+---------+
| Versioned  | 1       | create person  | SQL  | 2024-01-01 10:00:00 | Success |
| Versioned  | 2       | add email      | SQL  | 2024-01-02 11:30:00 | Success |
| Versioned  | 3       | add phone      | SQL  |                     | Pending |
| Repeatable |         | refresh view   | SQL  | 2024-01-02 11:31:00 | Success |
+------------+---------+----------------+------+---------------------+---------+

```

说明：

- 每条命令第一行打印版本横幅 `eFlyway Version: 0.1.0`（可用 `-q` 抑制）；
- `Database:` 行在每次运行的首次连接时打印，格式为 `<url> (<产品名> <主版本.次版本>)`，且会隐藏 URL 中的用户名/密码与查询参数；
- `Schema version:` 为当前已应用的最高版本，空库显示 `<< Empty Schema >>`；
- `Installed On` 不显示毫秒；没有匹配的迁移时表格显示 `No migrations found`。

常见状态：

| 状态 | 含义 |
|------|------|
| `Pending` | 尚未应用 |
| `Success` | 已成功应用 |
| `Baseline` | 基线标记 |
| `Ignored` | 因已有更高版本、且未开启 `outOfOrder` 而跳过 |
| `Missing` | 数据库中存在、但本地找不到 |
| `Future` | 数据库中版本高于本地最新版本 |
| `Failed` | 应用失败 |
| `Out of Order` | 乱序应用成功 |
| `Outdated` | 可重复迁移内容变化，需要重跑 |
| `Superseded` | 可重复迁移的旧版本 |
| `Deleted` | 被 repair 标记为已删除 |
| `Below Baseline` | 低于基线版本，未应用 |
| `Above Target` | 高于 `target`，不在本次范围 |

### 6.3 validate

校验已应用迁移与本地脚本是否一致。

```bash
eflyway -url=sqlite3:///tmp/demo.db validate
```

校验失败的情况：

- 脚本被修改导致 **校验和** 不一致；
- 描述、类型不一致；
- 本地存在未应用的迁移（pending）；
- 数据库有本地缺失的迁移（missing）；
- 存在失败迁移。

可用开关放宽：

```bash
eflyway -url=... \
        -ignoreMissingMigrations=true \
        -ignorePendingMigrations=true \
        -ignoreIgnoredMigrations=true \
        validate
```

### 6.4 baseline

为一个已经有表、但尚未纳入迁移管理的数据库打基线。基线以下（含基线）的迁移会被标记为 `Below Baseline`，不再执行。

```bash
eflyway -url=sqlite3:///tmp/demo.db \
        -baselineVersion=1 \
        -baselineDescription="existing schema" \
        baseline
```

要点：

- 历史表不存在：创建并写入 baseline 行。
- 历史表已存在且有 baseline：若版本和描述一致则跳过，否则报错。
- 历史表已有迁移：报错。
- `baselineVersion=0` 且存在 `SCHEMA` 标记时会报错。

### 6.5 clean

删除所有受管 schema 中的对象（表、视图、存储过程、触发器等），**不可恢复**。

```bash
eflyway -url=sqlite3:///tmp/demo.db clean
```

安全建议：

- 生产环境务必设置 `-cleanDisabled=true`，防止误操作：

```bash
eflyway -url=mysql://prod... -cleanDisabled=true migrate
```

### 6.6 repair

修复 schema history 表：

- 删除失败迁移记录（MySQL 等无 DDL 事务的库尤其需要）；
- 把本地缺失的迁移标记为 `DELETE`；
- 对齐已应用迁移的 description / type / checksum。

```bash
eflyway -url=sqlite3:///tmp/demo.db repair
```

典型场景：修改了一个尚未上线的迁移脚本后，`validate` 报 checksum mismatch，执行 `repair` 即可对齐。

---

## 7. 配置

### 7.1 配置文件

eflyway 按顺序加载以下默认配置文件（后加载覆盖先加载，文件不存在则忽略）：

1. `<安装目录>/conf/flyway.conf`
2. `~/.flyway.conf`
3. `<工作目录>/flyway.conf`

也可以用 `-configFiles=a.conf,b.conf`（或环境变量 `FLYWAY_CONFIG_FILES`）指定额外文件，它们在默认文件之后加载并覆盖之；用 `-configFileEncoding` 指定编码（默认 UTF-8），`-configFiles=-` 表示从标准输入读取。

```
# ./flyway.conf
flyway.url=mysql://root:secret@localhost/demo
flyway.locations=filesystem:sql
flyway.table=schema_version
flyway.baselineOnMigrate=true
flyway.placeholders.env=dev
```

```bash
eflyway migrate
```

---

> 说明：配置加载统一由 `eflyway_config` 实现，按命令行、环境变量、显式配置文件、默认配置文件的优先级合并。

### 7.2 环境变量

配置键大写、`.` 换成 `_`，加 `FLYWAY_` 前缀：

```bash
export FLYWAY_URL=mysql://root:secret@localhost/demo
export FLYWAY_USER=root
export FLYWAY_LOCATIONS=filesystem:sql
eflyway migrate
```

### 7.3 优先级

```
命令行  >  环境变量  >  配置文件  >  内置默认值
```

### 7.4 配置项速查

| 配置键 | 默认 | 说明 |
|--------|------|------|
| `flyway.url` | — | 数据库 URL |
| `flyway.user` | — | 用户 |
| `flyway.password` | — | 密码 |
| `flyway.locations` | `filesystem:sql` | 脚本目录 |
| `flyway.table` | `flyway_schema_history` | 历史表名 |
| `flyway.schemas` | — | 受管 schema |
| `flyway.defaultSchema` | — | 默认 schema |
| `flyway.baselineVersion` | `1` | 基线版本 |
| `flyway.baselineDescription` | `<< Baseline >>` | 基线描述 |
| `flyway.baselineOnMigrate` | `false` | 自动基线 |
| `flyway.target` | latest | 目标版本 |
| `flyway.outOfOrder` | `false` | 乱序迁移 |
| `flyway.validateOnMigrate` | `true` | migrate 前校验 |
| `flyway.validateMigrationNaming` | `false` | 校验文件名 |
| `flyway.ignoreMissingMigrations` | `false` | 忽略缺失 |
| `flyway.ignorePendingMigrations` | `false` | 忽略 pending |
| `flyway.ignoreIgnoredMigrations` | `false` | 忽略 ignored |
| `flyway.ignoreFutureMigrations` | `true` | 忽略 future |
| `flyway.cleanDisabled` | `false` | 禁用 clean |
| `flyway.cleanOnValidationError` | `false` | 校验失败自动 clean |
| `flyway.createSchemas` | `true` | 自动建 schema |
| `flyway.placeholderReplacement` | `true` | 占位符替换 |
| `flyway.placeholderPrefix` | `${` | 占位符前缀 |
| `flyway.placeholderSuffix` | `}` | 占位符后缀 |
| `flyway.placeholders.<key>` | — | 自定义占位符 |
| `flyway.encoding` | `UTF-8` | 编码 |
| `flyway.mixed` | `false` | 混合事务语句 |
| `flyway.installedBy` | — | 安装者 |
| `flyway.connectRetries` | `0` | 连接重试 |
| `flyway.lockRetryCount` | `50` | 锁重试次数 |
| `flyway.configFiles` | — | 显式配置文件，逗号分隔 |
| `flyway.configFileEncoding` | `UTF-8` | 配置文件编码 |

---

## 8. 占位符

在 SQL 中使用 `${key}`，运行时可被替换：

```sql
${flyway:defaultSchema}.person
```

自定义：

```bash
eflyway -url=... \
        -placeholders.env=dev \
        -placeholders.owner=app \
        migrate
```

```sql
CREATE TABLE ${env}_person ( ... );
```

内置占位符：

| 占位符 | 值 |
|--------|----|
| `${flyway:defaultSchema}` | 默认 schema |
| `${flyway:user}` | 当前数据库用户 |
| `${flyway:database}` | 当前 catalog / 数据库名 |
| `${flyway:timestamp}` | 运行时间 `yyyy-MM-dd HH:mm:ss` |
| `${flyway:filename}` | 当前脚本文件名 |

关闭替换：

```bash
eflyway -placeholderReplacement=false migrate
```

> 注意：占位符替换发生在**校验和计算之后**。因此可重复迁移会同时记录替换前后的校验和，`repair` 可以在两者间对齐。

---

## 9. 可重复迁移

可重复迁移（`R__*.sql`）没有版本号，每次运行都会重新计算校验和：

- 校验和与历史表一致：跳过；
- 校验和不同（脚本内容变化）：重新执行，并记录新行，旧行状态变为 `Superseded`。

示例：

```sql
-- R__refresh_report_view.sql
DROP VIEW IF EXISTS report_view;
CREATE VIEW report_view AS
SELECT ...;
```

注意：

- 可重复迁移在**所有版本化迁移之后**执行；
- 建议写成幂等的（先 DROP 再 CREATE）。

---

## 10. 校验和与验证

eflyway 为每个脚本计算 CRC32 校验和：

- 按行读取，忽略换行符差异（`\n` / `\r\n` 相同）；
- 忽略 UTF-8 BOM；
- 以 UTF-8 编码计算。

`validate` 会检查：

1. 已应用迁移的校验和是否与本地脚本一致；
2. description / type 是否一致；
3. 是否有本地已删除但数据库中仍存在的迁移；
4. 是否有本地新增但尚未应用的迁移；
5. 是否存在失败迁移。

修复不一致：

```bash
eflyway -url=... repair
```

---

## 11. 修复

`repair` 会：

| 动作 | 说明 |
|------|------|
| 删除失败记录 | 移除 `success=false` 的行（MySQL 上 DDL 失败后常用） |
| 标记删除 | 把本地缺失的迁移插入一条 `DELETE` 记录 |
| 对齐 | 更新已应用迁移的 description / type / checksum |

MySQL 无 DDL 事务，迁移失败后会留下半完成的对象，`repair` 只能修正历史表，**数据库对象仍需手工清理**。

---

## 12. SQL 解析规则与限制

eflyway 的 SQL 解析策略：

- 默认语句分隔符为 `;`；
- 支持 `--` 行注释、`/* ... */` 块注释（可嵌套）；
- MySQL 额外支持 `#` 行注释、`/*! ... */` 指令、反引号标识符、双引号字符串、`DELIMITER` 指令；
- 字符串内的分隔符不会被误切分；
- 支持 `BEGIN ... END` 块（SQLite 的 `BEGIN`/`CASE`/`END`，MySQL 的存储程序）；
- MySQL 存储程序建议使用 `DELIMITER`：

```sql
DELIMITER $$
CREATE PROCEDURE p()
BEGIN
    SELECT 1;
END$$
DELIMITER ;
```

已知限制：

- 某些数据库方言的极端语法可能无法识别；
- 非 SQL 脚本（Java migration、自定义 resolver）不支持；
- 云端/classpath 资源不支持。

SQLite 的 `PRAGMA foreign_keys` 被视为非事务语句。

---

## 13. 退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功 |
| `1` | 执行失败（连接、迁移、校验等） |
| `2` | 命令行参数错误 / 用法错误 |

CI 中可以据此判断：

```bash
if ! eflyway -url=... migrate; then
    echo "migration failed"
    exit 1
fi
```

---

## 14. 常见问题

### Q1. `Found non-empty schema(s) "demo" but no schema history table`

数据库已有对象但从未被迁移工具管理。两种处理方式：

```bash
# 方式一：打基线
eflyway -url=... -baselineVersion=1 baseline

# 方式二：migrate 时自动打基线
eflyway -url=... -baselineOnMigrate=true migrate
```

### Q2. `Migrations have failed validation`：checksum mismatch

脚本在应用后被修改。若确实要接受新内容（例如脚本尚未上线），执行：

```bash
eflyway -url=... repair
```

### Q3. `Detected applied migration not resolved locally`

本地删除了已应用的脚本。若是有意删除：

```bash
eflyway -url=... repair     # 标记为 DELETE
```

否则请恢复脚本。

### Q4. `Detected resolved migration not applied to database`

存在 pending 迁移。运行 `migrate`，或校验时加 `-ignorePendingMigrations=true`。

### Q5. MySQL 迁移失败后表对象残留

MySQL 的 DDL 会隐式提交，无法回滚。需要：

1. 手工清理残留对象；
2. 运行 `repair` 删除失败记录；
3. 修正脚本后重新 `migrate`。

### Q6. 连接失败

- 检查 URL scheme 是否为 `mysql` 或 `sqlite3`；
- MySQL 检查主机、端口、库名、账号密码、网络；
- SQLite 检查文件路径及目录写权限；
- 需要重试时使用 `-connectRetries=3`。

### Q7. 想自定义迁移目录

```bash
eflyway -url=... -locations=filesystem:./db/migrations migrate
```

多个目录用逗号分隔：

```bash
-locations=filesystem:./migrations,filesystem:./hotfix
```

### Q8. 如何查看实际执行的 SQL

加 `-X` 开启 debug：

```bash
eflyway -X -url=... migrate
```

### Q9. `info` / `validate` 会自动创建 `flyway_schema_history` 表吗？

不会。

- `info`、`validate`、`repair` 在历史表不存在时将其视为空（`all_applied` 返回空列表），**不会创建表**；
- 只有 `migrate`（空 schema 路径）和 `baseline` 会创建历史表；
- 因此在全新数据库上运行 `info`，会直接把本地迁移显示为 `Pending`，数据库里不会多出任何表。

### Q10. 目标数据库不存在怎么办？

eflyway **不会自动创建数据库**，也不会把 “Unknown database” 抛成 crash，而是打印一行友好提示并退出（退出码 1）：

```
ERROR: database_does_not_exist: Database 'new_db' does not exist. Create it first.
```

- MySQL：连接时先不带 database 连到服务器，检测到库不存在即返回上述提示，不执行 `CREATE DATABASE`；
- SQLite：库文件本身由 SQLite 自动创建，但其**父目录必须已存在**；否则提示 `Directory ... does not exist. Create it first`；
- `createSchemas` 不再触发数据库/目录的自动创建。

先手动创建数据库，再执行迁移：

```bash
mysql -uroot -p -e "CREATE DATABASE new_db"
eflyway -url=mysql://root:root@127.0.0.1:3306/new_db -locations=filesystem:sql migrate
```

---

## 15. 功能范围与限制

eflyway 目前不支持以下能力：

- Java 编写的迁移，明确不实现；
- Callback（`beforeMigrate`、`afterMigrate` 等）；
- `undo`（回退迁移）；
- `cherryPick`、`skipExecutingMigrations`、`dryRunOutput`、`errorOverrides`、`stream`、`batch`；
- 云端资源（S3/GCS）与 classpath 资源；
- SQLite 内存库（`:memory:`）——仅支持文件库；
- Maven / Gradle 插件，仅提供独立的 escript CLI；
- MySQL、SQLite 之外的数据库。

除此之外，迁移文件命名、校验和算法、schema history 表结构、迁移状态与命令语义均保持稳定，已有项目的迁移脚本可以直接复用。

---

祝迁移愉快！
