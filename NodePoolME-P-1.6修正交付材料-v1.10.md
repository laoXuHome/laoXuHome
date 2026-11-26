# NodePoolME P-1.6 修正交付材料（Migration State Machine Review Fixes）

**阶段**：P-1.6 复审限定修正（五类问题）
**新提交**：`7cf710bbeef0923049f0ca8aa00c68106c9adec0`（`7cf710b`，已推送 `main`）
**上一提交（被复审）**：`9f558cf3641304d13e9be8bdd241da6ac5833fac`
**基线**：`3fb7c515f894569e231d687f228df7ad3d8dac5b`（P-1.5，已验收）
**依据**：《新架构总体设计方案 v1.10》《P-1 实施计划 v1.10》（本轮未修改）
**边界**：未接入 durable 事件链、未执行真实备份恢复、未进入 P-1.7/P-1.8、未接触 NAS/生产库/生产容器/生产服务、未执行 P-7。
**停止点**：完成后立即停止，等待 ChatGPT 独立复审；不自评验收通过。

---

## 1. 变更清单

**commit**：`7cf710bbeef0923049f0ca8aa00c68106c9adec0`
本轮 diff：2 files changed, 590 insertions(+), 129 deletions(-)

| 文件 | 本轮变更 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- | --- |
| `backend/database/migrate.py` | 改（409 行变动） | 66,737 B | 1,525 | `a4a176b1ea3289bdeb3827cb5a885766a358b6cf` |
| `tests/test_migration_state.py` | 改（+310/−，42 项） | 38,323 B | 926 | `b72fb645661cfaefb7ad07074413a1258ad80499` |
| `backend/database/cli.py` | **本轮未改**（上一提交已接线） | 6,570 B | 157 | `b07d9a906d20ca2106426512cdc45f7b1e4c06b7` |
| `backend/config.py` | **本轮未改** | 7,078 B | 160 | `e6dc1aa9dcd5d79c382cbb7f8d00c978ba6317b5` |

未改：两份 v1.10 文档、`db.py`（提交原子性实现）、`pool.py`/`gate.py`/`maint.py`/`backup.py`/`main.py`/`routes.py`/`manager.py`、`SCHEMA` 与业务表、services/testers/scoring/前端、Compose/镜像/部署配置。

---

## 2. 五类修正逐项说明

### 2.1 修正 1：补齐 `phase_epoch`（计划 §2.5.1）

* `MigrationRecord` 新增 `phase_epoch: int = 0`。
* `set_phase_memory()` 顺序严格为：`halted` 检查 → 旧值匹配（`PhaseMismatch`）→ `UNKNOWN→UNKNOWN` 拒绝 → `LEGAL_TRANSITIONS` 检查 → **赋值 phase → `phase_epoch += 1`**。
* 只有"转换合法 + 旧值匹配 + 未 halted + 赋值成功"这一条路径会递增，且每次成功转换只加一。
* 非法转换、旧值不匹配、重复写同一转换、halt 后调用：phase 与 `phase_epoch` 都保持不变（测试逐条断言）。

### 2.2 修正 2：事务失败分支的状态误判

用三个**本地事实**判定（计划 §2.5.1 的失败二分口径）：

```text
begin_ok     = BEGIN IMMEDIATE 是否真的返回成功
rollback_ok  = ROLLBACK 是否明确成功
recheck_ok   = 只读复核（独立连接 + PRAGMA query_only=1）结构摘要是否仍等于迁移前
```

