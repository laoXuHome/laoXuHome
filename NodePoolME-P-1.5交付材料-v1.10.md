# NodePoolME P-1.5 交付材料（v1.10）

> 阶段：P-1.5 五入口与二次封锁机制接线（PT-15 / PT-16 / PT-23）
> 依据：`NodePoolME-P-1实施计划-v1.10.md` §2.7 / §3.1 / §5、`NodePoolME 新架构总体设计方案-v1.10.md` §2.1 / §3.3 / MC62–MC68
> 基线：v1.8.7 (`e721797`)，本阶段基于 P-1.4 验收后的 `357c90aa`
> 本阶段**未**接触生产数据库、**未**在 NAS 生产容器上运行任何自检、**未**执行 P-7、**未**改动 Compose/镜像/部署配置

---

## 1. 修改文件清单（字节数 / 行数 / blob SHA）

| 文件 | 性质 | 字节数 | 行数 | blob SHA | 修改目的 |
| --- | --- | --- | --- | --- | --- |
| `backend/database/pool.py` | 新增 | 4,757 | 141 | `a58a3d8d7d251e54b0a0ef45e7f13cdc55dd182b` | B 类唯一实现：写入闸、连接池 `dead`/`PoolClosed`、`halt_tail()` 前置检查；不含任何维护文件读取/维护态判定 |
| `backend/database/gate.py` | 新增 | 7,565 | 194 | `bba0294dcc26574602ea02098e1fa249e8f9a5ef` | A 类公共判定：`judge()` / `apply_state()` / `write_guard()`（含 `foreign_keys`、`recursive_triggers` 检查）+ 停写排空 `confirm_writes_blocked()` / `drain()` |
| `backend/database/cli.py` | 新增 | 3,712 | 103 | `f2038e4ec4cc5b3af212dcbe8b42b53d438403f1` | CLI 写命令入口（A 类入口 3）：`status/verify` 只读放行，`snapshot` 受维护态封锁且 `--allow-write` 不能绕过，`run/rollback` 返回 `not_implemented`（P-1.6） |
| `backend/database/db.py` | 修改（增量） | 27,549 | 724 | `9d3c4b188c18af06c465f09a036301ae1f59832d` | 新增 `connect_readonly()` / `read_connection()` / `table_exists()` / `close_all_connections()` / `close_write_connections()` / 只读连接 `query_only` 巡检；`connect()` 在池 dead 时抛 `PoolClosed`；写连接启用 `foreign_keys=ON`、`recursive_triggers=ON`；读辅助函数改走 `read_connection()`；`transaction()` 前置 `write_guard()`；连接"代际"计数避免旧句柄复活。**`SCHEMA` 零改动** |
| `backend/main.py` | 修改（薄） | 8,690 | 217 | `3713d4e3e82a2db34e683f7dd96fcb8378df68ab` | 启动顺序：`selfcheck_state_dir()` → `maintenance_state()` → `init_db()`；新增 HTTP 写请求中间件（503 + `reason`）；维护态下不初始化、不建调度、不写启动日志 |
| `backend/scheduler/manager.py` | 修改（判定一行 + 状态标记） | 43,076 | 930 | `f54e7750cbece26b8a60a13319bf56fdae2190aa` | 四个 job 每轮开始前 `maintenance_hold()`：只调 `gate.judge()` 一次，非 `INACTIVE` 直接 return 并把运行态标 `stopped` |
| `backend/api/routes.py` | 修改（薄） | 75,314 | 1,613 | `c015f4288a7a573f64c0c196a0995b1f9efc1021` | `/healthz` 增加 `migration` 字段，状态码语义不变 |
| `tests/conftest.py` | 修改（测试隔离） | 1,195 | 37 | `9410262dd2d1c6b0218fcd2d9f33c50755451863` | 每个测试开始前清空进程级写入闸，避免跨测试污染 |
| `tests/test_maintenance_lock.py` | 新增 | 13,740 | 377 | `8cbdc3a99085bbeed3e0b7cb055ce1b248dfa026` | PT-15 / PT-16 / PT-23 共 26 项验收测试 |

差异汇总：9 个文件、+1,077 / −28 行。

## 2. Git

