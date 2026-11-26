# NodePoolME P-1.5 最终局部修复材料（v1.10）

> 修复轮次：P-1.5 终审问题 1–2（确认凭据真实性 / 在途写事务封锁）
> 基线：`1499129e0a9cd80a43af9055d620bd4145269a20`
> 修复提交：`85cc85a3d7e7fa4349c7a3f00a50025e714fc27d`（已 push `main`，`git ls-remote` 回读一致）
> 修改范围：`backend/database/pool.py`、`backend/database/db.py`、`tests/test_maintenance_lock.py`（`gate.py` 本轮未改）
> 未改：两份 v1.10 文档、`migrate.py`、`SCHEMA`/业务表、services/testers/scoring/前端、Compose/镜像/部署配置；未接触 NAS 生产环境；未执行 P-7；未进入 P-1.6

## 1. 修改文件（blob SHA）

| 文件 | 字节数 | 行数 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/pool.py` | 11,653 | 286 | `415a2e204a37c28e72a3e20a1c0712fec793b101` |
| `backend/database/db.py` | 31,014 | 809 | `45b3b1d22683148183d735ce973e4108fd18d5ee` |
| `tests/test_maintenance_lock.py` | 28,688 | 731 | `80c93f73d6d6619c649c9d8084a1580996e0d666` |

---

## 2. 问题 1：`halt_tail()` 确认凭据真实性

### 2.1 旧实现的缺陷

`MaintConfirmation` 是公开 dataclass，`new_confirmation()` 是公开无验证工厂——任何调用方都能构造 `source="halt_migration"`、两个字段为 `True` 的对象并通过 `halt_tail()`。这与 §2.7「只用 `halt_migration` 已回读确认的 `rec.maintenance_ok ∧ rec.writes_blocked`」不符。

### 2.2 新模型：私有哨兵 + 受控发射器注册 + 失败关闭

1. **私有哨兵**：模块级 `_ISSUER_TOKEN = object()`（不导出）。`MaintConfirmation` 增加两个不参与 `repr`/`==` 的字段 `_token`、`_issuer`；`is_confirmed()` 要求 `_token is _ISSUER_TOKEN`，即"只有本模块签发过的实例"才可能有效。直接实例化、复制字段、构造子类都拿不到哨兵。
2. **受控发射器注册**：`register_confirmation_issuer(issue)` 检查 `issue.__module__ == "backend.database.migrate"`（非该模块调用 → `HaltPreconditionFailed("untrusted_issuer_module")`），通过后返回该发射器专属的签发令牌，并在内部登记。
3. **签发必须持令牌**：`mint_confirmation(token, migration_id, maintenance_ok, writes_blocked)` 要求 ① 令牌已注册（否则 `untrusted_issuer`）、② 两个确认字段为严格 `True`（`1`/非布尔真值拒绝）、③ **签发时刻 `confirm_writes_blocked()` 必须为真**（闸门置位、写连接全关、无仍可提交的在途事务、只读连接 `query_only=1`）——即"writes_blocked=True"这句话必须当场被证实，不能只是自称。
4. **失败关闭**：P-1.5 **不注册任何发射器**。此时 `halt_tail()` 对任何输入都抛 `HaltPreconditionFailed("no_trusted_issuer")`；已注册后又撤销（`reset_for_tests()` 清空注册表）也同样失败关闭。
5. **保留的校验**：`migration_id` 非空字符串、`confirmed_at` 为数值（且非 `bool`）、两个确认字段必须 `is True`、`source == "halt_migration"`。
6. **移除公开工厂**：`new_confirmation()` 已删除（`test_public_factory_is_gone_and_mint_needs_registered_token` 校验其不存在）。
7. **A/B 职责不变**：`pool.py` 仍不读维护文件、不查维护态（静态扫描测试继续通过）；`maintenance_ok` 的真实性只能由 P-1.6 的 `halt_migration` 在回读维护文件后声明。

拒绝原因码：`not_confirmation` / `no_trusted_issuer` / `unconfirmed` / `untrusted_issuer_module` / `untrusted_issuer` / `unconfirmed_state`。

---

## 3. 问题 2：在途写事务并发封锁

### 3.1 旧实现的缺陷

`block_writes()` 只关闭"已登记"的连接，但没有显式"中止在途事务"的语义，也没有提交前复核；测试也只验证了连接数量，无法证明"正在事务中的会话不能提交"。

### 3.2 新机制

1. **在途事务登记**（`db.py`）：`_INFLIGHT = {id(conn): {"conn":…, "aborted": bool}}`，`transaction()` 在 `BEGIN IMMEDIATE` 前登记，`finally` 注销。
2. **封锁即中止**：`block_writes()` 在同一把 `_blocking_lock` 内先 `db.abort_inflight_transactions()`（把全部在途事务标 `aborted`），再 `close_business_connections()`（关闭全部业务写连接）。因此封锁返回时 `active_write_transactions()==0`、`open_write_connections()==0`。
3. **提交前复核**：`transaction()` 在 `conn.commit()` 之前调用 `_assert_txn_committable(entry)`——`aborted` 或闸门已置位即抛 `WriteRefused("writes_blocked")`，拒绝提交（不是靠"连接恰好被关"这种副作用，而是显式拒绝）。
4. **排空判据加强**：`confirm_writes_blocked()` 新增 `active_write_transactions == 0`，与"写连接全关""闸门置位""只读 `query_only=1`"共同判定。
5. **回滚清理不外抛**：`transaction()` 的 except 分支里 rollback 失败被忽略，但**原始异常照常上抛**（不吞 SQLite 错误，也不把原始失败变成成功）。

### 3.3 确定性时序（两种暂停点各一组）

`test_inflight_transaction_cannot_commit_after_block[after_write / before_write]`：

1. 会话 1（独立线程）`with db.transaction() as conn` → 真正 `BEGIN IMMEDIATE` 并登记在途事务；
   - `after_write`：先 `INSERT INTO logs ...`，再置 `entered` 事件并等待 `resume`；
   - `before_write`：先置 `entered` 并等待 `resume`，`INSERT` 放在恢复之后。
2. 主线程 `entered.wait(5)` 成功 → 断言 `db.active_write_transactions() == 1`（事务确实在途）。
3. 会话 2（主线程）`pool.block_writes("maintenance")`：
   - 断言 `writes_blocked()`、`open_write_connections()==0`、`active_write_transactions()==0`、`confirm_writes_blocked()[0] is True`；
   - `db.connect()` 抛 `PoolClosed`（新会话 checkout 被拒）；
   - `db.rows("SELECT 1 AS x")` 正常（只读会话仍可用）。
4. `resume.set()` 会话 1 恢复：`after_write` 在退出 `with` 时被 `_assert_txn_committable` 拒绝 → `WriteRefused`；`before_write` 的 `INSERT` 打在已关闭连接上 → `ProgrammingError`。两种都断言"不是 ok"。
5. **数据库最终状态验证**：`SELECT COUNT(*) FROM logs WHERE message='t'` == `0`（封锁后没有任何提交落地）。
6. 封锁后再开事务：`with db.transaction()` 抛 `WriteRefused`/`PoolClosed`（拿不到写权）。

测试全程使用 `tmp` 一次性库（`tests` 统一 `NODEPOOL_DATA_DIR` 临时目录），不接触任何生产库。

---

## 4. 测试输出

### 4.1 专项（50 项）

```
tests/test_maintenance_lock.py::test_http_write_refused_when_active                     PASSED
tests/test_maintenance_lock.py::test_http_write_refused_when_recovery_required          PASSED
tests/test_maintenance_lock.py::test_http_read_only_not_intercepted_when_active         PASSED
tests/test_maintenance_lock.py::test_http_write_passes_when_inactive                     PASSED
tests/test_maintenance_lock.py::test_scheduler_round_stops_without_reading_twice         PASSED
tests/test_maintenance_lock.py::test_cli_write_refused_and_allow_write_cannot_bypass      PASSED
tests/test_maintenance_lock.py::test_cli_read_command_allowed_when_active                PASSED
tests/test_maintenance_lock.py::test_write_guard_reasons                                 PASSED
tests/test_maintenance_lock.py::test_write_guard_requires_pragmas                        PASSED
tests/test_maintenance_lock.py::test_db_connection_pragmas_are_on                        PASSED
tests/test_maintenance_lock.py::test_startup_blocks_before_init_on_active                PASSED
tests/test_maintenance_lock.py::test_startup_enters_recovery_on_corrupt                  PASSED
tests/test_maintenance_lock.py::test_startup_proceeds_on_inactive                       PASSED
tests/test_maintenance_lock.py::test_pool_dead_after_block_and_readonly_still_serves     PASSED
tests/test_maintenance_lock.py::test_halt_tail_requires_confirmed_flags                  PASSED
tests/test_maintenance_lock.py::test_write_connection_recovers_after_unblock             PASSED
tests/test_maintenance_lock.py::test_second_session_cannot_write_after_block             PASSED
tests/test_maintenance_lock.py::test_pool_module_does_not_read_maintenance_file          PASSED
tests/test_maintenance_lock.py::test_confirm_writes_blocked_conditions                   PASSED
tests/test_maintenance_lock.py::test_drain_ok_requires_two_rounds_with_interval          PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint0]          PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint1]          PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint2]          PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_external_holder                      PASSED
tests/test_maintenance_lock.py::test_drain_fails_without_write_block_and_skips_checkpoint PASSED
tests/test_maintenance_lock.py::test_wal_checkpoint_truncate_real                        PASSED
tests/test_maintenance_lock.py::test_block_cannot_overtake_inflight_checkout             PASSED
tests/test_maintenance_lock.py::test_no_write_connection_survives_block_under_race       PASSED
tests/test_maintenance_lock.py::test_every_write_helper_refused_after_block              PASSED
tests/test_maintenance_lock.py::test_recovery_reason_is_preserved_after_block            PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[1-10.0]        PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[0-10.0]        PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[2-0.0]         PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[2-9.9]         PASSED
tests/test_maintenance_lock.py::test_drain_parameters_cannot_weaken_floor[1-0.0]         PASSED
tests/test_maintenance_lock.py::test_drain_legal_parameters_not_coerced                  PASSED
tests/test_maintenance_lock.py::test_drain_failure_keeps_gate_blocked_and_blocks_continue PASSED
tests/test_maintenance_lock.py::test_drain_failure_blocks_even_if_gate_was_open          PASSED
tests/test_maintenance_lock.py::test_assert_drain_ok_passes_on_success                   PASSED
tests/test_maintenance_lock.py::test_halt_tail_rejects_unconfirmed_objects               PASSED
tests/test_maintenance_lock.py::test_halt_tail_accepts_only_confirmation_from_halt_migration PASSED
tests/test_maintenance_lock.py::test_direct_instantiation_of_confirmation_is_never_valid PASSED
tests/test_maintenance_lock.py::test_public_factory_is_gone_and_mint_needs_registered_token PASSED
tests/test_maintenance_lock.py::test_only_migrate_module_may_register_issuer             PASSED
tests/test_maintenance_lock.py::test_mint_refuses_unconfirmed_state                      PASSED
tests/test_maintenance_lock.py::test_mint_refuses_when_writes_not_actually_blocked       PASSED
tests/test_maintenance_lock.py::test_halt_tail_fails_closed_when_no_issuer_registered    PASSED
tests/test_maintenance_lock.py::test_halt_tail_rejects_unconfirmed_objects_with_codes    PASSED
tests/test_maintenance_lock.py::test_inflight_transaction_cannot_commit_after_block[after_write]  PASSED
tests/test_maintenance_lock.py::test_inflight_transaction_cannot_commit_after_block[before_write] PASSED
======================== 50 passed, 1 warning in 1.99s ========================
```

原 41 项全部保留并通过（其中 halt_tail 两项按新凭据模型改写构造方式，拒绝覆盖面只增不减）。

### 4.2 全量（既定分批）

```
python3 -m pytest -q --ignore=tests/test_migration_baseline.py
→ 354 passed, 1 skipped

