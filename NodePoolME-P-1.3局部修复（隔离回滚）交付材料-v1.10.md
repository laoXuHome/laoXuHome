# NodePoolME P-1.3 局部修复交付材料（v1.10）｜隔离中途失败的回滚安全

修复对象：`backend/database/backup.py` 的 `_quarantine_target()` 与 `_unquarantine()`（及其调用方 `restore_set()`、`_rollback_to_pre_restore()`）
修复范围：仅此一处交互问题；未进入 P-1.4；未接触生产库、未执行 NAS 恢复；未修改 v1.10 总体设计与 P-1 实施计划。
代码仓库：`laoXuHome/NodePoolME`（`main`）
上一提交：`1e9278ddb107f4825644fe67d9c37ed8a0c99d2e`
本次提交：`82e9c9a9de4760c8b510a9492a5c4dceca98268d`

---

## 1. 问题确认

`_quarantine_target()` 逐个改名 `db` → `-wal` → `-shm`。中途某步 `os.replace` 失败时，已隔离的文件需要还原，但**尚未隔离的原始文件仍在原路径**；旧的 `_unquarantine()` 却无条件先删 `目标.db`、`目标.db-wal`、`目标.db-shm`，于是：

- 场景 1（DB 改名成功、WAL 改名失败）：`-wal` 从未被移走，却被当作"新库 sidecar"删除 → WAL 中已提交数据丢失。
- 场景 2（DB、WAL 成功、SHM 失败）：原始 `-shm` 被误删。
- 场景 3（部分隔离后还原再次失败）：旧实现只返回 bool，既不保留隔离副本也不说明残留位置。

---

## 2. 修复语义

| 概念 | 判定方式 | 允许的操作 |
| --- | --- | --- |
| 已成功隔离的原始文件 | 出现在 `pairs` 中（改名成功并记录） | 可改名还原；还原失败则保留 |
| 尚未隔离、仍在原路径的原始文件 | 不在 `pairs` 中 | **只能保持原样，禁止删除/覆盖** |
| 替换后产生的新文件 | 仅当隔离**全部完成**且已尝试 `os.replace` 后，目标路径上的 `db/-wal/-shm` | 才允许清理 |

具体改动：

1. `_quarantine_target()` 中途失败 → 调 `_restore_moved(pairs, remove_new=False)`：
   - 只对 `pairs` 里的文件做 `隔离副本 → 原名` 改名，**不删除任何原路径文件**；
   - 还原顺序 `-wal/-shm` → `db`，避免"有 wal 无 db"的中间态；
   - 全部还原成功：抛 `restore_quarantine_failed`（信息说明"已将已隔离文件原样退回"）；
   - 有还原失败：保留失败者的 `*.restore-prev-*`，抛 `restore_quarantine_failed`，**错误信息列出完整残留路径**。
2. `_unquarantine()` 改为 `_restore_moved(pairs, remove_new=True)`，返回"未能还原的隔离副本列表"：
   - 仅在隔离全部完成、替换已尝试（失败）后调用，此时目标路径上的文件才确定属于新库；
   - 先清新库 `db/-wal/-shm`，再还原隔离副本；
   - 返回非空 → 调用方抛 `restore_rolled_back_leftover`（含路径），**不再退 pre-restore 覆盖**，避免在未知状态上再写。
3. `_rollback_to_pre_restore()` 使用同一语义：还原残留时抛 `rollback_leftover` 并保留副本。
4. 校验标准未降低：临时库仍做 integrity/fk/17 表/逐表计数/tasks 形态校验；异常一律转成明确的 `BackupError` 错误码，没有 `except: pass`。

---

## 3. 新增故障注入测试

目标库均为「存在未 checkpoint 已提交 WAL 帧」的库（`wal_autocheckpoint=0` 写入 5 行后复制 `db/-wal/-shm` 三件；所有计数与状态读取用 `mode=ro`，避免关闭连接触发 checkpoint 破坏前提）。