- commit：`2cfcaad1246bb47178d15f8afda37cc85e1fb83e`
- 分支：`main`，已 push（`git ls-remote origin refs/heads/main` 回读等于该 SHA）
- 父提交：`357c90aaf88ed28a37a0327f399dc51beb900ea1`（P-1.4 同卷判定严格化）

## 3. 测试结果

### 3.1 PT-15（五入口 + 两会话封锁）—— 26 项专项全绿

```
tests/test_maintenance_lock.py::test_http_write_refused_when_active                   PASSED
tests/test_maintenance_lock.py::test_http_write_refused_when_recovery_required       PASSED
tests/test_maintenance_lock.py::test_http_read_only_not_intercepted_when_active      PASSED
tests/test_maintenance_lock.py::test_http_write_passes_when_inactive                 PASSED
tests/test_maintenance_lock.py::test_scheduler_round_stops_without_reading_twice     PASSED
tests/test_maintenance_lock.py::test_cli_write_refused_and_allow_write_cannot_bypass  PASSED
tests/test_maintenance_lock.py::test_cli_read_command_allowed_when_active            PASSED
tests/test_maintenance_lock.py::test_write_guard_reasons                             PASSED
tests/test_maintenance_lock.py::test_write_guard_requires_pragmas                    PASSED
tests/test_maintenance_lock.py::test_db_connection_pragmas_are_on                    PASSED
tests/test_maintenance_lock.py::test_startup_blocks_before_init_on_active             PASSED
tests/test_maintenance_lock.py::test_startup_enters_recovery_on_corrupt               PASSED
tests/test_maintenance_lock.py::test_startup_proceeds_on_inactive                     PASSED
tests/test_maintenance_lock.py::test_pool_dead_after_block_and_readonly_still_serves PASSED
tests/test_maintenance_lock.py::test_halt_tail_requires_confirmed_flags              PASSED
tests/test_maintenance_lock.py::test_write_connection_recovers_after_unblock         PASSED
tests/test_maintenance_lock.py::test_second_session_cannot_write_after_block         PASSED
tests/test_maintenance_lock.py::test_pool_module_does_not_read_maintenance_file      PASSED
tests/test_maintenance_lock.py::test_confirm_writes_blocked_conditions               PASSED
tests/test_maintenance_lock.py::test_drain_ok_requires_two_rounds_with_interval      PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint0]      PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint1]      PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_bad_checkpoint[checkpoint2]      PASSED
tests/test_maintenance_lock.py::test_drain_fails_on_external_holder                  PASSED
tests/test_maintenance_lock.py::test_drain_fails_without_write_block_and_skips_checkpoint PASSED
tests/test_maintenance_lock.py::test_wal_checkpoint_truncate_real                    PASSED
======================== 26 passed, 1 warning in 1.13s ========================
```

### 3.2 PT-16（停写排空）

| 判据 | 覆盖方式 | 结果 |
| --- | --- | --- |
| ① 全局闸置位 ∧ 业务写连接全关 ∧ 只读连接 `query_only=1` | `test_confirm_writes_blocked_conditions`：置位前 `open_write_connections=1` 判否，置位后全部为真 | PASSED |
| ② `wal_checkpoint(TRUNCATE)` = `(0,0,0)` | 真实 SQLite WAL 库 `test_wal_checkpoint_truncate_real` 返回 `(0,0,0)`；`(0,1,1)` / `(1,0,0)` / 异常 → `None` 三种非零/失败路径均判 `drain_failed` | PASSED |
| ③ 无外部进程持有 `nodepool.db*` | 注入 `["1234:5"]` → `holders_ok=False`、`drain_failed` | PASSED |
| ④ 连续两次、间隔 ≥10s | 假时钟驱动，断言 `rounds[1]["gap"] >= 10.0`、`clock.t >= 10.0` | PASSED |
| checkpoint 只在确认停写后执行 | 未置位写入闸时 `checkpoint` 调用计数为 0 | PASSED |

### 3.3 PT-23（A/B 职责分离 + 两会话并发）

