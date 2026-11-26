# NodePoolME 备份与导入简化 · 交付材料（v1.10）

## 1. 结论与提交

- 代码提交：`048fd85bf366a8dca992acddb8ed2c1783026cd3`（`main`，父提交 `17773807587870ded91c3500eba298be689d6258`）
- 变更规模：10 个文件，**+912 / −2,943** 行
- 定位：只做"手动导出单文件 + 完整性校验 + 手动导入 + 导入期维护保护"；自动恢复体系整体删除；备份与迁移彻底解耦
- 未进入 P-1.8，未接触 NAS/生产库/容器/备份目录，未执行生产导入或迁移

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 18,198 | 485 | `ff777a45ddbb2bfbb67f6ea684db27aac5577e2a` |
| `backend/database/cli.py` | 10,451 | 251 | `c304d1caa6e19051e6d01559f49094225f0a44e4` |
| `backend/database/migrate.py` | 64,242 | 1,481 | `0c505220285ea894aa5ba678207ab46b7bab574e` |
| `backend/database/gate.py` | 11,606 | 292 | `5c9a4f6092a3ca9ca2e9f4d54014a31ddd747f80` |
| `backend/api/routes.py` | 74,409 | 1,584 | `1b58933fbb1155e70faca1d307c83993a4e30fa5` |
| `tests/test_backup_manual.py`（新增） | 13,391 | 373 | `52ee2c1ae9ab15d3f13ceefcf6059a1119d23599` |
| `tests/test_maintenance_lock.py` | 50,388 | 1,168 | `12941e0e0fcb05bdeb5ec9717592fb8072dbf47f` |
| `tests/test_migration_state.py` | 38,057 | 902 | `08c44b7b56c16e980396d3fb03b6c4a40224b8bf` |
| `tests/test_backup_set.py` | 删除 | — | 原 30 项三件套测试 |
| `tests/test_p17_drill.py` | 删除 | — | 原 11 项自动恢复演练 |

## 2. 新设计口径（代码即此实现）

### 2.1 手动导出（`cli backup`）

- SQLite 在线备份 API（`source.backup(dest, pages=1024)`），源连接 `mode=ro`；**禁止** `copy2` 运行中的库
- 产物：`nodepool-<stamp>-<label>.db` + 同名 `.json`（`created_at/app_version/sqlite_version/db_bytes/sha256/integrity_check/structure_hash/structure_profile/schema_version/tasks/tables/key_digests`）
- 顺序：`.tmp-*.db` → fsync → 独立只读连接 `integrity_check`+表集合+结构摘要 → `os.replace` → 目录 fsync → 写元信息 → 目录 fsync
- 校验不过 ⇒ 删临时文件、不落名、非零退出；库与既有备份零改动
- 不做滚动清理、不生成 `nodepool-latest.db`、没有任何"阶段保护"标记

### 2.2 校验（`cli verify [--file]`）

L1：文件存在/非空 → `integrity_check=ok` → 17 张基准表齐全 → 结构摘要命中已登记 profile（否则 `structure_profile_unregistered` fail-closed）→ 元信息 `db_bytes`/`sha256`/`structure_hash` 与实文件一致
L2：备份文件逐表计数与元信息 `tables` 一致；**不与实时源库比较**

### 2.3 手动导入（`cli import --file`）

固定顺序（缺一不可，代码中 `steps` 可见）：

1. `source_verified`：先将目标校验备份文件；无效 ⇒ 退出码 2，**不进入维护态**
2. `maintenance`：`set_maintenance()`（`migration_id=import-<stamp>`，`reason=manual_import`）+ 回读确认
3. `stop_writes`：`gate.apply_state(ACTIVE)` + `pool.block_writes()` + `confirm_writes_blocked()`
4. `drain`：`rounds=2, min_interval=10.0`
5. `close_connections`：`db.close_all_connections()`
6. 文件级：`/proc` 句柄复核（有第三方 ⇒ `import_handles_present`，文件不动）→ `-wal/-shm` 改名隔离 → 原库单副本 `*.preimport-<stamp>.db` → 同卷 `.import-*.db` + fsync + 复核 → `os.replace` + 目录 fsync
7. `verify_imported`：完整性 + 结构摘要 + 逐表计数与**源备份文件**比对
8. `release`：删除 `maintenance.json` + 目录 fsync + 复核 `INACTIVE` ⇒ `gate.release()`；失败路径不释放
9. 任何失败：维护态与写封锁保持；能复原就复原原库；无法复原报 `import_failed_leftover` 并给出留存路径

### 2.4 HTTP 端点

- `POST /api/system/backup`、`GET /api/system/backup/download`：复用 `export_backup()`，返回/下载已校验文件
- `POST /api/system/restore`：改为 **409 `manual_import_required`**，运行中进程不再覆盖库文件（旧实现 `copy2` 覆盖 + 无 WAL 处理已移除）

## 3. 删除的机制（专用测试一并删除）

