# NodePoolME P-1.8 第三轮文档修正记录（v1.10）

**性质**：仅文档与实施设计修订。未修改程序代码，未运行 pytest，未运行 Docker，未执行迁移，未连接 NAS。
**依据**：ChatGPT 第三轮复审意见（2026-11-26）——需明确源库基线状态、补齐 `docker kill` 后的持久化恢复证据。
**日期**：2026-11-26

## 1. 源数据库状态定义表

### 1.1 结论：P-1.8 统一采用 **B（已有基线）**

| 项 | 定义 |
| --- | --- |
| 源库版本 | `1.8.7-baseline`（`VERSION_SEQ=1`） |
| 业务表集合 | 17 张：`settings`、`airports`、`fetch_logs`、`nodes`、`airport_filtered_nodes`、`test_groups`、`results`、`latency_results`、`share_history`、`schedule_history`、`batches`、`run_events`、`logs`、`speed_sources`、`speed_source_checks`、`speed_runs`、`speed_samples`；另加可选历史表 `tasks`（测试统一"不存在"或"存在且 0 行"） |
| `schema_migrations` | **存在**，列 `id/migration_id/seq/version/status/started_at/finished_at/detail_json` |
| 基线记录 | **存在且唯一**：`migration_id='1.8.7-baseline'`、`seq=1`、`version='1.8.7-baseline'`、`status='success'` |
| `ensure_schema_table_transactional()` | P-1.8 **不执行**；只在测试环境预备步骤经 `record_baseline()` 调用一次，把 v1.8.7 副本变成 B 状态 |
| 迁移事务内 DDL | **零 DDL**；`BEGIN IMMEDIATE` → 插 `running`（`seq=2, version='1.10'`）→ `COMMIT` → 第二事务置 `success` |

### 1.2 选择依据（代码与文档核对）

| 证据 | 事实 |
| --- | --- |
| `migrate.run()` | 只调用 `preflight()`，**不调用** `ensure_schema_table_transactional()`/`record_baseline()`；表不存在时 `preflight` 返回 `absent`，但 `run()` 随后直接 `INSERT`，无建表动作 |
| `preflight()` | 表不存在 ⇒ `action=create_table_and_record_baseline`（仅是建议，无执行者） |
| P-1.6 测试 | `tests/test_migration_state.py`、`test_migration_baseline.py` 都先显式 `record_baseline(conn)` 再跑迁移 |
| P-1.7 测试 | `tests/test_backup_manual.py` 亦先 `record_baseline`，否则 `preflight=absent` |
| 生产基线 | v1.8.7 容器库无 `schema_migrations`；首次基线属部署引导，不在 P-1.8 |

因此若选 A，必须先给 `run()` 增加"建表 + 基线"入口逻辑，属未批准的架构追加；选 B 才与现有代码、已验收测试一致。

### 1.3 R1–R5 与源库状态映射

| 场景 | 源状态 | 说明 |
| --- | --- | --- |
| R1 正常迁移 | B | 全新 B 副本，迁移前先备份 |
| R2 重复执行 | B（经 R1 成功，`current_version=1.10`） | 复用 R1 产物，验证 `version_mismatch` 拒绝且不新增行 |
| R3 `docker kill` | B | 全新 B 副本，`TX_OPEN` 阶段 SIGKILL |
| R4 失败/恢复 | B | 全新 B 副本，注入非法 DDL；恢复用其迁移前 B 备份 |
| R5 手动回滚 | B | 用 R1 迁移前备份（仅基线行），回滚后回到 `1.8.7-baseline` |

> 同一场景不得同时出现"表不存在/迁移建表"的 A 描述。A 由 P-1.2/P-1.6 覆盖，P-1.8 不重复。

## 2. `docker kill` 前后状态转换表

### 2.1 kill 前的持久化事实

| 时点 | maintenance.json | `schema_migrations` | 迁移锁 |
| --- | --- | --- | --- |
| 写维护后、封锁/事务前 | `maintenance=true`、`phase=PREPARED`、`pid=旧进程` | 仅基线行 | 空闲（事务前未持有） |
| `BEGIN IMMEDIATE` 成功后（需 D1） | `phase=TX_OPEN` | 仅基线行 | 持有 |
| 事务内插入 running 后、提交前 | `phase=TX_OPEN` | 未提交的 running 行（崩溃即回滚） | 持有 |
| COMMIT 成功、置 success 前（需 D1） | `phase=COMMIT_ATTEMPTED` | 基线 + running 行 | 持有 |
| success 已落库、未清维护（需 D1） | `phase=COMMITTED` | 基线 + success(1.10) | 空闲/待释放 |

### 2.2 SIGKILL 后重启判定（D1–D3 生效后）

| 文件 phase | 锁 | DB 行 | 判定 | 持久证据来源 |
| --- | --- | --- | --- | --- |
| `PREPARED` | 空闲 | 仅基线 | `RECOVERY_REQUIRED`（`interrupted_before_tx`） | 维护文件存在 + 锁空闲 + 无 running |
| `TX_OPEN` | 空闲 | 仅基线（running 已回滚） | `RECOVERY_REQUIRED`（`interrupted_in_tx`） | 文件 phase + 锁空闲 |
| `COMMIT_ATTEMPTED` | 空闲 | 基线 + running | `RECOVERY_REQUIRED`（`interrupted_before_finalize`） | 文件 phase + running 行 |
| `COMMITTED` | 空闲 | 基线 + success | `RECOVERY_REQUIRED`（`success_pending_release`） | 文件 phase + success 行 |
| `UNKNOWN` | 空闲 | 任意 | `RECOVERY_REQUIRED` | 文件 phase |
| 任意 | 被持有 | 任意 | 拒绝启动（`already_running`） | flock 实测 |
| 文件缺失 | 空闲 | 含 running/failed | `RECOVERY_REQUIRED` | `judge_by_migration_rows()` |