- **两会话并发**：会话 1 已 checkout 写连接并成功读；A 类判定 ACTIVE 后（`gate.apply_state`）该连接被关闭（`open_write_connections()==0`），再次使用抛错；另起线程模拟会话 2 调 `db.execute()` → `PoolClosed`；`write_guard()` 对会话 2 抛 `WriteRefused`。证据：`test_second_session_cannot_write_after_block` PASSED。
- **静态扫描**：`pool.py` 源码中不存在 `MAINT_FILE`、`read_maint_file`、`maintenance.json`、`maintenance_state`、`import maint` 任一标识。证据：`test_pool_module_does_not_read_maintenance_file` PASSED。
- **`halt_tail`**：仅接受 `rec.maintenance_ok ∧ rec.writes_blocked` 双真；缺任一或字段缺失 → `HaltPreconditionFailed`；不读维护文件、不查库。证据：`test_halt_tail_requires_confirmed_flags` PASSED。

### 3.4 全量测试（沿用本阶段既定的分批方式）

```
python3 -m pytest -q --ignore=tests/test_migration_baseline.py
→ 330 passed, 1 skipped（1 warning）

python3 -m pytest -q tests/test_migration_baseline.py
→ 15 passed
```

合计 345 passed / 1 skipped / 0 failed。分批原因与本项目已说明一致（`test_migration_baseline.py` 的 PT-06 系列依赖"仓库开发库 = alter_history 形态"，多个业务测试模块在导入期覆盖 `NODEPOOL_DATA_DIR`，单进程混跑必失败 4 项；该现象在 P-1.4 及更早 HEAD 同样存在）。本阶段新增 `tests/test_maintenance_lock.py` 未加剧该问题：分别单跑与两批混跑均为全绿。

## 4. 关键异常场景与降级行为

1. **维护态判定为 ACTIVE（文件有效 ∧ `maintenance=true` ∧ 结构合法）**
   写请求 → 503 `reason=maintenance`；调度器四个 job 每轮首行判定后直接 return、运行态 `phase=stopped`；CLI 写命令退出码 2；`write_guard()` 抛 `WriteRefused("maintenance")`；启动时跳过 `init_db()`、`migrate_filter_defaults()`、调度器与速度队列。只读请求（`rows/row/get/get_int`）改走 `mode=ro` + `query_only=1`，正常返回。
2. **RECOVERY_REQUIRED（文件缺失且库内有非 success 迁移行 / CORRUPT / UNREADABLE / 结构不自洽 / 库无法确认）**
   同上封锁，但 `reason=recovery_required`，`/healthz.migration="RECOVERY_REQUIRED"`。不查库判定被损坏/不可读文件时**不**回退放行（P-1.4 语义未改）。
3. **判定自身异常**（中间件里 `gate.judge()` 抛异常）：按 `recovery_required` 保守拒绝，不 500、不放行。
4. **`write_guard()` PRAGMA 检查失败**：写连接未带 `foreign_keys=ON` / `recursive_triggers=ON` 时抛 `WriteRefused("pragmas_not_enabled")`，不静默写库。
5. **连接池 dead 后的旧句柄**：批量关闭连接后 `_GENERATION` 递增，其它线程残留的 thread-local 句柄在下次 `connect()` 时检测代际不符并重开；维护结束调用 `gate.release()` 后可正常写入（`test_write_connection_recovers_after_unblock`）。
6. **排空失败**：`drain()` 任一轮任一判据不满足即返回 `code=drain_failed`；未确认停写时不执行 checkpoint（避免"只读探针里出现写操作"）；本阶段不实现 `halt_migration("drain_failed")` 状态机，由 P-1.6 接线。
7. **启动自检失败（P-1.4 钩子）**：仍只禁用迁移入口，不影响业务启动、不 503、不自动迁移。
8. **首次部署（库文件不存在且维护文件 ABSENT）**：`maintenance_state()` 会因库无法只读打开返回 `RECOVERY_REQUIRED`（P-1.4 保守语义），启动层显式识别"库不存在 + 维护文件确为 ABSENT"并视为 INACTIVE，从而不破坏首装；维护文件为 CORRUPT/UNREADABLE 时**不**走该特例。

## 5. 启动顺序（重启恢复，A 类入口 5）

