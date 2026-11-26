# NodePoolME P-1.6 交付材料（迁移状态机）

**阶段**：P-1.6 Migration State Machine
**提交**：`9f558cf3641304d13e9be8bdd241da6ac5833fac`（`9f558cf`，已推送 `main`）
**基线**：`3fb7c515f894569e231d687f228df7ad3d8dac5b`（P-1.5 发射器对象身份绑定，已验收）
**依据文档**：《NodePoolME 新架构总体设计方案 v1.10》《NodePoolME-P-1 实施计划 v1.10》（均未修改）
**生产环境**：未接触 NAS、生产库、生产容器、生产服务；未执行 P-7；未做生产迁移或部署。
**停止点**：本阶段到此停止，等待负责人复审。**未进入 P-1.7 / P-1.8**，不自评通过。

---

## 0. 必须先裁决的一处文档冲突（影响"事件记录"这一项验收）

任务书要求"实现 P-1.6 规定的迁移状态机、状态转换、**事件记录**、异常处理及安全拒绝路径"，并要求"必须保证迁移状态转换与**事件记录**的一致性"。但是两份批准文档对本阶段的规定与该要求直接冲突：

| 位置 | 原文规定 |
| --- | --- |
| 计划 v1.10 §3.2（表：数据库表） | `system_events` / `migration_tx_notes`：**P-1 不建**；任何"用 `schema_migrations` 冒充事件表"的写法本轮禁止 |
| 计划 v1.10 §5 PT-09b | 迁移器不写事件接缝：**`write_event()` 必须抛 `NotImplementedError`**；只有 `schema_migrations` 的 `running/failed/success`；不得出现 `event/seq/prev_sha/token_fp/s5_failed_ever` 等持久化事件链列 |
| 计划 v1.10 §8 阶段表 | P-1.6 = "`migrate.py` 最小状态机（**无事件链**）+ 空迁移 dry-run"，验收 PT-09b / PT-12 / PT-13 / PT-19 / PT-25 |
| 设计 v1.10 §2.1 | 定义 `system_events`（含 `seq/prev_sha/token_fp/s5_failed_ever`）与 `migration_tx_notes` 两表 DDL、`write_event()` 全链校验、A/B/C 提交结果确认 |
| 设计 v1.10 §1 / §2.2 / §5 | T4/T5/T6/T7/T8 的 durable 事件时点、E1–E3、β/β′ 路径、`s5_failed_ever` 单调 |

**结论**：在 PT-09b 未解除前，"事件记录"无法在不违反批准文档的前提下实现。按任务书"发现设计文档与现有代码/要求冲突，先报告具体冲突及影响，不得自行改变已批准架构"，本轮采取：

1. **按计划 v1.10 §8 施工**：实现无事件链的最小状态机 + 空迁移 dry-run，事件接口按 PT-09b 显式 `NotImplementedError` 失败关闭；
2. **不建** `system_events`/`migration_tx_notes`，不加任何哈希链列，不用内存或普通日志冒充持久事件；
3. phase 的唯一 durable 痕迹保持为 `schema_migrations.status`；
4. 把 durable 事件链列为**未完成项**，等负责人裁决：要么解除 PT-09b（则另开一次提交专门接入事件链），要么明确 P-1.6 的"事件记录"就指 status 行 + `migration-fault.log`。

**影响**：P-1.6 的"事件一致性"只覆盖 `running → success/failed` 与 phase 推进的先后关系（见 §2），不覆盖设计 §2.1 的 A/B/C 提交结果确认与哈希链。P-1.7 的全链路演练（PT-05/07/08/17/18/20/22/26）在事件链缺失下只能演练"文件日志 + status 行"口径。

---

## 1. 提交与变更清单

**commit**：`9f558cf3641304d13e9be8bdd241da6ac5833fac`

| 文件 | 变更 | 字节数 | 行数 | blob SHA |
| --- | --- | --- | --- | --- |
| `backend/database/migrate.py` | +791 行（状态机、halt、run、rollback、分派表自检） | 57,994 B | 1,352 | `0f33d549d5df3910c55af22a68ab8f5b4d23c3a9` |
| `tests/test_migration_state.py` | 新增 638 行（29 项） | 26,636 B | 638 | `68f0d138048ffe66bc01fa0293db53b2e1fc6cb8` |
| `backend/database/cli.py` | +74 −6（`run`/`rollback` 接线、`status` 增 `migrate_state`） | 6,570 B | 157 | `b07d9a906d20ca2106426512cdc45f7b1e4c06b7` |
| `backend/config.py` | +9（`MIGRATION_ENABLED`、`MIGRATION_FAULT_LOG`） | 7,078 B | 160 | `e6dc1aa9dcd5d79c382cbb7f8d00c978ba6317b5` |