| 组合 | 判定 | 动作 | 持久痕迹 |
| --- | --- | --- | --- |
| `begin_ok=False` | 没有事务 | phase 保持 `PREPARED`（`phase_epoch=0`）；不伪造 `TX_OPEN`、不写任何行、不调 `set_phase_memory` | 零行；`migration-fault.log` 记 `begin_failed` |
| `begin_ok ∧ rollback_ok ∧ recheck_ok` | `KNOWN_FAILED` | 从**当前实际 phase**（`TX_OPEN` 或 `COMMIT_ATTEMPTED`）推进 `TX_ROLLED_BACK`（T3/T5），独立短事务写 `failed` 行 | `status='failed'` + `known_failed:true` ⇒ `migration_incomplete` ⇒ RECOVERY_REQUIRED |
| `rollback_ok=False` / `recheck_ok=False` / 复核不可用 | `OUTCOME_UNKNOWN` | **不伪造 `TX_ROLLED_BACK`**、**不写误导性 failed 行**；phase 停在最后已知状态；关闭迁移连接（并确认）后 `halt_migration("rollback_unverified")` | 零新行；fault log 记 `migration_transaction_failed`（含 begin/rollback/recheck 三事实） |
| `failed` 行写不进去 | 无法留下可信痕迹 | `halt_migration("failed_row_unwritable")` | 零新行 |

连接清理：所有分支都在 `finally` 里 `conn.close()`（并有独立 `_close_migration_connection` 复核），状态转换异常不会跳过清理；`_mark_failed` 使用**独立短事务**，不与已回滚事务共用连接。

只读复核实现：`_recheck_structure_unchanged()` 用新连接 + `PRAGMA query_only=1` 调 `structure_hash()`，异常一律视为"无法确认"，绝不默认成功。

### 2.3 修正 3：`halt_migration()` 三动作独立异常边界

```python
try: block_reason = pool.block_writes(...)        except Exception: block_error
try: state        = maint.maintenance_state()     except Exception: maint_error
try: writes_ok, detail = pool.confirm_writes_blocked()  except Exception: confirm_error
```

* 三个 `try` 各自独立：先封锁抛错**不会**跳过维护态与回读确认，反之亦然（测试用探针记录调用序列，断言 `["block","state","confirm"]` 全部执行）。
* 只有 `block_error is None ∧ maint_error is None ∧ confirm_error is None ∧ maintenance_ok is True ∧ writes_blocked is True` 时，才注册可信发射器 → `mint_confirmation` → `halt_tail`。
* 否则 `FatalExit("halt_unconfirmed")`：不注册令牌、不签发凭据、不置 `rec.halted`（测试断言 `pool._ISSUERS == {}`、`rec.halted is False`）。
* 故障日志写入包在 `_log()` 内：失败只进 `log_errors`，不中断封锁与确认；`halt_migration` 返回的 `diagnostics.log_errors` 与 `halt_requested` 记录里保留该错误。`run()` 内的日志调用统一走 `_safe_log()`（失败返回错误串，不抛出）。
* `rec.halted = True` 只在 `pool.halt_tail()` 复核成功之后执行。

### 2.4 修正 4：COMMIT 异常时迁移连接纳入关闭确认

`migrate.open_connection()` 是直接 SQLite 连接，不在 P-1.5 业务连接池里，`pool.confirm_writes_blocked()` 证明不了它已关闭。因此：

1. `COMMIT` 抛异常 → phase 保持 `COMMIT_ATTEMPTED`（`phase_epoch` 只含 T1+T2），**不写** success / failed 来猜结果，不重试、不重放事务。
2. 立即 `_close_migration_connection(conn)`：`close()` 后**再执行一条 `SELECT 1`**，必须抛 `ProgrammingError` 才算"已关闭"；非 `ProgrammingError` 或仍可执行 ⇒ 视为未确认。
3. 关闭确认成功 → `halt_migration("commit_outcome_unknown")`；关闭失败 → `FatalExit("migration_connection_open")`（非零退出），**不把连接池确认冒充为全部连接已关闭**。
4. `running → success` 落盘失败、A 之后内存落地失败两条 halt 路径同样先关闭并确认连接，再 halt。
5. 返回体新增 `connection_closed`；fault log 中 `migration_commit_outcome_unknown` 必先于 `halt_requested`（测试断言事件顺序）。

### 2.5 修正 5：P-1.6 禁止执行真实备份恢复

`rollback_to_snapshot()` 已重写为**只做安全前置检查 + 只读验证**：

1. 开关开启；维护态 `ACTIVE`；
2. 定位备份集（显式 `--set` 或最新集），`backup.verify_set()` **纯只读**校验；
3. 无论校验是否通过，最终都 `MigrationRefused("p17_required")` 拒绝执行恢复。

