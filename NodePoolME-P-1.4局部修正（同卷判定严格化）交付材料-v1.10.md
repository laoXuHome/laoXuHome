# NodePoolME P-1.4 局部修正交付材料（v1.10）｜STATE_DIR 同卷判定严格遵循 §2.6

修正范围：`backend/database/maint.py` 中 `selfcheck_state_dir()` 的数据库文件设备号判定，以及 `tests/test_maint_state.py` 的对应测试。未扩大施工范围，未进入 P-1.5。
上一提交：`bbb7fc98e47966f6ad9ad428b182d96cd6c58102`（P-1.4 首版）
本次提交：`357c90aaf88ed28a37a0327f399dc51beb900ea1`

---

## 1. 改动文件

| 文件 | 字节 | 行 | blob SHA | 变化 |
| --- | --- | --- | --- | --- |
| `backend/database/maint.py` | 25,804 | 639 | `9f1860bb42940693cd5e0c8e228588264ac1fe86` | +57 / −28 |
| `tests/test_maint_state.py` | 30,539 | 766 | `5a930da5c19e4436455181eae53fc2da62a228bd` | +176 / −28 |

远端 `contents` API 复核 `size`/`sha` 与上表一致。`git diff --stat` 仅这两个文件。
未修改 `config.py`、`main.py`、`db.py`、`migrate.py`、`routes.py`；未改两份 v1.10 文档；未接线五个业务入口。

---

## 2. 判定逻辑（严格版）

```python
state_dev = _st_dev(state_dir)                 # 失败 → maint_fs_unsupported + errno
try:
    db_dev = _st_dev(db_path)                  # DB_PATH 存在：必须用文件自身 st_dev
except FileNotFoundError:                      # 唯一允许退回目录锚点的情形
    db_dev = _st_dev(db_dir)                   # 目录 st_dev 作为同一挂载锚点
except OSError as e:                           # PermissionError / EIO / EBUSY / 其它
    return finish(False, ERR_MAINT_FS_UNSUPPORTED, e.errno, "…失败关闭…")
if db_dev != state_dev:
    return finish(False, ERR_STATE_DIR_CROSS_DEVICE, None, …)   # 拒绝迁移，业务照常
```

要点：

1. **DB_PATH 已存在 ⇒ 必须用文件自身的 `st_dev`**。即使它与父目录不同，也不退回父目录——原「文件与父目录不一致就退回父目录」的放宽逻辑已删除。
2. **只有 `FileNotFoundError`** 才允许使用库所在目录的 `st_dev` 作锚点（首次部署、库文件尚未创建）。
3. **其它 `stat` 异常一律失败关闭**：`PermissionError` / `EIO` / `EBUSY` 等返回 `maint_fs_unsupported` 并带 `errno`，不伪装成文件不存在、不回退锚点、不进入探针。
4. 设备号不一致 ⇒ `state_dir_cross_device`，只禁用迁移入口，业务启动与接口不受影响（PT-14b 断言 `/healthz`、登录、`/api/nodes` 均 200）。
5. 新增 `_st_dev()` 作为**唯一**设备号取值点，使测试能在 `os.stat` 语义边界精确注入，且不波及 `pathlib`/其它模块对 `os.stat` 的使用。

---

## 3. 新增针对性测试（5 项，含参数化共 7 个用例）

| 用例 | 注入 | 断言 |
| --- | --- | --- |
| `test_pt14b_db_file_dev_differs_from_parent_uses_file_dev` | db 文件 900，父目录 700，state 900 | `ok=True`；`chk.db_dev == 900`（用文件而非父目录）；八步探针全 true |
| `test_pt14b_state_matches_parent_but_not_db_file_is_cross_device` | db 文件 900，父目录 700，state 700 | `cross_device`；`db_dev=900, state_dev=700`；探针未启动；STATE_DIR 内无残留 |
| `test_pt14b_state_matches_db_file_but_not_parent_is_ok` | db 文件 900，父目录 700，state 900 | `ok=True`；`db_dev=900, state_dev=900`（按文件设备号判同卷） |
| `test_pt14b_db_absent_allows_parent_dir_anchor` | db 抛 `FileNotFoundError`，父目录 700：state 700→通过；state 900→跨卷 | 允许目录锚点；不创建库文件；两种取值分别 `ok` / `cross_device` |
| `test_pt14b_db_stat_error_fails_closed[PermissionError/EIO/EBUSY]` | db stat 抛对应异常，父目录 700，state 900 | `maint_fs_unsupported`（**不是** `cross_device`）；`errno` 与注入一致；探针未启动；detail 含「失败关闭」；无残留 |

设备号差异全部通过 monkeypatch 注入，不做真实挂载操作。