合计：4 files changed, 1,502 insertions(+), 10 deletions(-)。

**超出"原则上只改 migrate.py / tests"的部分及理由**：

* `cli.py`：计划 §3.1 明确 CLI 是 A 类入口 3，`run`/`rollback` 在 P-1.6 必须从 `not_implemented` 变成可用接线（任务书要求"实现异常处理及安全拒绝路径"，拒绝路径必须能从 CLI 走到）。
* `config.py`：`MIGRATION_ENABLED`、`MIGRATION_FAULT_LOG` 是计划 §3.4 配置项，状态机与 fault log 路径必须由配置提供；默认关闭，不改变现有启动行为。
* **未改**：`db.py`（提交原子性实现原样保留）、`migrate.py` 既有基线逻辑、`pool.py`/`gate.py`/`maint.py`/`backup.py`、两份 v1.10 文档、`SCHEMA` 与业务表、services/testers/scoring/前端、Compose/镜像/部署配置。

---

## 2. 状态机实现说明

### 2.1 状态与转换（与设计 §5 一一对应）

```text
Phase = PREPARED → TX_OPEN → COMMIT_ATTEMPTED → COMMITTED
                        ↘ TX_ROLLED_BACK        ↘ UNKNOWN → COMMITTED
                                                        ↘ TX_ROLLED_BACK
```

`LEGAL_TRANSITIONS` 恰好 8 条（T1–T8），与设计 §1.2/§5 逐行对齐：

| 转换 | 边 | 分派后端 |
| --- | --- | --- |
| T1 | PREPARED → TX_OPEN | tx_local |
| T2 | TX_OPEN → COMMIT_ATTEMPTED | tx_local |
| T3 | TX_OPEN → TX_ROLLED_BACK | durable |
| T4 | COMMIT_ATTEMPTED → COMMITTED | durable |
| T5 | COMMIT_ATTEMPTED → TX_ROLLED_BACK | durable |
| T6 | COMMIT_ATTEMPTED → UNKNOWN | durable |
| T7 | UNKNOWN → COMMITTED | durable |
| T8 | UNKNOWN → TX_ROLLED_BACK | durable |

**拒绝语义**（全部为显式异常，不返回裸 bool）：

* 不在表内 → `IllegalTransition`（含 `COMMITTED → *` 全面禁回退、`TX_ROLLED_BACK → COMMITTED`、`PREPARED → COMMITTED`）；
* `UNKNOWN → UNKNOWN` → `IllegalTransition`，并提示"记录原因请用 `append_reason`"（设计 §1.1 禁止用状态变化表达原因）；
* `old` 与 `rec.phase` 不一致 → `PhaseMismatch`（同一转换被写两次的典型症状）；
* `rec.halted` 后任何 `set_phase_memory` / `append_reason` → `MigrationHalted`（零数据库写入）。

### 2.2 入口与返回类型

* `set_phase_memory()`：P-1 的 phase 推进入口（只改内存），返回 `PhaseResult.SUCCESS`。
* `set_phase()` / `write_event()` / `write_tx_event()` / `emit_event()`：PT-09b 要求的事件后端，**一律 `NotImplementedError`**。刻意不做"直接改内存后假装已持久化"的降级实现。
* `append_reason()`：phase 不变地追加上下文，P-1 只写非 DB 通道 `<STATE_DIR>/migration-fault.log`，返回 `WriteOutcome.LOCAL`。
* `WriteOutcome`（`COMMITTED/ABSENT/UNRESOLVED/LOCAL`）与 `PhaseResult`（`SUCCESS/REJECTED/HALTED`）两个枚举均已落地，任何上层不得用布尔替代（PT-13）。
* `check_transition_table()`：模块**导入即自检**（显式 `if` + `DispatchTableBroken`，不用 `assert`，普通模式与 `-O` 一致拒启动）：分派表键集合必须恰好等于 `LEGAL_TRANSITIONS`，T1/T2 必须 `tx_local`，T3–T8 必须 `durable`，名称表必须一一对应。

### 2.3 空迁移 dry-run（`run()`）

安全边界（任一不满足即拒绝，不动任何数据）：