python3 -m pytest -q tests/test_migration_baseline.py
→ 15 passed
```

合计 369 passed、1 skipped、0 failed（较上轮 +9）。

---

## 5. P-1.6 如何安全产生并传递确认凭据

```python
# backend/database/migrate.py（P-1.6 实现时）
_TOKEN = pool.register_confirmation_issuer(halt_migration)   # 函数定义在 migrate 模块内才被接受

def halt_migration(code: str, ...) -> pool.MaintConfirmation:
    # 1) 置位封锁（保证 confirm_writes_blocked() 为真）
    pool.block_writes(pool.REASON_MAINTENANCE)
    # 2) 回读维护文件，确认 maintenance=true / migration_id 与 code 对应
    rd = maint.read_maint_file(); blob = rd.blob or {}
    maintenance_ok = rd.status is Maint.Read.PRESENT and blob.get("maintenance") is True
    # 3) writes_blocked 由 B 类当场核实（mint 内部还会再核一次）
    writes_blocked = pool.confirm_writes_blocked()[0]
    # 4) 签发凭据（字段不为 True 或封锁未真实成立时 mint 会直接拒绝）
    rec = pool.mint_confirmation(_TOKEN, blob["migration_id"], maintenance_ok, writes_blocked)
    # 5) 交给 halt_tail 做收尾前置检查
    pool.halt_tail(rec)
    return rec
```

要点：`_TOKEN` 保存在 `migrate` 模块私有变量里，不对外暴露；`halt_tail(rec)` 只接受这种由已注册发射器用哨兵签出的实例；任何"自己 new 一个 dataclass"或"调用公开工厂填 True"都不会得到有效凭据。P-1.5 未注册发射器 ⇒ 该路径当前必然失败关闭。

---

## 6. 未实现 / 边界

- 未实现 `halt_migration`、phase 推进、事件链（P-1.6）。
- 未实现多进程/多实例闸门（当前为单进程内存态；跨进程靠"关闭连接 + checkpoint + holders 扫描"的排空判据）。
- 未接触生产数据库 / NAS 生产容器 / 生产服务；未执行 P-7；未改 Compose、镜像、部署配置；未改两份批准文档；未进入 P-1.6。

完成后停止，等待负责人重新审查。