**测试临时目录的一处必要调整（如实说明）**：本机 `/tmp` 上「文件」与「目录」的 `st_dev` 不同（实测 48 vs 47，overlay 沙箱特性），在该文件系统上任何正常同卷布局都会被严格判定判成跨卷（已单独复现：`/tmp` 下 `os.stat(dir).st_dev=47`、`os.stat(file).st_dev=48`）。因此 `env` 夹具的临时根目录改到 `$HOME`（实测文件与目录同为 53，与生产 btrfs 单卷形态一致），用例仍在真实文件系统上跑真写/真 fsync/真 rename。**PT-24 仍留在 `/tmp`**，因为只有该文件系统上「只读打开不改变 `-wal` mtime」成立，能真正断言计划原文的「大小与 mtime 均不变」；该用例只对设备号做注入（`state`、`db`、父目录同为 47），文件系统行为不做任何伪造。`test_pt14_selfcheck_on_real_state_dir` 在单进程混跑中若遇到「DB_PATH 被其它模块重定向到 `/tmp`」这种沙箱伪差异会 `skip` 并注明原因；单独运行该文件时它是通过（见第 4 节 72 passed）。

---

## 4. 测试结果

### P-1.4 专项（`tests/test_maint_state.py`，单独运行）

```
72 passed, 1 warning in 68.97s
```

PT-14（9）：`selfcheck_full_chain` / `cached_once` / `cross_device_rename_reports_exdev`(errno 18) / `rename_failure_reports_errno`(22) / `dir_fsync_failure_reports_errno`(22) / `readback_mismatch`(errno 5) / `mkdir_failure_reports_errno` / `on_real_state_dir` / `same_device_check_uses_db_path_st_dev` —— 全部 PASSED。

PT-14b（13，含新增 7 个用例）：原有 6 项 + 新增 7 项全部 PASSED（含 `cross_device_keeps_business_ok`：`/healthz` 200、登录 200、`/api/nodes` 200）。

PT-24（2）：`probe_never_touches_database`（WAL 未 checkpoint 库：db sha256、`-wal` 大小与 mtime、`-shm` 存在性、目录条目集合前后完全一致；STATE_DIR 只有 `maintenance.json`）、`selfcheck_failure_creates_no_database_files` —— PASSED。

### 全量回归（沿用分批方式）

```
--ignore=tests/test_migration_baseline.py     304 passed, 1 skipped
tests/test_migration_baseline.py               15 passed
合计 319 passed / 0 failed / 1 skipped
```

`1 skipped` 即上文 `test_pt14_selfcheck_on_real_state_dir` 在混跑时遇到 `/tmp` 伪差异的显式跳过（单独运行该文件时通过）。`test_migration_baseline.py` 的单进程混跑问题与上一轮相同且仍在改动前即可复现（`NODEPOOL_DATA_DIR` 导入期覆盖导致其依赖的仓库开发库形态变成全新库），本阶段未修改该文件，故仍分批执行。

### 反向验证

把旧放宽逻辑重新注入（`if db_dev != 父目录 dev: db_dev = 父目录 dev`）后跑新增用例：

```
3 failed  test_pt14b_db_file_dev_differs_from_parent_uses_file_dev
          test_pt14b_state_matches_parent_but_not_db_file_is_cross_device
          test_pt14b_state_matches_db_file_but_not_parent_is_ok
```

即：旧实现在「文件与父目录设备号不同」时会用错设备号（该判跨卷的放行、该放行的误判），新测试能逐条识别；恢复严格实现后全部通过。

---

## 5. 行为对照（旧 → 新）

| 情形 | 旧实现 | 新实现 |
| --- | --- | --- |
| 文件 900 / 父目录 700 / state 900 | 退回 700 判 → **误判跨卷** | 用 900 → 同卷通过 |
| 文件 900 / 父目录 700 / state 700 | 退回 700 判 → **误判同卷（放行）** | 用 900 → 跨卷拒绝 |
| 库文件不存在 | 目录锚点（`exists()` 判定） | 仅 `FileNotFoundError` 才用目录锚点 |
| 库 stat 抛权限/IO 异常 | `OSError` 失败关闭（但 `exists()` 先吞掉部分异常） | 显式失败关闭 + errno，绝不退回锚点 |

---

## 6. 边界声明

- 未接触生产数据库，未在 NAS 生产环境执行任何操作，未执行 P-7。
- 未修改 v1.10 总体设计与 P-1 实施计划；未修改 `config.py`、`main.py`（本次修正无需改动它们）。
- 未修改 `db.py`、`migrate.py`、`routes.py`；未接线五个业务入口。
- 生产 `structure_hash` 归属仍未确认，本材料不作「生产结构已验证」表述。

已停止在本修正，等待审查验收；未进入 P-1.5。