1. `NODEPOOL_MIGRATION_ENABLED=1`，否则 `MigrationDisabled`（默认 0，入口不可达）；
2. `dry_run=True` 且目标库**不是** `config.DB_PATH`，否则 `dry_run_requires_copy`（P-1.6 不碰主库）；
3. `dry_run=False` → `p17_required`（真实迁移属 P-1.7/P-1.8）；
4. 维护态必须 `ACTIVE`（`gate.judge()`，A 类唯一判定入口），否则 `maintenance_required`；
5. 单实例锁 `<STATE_DIR>/migration.lock`（`flock` 非阻塞）→ 并发第二会话 `AlreadyRunning`；
6. `gate.apply_state(ACTIVE)` 封锁写入 → `gate.drain()` 排空判据（2 轮 + 间隔 ≥10s，不被削弱）→ 失败即 `halt_migration("drain_failed")`；
7. `preflight == ready`，否则 `migration_not_ready`（`incomplete` 时不得"续跑"）。

**事务与状态顺序**（状态推进与持久痕迹的一致性口径）：

```text
BEGIN IMMEDIATE
  PREPARED → TX_OPEN              (T1)
  INSERT running 行 (seq=2, version=1.10)
  TX_OPEN → COMMIT_ATTEMPTED      (T2)
  （空迁移：零 DDL）
COMMIT ──抛异常──> halt_migration("commit_outcome_unknown")
                  · phase 停 COMMIT_ATTEMPTED（不冒充 UNKNOWN：无事件证据）
                  · 零 success/failed 行
                  · 写入闸保持封锁 + fault log
COMMIT 正常
  BEGIN IMMEDIATE; UPDATE running → success; COMMIT
      └─ 失败 ⇒ halt_migration("phase_commit_failed")，phase 停 COMMIT_ATTEMPTED
  COMMIT_ATTEMPTED → COMMITTED    (T4)
```

事务内任何异常：`ROLLBACK` → `TX_OPEN → TX_ROLLED_BACK`（T3）→ **独立短事务**写 `failed` 行 → `pool.ensure_blocked()` 重封锁 → `migration_incomplete` ⇒ 下次启动 RECOVERY_REQUIRED。

### 2.4 halt 路径（严格使用 P-1.5 可信发射器）

`halt_migration(reason)` 固定顺序、三个保护动作各自独立异常边界：

1. `pool.block_writes(REASON_MAINTENANCE)`（先封锁）；
2. `maint.maintenance_state()`（A 类唯一判定入口）→ `maintenance_ok`；
3. `pool.confirm_writes_blocked()`（闸置位 + 写连接全关 + 无在途可提交 + 只读 `query_only`）；
4. **惰性**注册 `halt_migration` 为可信发射器（`pool.register_confirmation_issuer`，对象身份校验），`pool.mint_confirmation(token, mid, True, True)`；
5. `pool.halt_tail(conf)` 复核通过后才置 `rec.halted`。

任一确认不成立 → `FatalExit("halt_unconfirmed")`（非零退出、零数据库写入），**不发凭据、不注册令牌、不"尽力而为"继续**。

`halt_tail(confirmation)` 落在 `migrate.py`（计划 §3.1 归属），只做复核并返回 `halt_tail` 常量，不读维护文件、不查库、不推进 phase；实际复核逻辑复用 P-1.5 的 `pool.halt_tail()`。

**P-1.5 语义未被改变**：注册是**惰性**的（模块 import 不注册），P-1.5 的 63 项专项测试全绿（含"无发射器 ⇒ `no_trusted_issuer` 失败关闭"）。

### 2.5 回滚入口（`rollback_to_snapshot()`）

前置：开关开启 → 维护态 `ACTIVE` → 封锁 → 排空 → `backup.restore_set()`（内部自带 verify → `pre-restore` → 关闭连接 → 无第三方句柄 → 同卷临时文件 + fsync → 完整校验 → 原库三件改名隔离 → 原子替换 → 恢复后校验）。

**已知接口边界（P-1.6 不解决）**：`restore_set()` 的恢复后校验调用 `db.init_db()`，需要写连接；而 P-1.5 的维护期写入闸已关闭业务写连接，因此"进程内 + 已封锁"的成功恢复在 P-1.6 走不通 → 返回 `restore_failed` 并 `halt_migration`。真实恢复必须在停机窗口由独立进程执行（计划 §6 的恢复步骤 = P-1.7 演练内容）。本轮不为了"跑通"绕开写封锁，测试验证的是**失败安全**（原库行数不变、封锁保持、fault log 记录）。

