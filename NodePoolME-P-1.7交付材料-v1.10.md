# NodePoolME P-1.7 交付材料 · 全链路故障恢复与迁移演练（v1.10）

- 阶段：P-1.7（全链路演练：副本库 + 临时环境；**不含**生产窗口）
- 基线：v1.8.7 / `e721797`；上一阶段 P-1.6 三轮提交（`9f558cf` → `7cf710b` → `41de972`）
- 本次提交：`17773807587870ded91c3500eba298be689d6258`（已推送 `main`）
- 依据：《新架构总体设计方案 v1.10》《P-1 实施计划 v1.10》§8 P-1.7；未修改两份文档
- 停止点：完成即停，等待 ChatGPT 独立复审；未进入 P-1.8

---

## 1. 变更文件

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/migrate.py` | 77,817 | 1,767 | `8a62e0c2845df5ce9145ab5ed952ee3c936e6390` |
| `backend/database/backup.py` | 37,679 | 965 | `95242a5793d968f97a626cc78e25a382d0c5ce41` |
| `backend/database/cli.py` | 8,194 | 186 | `f0d7ecf6891191edcf1a30df3f506ff712745c30` |
| `tests/test_p17_drill.py`（新增） | 26,022 | 606 | `24c21bf7fe8f6c992d399dd88c13fbc9e3499a6a` |
| `tests/test_migration_state.py` | 41,024 | 974 | `5916f115307c48f44dd406a2c20096b4fd405fab` |
| `tests/test_maintenance_lock.py` | 50,323 | 1,169 | `e7494cbcfde5c5bd543ce05ee77d72e15375a040` |

`git show --stat`：6 files changed, 935 insertions(+), 62 deletions(-)。

---

## 2. 实现要点（对应计划 §6 恢复步骤）

`migrate.rollback_to_snapshot()` 现在实到 v1.10 序列，步骤名固化在 `RESTORE_SEQUENCE`：

| # | 步骤 | 实现 |
| --- | --- | --- |
| 1 | `snapshot_verified` | `backup.verify_set()` L1/L2（无效集 ⇒ `backup_invalid`，不动文件） |
| 2 | `stop_writes` | `gate.apply_state(ACTIVE)` + `pool.block_writes()`；`confirm_writes_blocked()` 取 `(ok, detail)` 解包，失败 ⇒ `FatalExit("writes_block_unconfirmed")` |
| 3 | `drain` | `gate.drain(rounds=2, min_interval=10.0)`；失败 ⇒ 保持封锁 + `halt_migration("drain_failed")` |
| 4 | `close_connections` | `db.close_all_connections()` |
| 5 | `recheck_handles` | `backup.holders_of(target)` 扫 `/proc/*/fd`；非空 ⇒ `restore_handles_present`，**原库不动**、封锁保持 |
| 6 | `restore_atomic` | 独立子进程 `cli restore-set` 独占目标库：`snapshot_set(pre-restore)` → `-wal/-shm` 改名隔离 → 同卷临时文件 + `fsync` → `os.replace` → 目录 fsync → `init_db()` 后置校验 |
| 7 | `verify_restored` | 父进程只读复核：`PRAGMA query_only=1` + `integrity_check` + 逐表计数 vs manifest |
| 8 | `confirm_blocked` | 再次 `confirm_writes_blocked()`；`maintenance.json` **保留**（需人工确认） |

失败统一走 `_restore_failed()`：保持封锁 → `halt_migration(code, detail=...)` → 返回 `ok=False`；**不重试、不开放写入、不伪造 `restored`**。

为什么恢复必须走子进程：`restore_set()` 的后置校验要调 `db.init_db()`（写连接），父进程正处于维护期封锁（P-1.6 已认定为进程内不可恢复）；子进程 env 由 `config` 现算（`NODEPOOL_DB/DATA_DIR/CONFIG_DIR/LOG_DIR/BACKUP_DIR/STATE_DIR` + `MIGRATION_ENABLED=0`），父进程关闭全部连接后才 spawn，父子不同时持库。

`migrate.run()` 新增 `statements: Sequence[str] = ()`：默认零 DDL（P-1.6 行为不变），仅用于演练注入真实 `ALTER`，以覆盖"DDL 中途抛错 → 回滚 → failed"。

`backup.restore_set()`：删除 `raise` 之后**不可达**的 pre-restore 段，并明确「隔离副本不可用时不拿 pre-restore 覆盖目标路径」（见 §7 偏差 3）。

---

## 3. 逐项测试结果（11 项全绿）

命令：`python3 -m pytest -q tests/test_p17_drill.py` → `11 passed in 46.64s`

| PT | 测试 | 关键实测输出 |
| --- | --- | --- |
| PT-07 | `test_pt07_snapshot_failure_halts_without_running_row` | `[PT-07] snapshot_failed None phase= PREPARED`；无 `running` 行、`pool.writes_blocked()=True`、`write_slot()` 抛 `PoolClosed`、`cli.main(["run","--db",副本]) != 0` |
| PT-08 | `test_pt08_alter_failure_marks_failed_then_snapshot_restore` | `[PT-08] run= migration_failed`；`failed` 行 1 条；`p17_probe` 列不存在（事务回滚）；恢复 `code=restored`、8 步齐全、`restore_atomic 0.89s`；恢复后结构摘要/行数与迁移前一致；`maintenance.json` 删除 + `unblock_writes()` 后写入成功 |
| PT-17 | `test_pt17_rollback_script_full_checks` | 行数逐表一致、`structure_hash` 一致、`-wal` 字节 = 0（无 stale 帧）、`maintenance.json` 仍在；人工清维护后 `builder.publish()` 四格式重建：`clash` 含 `proxies:`、`singbox` 含 `outbounds`、`loon` 含 `Loon`、`base64` 返回合法空载荷 |
| PT-18 | `test_pt18_conservative_recovery_five_entries` | 删维护文件 + `failed` 行 ⇒ `maintenance_state()=RECOVERY_REQUIRED`；①HTTP POST 503 `reason=recovery_required`、`/healthz.migration=RECOVERY_REQUIRED`；②`manager.maintenance_hold()` 真、`job_cycle()` 不改 `last_cycle_at`；③`write_slot()` 抛 `PoolClosed`；④`cli.main(["snapshot"])=2`；⑤`gate.write_guard()` 抛错；`status` 仍 0 |
| PT-20 | `test_pt20_performance_budget_real_timings` | 见 §6，真实耗时 |
| PT-22a | `test_pt22a_third_party_handle_blocks_restore_without_touching_files` | 独立子进程持库 ⇒ `[PT-22a] restore_handles_present ['5379:4']`；目标库 db+wal+shm 摘要不变；封锁保持 |
| PT-22b | `test_pt22b_replace_failure_keeps_original_db` | `os.replace` 注入失败 ⇒ `[PT-22b] restore_replace_failed`；隔离副本还原后摘要与失败前一致 |
| PT-22c | `test_pt22c_post_restore_init_db_failure_rolls_back` | `db.init_db` 注入失败 ⇒ `[PT-22c] restore_rolled_back`；摘要回到原库；`pre-restore` 集存在且 L1 通过 |
| PT-22d | `test_pt22d_restore_clears_wal_before_atomic_replace` | 包装 `os.replace` 现场断言：替换瞬间 `-wal`/`-shm` 均不存在；`src` 与目标同目录（同卷原子替换，非 `copy2`） |
| PT-26 | `test_pt26_prune_protects_pre_sets_and_partials` | `[PT-26] removed=['…-daily','…-manual'] kept=['…-daily-1'] skipped=['nodepool-20200101-000000-daily','…-pre-migrate','…-pre-restore']`（2020 年旧集仍被保护；半成品保留） |
| PT-05 | `test_pt05_l3_restore_drill_on_port_8089` | 见 §5 |

---

## 4. 回归与全量

| 套件 | 结果 |
| --- | --- |
| P-1.5 专项 `tests/test_maintenance_lock.py` | `63 passed in 2.63s` |
| P-1.6 专项 `tests/test_migration_state.py` | `44 passed in 111.10s` |
| P-1.4 `tests/test_maint_state.py` | `72 passed in 69.83s` |
| P-1.3 `tests/test_backup_set.py` | `30 passed in 37.38s` |
| 全量批 1（除 baseline / migration_state） | `378 passed, 1 skipped in 63.15s` |
| 全量批 2 `tests/test_migration_baseline.py` | `15 passed in 14.79s` |
| 全量合计 | **437 passed / 1 skipped**（批 1 已含 P-1.7 的 11 项） |

分批原因不变：`test_migration_baseline.py` 的 PT-06 系列依赖"仓库开发库 = alter_history 形态"，与其它模块单进程混跑必失败 4 项（改动前 HEAD 同样复现）。

P-1.6 两项测试按阶段推进改写（**非弱化**）：
1. `test_rollback_requires_valid_set_without_touching_target`：删除 `complete.json` 判无效 ⇒ `backup_invalid`、`restore_set` 零调用、目标字节不变（原"P-1.6 禁止真实恢复"断言随阶段边界演进）。
2. `test_cli_rollback_restores_only_named_target`：`rollback --db 副本 --set 集` 只动副本、主库迁移行与结构不变（WAL checkpoint 会改写 `-wal/-shm`，故不按文件字节判等，改按迁移行）。

---

## 5. PT-05：端口 8089 临时服务演练

**环境限制（必须记录）**：本机 `docker: command not found`，无法按计划"临时容器 `-p 8089:8080` + 生产镜像"执行；改用**独立 uvicorn 进程 + 8089 + 独立 `NODEPOOL_DB`/`NODEPOOL_STATE_DIR`/`MIGRATION_ENABLED=0`** 等价演练，判定项不变。

实测：
- 备份集 `db` 落成恢复副本 → 起服务前逐表比对：`airports=2`、`nodes=0`、`settings=52` 与源库**完全一致**；
- `GET /healthz` → 200，`status=ok`；
- 订阅：`/sub/all/<token>/clash|singbox|loon|base64` 全部 200；clash 含 `proxies:`、singbox 含 `outbounds`、loon 含 `Loon` 头、base64 解码合法（0 节点 ⇒ 空载荷属正常）；
- 起服务后 settings 因启动自补种子项增至 55，故服务后只比对业务实体条数（airports/nodes），不作"settings 恒定"的错误断言。

---

## 6. PT-20 性能实测（100.3 MB，真实计时）

```
[PT-20] db=100.3MB snapshot=1.986s verify=0.147s drain=10.350s total=12.483s
```

| 指标 | 实测 | 预算 | 判定 |
| --- | --- | --- | --- |
| 快照 `snapshot_set` | 1.986 s（另一次 1.830 s / 1.867 s / 1.891 s） | ≤5 s | 通过 |
| L1/L2 验证 | 0.147 s | — | 记录 |
| 排空（2 轮，间隔 ≥10 s，真实 `wal_checkpoint(TRUNCATE)`） | 10.350 s | ≤30 s | 通过 |
| 总停写窗口（快照+验证+排空） | 12.483 s | ≤60 s | 通过 |

注：100 MB 由业务表 `logs` 的正文撑起（**不新增表**，避免结构摘要未登记）；排空为真实时钟与真实 checkpoint，未注入。

---

## 7. 偏差、未覆盖项与风险

1. **PT-05 无 docker**：如上，容器→独立进程等价演练；未拉取/运行生产镜像，未接触生产容器。
2. **PT-22「自动回退 pre-restore」**：实现为"隔离副本原样还原 + `pre-restore` 集生成"，结果等价于回到原库（摘要逐字节一致）。若隔离副本本身丢失，代码**不**用 `pre-restore` 覆盖目标路径（那会毁掉刚替换进来的新库，即现场唯一可取证副本），改为保留现状 + 报 `restore_rolled_back_leftover`。这是 P-1.3/P-1.5 既有安全判据（"预检失败不得删除目标路径的新库 DB"）的延续，未弱化。
3. **`pre-restore` 快照要做 L1 结构登记校验**：若迁移把库改成**未登记结构**，`pre-restore` 快照自身会 `structure_profile_unregistered` 失败（fail-closed）。P-1.6 演练中注入的未登记 `ALTER` 正是因此无法作为回滚剧本的"脏库"来源，PT-17 改用数据层变更。**P-1.8 前必须确认目标 DDL 的结构 profile 已登记**，否则回滚二道防线不可用。
4. **排空时钟注入**：除 PT-20 外，演练用递增时钟 + 空休眠完成 2 轮/≥10 s 判据（判据参数未改）；CLI 路径用的是**真实 10 s 排空**（日志中 `drain 10.35s`）。PT-16（真实排空）仍由 P-1.5 套件保证。
5. **单进程闸门**：跨进程/多实例排空与闸门仍未覆盖（沿用 P-1.5 的既定事实）；本次仅以 `/proc` 句柄探针覆盖"第三方持库"。
6. **CLI `rollback` 缺省主库**：`--db` 可选、缺省 `config.DB_PATH`，本阶段所有测试只对副本执行；对主库执行属 P-1.8 停机窗口，需二次确认。
7. **恢复后 `-wal` 为 0 字节、`-shm` 32KB**：`init_db()` 以 WAL 重开会生成空 `-wal` 与 32KB `-shm`；PT-17 判据为"`-wal` 字节 = 0（无 stale 帧）"，不是"文件不存在"。
8. **恢复后设置项增加**：服务启动自补 `sub_publish_*` 等种子项，`settings` 计数会变；数据实体（airports/nodes 等）不受影响。
9. **未接事件链**：无 `system_events` / `migration_tx_notes` / 哈希链字段；`PT-09b` 原样有效；`migration-fault.log` 仍只是非 DB 诊断通道。
10. **未做**：P-7 探针、NAS/生产库/生产容器/生产备份目录/生产配置、P-1.8 生产窗口。

---

## 8. 与计划条款对照

| 计划条款 | 本次落地 | 证据 |
| --- | --- | --- |
| §5 PT-05 | 8089 副本服务：healthz 200、条数一致、四格式重建（容器→进程等价） | §5 |
| §5 PT-07 | 备份失败 ⇒ halt、无 running、退出码非零、写入仍拒 | §3 |
| §5 PT-08 | DDL 中途抛错 ⇒ 回滚 + `failed` + pre-migrate 恢复 + 可写（人工解封后） | §3 |
| §5 PT-17 | 行数/摘要一致、无 stale WAL、四格式重建、维护文件需人工移除 | §3 |
| §5 PT-18 | 删文件 + 非 success ⇒ 五入口一致 `RECOVERY_REQUIRED` | §3 |
| §5 PT-20 | 100 MB：快照 ≤5 s、排空 ≤30 s、总窗口 ≤60 s（实测回填） | §6 |
| §5 PT-22 | 句柄阻断不改文件、替换失败回原库、后置校验失败回原库、替换前清 WAL/SHM、`os.replace` | §3 |
| §5 PT-26 | `pre-migrate`/`pre-restore` 永不删；半成品保留；旧 daily/manual 按规则删 | §3 |
| §6 恢复步骤 1–6 | 停写→快照→验证→副本演练→核对→收尾 全链可执行（步骤 7–8 属 P-1.8） | §2、§5 |
| §7 F4/F5/F10 | DDL 失败落 `failed`+`RECOVERY_REQUIRED`；COMMIT 异常保持 `COMMITTED_ATTEMPTED`+halt（P-1.6 未改）；句柄存在中止恢复 | §2、§3 |
| §8 P-1.7 | 仅副本库/临时环境；完成即停 | 本文件 |

---

## 9. 边界声明

- 未修改两份 v1.10 文档、未改业务表与 SCHEMA、未改评分/健康判断/订阅下发逻辑；
- 未接 durable 事件链，未建 `system_events`/`migration_tx_notes`，未加哈希链字段；
- 未接触 NAS、生产数据库、生产容器、生产备份目录、生产配置；未执行 P-7；
- 未进入 P-1.8；不自评验收通过，等待 ChatGPT 独立复审。
</content>
