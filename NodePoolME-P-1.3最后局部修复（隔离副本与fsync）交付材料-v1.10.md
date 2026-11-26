# NodePoolME P-1.3 最后局部修复交付材料（v1.10）｜隔离副本缺失与目录持久化

修复对象：`backend/database/backup.py` 的 `_restore_moved()` / `_unquarantine()`，及 `_quarantine_target()`、`restore_set()`、`_rollback_to_pre_restore()` 的判定逻辑。
修复范围：仅此一处；未进入 P-1.4；未接触生产库、未执行 NAS 恢复；未改 v1.10 总体设计与 P-1 实施计划。
代码仓库：`laoXuHome/NodePoolME`（`main`）
上一提交：`82e9c9a9de4760c8b510a9492a5c4dceca98268d`
本次提交：`a2993236856c428fb97c7085c7591bd3568175c0`

---

## 1. 问题确认

```python
for src, dst in ordered:
    try:
        if dst.exists():
            os.replace(dst, src)
    except OSError:
        ...
```

两处缺陷：

1. **隔离副本缺失被当成成功**：`pairs` 中的每一项都代表已成功隔离的原始文件，`dst` 理应存在；但 `dst` 不存在时代码直接跳过，不记 `leftover`，函数可能返回空列表，调用方据此宣称"原库已完整还原"——实际原库最关键的 `db` 已不在原路径。
2. **目录 `fsync` 被静默忽略**：还原后 `_fsync_dir()` 的 `OSError` 被 `except OSError: pass` 吞掉，改名是否落盘未确认，却仍返回"成功"。

---

## 2. 修复语义

新增结果对象，让"是否真的还原成功"成为可判定的显式状态：

```python
@dataclass
class _RestoreOutcome:
    leftover: list[Path]       # 改名还原失败、已保留的隔离副本
    missing: list[Path]        # 应存在却缺失的隔离副本
    persist_error: str | None  # 目录 fsync 失败原因
    target_dir: Path | None
    def ok(self) -> bool       # leftover/missing/persist_error 全空才为真
    def detail(self) -> str    # 直接用于错误信息
```

规则：

| 情形 | 处理 |
| --- | --- |
| `dst` 不存在 | 记入 `missing`，**绝不视为还原成功**，不清理任何文件 |
| `os.replace` 失败且 `dst` 仍存在 | 记入 `leftover`（完整路径），保留副本 |
| `os.replace` 失败且 `dst` 已消失 | 记入 `missing` |
| 还原后目录 `fsync` 失败 | 记 `persist_error`（含目录与异常文本），整体判为未成功 |
| `remove_new=True`（仅隔离全部完成后） | 先清新库 `db/-wal/-shm`，再还原；新文件与原始文件判定严格区分 |

调用方改为按 `outcome.ok()` 判定：

- `_quarantine_target()` 中途失败：`outcome` 非 ok → `restore_quarantine_failed`，信息含"隔离副本缺失/改名还原失败/目录 fsync 失败"与完整路径。
- `restore_set()` 替换或恢复后校验失败：`outcome` 非 ok → `restore_rolled_back_leftover`（含 `detail()`），不再宣称已还原。
- `_rollback_to_pre_restore()`：`outcome` 非 ok → `rollback_leftover`。
- 不再有 `except OSError: pass`；残留副本一律保留，无静默删除。

---

## 3. 新增故障注入测试（目标库均含未 checkpoint 已提交 WAL 数据）

| 测试 | 注入 | 断言 |
| --- | --- | --- |
| `test_missing_quarantine_copy_reports_leftover_not_success` | DB 隔离成功后立即删除其隔离副本，再让 WAL 改名失败 | `restore_quarantine_failed`；信息含"隔离副本缺失"与副本路径；原路径无 `db`（不宣称已还原）；WAL 字节不变；SHM 未被删 |
| `test_restore_rename_failure_reports_full_path` | WAL 改名失败 + DB 还原再次失败 | 信息含"改名还原失败"与绝对路径；隔离副本保留且 sha256 等于原 DB；WAL 字节不变 |
| `test_fsync_failure_reports_persistence_unconfirmed` | 目标目录 `_fsync_dir` 抛错（仅目标目录，不影响 pre-restore 发布） | `restore_quarantine_failed`；信息含 `fsync`、"持久化未确认"、目录路径；DB/WAL 字节不变，但整体不得判为成功 |