---

## 3. 测试证据

### 3.1 新增专项 `tests/test_migration_state.py`：**29 passed**（52.97s）

| # | 用例 | 覆盖 |
| --- | --- | --- |
| 1 | `test_pt09b_no_event_tables_and_event_api_not_implemented` | 无 `system_events`/`migration_tx_notes`；无 `prev_sha/token_fp/s5_failed_ever` 列；四个事件接口 `NotImplementedError` |
| 2 | `test_pt09b_schema_migrations_status_only_three_values` | `status` CHECK 只接受 `running/failed/success`（`pending/committed/unknown/''` 均 IntegrityError） |
| 3 | `test_pt09b_migration_entry_closed_when_disabled` | 开关关闭 ⇒ `run`/`rollback` 均 `MigrationDisabled`，行数不变 |
| 4–5 | `test_pt12_dispatch_table_is_exactly_legal_transitions` / `test_pt12_broken_dispatch_table_is_refused` | 分派表 = 合法转换集合；多一条/少一条/后端写反/名称表缺失均 `DispatchTableBroken` |
| 6 | `test_pt13_reason_and_phase_return_typed_results` | `append_reason → WriteOutcome.LOCAL` 且不改 phase；`set_phase_memory → PhaseResult.SUCCESS`（非 `True`） |
| 7–11 | 状态机 5 项 | 8 条合法转换全部接受；9 条非法组合全部拒绝且 phase 不变；重复写同一转换 → `PhaseMismatch`；`halted` 后拒推进/拒记原因 |
| 12 | `test_run_dry_run_commits_empty_migration` | running→success、`version=1.10`、`seq=2`、`structure_hash` 不变（零 DDL）、无 halt 记录 |
| 13 | `test_run_refuses_live_db_and_non_dry_run` | `dry_run_requires_copy` / `p17_required`，两库行数不变 |
| 14 | `test_run_requires_active_maintenance` | 无维护文件 ⇒ `maintenance_required`，零写入 |
| 15 | `test_run_drain_failure_halts_and_keeps_block` | 排空失败 ⇒ `drain_failed` + `halt_tail` 成功 + 封锁保持 + 零写入 + fault log |
| 16 | `test_run_transaction_failure_writes_failed_row_and_blocks` | 事务内异常 ⇒ `migration_failed`、phase `TX_ROLLED_BACK`、独立事务写 `failed` 行、封锁保持、`preflight=incomplete` |
| 17 | `test_run_commit_exception_halts_without_advancing_phase` | COMMIT 抛 `disk I/O error` ⇒ `commit_outcome_unknown`、phase 停 `COMMIT_ATTEMPTED`、零 success/failed 行、`halt_tail` 成功 |
| 18 | `test_second_run_after_commit_is_refused` | 重复执行 ⇒ `migration_not_ready`，行数仍为 2（不重复记账） |
| 19 | `test_concurrent_run_is_refused_by_single_instance_lock` | 另一会话持锁 ⇒ `AlreadyRunning`，零写入 |
| 20 | `test_crash_between_begin_and_commit_leaves_no_running_row` | 子进程 `os._exit(7)` 于 `BEGIN IMMEDIATE` 后 ⇒ 无 running 行残留；重启不推进 phase；可再次成功 dry-run |
| 21–23 | PT-19 / PT-25 三项 | 无维护文件 + 主库有 running 行 ⇒ `RECOVERY_REQUIRED` 且不补写；有维护文件 ⇒ `ACTIVE` 但仍 `incomplete`、`run` 拒绝；`preflight action=recovery_required`、`allowed=False` |
| 24 | `test_halt_uses_trusted_issuer_and_registry_holds_function_object` | 进入 halt 前注册表为空（惰性）；halt 后登记项 `function is migrate.halt_migration`、`token is` 本模块令牌 |
| 25 | `test_halt_without_maintenance_is_fatal_and_keeps_writes_blocked` | 维护态缺失 ⇒ `FatalExit`，封锁保持，**连令牌都不注册** |
| 26 | `test_replaced_halt_migration_object_cannot_mint` | 同名函数对象被真实替换 ⇒ `issuer_replaced`（P-1.5 绑定回归） |
| 27 | `test_unregistered_token_cannot_mint` | 未注册令牌 ⇒ `untrusted_issuer` |
| 28–29 | `test_rollback_requires_active_maintenance` / `test_rollback_missing_set_refused` / `test_rollback_failure_is_safe_and_halts` | 回滚拒绝路径 + 失败安全（原库行数不变、封锁保持、fault log `restore_failed`） |