```
setup_logging()
→ maint.selfcheck_state_dir()        # P-1.4：只禁用迁移，不影响启动
→ startup_maintenance_state()        # 本阶段：先于 init_db()，判定 + 置位写入闸/池 dead
→ 若 INACTIVE：db.init_db() → fetcher.migrate_filter_defaults() → 调度器/速度队列
→ engine_manager.start()             # 维护态下仍启动（只读观测可用）
→ 维护态下：不 init_db、不建调度、不写启动日志/run_event、不自动推进 phase、不重试迁移
```

## 6. 与批准方案的偏差 / 需负责人裁决的冲突（如实列出，未擅自改架构）

1. **CLI 模块名**：计划 §3.1/§3.3 写的是 `python -m backend.database.migrate`（`status/verify/snapshot/run/rollback`）。P-1.5 禁止提前实现 P-1.6 状态机，`migrate.py` 目前只有 P-1.2 的 schema 基线能力且无 `__main__`。本阶段把 CLI 落在新模块 `backend/database/cli.py`（`python -m backend.database.cli`），**未改动 `migrate.py`**。建议 P-1.6 按计划把 `__main__` 挂到 `backend.database.migrate` 并转发到本模块，或直接迁移文件。
2. **`halt_tail()` 归属**：设计把 `halt_migration`/`halt_tail` 放在 `migrate.py`。P-1.5 只实现"前置检查"（`pool.halt_tail(rec)`），不实现状态机、不写事件链；P-1.6 实现 `halt_migration` 后可直接复用该检查，或按计划迁入 `migrate.py` 再转发。
3. **`/api/system/migration/status`**：§3.3 列为新增只读接口，但它属"迁移状态查询"，依赖 P-1.6 的 `phase`/`schema_version` 语义。本阶段只做了 `/healthz` 的 `migration` 字段；该接口留待 P-1.6。
4. **HTTP 写方法判定会连带拦截 `/api/login`**：中间件按"方法 ∈ {POST,PUT,PATCH,DELETE} 且路径前缀 `/api`/`/sub`"判定，维护期登录 POST 同样返回 503。计划原文为"所有业务写接口 维护期 503"，未给登录例外；本阶段严格按字面执行，如需保留登录入口需负责人明确后再改。
5. **只读连接与连接池语义的落地方式**：`db.py` 只有一条 thread-local 写连接且读写共用，若直接让 `connect()` 抛 `PoolClosed`，维护期读请求会一起崩，与 PT-15"只读请求正常"冲突。落地方式：`connect()`（写）在池 dead 时抛 `PoolClosed`；读辅助函数改走新增的 `connect_readonly()`（`mode=ro` + `query_only=1`），正常态行为与改动前完全一致（仍复用写连接）。
6. **`backend/api/routes.py` 有薄改动**（`/healthz` 一个字段 + 形参 `request`）：P-1.5 边界允许"根据实际代码结构修改实现上述目标所必需的文件"，这一处是 §3.1 明确要求的 `/healthz` 增字段。未新增任何业务路由。

## 7. 未实现 / 未覆盖 / 后续阶段

- **未实现**：`halt_migration()` 状态机、`run()`/`rollback_to_snapshot()`、持久化事件链（`system_events`/`migration_tx_notes`，属 P0/P-1.6）、`/api/system/migration/status`、迁移期的全局写锁（P-1.6）。
- **未实现**：把 `drain_failed`/`halt_tail` 接进真实迁移流程（现在只有可调用的实现与测试，无调用点）。
- **未覆盖**：真实跨进程排空（另起独立进程持库，确认 `holders_of` 能检出）——本阶段仅以注入方式覆盖判据；多 worker/多实例部署下的进程级闸门（当前为单进程模型，闸门是进程内存态）。
- **未执行**：P-7 生产探针、NAS 启动自检、生产容器 any 操作。
- **未改动**：`backend/services/`、`backend/testers/`、`backend/scoring/`、前端、`db.py` 的 `SCHEMA`、`migrate.py`、业务表结构、节点检测/评分/订阅下发规则、Compose/镜像/部署配置、两份 v1.10 批准文档。

## 8. 边界自证

- 未接触生产数据库（本阶段所有库操作均在临时目录/一次性库/仓库开发库，且开发库只读 status 一次）。
- 未在 NAS 生产容器上运行启动自检；未执行 P-7。
- 未修改 Compose、镜像、生产服务与部署配置。
- 未进入 P-1.6，未接线迁移状态机。

完成后停止，等待验收。
