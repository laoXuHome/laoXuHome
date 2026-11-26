# NodePoolME P-1.7 验收修正交付材料（v1.10）

**任务**：P-1.7 简化版验收修正（Targeted Acceptance Fixes）
**基线提交**：`048fd85bf366a8dca992acddb8ed2c1783026cd3`（简化版）
**本轮提交**：`ac9234f793a38a0f8465fa873bec779fb8b43434`（main，父 `048fd85`）
**施工环境**：隔离 VM（`vm`，Linux，python 3.12.11 / pytest 9.2.0），未接触 NAS 与生产库
**架构口径**：仍是"手动导出单文件 + 完整性校验 + 手动导入 + 导入期维护保护"；未重新引入自动恢复链、多级快照、恢复子进程；未进入 P-1.8

## 1. 五个问题的修正结果

| # | 复审问题 | 修正实现 | 关键行为 |
| --- | --- | --- | --- |
| 1 | 连接关闭无逐条确认 | `db.close_all_connections_report()` 返回 `{closed, failed:[{label,error}], remaining, ok}`；`close_all_connections()` 退化为兼容入口；`close_write_connections()` 同样"只在关闭成功时出表"；线程本地 `_local.conn`/`_local.ro` 按同规则置空 | 任一连接关闭失败 ⇒ 留在登记表并计入 `remaining`，`ok=False`；CLI `close_connections` 步骤据此报 `connections_not_closed` + 退出码 4，维护态与写封锁保持、不替换文件 |
| 1b | 本进程句柄未复核 | 新增 `backup.self_handles_of(target)`，扫 `/proc/self/fd` 找本进程对 `.db`/`-wal`/`-shm` 的句柄，与第三方 `holders_of()` 并列 | 命中 ⇒ `import_self_handles_present`，中止；不替换数据库 |
| 2 | 元信息未强制 | 新增 `REQUIRED_META_FIELDS`；`verify_backup()` 要求 `.json` 存在（`meta_missing`）、可解析（`meta_unreadable`）、字段齐全（`meta_fields_missing:…`）、`format=2`、`db_bytes`/`sha256`/`structure_hash`/`integrity_check` 实配 | `verify` 与 `import` 调用同一函数、同一规则；校验失败发生在进维护态之前，目标库零改动 |
| 3 | 秒级文件名冲突 | 文件名 `nodepool-<YYYYMMDD-HHMMSS>-<label>-<6位hex>.db`；`_publish_unique()` 用 `os.link(tmp, candidate)` 排他落名，`FileExistsError` 换名重试（上限 64 次） | 同秒连导、并发导出均唯一；绝不覆盖、不删除任何旧备份 |
| 4 | preimport 缺 WAL 已提交数据 | `_snapshot_original()` 改用 SQLite 在线备份 API 生成 `*.preimport-<stamp>.db`（不是 `copyfile` 主库），生成后 `_probe_file` 只读校验 + 与当前库逐表计数比对 | 计数不等 ⇒ `preimport_incomplete` 且不替换；副本保留、不自动删除；失败复原路径保留副本 |
| 5 | 缺专项测试 | `tests/test_backup_manual.py` 由 13 项增至 19 项 | 见 §4 |

**顺带修正（必需，否则上述能力不成立）**：纯 `mode=ro` 打开 WAL 库会读到旧快照（实测同一库 `_probe_file` 读到 `airports=1`，SQLite backup API 读到 2）。活库读取统一改为 `mode=rw` + `PRAGMA query_only=1` + `busy_timeout`；冻结备份文件仍用 `mode=ro&immutable=1`。此改动同时修正了导出源连接与 preimport 计数比对。

## 2. 修改文件（4 个，+355 / −54）

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 22,876 | 593 | `4763d61ae05b5bf5e2d23e39202ef4e52d0c5c9d` |
| `backend/database/db.py` | 34,732 | 878 | `db90fd386b1d9bc0dc4311f2bae7b507486ac0fb` |
| `backend/database/cli.py` | 11,065 | 261 | `b3fad81d96fd1d53b1c617678879f4a8058eb1bd` |
| `tests/test_backup_manual.py` | 18,943 | 511 | `47187bafce7533bfadb1ea41b47bfaa9102165ee` |

未改动：`migrate.py`、`gate.py`、`routes.py`、`maint.py`、`pool.py` 及全部迁移逻辑。

## 3. 删除 / 保留

