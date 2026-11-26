# NodePoolME P-1.3 局部修复交付材料（v1.10）｜隔离副本预检先于目标文件清理

修复对象：`backend/database/backup.py` 的 `_restore_moved()`（引入执行前预检）。
修复范围：仅此一处；未进入 P-1.4；未执行 P-7；未接触生产数据库、未在 NAS 执行恢复；未改 v1.10 总体设计与 P-1 实施计划。
代码仓库：`laoXuHome/NodePoolME`（`main`）
上一提交：`a2993236`（隔离副本缺失与 fsync 修复）
本次提交：`10e03962ec40e9c126af966fed804a29fe80d05b`

---

## 1. 问题确认

原顺序（`remove_new=True`，即隔离已全部完成、替换已发生后回滚）：

1. 删除目标路径上的 `db`、`-wal`、`-shm`（此时它们是刚替换成功的新库文件）；
2. 再逐项检查 `pairs` 的隔离副本 `dst` 是否存在。

若某个隔离副本（尤其是 DB）已经丢失，第 1 步已经把新库删掉，第 2 步才发现原始副本也不在——两侧都没了，等于在已经失败的回滚上再造成一次数据损失。

---

## 2. 修复

在**任何删除/改名之前**先做隔离副本预检：

```python
missing_pre = [dst for _src, dst in pairs if not dst.exists()]
if missing_pre:
    outcome.missing.extend(missing_pre)
    return outcome          # 立即失败返回；此时尚未动过任何目标文件
```

规则：

| 情形 | 行为 |
| --- | --- |
| 所有隔离副本在位 | 才允许后续清理（`remove_new=True` 清新库）与逐项还原 |
| 任一隔离副本缺失 | 缺失路径全部记入 `outcome.missing`，**立即返回**；不删除、不覆盖、不改名任何目标路径文件 |
| `remove_new=False`（部分隔离失败场景） | 同一预检先行；不删除任何尚未隔离的原始文件 |
| `os.replace` 还原失败 | 副本仍存在则记 `leftover`（完整路径），保留副本 |
| 目录 `fsync` 失败 | 仍记 `persist_error`，报告持久化未确认，不判成功 |

预检对 `remove_new=True` / `False` 两类调用统一生效，避免"先恢复一部分、之后才发现另一份副本缺失"。

---

## 3. 新增故障注入测试

| 测试 | 类型 | 断言 |
| --- | --- | --- |
| `test_preflight_missing_copy_blocks_target_cleanup` | 直接调用 `_restore_moved(remove_new=True)`，SHM 隔离副本故意缺失 | `outcome.ok() is False`；`missing` 为该 SHM 副本名；目标 `db/-wal/-shm` 三个哨兵文件字节完全不变；已存在的 DB/WAL 隔离副本未被提前清理 |
| `test_preflight_missing_db_copy_keeps_replaced_library_readable` | 集成：正常完成三件隔离 + 替换 → 恢复后校验失败 → `_unquarantine` 前删除 DB 隔离副本 | 错误码 `restore_rolled_back_leftover`；信息含"隔离副本缺失"与缺失副本绝对路径；目标新库 `db` 仍存在且 sha256 等于备份集 `db`；`integrity_check=ok`；`logs` 等于 manifest 计数；WAL/SHM 隔离副本均未被提前清理 |

构造沿用现有"未 checkpoint、含已提交 WAL 数据"的测试库方式（`wal_autocheckpoint=0` 写入 5 行后复制三件；只读方式计数）。

---

## 4. 测试结果

| 范围 | 数量 | 通过 | 失败 |
| --- | --- | --- | --- |
| `tests/test_backup_set.py`（P-1.3 专项，原有 28 + 新增 2） | 30 | 30 | 0 |
| 全量回归 | 248 | 248 | 0 |

（218 基线 + 16 首版 + 6 restore 失败安全 + 3 隔离回滚 + 3 副本缺失/fsync + 本次 2 = 248。）

### 反向验证（修复前代码）

回退到 `a2993236` 后跑新增 2 项：

```
2 failed, 28 deselected
FAILED test_preflight_missing_copy_blocks_target_cleanup
FAILED test_preflight_missing_db_copy_keeps_replaced_library_readable
```

修复后 2 项均通过，说明测试确实识别"先清理后检查"的缺陷。

---

## 5. 实跑证据（集成场景）

```
备份集: nodepool-20261126-150445-manual | 备份 db sha: 1f5d646f4d49 | manifest logs: 6

结果: restore_rolled_back_leftover
错误信息: 恢复失败（inject: post-check 失败）；原库未确认还原：隔离副本缺失（无法还原）：
          ['/tmp/…/live.db.restore-prev-ae0ec54152c4f6e4']
目标新库 DB 存在: True | sha: 1f5d646f4d49（与备份 db 一致）
新库 integrity: ok | logs: 6（manifest 6）
WAL 隔离副本仍保留: True live.db-wal.restore-prev-ae0ec54152c4f6e4
SHM 隔离副本仍保留: True live.db-shm.restore-prev-ae0ec54152c4f6e4
残留隔离副本总数: 2（未静默删除）
```

结论：预检失败时目标路径上的新库未被删除或覆盖，仍可正常读取；WAL/SHM 隔离副本未被提前清理；整体结果明确为失败，未报告回滚成功。

---

## 6. 代码交付

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 37,921 | 973 | `fad3c8134617f597996b752c435194176ec1ce4d` |
| `tests/test_backup_set.py` | 42,977 | 995 | `2887eb030641e20220df7ddab842ac148031521c` |

Commit `10e03962ec40e9c126af966fed804a29fe80d05b` 已推送 `main`；远端 `contents` API 复核 `size/sha` 与本表一致。
未修改 `db.py`、`migrate.py`、通用 SCHEMA、`init_db()`、`routes.py`、Compose/镜像/运行配置。

---

## 7. 边界与残留

- 未接触生产数据库，未在 NAS 执行恢复，未执行 P-7。
- 预检失败会保留 `*.restore-prev-*` 副本与当前目标文件；错误信息给出缺失副本路径，属可识别、可手工处置的残留，不静默删除。
- 生产结构归属（`alter_history` / `fresh_init`）仍待 NAS 只读实测，本材料不作"已验证"表述。
- L3 容器级演练（PT-05）仍属后续阶段。

已停止在本修复，等待最终验收，未进入 P-1.4。
