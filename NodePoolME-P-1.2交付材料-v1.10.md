# NodePoolME P-1.2 交付材料｜Schema Migration Baseline

> 阶段：P-1.2（严格按《P-1 实施计划 v1.10》§2.2 施工）
> 代码基准：`e721797`（v1.8.7）→ 本次提交 `2890728`
> 性质：**代码施工**。未连接 NAS、未改生产库、未建任何生产表、未执行迁移器、未进入 P-1.3。
> 日期：2026-11-26

---

## 1. 交付文件

| 文件 | 状态 | 字节 | 行 | blob SHA | commit |
|---|---|---|---|---|---|
| `backend/database/migrate.py` | 新增 | 18,842 | 517 | `5ce96a1c94d7e0f1dd23e98ab6ced162abe1ed6d` | `2890728` |
| `tests/test_migration_baseline.py` | 新增 | 16,108 | 418 | `abb2e555f675e5cec6cda069d61dbe9e0df34783` | `2890728` |

提交：`2890728`（`feat(P-1.2): schema_migrations 基线与事务化登记…`），已推送 `laoXuHome/NodePoolME` `main`（`e721797..2890728`），远端 blob 与本地逐字节一致（已用 contents API 校验 `size`/`sha`）。

**改动面仅此两个文件。** `backend/database/db.py` 未改动（`git show --stat` 只有 2 个新增文件，0 删除 0 修改）→ `schema_migrations` 没有进入 `SCHEMA`，`init_db()` 逻辑未变。

---

## 2. 实现的接口（§2.2 要求项对照）

| 计划要求 | 实现 | 语义 |
|---|---|---|
| `SCHEMA_MIGRATIONS_DDL` | 模块常量 | 含 `seq INTEGER NOT NULL UNIQUE`；DDL 只在本模块，不在 `db.SCHEMA` |
| `VERSION_SEQ` | `{"1.8.7-baseline": 1, "1.10": 2}` | seq 唯一分配，禁止运行时自增猜测 |
| `ensure_schema_table_transactional()` | 有 | `BEGIN IMMEDIATE` → `CREATE TABLE IF NOT EXISTS` → 插基线 → `count==1` → `COMMIT`；任一步异常 `ROLLBACK` |
| `record_baseline()` | 有，幂等 | 结构校验（不匹配/缺表/`tasks` 非空 → 拒绝，且**在任何写入之前**）→ 复用上面的事务入口；重复调用返回 `already_present`，seq 不变 |
| `current_version()` | 有 | `status='success' ORDER BY seq DESC LIMIT 1`；无 `MAX(version)`、无 `ORDER BY version` |
| `preflight()` | 有，只读 | `absent / empty / incomplete / unknown_version / version_mismatch / ready`，含 `allowed`、`reason`、`action`、`pending` |
| 基线版本 = 生产实测 1.8.7 | `BASELINE_VERSION = "1.8.7-baseline"`（由 `config.VERSION` 派生） | 与 P-1.1 四值核对结果一致 |
| `tasks` 双合法形态 | `tasks_state()` 独立记账（`tasks_present / tasks_rows / tasks_hash`） | 不存在 与 存在且空 都放行且**主摘要相同**；存在但非空 → `tasks_not_empty` 拒绝；全程不 DROP/DELETE/ALTER 该表 |
| 17 张基准表 | `BASE_TABLES` 常量 + `missing_base_tables` 校验 | 缺任何一张 → `missing_base_tables` 拒绝 |

---

## 3. 一处实现层修正（需要说明，但不改设计意图）

计划 §2.2.4 写的是「对 `sqlite_master` 的 `sql` 去空白后拼串取 sha256」。实测发现这条**字面口径不可用**：

- 生产/开发库是历次 `ALTER TABLE` 演化来的，`airports`、`speed_runs`、`share_history` 三张表的 DDL 文本里**列声明顺序**与「全新 `init_db()` 建出来的库」不同（`filter_keywords`、`created_at/updated_at`、`mb_per_s` 等是后加的，追加在尾部）；
- 因此字面哈希在两个**语义完全相同**的库上就不同：dev `fb440a9a…` vs fresh `901ad4a9…`。若把其中一个写成常量，另一个必然被拒绝，PT-06e（全新库登记基线）就无法通过。

改为**语义签名**（仍是"结构摘要"，只是把"去空白"升级为"去格式与列序"）：

