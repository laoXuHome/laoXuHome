# NodePoolME P-1.5 局部修复材料（v1.10）

> 修复轮次：P-1.5 初审问题 1–5
> 基线：`2cfcaad1246bb47178d15f8afda37cc85e1fb83e`（P-1.5 首版）
> 修复提交：`1499129e0a9cd80a43af9055d620bd4145269a20`（已 push `main`）
> 修改范围：仅 `backend/database/pool.py`、`backend/database/gate.py`、`backend/database/db.py`、`tests/test_maintenance_lock.py`
> 未接触生产数据库 / NAS 生产容器 / P-7 / Compose 镜像部署；未改 `migrate.py`、`db.py` 的 `SCHEMA`、业务表结构、services/testers/scoring/前端

---

## 1. 修改文件（blob SHA）

| 文件 | 字节数 | 行数 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/pool.py` | 8,084 | 216 | `c45a2fe30a72e62d16a5f8ca7cb39f2226a87d9e` |
| `backend/database/gate.py` | 11,617 | 292 | `ba7fb8bff939cc70e487629d20e12542f0f1c316` |
| `backend/database/db.py` | 29,077 | 757 | `8d2c00268d5141fbddb05a4e38b7de04f57e7790` |
| `tests/test_maintenance_lock.py` | 22,311 | 582 | `13b1e9a107bb74374860dd7f51722bc42a2e6380` |

差异：4 文件、+483 / −72 行。commit `1499129e0a9cd80a43af9055d620bd4145269a20`，`git ls-remote origin refs/heads/main` 回读一致。

---

## 2. 问题 1：连接池并发封锁竞态

**根因**：`db.connect()` 里先独立判断 `pool.pool_dead()`，再创建并登记连接，检查与登记不是一个原子操作；`block_writes()` 只置位并关闭"当时已登记"的连接，于是存在"检查通过 → 封锁并关闭 → 该线程又登记新写连接"的窗口。

**修法**：引入 `pool.write_slot()`（基于可重入 `_blocking_lock` 的上下文管理器），把"复核闸门 + 创建连接 + PRAGMA 校验 + 登记到 `_WRITE_CONNS`"整段放进同一临界区；`block_writes()` 在同一把锁内置位闸门并关闭全部写连接。由此：

- 在途 checkout 未出临界区前，`block_writes()` 无法抢先完成（必须先等它登记完，再由封锁统一关闭）；
- `block_writes()` 返回之后，任何并发 checkout 在 `write_slot()` 内立刻被 `PoolClosed` 拒绝，不可能再创建/登记；
- 连接代际 `_GENERATION` 继续兜住"其它线程残留的 thread-local 旧句柄"，解除封锁后自动重开。

**只读不受影响**：`read_connection()` 保留"先试写连接、失败即退只读连接"的双分支，即使恰好在封锁瞬间也不会让只读请求失败。

**另外发现并修复的真实缺陷（同一修复项范围内）**：`connect_readonly()` 原先用 `str(path) + "?mode=ro"` 拼 URI，没有 `file:` 前缀，实际打开的是名称里带 `?mode=ro` 的另一个文件；即使修正 URI，纯只读句柄在 WAL 新库上也只能看到空 schema（schema 还在 `-wal` 里）。现改为 `Path(DB_PATH).as_uri() + "?mode=rw"` + 立即 `PRAGMA query_only=1`：不建库、由 SQLite 拒绝一切写语句，且能正常读 WAL。**封锁态只读查询因此真正可用**（原实现是"看起来可用"，`SELECT 1` 不暴露问题）。

### 并发时序测试（必须真实覆盖窗口）

1. `test_block_cannot_overtake_inflight_checkout`：把 `sqlite3.connect` 换成"进入即置 `inside` 事件、等待 `go`"的桩；A 线程停在创建阶段时，主线程起 `blocker` 线程调 `block_writes()`，断言 `blocked.wait(0.3) is False`（封锁被临界区挡住，不能抢跑），随后放行 `go`；两线程结束后断言封锁已完成、A 拿到连接、`open_write_connections()==0`（刚登记的连接被封锁关闭）、再次 `db.connect()` 抛 `PoolClosed`。
2. `test_no_write_connection_survives_block_under_race`：8 个线程用 `threading.Barrier` 与主线程同时放行，各自 `db.connect()` + 真实 `INSERT`；主线程同时 `block_writes()` 并记录时间点。断言：封锁返回后没有任何"成功写入"，`open_write_connections()==0`，闸门仍封锁，`db.connect()` 抛 `PoolClosed`。

---

## 3. 问题 2：写入入口封锁覆盖

**结论**：所有正式业务写入都经过唯一入口 `db.connect()`（`write_slot` 复核闸门），并由 `execute()` / `set_setting()` / `record_run_event()` / `append_log()` / `transaction()` 复用；`transaction()` 额外走 `gate.write_guard()`（维护态判定 + `foreign_keys`/`recursive_triggers` 校验）。新建写连接在临界区内做 PRAGMA 校验，不通过即 `WriteRefused("pragmas_not_enabled")` 并关闭该连接，绝不静默写库。

覆盖矩阵：

| 写入入口 | 封锁手段 | 封锁后行为 |
| --- | --- | --- |
| `execute()` | `connect()` → `write_slot` | `PoolClosed` |
| `set_setting()` | 同上 | `PoolClosed` |
| `record_run_event()` | 同上（经 `execute`） | `PoolClosed` |
| `append_log()` | 同上，异常被自身吞掉 | 不抛出、不落库（日志失败不影响只读服务、也不构成放行） |
| `transaction()` | `gate.write_guard()` → `connect()` | `WriteRefused("maintenance"/"recovery_required"/"pragmas_not_enabled")` |
| `init_db()` / 迁移器 | 启动层在维护态直接跳过 | 不执行 |

只读：`rows/row/get/get_int` 走 `read_connection()`，封锁态用 `PRAGMA query_only=1` 连接，正常返回。

新增测试：`test_every_write_helper_refused_after_block`（逐入口拒绝 + `logs` 行数与 `settings` 值不变 + 只读仍可查）、`test_recovery_reason_is_preserved_after_block`（`PoolClosed.reason` 与 `WriteRefused.reason` 均为 `recovery_required`）。

---

## 4. 问题 3：PT-16 排空参数不可削弱

`gate.effective_drain_params()` 把 `rounds` 抬到 ≥2、`min_interval` 抬到 ≥10（含 `int` 转换失败、`NaN/Inf` 的兜底），`drain()` 一律用抬高后的值执行，并在结果里保留 `requested_rounds` / `requested_interval` / `coerced`，任何成功结果都满足"≥2 次完整检测、相邻间隔 ≥10s"。

| 入参 | 实际执行 | `coerced` | 结果 |
| --- | --- | --- | --- |
| `rounds=1, min_interval=10` | 2 轮 / 10s | True | ok，`len(rounds)==2`，`gap≥10` |
| `rounds=0, min_interval=10` | 2 轮 / 10s | True | ok |
| `rounds=2, min_interval=0` | 2 轮 / 10s | True | ok |
| `rounds=2, min_interval=9.9` | 2 轮 / 10s | True | ok |
| `rounds=1, min_interval=0` | 2 轮 / 10s | True | ok |
| `rounds=3, min_interval=10` | 3 轮 / 10s | False | ok，三个 gap 均 ≥10 |

---

## 5. 问题 4：排空失败保持封锁 + P-1.6 接线契约

- 任一轮判据失败：`pool.ensure_blocked("maintenance")`（只封锁、不解除），结果 `code="drain_failed"`、`halt_code="drain_failed"`、`halt_pending=True`、`continue_allowed=False`。
- 新增 `gate.assert_drain_ok(result)`：失败即抛 `DrainFailed(result)`（携带 `halt_request()`），调用方无法把失败当"可重试成功"继续。
- **P-1.6 接线契约**（供 `migrate.run()/rollback_to_snapshot()` 使用）：
  1. 在快照/迁移前置阶段调用 `gate.drain(...)`；
  2. 立刻 `gate.assert_drain_ok(result)`，或在 `except gate.DrainFailed as exc` 中调用 `migrate.halt_migration(exc.code)`（`exc.code == "drain_failed"`），随后 `pool.halt_tail(...)` 只接受 `halt_migration` 回读确认后生成的 `MaintConfirmation`；
  3. 失败路径不得推进 `phase`、不得解除写入闸、不得重试迁移；只有"迁移 success + 人工确认 + 删维护文件 + 重启"才解除。
- 本阶段不建事件链、不写 phase、不实现状态机。

新增测试：`test_drain_failure_keeps_gate_blocked_and_blocks_continue`、`test_drain_failure_blocks_even_if_gate_was_open`（原本闸门未封锁，失败后也必须落到封锁态）、`test_assert_drain_ok_passes_on_success`。

---

## 6. 问题 5：`halt_tail()` 回读确认边界

新增不可变凭据 `pool.MaintConfirmation(migration_id, maintenance_ok, writes_blocked, confirmed_at, source="halt_migration")`，唯一工厂 `pool.new_confirmation(...)` 供 P-1.6 的 `halt_migration` 在回读确认后构造。`halt_tail(rec)` 现在要求：

1. `isinstance(rec, MaintConfirmation)`——普通对象、dict、鸭子类型一律拒绝；
2. `source == "halt_migration"`（未经回读确认的凭据拒绝）；
3. `migration_id` 非空字符串；
4. `maintenance_ok is True` 且 `writes_blocked is True`（`1`/`"true"` 等非布尔真值拒绝）；
5. `confirmed_at` 为数值。

不读维护文件、不查库、不推进状态。测试：`test_halt_tail_rejects_unconfirmed_objects`（7 种非法输入）、`test_halt_tail_accepts_only_confirmation_from_halt_migration`；原 `test_halt_tail_requires_confirmed_flags` 按新契约改用 `new_confirmation` 构造（覆盖范围未缩小）。

---

## 7. 专项测试输出（41 项）

```
tests/test_maintenance_lock.py::test_http_write_refused_when_active                    PASSED
tests/test_maintenance_lock.py::test_http_write_refused_when_recovery_required        PASSED
tests/test_maintenance_lock.py::test_http_read_only_not_intercepted_when_active       PASSED
tests/test_maintenance_lock.py::test_http_write_passes_when_inactive                  PASSED
tests/test_maintenance_lock.py::test_scheduler_round_stops_without_reading_twice      PASSED
tests/test_maintenance_lock.py::test_cli_write_refused_and_allow_write_cannot_bypass   PASSED
tests/test_maintenance_lock.py::test_cli_read_command_allowed_when_active             PASSED
tests/test_maintenance_lock.py::test_write_guard_reasons                              PASSED
tests/test_maintenance_lock.py::test_write_guard_requires_pragmas                     PASSED
tests/test_maintenance_lock.py::test_db_connection_pragmas_are_on                     PASSED
tests/test_maintenance_lock.py::test_startup_blocks_before_init_on_active             PASSED
tests/test_maintenance_lock.py::test_startup_enters_recovery_on_corrupt               PASSED
tests/test_maintenance_lock.py::test_startup_proceeds_on_inactive                     PASSED
tests/test_maintenance_lock.py::test_pool_dead_after_block_and_readonly_still_serves  PASSED
tests/test_maintenance_lock.py::test_halt_tail_requires_confirmed_flags               PASSED
tests/test_maintenance_lock.py::test_write_connection_recovers_after_unblock          PASSED
tests/test_maintenance_lock.py::test_second_session_cannot_write_after_block          PASSED
tests/test_maintenance_lock.py::test_pool_module_does_not_read_maintenance_file       PASSED
tests/test_maintenance_lock.py::test_confirm_writes_blocked_conditions                PASSED
tests/test_maintenance_lock.py::test_drain_ok_requires_two_rounds_with_interval       PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint0]       PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint1]       PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint2]       PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_external_holder                   PASSED
tests/test_maintenance_lock.py::test_drain_fails_without_write_block_and_skips_checkpoint PASSED
tests/test_maintenance_lock.py::test_wal_checkpoint_truncate_real                     PASSED
tests/test_maintenance_lock.py::test_block_cannot_overtake_inflight_checkout          PASSED
tests/test_maintenance_lock.py::test_no_write_connection_survives_block_under_race    PASSED
tests/test_maintenance_lock.py::test_every_write_helper_refused_after_block           PASSED
tests/test_maintenance_lock.py::test_recovery_reason_is_preserved_after_block         PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[1-10.0]     PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[0-10.0]     PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[2-0.0]      PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[2-9.9]      PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[1-0.0]      PASSED
tests/test_maintenance_lock.py::test_drain_legal_parameters_not_coerced               PASSED
tests/test_maintenance_lock.py::test_drain_failure_keeps_gate_blocked_and_blocks_continue PASSED
tests/test_maintenance_lock.py::test_drain_failure_blocks_even_if_gate_was_open       PASSED
tests/test_maintenance_lock.py::test_assert_drain_ok_passes_on_success                PASSED
tests/test_maintenance_lock.py::test_halt_tail_rejects_unconfirmed_objects            PASSED
tests/test_maintenance_lock.py::test_halt_tail_accepts_only_confirmation_from_halt_migration PASSED
======================== 41 passed, 1 warning in 1.79s ========================
```

原 26 项全部保留并通过（其中 `test_halt_tail_requires_confirmed_flags` 按新凭据契约调整构造方式，断言强度未降低）。

## 8. 全量（既定分批）

```
python3 -m pytest -q --ignore=tests/test_migration_baseline.py
→ 345 passed, 1 skipped

python3 -m pytest -q tests/test_migration_baseline.py
→ 15 passed
```

合计 360 passed、1 skipped、0 failed（较首版 +15 项，均为本轮新增）。

---

## 9. 未实现 / 后续

- `halt_migration("drain_failed")` 本体、`phase` 推进、事件链：P-1.6。
- `/api/system/migration/status`、CLI 挂到 `backend.database.migrate`：P-1.6。
- 跨进程真实排空（独立进程持库）+ 多实例闸门：本阶段仍是单进程内存态，靠"进程内闸 + 关闭连接 + checkpoint + holders 扫描"保证，已在材料中如实标注。
- 未接触生产库/NAS/生产容器；未执行 P-7；未改 Compose/镜像/部署配置；未改批准文档；未进入 P-1.6。

完成后停止，等待负责人重新审查。