实际输出：

```text
$ python3 -m pytest -q tests/test_migration_state.py
29 passed in 52.97s
```

### 3.2 并发 / 重复 / 事务失败 / 进程中断边界（逐项对应）

| 边界 | 用例 | 结果 |
| --- | --- | --- |
| 并发两会话 | `#19` flock 单实例 | 第二会话 `AlreadyRunning`，零写入 |
| 重复执行（重复事件） | `#18` | `migration_not_ready`，不重复写行 |
| 事务内失败 | `#16` | `failed` 行 + `TX_ROLLED_BACK` + 封锁 |
| COMMIT 结果不可知 | `#17` | `commit_outcome_unknown` + 停 `COMMIT_ATTEMPTED` + 无伪造证据 |
| 进程中断（kill -9 等价） | `#20` | 未提交 running 行消失、重启不自动推进 |
| 排空失败 | `#15` | `drain_failed` + halt_tail + 保持封锁 |
| 维护态未成立时 halt | `#25` | `FatalExit`，不签发凭据 |

### 3.3 既有专项与全量（实际输出）

```text
$ python3 -m pytest -q tests/test_maintenance_lock.py
63 passed, 1 warning in 2.75s

$ python3 -m pytest -q tests/test_maint_state.py tests/test_backup_set.py
102 passed, 1 warning in 101.44s

$ python3 -m pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py
367 passed, 1 skipped, 1 warning in 23.97s

$ python3 -m pytest -q tests/test_migration_baseline.py
15 passed in 13.13s
```

合计：29 + 63 + 102 + 367(+1 skipped) + 15 = **576 passed, 1 skipped**。全量仍按既定分批执行（`test_migration_baseline.py` 的 PT-06 系列要求"仓库开发库 = alter_history 形态"，单进程混跑必失败 4 项，与改动前 HEAD 一致）。

---

## 4. 对照 v1.10 逐项完成情况

| 要求（来源） | 状态 | 说明 |
| --- | --- | --- |
| phase 集合与 T1–T8 转换表（设计 §1.2 / §5） | 完成 | `Phase` + `LEGAL_TRANSITIONS`（8 条）+ `TRANSITION_NAMES` |
| `IllegalTransition`、`COMMITTED` 不可回退、`UNKNOWN→UNKNOWN` 禁止（设计 §5） | 完成 | 9 条非法组合全部拒绝且 phase 不变 |
| `set_phase` 三态返回（设计 §2.2） | 部分 | `PhaseResult` 三态已定义、`set_phase_memory` 返回 `SUCCESS`；durable `set_phase` 按 PT-09b `NotImplementedError` |
| 分派表启动自检、`DispatchTableBroken`（设计 §0.10 / PT-12） | 完成 | 导入即自检，显式 `if`，`-O` 下同样拒启动 |
| 事件返回 `WriteOutcome` 而非裸 bool（PT-13） | 完成 | `WriteOutcome{LOCAL,COMMITTED,ABSENT,UNRESOLVED}` |
| durable 事件链（`system_events`/`migration_tx_notes`、`seq/prev_sha`、`token_fp`、`s5_failed_ever`）（设计 §2.1） | **未完成（阻塞）** | 计划 §3.2 与 PT-09b 明令 P-1 不建、`write_event` 抛 `NotImplementedError`；见 §0 冲突 |
| A/B/C 提交结果确认、E1–E3、β/β′ 恢复入口（设计 §1.3–§1.4、§2.2–§2.4） | **未完成（阻塞）** | 同上；P-1.6 的 COMMIT 异常路径按"无证据 ⇒ 停 `COMMIT_ATTEMPTED` + halt"处理 |
| K1/S5 判定与 `s5_failed_ever` 单调（设计 §3） | **未完成（阻塞）** | 依赖持久事件流；P-1 无事件表 |
| halt 走可信发射器、未确认即非零退出（设计 §0.10；P-1.5 接口） | 完成 | `halt_migration` + `halt_tail`，惰性注册、对象身份绑定、`FatalExit` |
| halt 后零 DB 写入、maintenance 保持（设计 §5 注） | 完成 | `rec.halted` 拒绝后续 `set_phase_memory`/`append_reason`；fault log 为唯一通道 |
| 空迁移 dry-run + 开关关闭不可达（计划 §8 / PT-09b / PT-11） | 完成 | `run()` 只允许副本、`MIGRATION_ENABLED` 默认 0 |
| 迁移窗口内重启不推进 phase、不补写（PT-19） | 完成 | 无自动续跑路径；`incomplete` 时 `run` 拒绝 |
| `migration_incomplete` / RECOVERY_REQUIRED（PT-25） | 完成 | `failed`/`running` 行 ⇒ `incomplete`，`preflight action=recovery_required` |
| 排空与备份前置、失败即 halt（计划 §2.7 / F1–F3） | 完成 | `gate.drain` + `assert` 等价判定；`snapshot` 可选（失败即 halt） |
| 回滚入口（计划 §2.7 回滚路径） | **部分** | 前置检查、失败关闭完成；进程内成功恢复受写封锁阻塞（§2.5），留 P-1.7 停机窗口 |
| CLI `run`/`rollback`（计划 §3.1） | 完成 | `python -m backend.database.cli run --db <副本>` / `rollback --set <集>`，退出码 0/2/4 |
| 不建事件表、不改 SCHEMA、不改业务表（计划 §3.2） | 完成 | 仅 `schema_migrations` 既有 9 列 |
| 未进入 P-1.7 / P-1.8、未接触生产 | 完成 | 本轮全部在临时目录与一次性库上执行 |