- 每张表取 `PRAGMA table_info`（列名/类型/`NOT NULL`/默认值/主键位次，按列名排序）、`PRAGMA index_list` + `index_info`（唯一性、来源、部分索引、列序）、`PRAGMA foreign_key_list`、以及 DDL 中的 `CHECK(...)` 表达式（括号配对抽取）；
- 显式索引/视图/触发器取去注释、折叠空白后的 SQL 文本；
- 排除 `tasks` 与 `sqlite_%`，以及 `schema_migrations` 自身（否则登记动作会改变自己的摘要）。

效果：dev 库与全新 `init_db()` 库得到**同一个** `structure_hash`：

```
eb5fd0ce54a87d6e748a144a35ce97903b71acfb5415eb9fd8e4cba28f88da0b
```

`BASELINE_STRUCTURE_HASH` 即此值。**校验强度未降低**：新增/删除列、改类型、改 `NOT NULL`、改默认值、改主键、改索引列或唯一性、改外键、改 `CHECK`、少一张基准表，全部会被这个摘要捕获（`tests/test_migration_baseline.py::test_pt06d_structure_drift_is_refused`、`…missing_base_table_is_refused` 覆盖）。

---

## 4. 测试结果

### 4.1 本阶段专项（12 项，全通过）

```
tests/test_migration_baseline.py::test_pt06_baseline_idempotent_and_business_tables_unchanged PASSED
tests/test_migration_baseline.py::test_pt06b_version_ordering_uses_seq_not_string PASSED
tests/test_migration_baseline.py::test_pt06c_create_and_insert_are_atomic_on_insert_failure PASSED
tests/test_migration_baseline.py::test_pt06c_count_verification_failure_rolls_back PASSED
tests/test_migration_baseline.py::test_pt06d_tasks_absent_and_empty_present_share_same_hash PASSED
tests/test_migration_baseline.py::test_pt06d_tasks_present_but_not_empty_is_refused PASSED
tests/test_migration_baseline.py::test_pt06d_structure_drift_is_refused PASSED
tests/test_migration_baseline.py::test_pt06d_missing_base_table_is_refused PASSED
tests/test_migration_baseline.py::test_pt06d_hash_ignores_alter_history_and_column_order PASSED
tests/test_migration_baseline.py::test_pt06e_init_db_never_creates_schema_migrations PASSED
tests/test_migration_baseline.py::test_preflight_matrix_empty_incomplete_and_mismatch PASSED
tests/test_migration_baseline.py::test_preflight_and_record_baseline_refuse_on_version_mismatch PASSED

12 passed in 10.36s
```

| 编号 | 验收点 | 结果 | 关键断言 |
|---|---|---|---|
| PT-06 | 基线幂等性 | PASS | 连续两次 `record_baseline()`：`created` → `already_present`；表内恒 1 行、`seq=1`、`version=1.8.7-baseline`、`current_version()` 不变 |
| PT-06b | 版本排序正确性 | PASS | 插入 `1.9(seq=10)`、`1.10(seq=11)`；`current_version()=="1.10"`；同时断言 `MAX(version)=="1.9"`（字符串会错序），证明排序键是 `seq` |
| PT-06c | 建表与登记原子性 | PASS（两次注入） | ①插行抛错 ②行数校验抛错；两种故障后 `schema_migrations` **不存在**、业务表指纹不变 |
| PT-06d | 结构核对 + `tasks` 双合法 | PASS（4 项） | `tasks` 存在空 / 不存在 → 同一 `structure_hash`、登记成功；`tasks` 非空 → `tasks_not_empty` 拒绝且表未被动；加无关表 → `structure_mismatch`；少基准表 → `missing_base_tables` |
| PT-06e | `init_db()` 不提前建表 | PASS | 全新库连跑 3 次 `init_db()`：`schema_migrations` 不存在、`current_version()=None`；`preflight()` 判 `absent` 且**只读**（调用后表仍不存在）；登记后 1 行；再跑 2 次 `init_db()` 后仍 1 行、业务表计数与结构摘要不变、`preflight()` 转 `ready` |
| 附加 | preflight 矩阵 | PASS | `empty→refuse`、`running→recovery_required`、仅 success 但版本不符 → `version_mismatch`、基线 → `ready` |
| 附加 | 版本闸 | PASS | 未注册的 `runtime_version` → `unsupported_runtime_version`；`healthz_version=1.10` → `version_mismatch`；均未建表 |

### 4.2 全量回归