代码中**不存在** `backup.restore_set()` 调用，不替换/覆盖/隔离任何目标库文件；CLI `rollback` 因此固定返回 `p17_required`（exit 2），不会默认对 `config.DB_PATH` 恢复。测试用"调用即失败"的 `restore_set` 替身证明零调用，并用 db/-wal/-shm 三件字节摘要证明文件与数据未变。

---

## 3. 测试证据（实际输出）

### 3.1 P-1.6 专项：**42 passed**

```text
$ python3 -m pytest -q tests/test_migration_state.py
42 passed in 81.40s
```

本轮新增/加强的 13 项：

| 用例 | 覆盖 | 结果 |
| --- | --- | --- |
| `test_phase_epoch_equals_number_of_successful_transitions` | 六个 phase 的 epoch 深 = 成功转换数（0/1/2/3/3/2） | pass |
| `test_legal_transitions_are_exactly_eight_and_all_accepted` | 每条合法转换 epoch +1（只加一次） | pass |
| `test_illegal_transitions_rejected` | 9 条非法组合：phase 与 epoch 均不变 | pass |
| `test_phase_mismatch_when_same_transition_written_twice` | 重复转换：epoch 停留 1 | pass |
| `test_halted_record_rejects_phase_and_reason` | halt 后：phase 与 epoch 均不变 | pass |
| `test_begin_failure_keeps_prepared_and_writes_nothing` | **BEGIN 失败**：phase `PREPARED`、epoch 0、零行、封锁保持 | pass |
| `test_known_failed_requires_rollback_and_recheck_success` | **回滚 + 复核成功** ⇒ `known_failed`、epoch 2（T1+T3，插入失败发生在 T2 之前）、`failed` 行 | pass |
| `test_rollback_failure_is_outcome_unknown_and_halts` | **ROLLBACK 失败**：不伪造 `TX_ROLLED_BACK`、零 failed 行、halt `rollback_unverified` | pass |
| `test_recheck_failure_is_outcome_unknown_and_halts` | **只读复核不可用**：同样进 halt，phase 停最后已知状态 | pass |
| `test_structure_changed_is_outcome_unknown_not_known_failed` | **复核发现结构变化**：不得认定 KNOWN_FAILED | pass |
| `test_commit_exception_closes_connection_before_halt` | 关闭确认先于 halt；`connection_closed=True`；fault log 事件顺序 | pass |
| `test_commit_exception_close_failure_is_fatal` | **关闭失败**：`FatalExit("migration_connection_open")`、零 success/failed 行 | pass |
| `test_halt_block_writes_failure_still_confirms_other_actions` | 封锁抛错仍执行后两项确认 ⇒ `FatalExit`，无凭据 | pass |
| `test_halt_maintenance_state_failure_is_fatal_but_keeps_block` | 维护态抛错：封锁保持、无凭据、不置 halted | pass |
| `test_halt_confirm_failure_is_fatal_without_credential` | 回读确认抛错：无凭据、不置 halted | pass |
| `test_halt_log_failure_does_not_block_lockdown` | 日志写失败不阻断停机；错误保留在 `diagnostics.log_errors` | pass |
| `test_rollback_never_calls_restore_set` | 函数入口零调用 `restore_set`、三件字节不变、行数不变 | pass |
| `test_cli_rollback_refuses_and_leaves_db_untouched` | CLI `rollback` 返回 `EXIT_REFUSED`（p17_required），主库与副本均未被改写 | pass |

原有 PT-09b（4 项）、PT-12（2 项）、PT-13（1 项）、PT-19（2 项）、PT-25（1 项）、run 正常/拒绝路径、并发锁、进程中断、可信发射器绑定等 24 项继续通过。

### 3.2 P-1.5 专项回归

```text
$ python3 -m pytest -q tests/test_maintenance_lock.py
63 passed, 1 warning in 2.86s
```

### 3.3 全量（既定分批）

```text
$ python3 -m pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py
367 passed, 1 skipped, 1 warning in 26.65s

$ python3 -m pytest -q tests/test_migration_baseline.py
15 passed in 14.36s
```

