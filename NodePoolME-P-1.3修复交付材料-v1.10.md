# NodePoolME P-1.3 修复交付材料（v1.10）｜Restore Failure Safety

修复对象：`backend/database/backup.py` 的 `restore_set()`（及同步收紧的 `_rollback_to_pre_restore()`）
修复范围：仅此一项，无其它改动；未进入 P-1.4；未接触生产库、未在 NAS 执行任何恢复。
代码仓库：`laoXuHome/NodePoolME`（`main`）
修复前提交：`ce0c018`（P-1.3 首版）
修复提交：`1e9278ddb107f4825644fe67d9c37ed8a0c99d2e`

---

## 1. 问题确认

原顺序为：`verify_set` → `pre-restore` 快照 → 关闭连接 → 查句柄 → **删除目标库 `-wal/-shm`** → 复制备份到临时文件 → `fsync` → 校验临时文件 → `os.replace`。

风险确实成立：第 5 步之后目标库仅剩主文件。若此时复制、`fsync` 或临时库校验失败，原库中**只存在于 WAL 的已提交事务**就随 `-wal` 一起消失，且没有任何代码路径会还原它。

实测构造（新库 + `wal_autocheckpoint=0`，5 条已提交行只落在 WAL）：

```
原库 logs 行数: 6
只复制 db 主文件（相当于旧代码删掉 -wal 后的状态）行数: 1
```

即旧顺序下 5 行已提交数据会被抹掉。

---

## 2. 修复设计

`restore_set()` 改为两阶段，核心原则：**在临时库完成复制、`fsync`、完整校验之前，不删除、不改名、不打开写模式地触碰目标库任何文件**。

### 阶段 A（只读准备，目标库零改动）

1. `verify_set(source_set)` — 备份集无效直接抛 `backup_invalid`。
2. `snapshot_set("pre-restore", src_db=target)` — 恢复前快照，供兜底回退（此后不再改动它）。
3. `close_connections()` 关闭本进程连接。
4. `holders_of(target)` — 仍有其它进程持有则抛 `restore_handles_present`。
5. `shutil.copyfile` 复制备份 `db` 到同卷临时文件 `restore-<nonce>.db` + `_fsync_file`。
   失败 → 清理临时文件，抛 `restore_stage_failed`；**目标库 `db/-wal/-shm` 字节不变**。
6. `_verify_staged_db(tmp, manifest)`：`integrity_check`、`foreign_key_check`、17 张基准表齐全、逐表计数与 manifest 一致、`tasks` 存在性与行数一致。
   失败 → 清理临时文件，抛 `restore_verify_failed`；目标库仍字节不变。

### 阶段 B（隔离替换，可原样还原）

7. `_quarantine_target(target, nonce)`：把 `db`、`-wal`、`-shm` **改名**为 `*.restore-prev-<nonce>`（**不是删除**），并 `fsync` 目录；中途失败立即把已改名的文件还原再抛错。
8. `os.replace(tmp, target)` + `fsync` 目录。
9. `_post_restore_checks()`：`init_db()` → `integrity_check` → 逐表计数与 manifest 比对。
10. 任一步失败：先删除新库及其 `-wal/-shm`，再把隔离副本按 `-wal/-shm` → `db` 顺序改回原名并 `fsync` 目录 → 抛 `restore_replace_failed` 或 `restore_rolled_back`。隔离副本本身不可用（改名失败等）时，才退回 `_rollback_to_pre_restore()`（同样改为「临时文件 + fsync + 校验 + 隔离替换」）。
11. 全部成功后：丢弃隔离副本与临时文件，再执行可选 `publish`。

要点对照交付要求：

| 要求 | 实现 |
| --- | --- |
| 新库复制/fsync/校验完成前不删目标库任何文件 | 阶段 A 全程只读，删除/改名集中在阶段 B |
| 替换失败时原库及 WAL 状态可安全恢复 | 原库三件改名隔离而非删除，失败原样改名还原（WAL 帧不入库即仍在） |
| pre-restore 快照仍有效 | 步骤 2 生成后不再触碰，回退失败时才使用；实跑复核 `verify_set` 仍 `ok` |
| 不靠忽略异常/降标准/跳过 WAL 检查 | 校验项不减反增（fk、逐表计数、tasks 形态、隔离还原失败再退 pre-restore，双层兜底） |

---

## 3. 失败路径全量复核

| 路径 | 结果码 | 目标库状态 | 遗留物 |
| --- | --- | --- | --- |
| 备份集无效 | `backup_invalid` | 未触碰 | 无 |
| 本进程连接未关/第三方句柄 | `restore_handles_present` | 未触碰 | 无 |
| 复制失败 | `restore_stage_failed` | `db/-wal/-shm` 字节不变 | 临时文件已清理 |
| `fsync` 失败 | `restore_stage_failed` | 同上 | 无 |
| 临时库校验失败 | `restore_verify_failed` | 同上 | 无 |
| 隔离改名失败 | `restore_replace_failed` | 已改名文件被立即还原 | 无 |
| `os.replace` 失败 | `restore_replace_failed` | 隔离副本原样还原（含 WAL） | 无 |
| 恢复后校验失败 | `restore_rolled_back` | 隔离副本还原；失败则 pre-restore | 无 |
| 全链路回退失败 | `restore_failed`（明确报错，不伪装成功） | 取决于底层，错误信息含两段原因 | — |

---