| 测试 | 注入 | 断言 |
| --- | --- | --- |
| `test_quarantine_fails_on_wal_keeps_original_db_and_sidecars` | `-wal` 隔离改名抛错 | 错误码 `restore_quarantine_failed`；DB sha256 不变；**WAL sha256 不变**；SHM 未被删；WAL 中已提交行仍可读（6 行）；无 `*.restore-prev-*` 残留 |
| `test_quarantine_fails_on_shm_keeps_wal_data_readable` | `-shm` 隔离改名抛错 | DB/WAL sha256 不变；SHM 未被删；行数仍为 6；无残留 |
| `test_quarantine_rollback_failure_keeps_quarantine_copy` | `-wal` 改名失败 + DB 还原再次失败 | 错误码 `restore_quarantine_failed`；错误信息含 `.restore-prev-` 完整路径；隔离副本保留且 sha256 等于原 DB；未隔离的 WAL/SHM 内容不变；原路径没有出现新库文件（无"半个库"） |

---

## 4. 测试数量

| 范围 | 数量 | 通过 | 失败 |
| --- | --- | --- | --- |
| `tests/test_backup_set.py`（P-1.3 专项） | 25 | 25 | 0 |
| 全量回归 | 243 | 243 | 0 |

（P-1.2 基线 218 + P-1.3 首版 16 + restore 失败安全 6 + 本次 3 = 243。）

### 回归证明：新测试确实抓得住旧缺陷

把 `backup.py` 回退到上一提交（`1e9278dd`）后跑新增 3 项：

```
3 failed, 22 deselected
FAILED test_quarantine_fails_on_wal_keeps_original_db_and_sidecars
FAILED test_quarantine_fails_on_shm_keeps_wal_data_readable
FAILED test_quarantine_rollback_failure_keeps_quarantine_copy
```

修复后同组全部通过。

---

## 5. 实跑证据（独立副本 + 临时目录）

```
原库: db 163840B sha 3c7e18231e14 | -wal 8272B sha 6225c78d3e42 | -shm 32768B | logs 6

场景1 DB 成功 / WAL 改名失败: restore_quarantine_failed
   db 字节不变: True | -wal 字节不变: True | -shm 未被删: True
   WAL 已提交行（停写前 6）: 6 | 隔离副本残留: []
   错误: 隔离中断，已将已隔离文件原样退回：inject: WAL 改名失败

场景2 DB+WAL 成功 / SHM 改名失败: restore_quarantine_failed
   db 字节不变: True | -wal 字节不变: True | -shm 未被删: True
   WAL 已提交行（停写前 6）: 6 | 隔离副本残留: []
   错误: 隔离中断，已将已隔离文件原样退回：inject: SHM 改名失败

场景3 部分隔离 + 还原再次失败: restore_quarantine_failed
   db 字节不变: False（DB 位于隔离副本，未还原）| -wal 字节不变: True | -shm 未被删: True
   隔离副本残留: ['live.db.restore-prev-85a55b6448d34811']
   错误: 隔离中断（inject: WAL 改名失败）；以下隔离副本未能还原，已保留待人工处置：
        ['/tmp/…/live.db.restore-prev-85a55b6448d34811']
   保留副本: live.db.restore-prev-85a55b6448d34811 | sha 3c7e18231e14 | 163840 字节（与原库 DB 一致）
   目标路径 db 存在: False | -wal: True | -shm: True → 未静默删除，残留可定位
```

`-shm` 是 WAL 索引、可由 WAL 重建，测试与证据对 `-shm` 只断言"存在且大小未变、未被删除"，对 `db`/`-wal` 断言 sha256 不变。

---

## 6. 代码交付

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 36,245 | 935 | `657cade9cd3397b2a1e16eeb662472315cd15475` |
| `tests/test_backup_set.py` | 35,268 | 835 | `78270c6759e29c95d7922073a07ba2daeb30c75e` |

Commit `82e9c9a9de4760c8b510a9492a5c4dceca98268d` 已推送 `main`；远端 `contents` API 复核 `size/sha` 与本表一致。
未修改 `db.py`、`migrate.py`、通用 SCHEMA、`init_db()`、`routes.py`、Compose/镜像/运行配置。

---

## 7. 边界与残留

- 未接触生产数据库，未在 NAS 执行恢复，未创建/删除/覆盖生产备份。
- 场景 3 下若 DB 还原失败，原路径会出现"有 `-wal/-shm` 无 `db`"的中间态；此时 DB 完整保存在 `*.restore-prev-<nonce>`，错误信息给出绝对路径，属可识别、可手工恢复的残留（不做静默清理）。
- 生产结构归属（`alter_history` / `fresh_init`）仍待 NAS 只读实测，本材料不作"已验证"表述。
- L3 容器级演练（PT-05）仍属后续阶段。

已停止在本修复，等待重新验收。