---

## 5. P-1.6 对 P-1.5 接口的使用与兼容性（供 P-1.7 复用）

1. **发射器注册**：`migrate._ensure_issuer_token()` 惰性调用 `pool.register_confirmation_issuer(migrate.halt_migration)`；模块级 `_ISSUER_FN` 强引用原函数对象，模块 import 不注册（P-1.5"无发射器 ⇒ 失败关闭"语义不变）。
2. **凭据签发**：只经 `pool.mint_confirmation(token, migration_id, maintenance_ok, writes_blocked)`；令牌、登记项、发射器函数对象三者任一被替换 → `untrusted_issuer` / `issuer_replaced` / `issuer_identity_conflict` 均按失败关闭处理。
3. **停机复核**：`migrate.halt_tail(conf)` 仅转调 `pool.halt_tail(conf)`，不复刻校验逻辑，避免两处口径漂移。
4. **封锁/排空**：只用 `pool.block_writes/ensure_blocked/confirm_writes_blocked` 与 `gate.judge/apply_state/drain`，不新增闸门、不直接关 SQLite 连接替代封锁。
5. **P-1.7 可直接复用**：把 `run(dry_run=False)` 打开时，只需替换"空迁移"为真实 DDL，并把 `COMMIT_ATTEMPTED → COMMITTED` 的前提从 status 行升级为 durable 事件（待 §0 裁决）。

---

## 6. 未完成项与请裁决事项

1. **（阻塞）持久化事件链**：`system_events` / `migration_tx_notes`、`seq/prev_sha` 哈希链、`token_fp`、`s5_failed_ever` 单调、A/B/C 提交结果确认、E1–E3、β/β′ —— 需负责人解除计划 §3.2 / PT-09b 后另行施工。
2. `run()` 的 `snapshot=True` 备份前置已在代码里接线但本轮未作为验收项演练（属 P-1.7 PT-07/PT-08）。
3. 进程内成功恢复不可达（§2.5）：需 P-1.7 定义"停机窗口 + 独立进程"的恢复流程；本轮只交付受控入口与失败关闭。
4. 跨进程真实排空（独立进程持库）与多实例闸门仍为单进程内存态（P-1.5 已列入未决项，未扩大处理）。
5. 计划 §3.1 的 CLI 形态仍为 `python -m backend.database.cli`（与计划的 `-m backend.database.migrate` 存在既有偏差，P-1.5 已列，本轮未变）。

---

## 7. 声明

* 未修改两份 v1.10 批准文档；未修改 `db.py` 的提交原子性实现；未修改 `pool.py`/`gate.py`/`maint.py`/`backup.py`/`main.py`/`routes.py`/`manager.py`；未改 `migrate.py` 既有基线逻辑；未改 SCHEMA 与业务表；未改 services/testers/scoring/前端；未改 Compose/镜像/部署配置。
* 未接触 NAS 生产环境、生产数据库、生产容器、生产服务；未执行 P-7；未做生产迁移或部署。
* **未进入 P-1.7 / P-1.8**，不自评 P-1.6 通过；完成后即停止，等待负责人复审与对 §0 冲突的裁决。