合计：42 + 63 + 367(+1 skipped) + 15 = **487 passed, 1 skipped**（含 `test_maint_state.py` / `test_backup_set.py`）。

---

## 4. 与 v1.10 计划逐项对照

| 条款 | 要求 | 本轮落实 |
| --- | --- | --- |
| §2.5.1 | 单进程内存 phase 推进 = `rec.phase` + `phase_epoch` | `MigrationRecord.phase_epoch`；`set_phase_memory()` 成功才 +1，拒绝路径不变 |
| §2.5.1 | 阶段结果的持久痕迹只用 `schema_migrations.status` + `detail_json` | `running/failed/success` 三态；`detail_json` 记 `dry_run/statements/known_failed/recheck`；无事件表 |
| §2.5.1 | 失败二分 `KNOWN_FAILED` / `OUTCOME_UNKNOWN` 由"是否 BEGIN、COMMIT 是否发出、能否只读复查"判定 | 见 §2.2 四行判定表；实现 `_recheck_structure_unchanged()`（query_only 只读） |
| §2.5.1 | `write_event()` 必须 `NotImplementedError`；禁止冒充事件表 | 保持：`write_event`/`write_tx_event`/`emit_event`/`set_phase` 全部抛错，零事件表、零哈希链列 |
| §2.5.2-1 | `KNOWN_FAILED` ⇒ 写 `failed`、`migration_incomplete` ⇒ RECOVERY_REQUIRED、写入继续封锁、不提供自动改回 success | `_mark_failed()` + `ensure_blocked()`；CLI 无任何"改成 success"的能力 |
| §2.5.2-2 | `OUTCOME_UNKNOWN` ⇒ 不重试不重放，`halt_migration("commit_outcome_unknown")` | 已实现（含连接关闭确认）；`rollback_unverified` 同口径 |
| §2.5.2-3 | 回滚顺序：停写→排空→关连接→恢复→校验→人工确认→重启 | **P-1.6 不执行恢复**（见修正 5），仅在 `p17_required` 中说明该流程属 P-1.7 |
| §2.5.2-4 | 禁止重试、halt 中写库、DROP 表、VACUUM 替代恢复 | 无任何重试/重放；halt 只写文件日志；未触碰业务表 |
| PT-09b | 无事件表、`write_event()` NotImplementedError、status 三值 | 通过（4 项） |
| PT-12 | 分派表自检、异常而非 assert | 通过（2 项，含 -O 同口径的显式 `if`） |
| PT-13 | 返回 `WriteOutcome`/`PhaseResult`，无裸 bool | 通过（1 项） |
| PT-19 | 重启不推进 phase、不补写事件 | 通过（2 项 + 进程中断 1 项） |
| PT-25 | `migration_incomplete` ⇒ RECOVERY_REQUIRED、拒绝 run | 通过（1 项） |
| 修正 4 补充 | COMMIT 异常必须确认迁移连接已关闭才能 halt | `_close_migration_connection()` + 两条测试 |
| 修正 5 补充 | 不得调用 `restore_set`、CLI rollback 拒绝 | 两条测试 + 代码中零调用 |

---

## 5. 明确声明

1. **未接入 durable 事件链**：未创建 `system_events` / `migration_tx_notes`，未增加 `seq/prev_sha/token_fp/s5_failed_ever` 等任何哈希链字段；`migration-fault.log` 只作非 DB 故障诊断通道，**不称为完整事件记录**。
2. **未执行真实备份恢复**：代码无 `restore_set()` 调用，CLI `rollback` 固定 `p17_required`，目标库文件与数据在测试中经字节摘要验证未变。
3. **未进入 P-1.7 / P-1.8**：未实现真实迁移 DDL、未演练全链路、未开生产窗口。
4. **未接触生产环境**：未连接 NAS、生产数据库、生产容器、生产服务；未执行 P-7。
5. 未修改两份 v1.10 批准文档；未改 `db.py`；未改 SCHEMA 与业务表。
6. 本轮不做自评验收，等待 ChatGPT 独立复审；完成后停止，不自行进入下一阶段。