---

## 4. 回归与反向验证

| 范围 | 数量 | 通过 | 失败 |
| --- | --- | --- | --- |
| `tests/test_backup_set.py`（P-1.3 专项） | 28 | 28 | 0 |
| 全量回归 | 246 | 246 | 0 |

（P-1.2 基线 218 + P-1.3 首版 16 + restore 失败安全 6 + 隔离回滚 3 + 本次 3 = 246。）

**反向验证**：将 `backup.py` 回退到 `82e9c9a`（上一版）后跑新增 3 项：

```
3 failed, 24 deselected
FAILED test_missing_quarantine_copy_reports_leftover_not_success
FAILED test_restore_rename_failure_reports_full_path
FAILED test_fsync_failure_reports_persistence_unconfirmed
```

修复后同组全部通过，说明新增测试确实识别修复前的缺陷。

---

## 5. 实跑证据（独立副本 + 临时目录）

基准库：`db 163,840 B / -wal 8,272 B / -shm 32,768 B`，`logs=6`，其中 5 行为"仅存在于 WAL"的已提交数据。

```
场景1 隔离副本在回滚前缺失: restore_quarantine_failed
   原库: db 92731a5b9170 / -wal 9aa391cf5b6a / logs 6
   失败后: db None / -wal 9aa391cf5b6a / -shm 存在 True / logs 可读 None
   db 不变 False | -wal 不变 True | -shm 未被删 True | 残留副本: []
   错误: 隔离副本缺失（无法还原）：['/tmp/…/live.db.restore-prev-598ac81091676da8']

场景2 隔离副本改名还原失败: restore_quarantine_failed
   原库: db 92731a5b9170 / -wal 9aa391cf5b6a / logs 6
   失败后: db None / -wal 9aa391cf5b6a / -shm 存在 True / logs 可读 None
   db 不变 False | -wal 不变 True | -shm 未被删 True
   残留副本: ['live.db.restore-prev-5ca2a45805e1c188']
   错误: 隔离副本改名还原失败，已保留：['/tmp/…/live.db.restore-prev-5ca2a45805e1c188']

场景3 目录 fsync 失败: restore_quarantine_failed
   原库: db 92731a5b9170 / -wal 9aa391cf5b6a / logs 6
   失败后: db 92731a5b9170 / -wal 9aa391cf5b6a / -shm 存在 True / logs 可读 6
   db 不变 True | -wal 不变 True | -shm 未被删 True | 残留副本: []
   错误: 目录 fsync 失败，还原持久化未确认（/tmp/…）：OSError: inject: fsync dir 失败
```

要点：场景 1、2 中原路径没有 `db`，`logs` 读不到（`None`）——**没有被误报为"已恢复"**，且 WAL 与 SHM 均原样保留或可定位；场景 3 文件内容确实还原（`db`/`-wal` 字节不变），但因 `fsync` 失败被明确判定为"持久化未确认"，不返回成功。

`-shm` 是 WAL 索引、可由 WAL 重建，证据对 `-shm` 只断言"存在且大小未变、未被删除"，对 `db`/`-wal` 断言 sha256 不变。

---

## 6. 代码交付

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 37,538 | 965 | `77f03dad0a955e115cffd29476996fda71ed00d8` |
| `tests/test_backup_set.py` | 39,520 | 923 | `16c0ba42489e71c3cd83a170004a0dbba46a1b81` |

Commit `a2993236856c428fb97c7085c7591bd3568175c0` 已推送 `main`；远端 `contents` API 复核 `size/sha` 与本表一致。
未修改 `db.py`、`migrate.py`、通用 SCHEMA、`init_db()`、`routes.py`、Compose/镜像/运行配置。

---

## 7. 边界与残留

- 未接触生产数据库，未在 NAS 执行恢复，未创建/删除/覆盖生产备份。
- 场景 1/2 会留下"有 `-wal/-shm` 无 `db`"的中间态：`db` 要么已按路径报出缺失，要么完整保存在 `*.restore-prev-<nonce>` 且路径写入错误信息，属可识别、可手工处置的残留，不静默清理。
- 生产结构归属（`alter_history` / `fresh_init`）仍待 NAS 只读实测，本材料不作"已验证"表述。
- L3 容器级演练（PT-05）仍属后续阶段。

已停止在本修复，等待最终验收，未进入 P-1.4。