**本轮未删除任何通用安全机制**（修正只做收紧）。简化版阶段（`048fd85`）已删除的废弃机制保持删除状态：`snapshot_set()` 三件套、`complete.json`、`restore_set()`、`prune()`、自动 pre-restore 多级链、恢复子进程、`rollback_to_snapshot()`、`RESTORE_SEQUENCE`、`migrate.run(snapshot=…)`、自动恢复状态管理；`/api/system/restore` 仍为 409 `manual_import_required`。

保留：在线备份 API、`fsync` + `os.replace`、WAL/SHM 隔离、句柄扫描（第三方 + 本进程）、完整性/结构/逐表计数校验、维护态与写封锁、preimport 副本。

## 4. 测试

**专项**：`python3 -m pytest -q tests/test_backup_manual.py` → **19 passed（91.34 s）**

新增/改造的 6 项：

| 测试 | 覆盖 |
| --- | --- |
| `test_close_report_keeps_failed_connection` | 关闭失败连接不出表、`ok=False`、`remaining` 含该连接 |
| `test_close_failure_aborts_import` | 关闭确认失败 ⇒ 退出码 4，库内容不变、`maintenance.json` 仍在、写封锁仍生效 |
| `test_self_handles_block_import` | 本进程持有目标库句柄 ⇒ 中止 |
| `test_verify_and_import_require_strict_meta` | 缺 `.json` / JSON 损坏 / 缺 `tables` 三态均拒绝 |
| `test_same_second_exports_never_overwrite` | 固定时间戳连导 3 次 ⇒ 3 个不同文件、全部可校验、旧文件 sha 不变 |
| `test_concurrent_exports_never_overwrite` | 6 线程并发导出 ⇒ 文件名互不相同、全部可校验 |
| `test_preimport_captures_committed_wal_data` | 子进程 `os._exit(0)` 造未 checkpoint 的已提交 WAL 页 ⇒ preimport 逐表计数等于含 WAL 的真实库且含该行 |

**回归（全量分批执行，单批否则超时）**

| 批次 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py` | **356 passed, 1 skipped**（71.73 s） |
| 2 | `pytest -q tests/test_migration_baseline.py` | **15 passed**（38.37 s） |
| 3 | `pytest -q tests/test_migration_state.py` | **40 passed**（215.76 s） |
| 专项 | `pytest -q tests/test_maintenance_lock.py` | **63 passed**（2.57 s） |

合计 **411 passed / 1 skipped**（P-1.6 减少 2 项 rollback 测试后为 40 项，无回归；跳过项为既有的环境性 skip）。测试发现的三处自身问题已修：`test_close_report_*` 与全局登记表串扰（改为 `monkeypatch` 独立字典）、导入失败断言用整文件 sha 判等（backup API 产物字节不同但内容等价，改为逐表计数）、CLI glob 未含随机后缀。

## 5. 操作命令

```bash
# 导出（运行期可用；产出 .db + 同名 .json，文件名唯一）
python -m backend.database.cli backup --out /backup --label manual --json

# 校验（严格：.db 与 .json 必须成对且字段/摘要实配）
python -m backend.database.cli verify --file /backup/nodepool-20261126-211910-manual-76187a.db --json

# 导入（自动进/退维护态；失败保持维护态与写封锁，保留 *.preimport-<stamp>.db）
python -m backend.database.cli import --file /backup/nodepool-20261126-211910-manual-76187a.db --json

# 状态
python -m backend.database.cli status --json
```

退出码：`0` 成功 / `2` 拒绝（备份无效、已在维护、目标不存在）/ `4` 中止（写封锁未确认、连接未关闭、句柄存在、导入失败，维护态保持）。

## 6. 文档同步

- 总体设计方案 v1.10 §11：补"验收修正"五条（连接逐条确认、元信息强制、唯一命名、preimport 完整性、活库读取口径）与更新后的验收清单。
- P-1 实施计划 v1.10：§2.3 改写为唯一命名 + 元信息强制成对 + 活库 `mode=rw&query_only`；§3.3 步骤 5–7 改写为逐条关闭确认、含本进程的句柄复核、backup-API preimport；§5 更新 PBT-01/03/09 并新增 PBT-11…16。
- 文档与代码一致；架构未变。

## 7. 边界声明

只在隔离测试环境施工；未连接、未读取、未修改 NAS 生产数据库与容器；未执行生产导入或迁移；未接入 P-1.8；未改变已批准的简化架构。**到此停止，等待独立复审。**