### 2.3 当前架构的缺口（必须明确报告）

| 核对项 | 当前事实 | 结论 |
| --- | --- | --- |
| 未提交事务被 kill | SQLite 崩溃回滚，running 行消失 | DB 无法单独证明迁移开始过 |
| maintenance.json phase | `set_maintenance()` 只在开始时写 `PREPARED`；`set_phase_memory()` 仅改内存 | 重启后永远看到 `PREPARED`，丢失 TX_OPEN 证据 |
| 重启后状态 | 文件 `maintenance=true` ⇒ `maintenance_state()` 返回 `ACTIVE` | **不会**得到 `RECOVERY_REQUIRED`，与正常维护不可区分 |
| 写封锁 | 启动顺序 `selfcheck → maintenance_state → init_db → 调度器` | 无"恢复态先封锁再 init"逻辑 |

**结论：以当前已批准架构无法可靠实现 R4-b。** 需要补充 D1–D3，且须项目方批准；未批准前 R3/R4-b 不得标记通过，禁止用 mock 或"预期结果"充当证据。

### 2.4 需批准的设计补充

| 编号 | 补充 | 口径 |
| --- | --- | --- |
| D1 | 维护文件持久化 phase | T1 后写 `TX_OPEN`、T2 前写 `COMMIT_ATTEMPTED`、成功后写 `COMMITTED`、halt 写 `UNKNOWN`；原子写 + fsync + 回读，nonce 不变 |
| D2 | 启动中断分类 | 锁被持有 ⇒ 拒绝启动；锁空闲且 `maintenance=true` ⇒ 按 phase 判 `RECOVERY_REQUIRED`（新增派生规则，不改 DB 行判定） |
| D3 | 重启即封锁 | `RECOVERY_REQUIRED`/`ACTIVE` 在 `init_db()`、调度器、HTTP 监听前封锁写入并确认；业务写 503，只读可用 |

**避免误判正常维护**：正常迁移进程存活并持有迁移锁，重启不会发生；一旦重启，锁必然释放。"锁空闲 + 维护文件存在"即中断充分条件。`PREPARED` 在重启后无法区分"刚开始"与"事务前死亡"，按 fail-closed 统一 `RECOVERY_REQUIRED`，由人工查看 phase 决定继续或导入。

### 2.5 R4-b 真实测试方法

1. 测试容器执行迁移；宿主机轮询 bind 的 `maintenance.json`，读到 `phase=TX_OPEN` 时 `docker kill --signal=KILL`（真实 SIGKILL，无测试钩子）。
2. 重启容器，读取三份外部证据：维护文件（phase/nonce/pid）、`sqlite3` 直读测试库（行集合与 17 表计数）、`cli status --json`（state/writes_blocked）。
3. 断言 `RECOVERY_REQUIRED`、`writes_blocked=true`、写接口 503、`backup` 目录无新增自动恢复文件、DB 无 success(1.10)。
4. `import --recover --file <迁移前 B 备份>` → `INACTIVE` → 计数回到 B → 重启只读复核通过。
5. D1–D3 未实现则本项记"设计缺口待批准"，不得判通过。

## 3. 修改位置与前后对照

| 文件 | 位置 | 修订前 | 修订后 |
| --- | --- | --- | --- |
| 计划 v1.10 | §8.3 | "唯一 DDL 是 CREATE TABLE…迁移事务建表"与"已有基线"并存，A/B 混用 | 统一 B：表与基线由预备步骤创建，迁移事务零 DDL；新增表集合、执行顺序、R1–R5 映射 |
| 同上 | §8.5（新增） | 无 | 现状核对、D1–D3、kill 状态判定表、真实测试方法 |
| 同上 | §8.1 R3/R4-b 行 | "DDL 阶段强杀" | 明确 B 源、`TX_OPEN` 时点、证据依赖 D1–D3 |
| 同上 | §8 阶段表 | 未含 §8.5 | 验收补"含 §8.5 证据" |
| 同上 | §10 修订记录 | 第 21 次为止 | 新增第 22 次条目 |
| 设计 v1.10 | §12 迁移内容 | 表不存在 ⇒ 建表 DDL | 改为 B 状态、预备步骤建表/基线、事务零 DDL、A 不在范围 |
| 同上 | §12 新增段 | 无 | `docker kill` 证据缺口、D1–D3、判定表、测试要求 |
| 同上 | 结尾统计 | 二十一次 | 二十二次 + 第 22 次说明 |

## 4. 未改动项与边界

- 程序代码零改动；未运行 pytest/Docker/迁移；未连接 NAS。
- P-1.7 已验收实现（`a62aeb2`）及交付材料未修改。
- 未新增任何未批准的业务数据迁移内容；D1–D3 属待批准设计补充，本轮未实现。
- 未把 R1–R5 宣称为"已具备实现基础"；§8.3 明确当前 `run()` 仍是空迁移框架。

## 5. 交付与停止

| 项 | 值 |
| --- | --- |
| 文档仓库 | `laoXuHome/laoXuHome`，`main` |
| 文档提交 | 见本次交付回复中的 commit SHA |
| 代码提交 | 无 |

**停止**：等待 ChatGPT 第三轮独立复审；复审通过并批准 D1–D3 后，才进入 P-1.8 施工。