```
NODEPOOL_DATA_DIR=<副本> NODEPOOL_DB=<副本> python3 -m pytest -q
215 passed, 1 warning in 6.97s
```

215 = 既有 203 + 本阶段 12；**通过 215 / 失败 0 / 跳过 0**。全量回归在独立副本库上执行，未触碰仓库 `data/` 里的开发实例。

### 4.3 故障注入

| 注入点 | 方法 | 结果 |
|---|---|---|
| 基线插入 | 运行时替换 `migrate._insert_row` 为抛错函数 | 异常抛出，事务 `ROLLBACK`，`sqlite_master` 无 `schema_migrations` |
| 行数校验 | 替换 `_count_rows`：第 1 次返回 0（进入插入分支）、第 2 次抛错 | 异常抛出，`ROLLBACK`，无残留空表 |

两项均验证了"表在、基线缺"的中间态**不可能存在**（SQLite DDL 在事务内可回滚）。

---

## 5. 17 张基准业务表零变化的证据

方法：`sqlite3.backup()` 复制开发库到副本 → 写入 2 行哨兵数据（`settings`、`logs`）→ 记录每表「行数 + 全表内容 sha256」与整体 `structure_hash` → `record_baseline()`（含幂等第二次）→ 再记录一次 → 比对。

```
structure_hash(before) = eb5fd0ce54a87d6e748a144a35ce97903b71acfb5415eb9fd8e4cba28f88da0b
base_tables = 17
record_baseline #1 -> {"status":"created","seq":1,"version":"1.8.7-baseline"...}
record_baseline #2 -> {"status":"already_present","seq":1,...}
structure_hash(after)  = eb5fd0ce54a87d6e748a144a35ce97903b71acfb5415eb9fd8e4cba28f88da0b
same_structure: True
table_diffs: []                 ← 17 张表逐表（行数、内容哈希）全部一致
schema_migrations rows: 1 | seq: 1 | version: 1.8.7-baseline | status: success
detail.tasks_present: True rows: 0 | tables_count: 17
integrity: ok
fk_violations: 0
tasks rows still: 0
```

`detail_json` 实际键集：`app_version, baseline, healthz_version, image_digest, runtime_version, structure_hash, tables, tables_count, tasks_hash, tasks_present, tasks_rows`。

---

## 6. 边界与未做项（如实声明）

1. **未连接 NAS**，未读取/写入生产库；生产 `schema_migrations` **不存在**，生产仍是 v1.8.7 原状。
2. **未修改** `db.py`、`SCHEMA`、`init_db()`、任何业务模块、Compose、镜像、运行配置；未动 `tasks`、`sqlite_sequence`、任何业务数据。
3. **未进入 P-1.3**（快照/备份集实现未动）。
4. 仓库内 `data/nodepool.db` 是 gitignored 的开发实例（非生产），该仓库既有 `tests/conftest.py` 会在每次测试前清空其业务表——这是原有测试行为，本次未改；所有迁移测试均使用**副本**，未依赖也未修改该实例作为证据来源。
5. **R1（生产备份陈旧）仍在**：本阶段是代码施工，未触碰生产；未来任何生产写入窗口前仍须先取得可验证 `pre-migrate` 备份。

---

## 7. 遗留问题与影响判定

| 项 | 说明 | 是否影响 P-1.2 验收 |
|---|---|---|
| 生产 `structure_hash` 未实测 | 生产库不可达，常量取自开发实例与全新 `init_db` 的一致性值（两者相等）。首次在生产登记时若 `actual != expected`，`record_baseline()` 会**拒绝**并打印 `actual=… expected=…` | **不影响**。这是设计要求的闸门（结构漂移必须停），不是缺陷；若真发生，需按报告比对差异后由项目负责人决策 |
| `tasks_hash` 依赖 DDL 文本（含注释/列序） | 仅用于记账展示，不参与任何放行判定 | 不影响 |
| `VERSION_SEQ` 仅含 `1.8.7-baseline=1`、`1.10=2` | 后续版本需在实现时注册 | 不影响本阶段 |
| `current_version()` 与 `preflight()` 的 `expected` 按 `config.VERSION` 派生 | 版本升级时语义随常量走，不需改代码逻辑 | 不影响 |

---

## 8. 复现方式

```sh
# 专项
python3 -m pytest tests/test_migration_baseline.py -v

# 全量（建议在副本库上跑，避免清空仓库内开发实例）
python3 -m pytest -q
```

---

*本阶段到此停止，不自动进入 P-1.3。*