## 4. 测试

### 4.1 新增专项（目标库均为「存在未 checkpoint 已提交 WAL 帧」的库）

| 测试 | 注入点 | 断言 |
| --- | --- | --- |
| `test_restore_copy_failure_leaves_original_untouched` | `shutil.copyfile` 对 `restore-*` 抛错 | `restore_stage_failed`；db/-wal/-shm 完全不变；行数不变；无临时文件 |
| `test_restore_fsync_failure_leaves_original_untouched` | `_fsync_file` 对 `restore-*` 抛错 | 同上 |
| `test_restore_staged_verify_failure_leaves_original_untouched` | `_verify_staged_db` 抛 `restore_verify_failed` | 同上；断言临时文件被清理 |
| `test_restore_replace_failure_preserves_original_wal` | `os.replace` 对 `restore-*` 抛错 | `restore_replace_failed`；三件还原；`logs` 行数含 WAL 行不变 |
| `test_post_restore_check_failure_restores_original_with_wal` | `_post_restore_checks` 抛错 | `restore_rolled_back`；三件回到原状；WAL 行仍在 |
| `test_restore_normal_path_on_wal_database_keeps_wal_rows` | 无 | 正常恢复成功；逐表计数与 manifest 全等 |

构造说明：先用 `init_db()` 建库，再以 `wal_autocheckpoint=0` 写入 5 行并 `commit`，保持写入连接打开时把 `db/-wal/-shm` 三件复制为目标库；断言「仅复制主文件」版本行数更少，从而证明数据确实停留在 WAL。计数与状态读取一律用 `mode=ro`，避免读写连接在关闭时触发 checkpoint 破坏前提。

### 4.2 测试数量

| 范围 | 数量 | 通过 | 失败 |
| --- | --- | --- | --- |
| `tests/test_backup_set.py`（P-1.3 专项） | 22 | 22 | 0 |
| 全量回归 | 240 | 240 | 0 |

（P-1.2 基线 218 + P-1.3 首版 16 + 本次修复新增 6 = 240。）

### 4.3 回归证明：新测试确实抓得住旧 bug

把 `backend/database/backup.py` 回退到修复前版本（`ce0c018`）再跑新增 6 项：

```
5 failed, 1 passed, 16 deselected
FAILED test_restore_copy_failure_leaves_original_untouched
FAILED test_restore_fsync_failure_leaves_original_untouched
FAILED test_restore_staged_verify_failure_leaves_original_untouched
FAILED test_restore_replace_failure_preserves_original_wal
FAILED test_post_restore_check_failure_restores_original_with_wal
```

修复后同组 6 项全通过。唯一在旧代码上也通过的是「正常恢复」（成功路径行为等价）。

---

## 5. 故障注入实跑证据（独立副本 + 临时目录）

```
原库初始: db 163840B sha 7796e7ae346f | -wal 8272B sha b46643a05b01 | -shm 32768B | logs 6
只复制 db 主文件（模拟旧代码删 WAL 后）logs: 1  vs 原库 6 → 5 行只在 WAL

A 复制失败:     restore_stage_failed   | db/-wal/-shm 完全不变: True | logs 6->6 | 临时文件: []
B fsync 失败:   restore_stage_failed   | 完全不变: True | logs 6->6 | 临时文件: []
C 临时库校验失败: restore_verify_failed | 完全不变: True | logs 6->6 | 临时文件: []
D 替换失败:     restore_replace_failed | db/-wal 字节不变，隔离副本原样还原 | logs 6->6
E 恢复后校验失败: restore_rolled_back   | 完全不变: True | logs 6->6
F 正常恢复:     ok=True | pre_restore=nodepool-…-pre-restore | logs=6 | integrity=ok
   逐表计数与 manifest 一致: True | 隔离副本残留: [] | pre-restore 集合仍有效: True
```

说明：`-shm` 是 WAL 索引，可从 WAL 重建，字节值不保证一致（测试对 `-shm` 只断言存在性与大小，对 `db`/`-wal` 断言 sha256 不变）。

---

## 6. 代码交付

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/backup.py` | 34,130 | 898 | `9499900fe823de0e8be3dd92be5c22da84cbfd72` |
| `tests/test_backup_set.py` | 29,743 | 715 | `a6b08ef618b2ec22f596399ad6d7296e442b304d` |

Commit：`1e9278ddb107f4825644fe67d9c37ed8a0c99d2e`，已推送 `main`，远端 `contents` API 复核 `size/sha` 与本表一致。
本阶段未修改 `db.py`、`migrate.py`、通用 SCHEMA、`init_db()`、`routes.py`、Compose/镜像/运行配置。

---

## 7. 边界与残留

- 未接触生产数据库，未在 NAS 执行恢复，未创建/删除/覆盖生产备份。
- 生产结构归属（`alter_history` / `fresh_init`）仍待 NAS 只读实测，本材料不作「已验证」表述。
- `pre-restore` 仍在恢复开始时生成，其有效性依赖备份目录可用空间与 `min_free_mb` 门槛；空间不足会直接抛 `snapshot_failed` 且不改动目标库。
- L3 容器级演练（PT-05）仍属后续阶段，本次为文件级恢复 + 注入验证。
- 若隔离改名中途失败且还原也失败，会抛 `restore_replace_failed` 并保留 `*.restore-prev-*` 文件供人工处置（不静默删除）。

已停止在本修复，等待重新验收。
