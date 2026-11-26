# NodePoolME P-1.7 最终验收修正交付材料（v1.10）

**任务**：P-1.7 最终验收修正（Final Acceptance Fix）
**基线提交**：`ac9234f793a38a0f8465fa873bec779fb8b43434`
**本轮提交**：`a62aeb2144ce866c3196c8f5b05bb8de8dcf7ece`（main，父 `ac9234f`），2 文件 +117 / −2
**施工环境**：隔离 VM（Linux，python 3.12.11 / pytest 9.2.0）；未接触 NAS 与生产库
**架构**：不变——手动导出单文件 + 完整性校验 + 手动导入 + 导入期维护保护；未重新引入自动恢复链、多级快照、恢复子进程；未进 P-1.8

## 1. 修正一：preimport 活库 WAL 实际状态复核

- `backup.import_backup()` 的 preimport 比对由 `live = _probe_file(target)` 改为 `live = _probe_file(target, immutable=False)`。
- 语义：`immutable=True` 用 `mode=ro&immutable=1` 只读主库文件，忽略 WAL 未 checkpoint 页；`immutable=False` 用 `mode=rw` + `PRAGMA query_only=1` + `busy_timeout`，读活库真实状态。preimport 副本由在线备份 API 生成（含 WAL 已提交页），两侧口径一致后逐表计数才可比。
- 未放松任何判据：计数仍要求完全相等，不等即 `preimport_incomplete`、不动替换。

**专项测试**（新增 2 项）：

| 测试 | 做法与断言 |
| --- | --- |
| `test_live_probe_sees_wal_but_immutable_does_not` | 子进程 `journal_mode=WAL` 写入并提交后**保持连接**（不 close、不 checkpoint），就绪文件同步；断言 WAL 存在且非空；`_probe_file(默认 immutable=True)` 读到 `airports=2`（漏 WAL），`_probe_file(immutable=False)` 读到 3；`_snapshot_original` 生成的 preimport 逐表计数等于活库且包含该行 |
| `test_import_compares_preimport_with_wal_aware_live_probe` | spy 记录 `_probe_file` 调用，跑完整导入；断言对目标库的 preimport 复核确实使用 `immutable=False` |

## 2. 修正二：元信息内容严格实配

`verify_backup()` 在原有"成对 + 字段存在 + sha/大小/结构摘要/format"之上，新增 `META_CONTENT_FIELDS = (tables, structure_profile, schema_version, tasks, key_digests)`：逐项与备份库实际重算结果比较，任一不等即 `meta_<field>_mismatch`。`REQUIRED_META_FIELDS` 同步补入 `key_digests`（此前导出会写但未列入必备）。`import` 仍调用同一 `verify_backup()`，校验失败发生在进维护态之前。

**专项测试**（新增 1 项，覆盖 5 个字段）：`test_meta_content_tampering_rejected` 对 `tables`（改为 `{"airports":999}`）、`structure_profile`（改为未注册值）、`schema_version`（改为不存在版本）、`tasks`（改为异形字典）、`key_digests`（改为全零摘要）逐一篡改，断言：`verify` 返回 `ok=False` 且错误码含 `meta_<field>_mismatch`；`cli import` 退出码 `2`；`maintenance.json` 不存在；目标库逐表计数不变。

## 3. 修改文件

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 23,411 | 600 | `a011860f3677d58bf1395b734f72b34853bebfda` |
| `tests/test_backup_manual.py` | 23,816 | 619 | `766862140206d71a82a6c67aaeaeb6715e7c265e` |

未改动 `db.py`、`cli.py`、`migrate.py`、`gate.py`、`routes.py` 及任何迁移逻辑。

## 4. 测试结果

**专项**：`python3 -m pytest -q tests/test_backup_manual.py` → **22 passed（108.83 s）**（上一轮 19 项 + 本轮 3 项）。

**回归（分批）**

| 批次 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py` | **359 passed, 1 skipped**（82.75 s） |
| 2 | `pytest -q tests/test_migration_baseline.py` | **15 passed**（38.13 s） |
| 3 | `pytest -q tests/test_migration_state.py` | **40 passed**（216.07 s） |
| 维护态 | `pytest -q tests/test_maintenance_lock.py` | **63 passed**（2.62 s） |

合计 **414 passed / 1 skipped**（上轮 411，本轮 +3 项新增测试；无回归、无新 skip）。

## 5. 操作命令（不变）

```bash
python -m backend.database.cli backup --out /backup --label manual --json
python -m backend.database.cli verify --file /backup/nodepool-<时间>-manual-<hex>.db --json
python -m backend.database.cli import --file /backup/nodepool-<时间>-manual-<hex>.db --json
python -m backend.database.cli status --json
```

退出码：`0` 成功 / `2` 拒绝（含元信息不实配）/ `4` 中止（连接未关闭、句柄存在、导入失败，维护态保持）。

## 6. 文档同步

- 总体设计方案 v1.10 §11：元信息校验补"内容逐项实配"；preimport 补"活库读法 `immutable=False`，不得用冻结读法误判"。
- P-1 实施计划 v1.10：§2.3 元信息条目改写为内容实配；§3.3 步骤 7 明确 `_probe_file(target, immutable=False)`；§5 增 PBT-17/18 并更新 PBT-16。

## 7. 边界声明

只在隔离测试环境施工；未连接、未读取、未修改 NAS 生产数据库与容器；未执行生产导入或迁移；未改无关迁移逻辑；未进 P-1.8。**到此停止，等待 ChatGPT 最终复审。**