| 机制 | 原位置 |
| --- | --- |
| 备份集三件套（`db`/`manifest.json`/`complete.json`）与原子目录发布 | `backup.snapshot_set()` |
| 三件套校验 `verify_set()`、`valid_sets()`/`latest_set()` | `backup.py` |
| `restore_set()` 全流程、`_quarantine_target`/`_unquarantine`/`_drop_quarantine`/`_silent_unlink`/`_verify_staged_db`/`_post_restore_checks` | `backup.py` |
| 自动回退 `_rollback_to_pre_restore()`（已无调用者） | `backup.py` |
| 滚动清理 `prune()`、`PROTECTED_STAGES`/`STAGES`/`DEFAULT_KEEP_*` | `backup.py` |
| `rollback_to_snapshot()` 8 步编排、`RESTORE_SEQUENCE`、`_restore_child_env`、`_default_restore_runner`、`_verify_restored`、`_restore_failed` | `migrate.py` |
| 恢复子进程 CLI `restore-set`、`rollback` 子命令 | `cli.py` |
| `migrate.run(snapshot=..., snapshot_stage=...)` 自动快照 | `migrate.py` |
| API 运行中 `copy2` 覆盖式 restore（含 `pre-restore-*.db` 快照） | `routes.py` |
| 依赖三件套/自动恢复的 41 项测试（30 + 11），以及 2 项 rollback 测试 | `tests/` |

## 4. 保留的基础能力（未为减代码而削弱）

- 在线备份 API + 独立只读连接；`_fsync_file`/`_fsync_dir`/`os.replace` 同卷原子替换
- `holders_of()`（`/proc/*/fd` 句柄扫描，`gate.py` 复用）
- 完整性（`integrity_check`）、表集合、结构摘要（`structure_hash`/`structure_profile_for`）、逐表计数、元信息 sha
- WAL/SHM 处理：替换前改名隔离，替换后复核，不残留旧帧
- 维护态体系：`maint` 四态、`pool.block_writes`/`confirm_writes_blocked`/`write_slot`、`gate.drain`、`db.close_all_connections`、`halt_migration`/`halt_tail`（迁移侧原样）
- `schema_migrations` 全链路与 P-1.6 状态机（仅删快照注入，其余零改动）

## 5. 操作命令

```bash
# 导出（可在线执行）
python -m backend.database.cli backup --out /backup/manual --label manual

# 校验（缺省校验目录内最新文件）
python -m backend.database.cli verify --file /backup/manual/nodepool-20261126-201500-manual.db

# 导入（维护窗口、停机后；命令自己进/退维护态）
python -m backend.database.cli import --file /backup/manual/nodepool-20261126-201500-manual.db

# 复核
python -m backend.database.cli status
```

退出码：`0` 成功、`2` 拒绝（未改动任何东西）、`4` 已进入维护/失败现场（需人工处置）。

## 6. 测试结果（实际输出）

| 批次 | 命令 | 结果 |
| --- | --- | --- |
| 专项-新备份 | `pytest -q tests/test_backup_manual.py` | **13 passed**（62.79s） |
| 专项-维护封锁 | `pytest -q tests/test_maintenance_lock.py` | **63 passed**（2.60s） |
| 批 1 | `pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py` | **350 passed, 1 skipped**（57.57s） |
| 批 2 | `pytest -q tests/test_migration_baseline.py` | **15 passed**（38.62s） |
| 批 3 | `pytest -q tests/test_migration_state.py` | **40 passed**（217.83s） |
| 合计 | — | **405 passed, 1 skipped** |

新增 13 项覆盖：导出单文件+元信息、运行期并发写一致性、截断/头部损坏/删表/元信息 sha 四类坏文件、正常导入并解除维护、无效备份不进入维护且库零改动、维护中拒绝导入、替换前写封锁生效（`PoolClosed`）、遗留 `-wal/-shm` 导入后无残留、替换失败原库复原且留存副本、导入失败维护态与封锁保持、CLI backup/verify/status、迁移不再自动导出。

## 7. 文档修订（与代码一致）

- `NodePoolME-P-1实施计划-v1.10.md`：§2.1 重写为单文件导出；§2.3 改为"迁移与备份解耦"；§2.4 改为单文件两级校验；§2.5.2 恢复路径改为手动导入；§3.1 文件表、§3.3 接口与 `import` 流程重写；§5 测试编号 PT-01/02/03/04/04b/17/21/22/26 → PBT-01…10；§6 步骤、§7 F1/F2/F4/F10/F11、§8 P-1.3/P-1.7 验收、§9 风险 4/6/8/14 同步修订；§10 加简化修订说明
- `NodePoolME-新架构总体设计方案-v1.10.md`：新增 **§11 备份与导入（实施期修订）**，钉死四条原则与"不做自动恢复"边界

## 8. 已知偏差与风险提示

1. 导入的"解除维护"是命令自动完成（要求原文："成功后解除维护状态"）；若复核 `INACTIVE` 不成立则不释放并返回 `maintenance_not_clear`
2. 导入保留 `*.preimport-<stamp>.db` 不自动删除，避免"成功后现场不可追溯"；清理需人工
3. 仍为单进程语义：`/proc` 扫描覆盖外部进程，但同进程内 `open()` 持有句柄由"先 `close_all_connections()`"保证；跨进程并发导入无分布式锁（与 P-1 现状一致）
4. 导入不执行 `init_db()`、不重建订阅；重启后由应用自行初始化/发布，避免在维护期制造写连接
5. PT-05 的 8089 演练在本机无 docker 条件下未复跑（本次改动不涉订阅/服务启动路径）；其余演练项均在隔离副本完成

## 9. 停止点

本任务到此结束，未进入 P-1.8、未触碰生产。等待 ChatGPT 独立审查。
