# NodePoolME P-1.3 交付材料（v1.10）

交付对象：ChatGPT 项目负责人
代码仓库：`laoXuHome/NodePoolME`（`main`）
施工基线：`e572916`（P-1.2 修正后）→ 本阶段提交 `ce0c018`
施工范围：v1.10 总体设计 / P-1 实施计划 §2.1、§2.3、§2.4、§3.3、§3.4 中 P-1.3 备份集部分。未触碰 P-1.4 及后续阶段。

---

## 1. 实际修改文件

| 文件 | 性质 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- | --- |
| `backend/database/backup.py` | 新增 | 29,286 | 787 | `71412f99b020da68b67b762160de4876254fa3a9` |
| `tests/test_backup_set.py` | 新增 | 22,162 | 551 | `3f0cc4ffdeb4718fd0b298f3368b5c7b1a783a43` |

Git commit：`ce0c0188178f15f950e36668f6fe35b8decdb32d`（`feat(P-1.3): 备份集实现…`）
本阶段**未修改**任何既有文件：`db.py`、`migrate.py`、通用 SCHEMA、`init_db()`、`routes.py`、Compose/镜像/运行配置均无改动（`git diff --stat` 为空，仅两个未跟踪文件被加入）。

### backup.py 各接口用途

| 接口 | 用途 |
| --- | --- |
| `snapshot_set(stage, *, src_db, backup_dir, stop_write, min_free_mb, verify)` | 用 `sqlite3.backup()` 从源库在线生成一致快照，写 `.tmp-<nonce>` 三件套 → 逐个 fsync → 目录 fsync → `os.replace` 成名 → `fsync(BACKUP_DIR)` |
| `verify_set(set_dir, *, live_source, require_source_compare)` | L1 结构 + L2 内容校验，返回结构化 `{ok,l1,l2,errors,tables,tasks}` |
| `restore_set(set_dir, *, db_path, backup_dir, close_connections, publish)` | 九步安全恢复（验证→pre-restore→关连接→查句柄→删 sidecar→同卷临时文件 fsync→`os.replace`→恢复后校验→失败回退） |
| `prune(backup_dir, *, keep_days, keep_daily, now)` | 滚动清理，只删有效 `daily`/`manual`；`pre-migrate`/`pre-restore` 永久保护；半成品/无效集不删 |
| `list_sets` / `valid_sets` / `latest_set` | 审计列表（含半成品与无效）／仅三件齐全且校验通过的集合／最新有效集合 |
| `holders_of(db_path)` | 扫 `/proc/*/fd`，返回仍持有 `db/-wal/-shm` 的**其它进程**（排除自身） |
| `business_counts` / `_digest_rows` | 业务表计数与关键表行摘要（`airports`/`nodes`/`settings`/`test_groups`） |

关键常量：`STAGES=("pre-migrate","daily","manual","pre-restore")`、`SET_PREFIX="nodepool-"`、`TMP_PREFIX=".tmp-"`、`LATEST_FILE="nodepool-latest.db"`、`NODEPOOL_SNAPSHOT_MIN_FREE_MB`(2048)、`NODEPOOL_BACKUP_KEEP_DAYS`(30)。
备份集目录**只含三件套**：`db`、`manifest.json`、`complete.json`。备份文件用 `mode=ro&immutable=1` 读取，不产生 `-wal/-shm` 污染；发布前若存在空 sidecar 一并清除（已由测试固定）。

### manifest / complete 结构

`manifest.json` 记录：`format`、`stage`、`created_at`、`app_version`（1.8.7）、`sqlite_version`、`db_bytes`、`tables`（17 表逐表 count，**从备份文件本身读出**）、`tables_expected`、`missing_tables`、`key_digests`、`important_counts`（latency_results/results/share_history/batches）、`tasks`（存在性/行数/定义摘要）、`schema_version`、`structure_profile`（`alter_history` / `fresh_init`，来自 P-1.2 已登记基准）、`write_quiesced`、`source_data_version{before,after}`、`source_counts`（仅停写窗口）、`source_db=null`（不写绝对路径）。

`complete.json` 记录 `stage`、`bytes`、`db_sha256`、`manifest_sha256`、`finished_at`。有效判据：三件齐全 + `complete` 的两个 sha 与实际文件相符 + `integrity_check=ok` + `fk_check` 0 行 + 17 表齐全。

---

## 2. 测试矩阵（PT-01 / 03 / 04 / 04b / 21）

全部测试使用**独立测试数据库副本**（`sqlite3.backup()` 从开发实例复制的临时库）与临时备份目录，`NODEPOOL_DB` / `NODEPOOL_BACKUP_DIR` 全部指向 `tmp_path`，未接触生产库与生产备份目录。

| # | 测试 | 覆盖点 | 结果 |
| --- | --- | --- | --- |
| 1 | `test_pt01_online_snapshot_with_concurrent_writes` | 在线（有并发写）快照仍一致；备份不阻塞写 | PASS |
| 2 | `test_pt01_space_gate_refuses_snapshot` | 可用空间低于门槛时拒绝创建 | PASS |
| 3 | `test_pt02_plain_copy_is_not_a_valid_backup` | WAL 下 `shutil.copyfile` 得到缺表/丢行副本，验证为无效 | PASS |
| 4 | `test_pt03_l1_good_set_passes_and_bad_sets_fail` | 好集通过；篡改 db／缺 `complete.json` 均失败 | PASS |
| 5 | `test_pt04_quiesced_l2_detects_one_row_loss_and_names_table` | 停写快照丢 1 行，L2 报 `count_mismatch` 并指出表名 | PASS |
| 6 | `test_pt04b_online_backup_never_compares_with_live_source` | 在线备份不与实时源比对，不误报 | PASS |
| 7 | `test_pt04b_quiesced_backup_reports_live_source_divergence` | 停写窗口源库多写 → 必须报警 | PASS |
| 8 | `test_pt21_incomplete_sets_are_invalid_and_never_pruned` | `.tmp-` 半成品不进 `valid_sets`，prune 不删 | PASS |
| 9 | `test_latest_copy_only_updated_for_valid_set` | `nodepool-latest.db` 仅在有效集时更新 | PASS |
| 10 | `test_restore_set_restores_content_and_publishes` | 恢复后内容一致、发布回调触发、无临时文件残留 | PASS |
| 11 | `test_restore_aborts_when_third_party_holds_the_file` | 独立进程持有库文件 → `restore_handles_present` | PASS |
| 12 | `test_restore_rolls_back_when_post_check_fails` | 恢复后校验失败 → `restore_rolled_back` 且库可用 | PASS |
| 13 | `test_prune_keeps_protected_and_recent_daily` | 保护 `pre-migrate`/`pre-restore`，保留最近 daily | PASS |
| 14 | `test_structure_drift_in_backup_is_rejected` | 备份内业务表结构漂移 → 拒绝 | PASS |
| 15 | `test_tasks_ddl_drift_in_backup_is_rejected` | `tasks` 定义漂移 → `tasks_ddl_drift` | PASS |
| 16 | `test_published_set_contains_only_three_files` | 集合目录仅三件套，校验后不留 sidecar | PASS |

### 数量汇总

- 本阶段专项：**16 项，16 通过，0 失败**
- 全量回归：**234 项，234 通过，0 失败**（P-1.2 前基线 218 + 本阶段 16）
- 回归命令：`NODEPOOL_DATA_DIR=<tmp> NODEPOOL_DB=<tmp>/nodepool.db python3 -m pytest -q`
- 回归环境：Python 3.12，SQLite 3.49.1（测试机），生产实测 SQLite 3.46.1（P-1.1 报告）

---

## 3. 证据（独立副本实跑）

### 3.1 备份集生成与校验

```
=== PT-01 备份集 ===
dir: nodepool-20261126-143310-pre-migrate
files: ["complete.json", "db", "manifest.json"]
db_bytes: 167936
db_sha256: b300598427b055cf5adfad59dd592a2c280d8c9a7309d8327a6dfbfc5852d09f
manifest_sha256: 640b2bab7441bbbb2626b9e04248198c1a74bc60b5ba3daa485b6d3aac8ffeb6
structure_profile: alter_history
tasks: {tasks_present: true, tasks_rows: 0, tasks_hash: 0e8a1c8d…}
write_quiesced: false
tables: 17 张（settings 52 / speed_sources 8 / test_groups 3 / logs 1 / 其余 0）

=== PT-01 verify ===
{"ok": true, "l1": {"ok": true}, "l2": {"ok": true, "mode": "online", "compared_to_source": false}, "errors": []}
校验后目录仍为三件套: ["complete.json", "db", "manifest.json"]
```

幂等性：连续两次调用不覆盖旧集合，各自生成独立目录（`…-pre-migrate` 与 `…-manual`），`valid_sets` 返回 2 个。命名冲突时自动加序号（`…-manual-1`）。

### 3.2 完整性 / 内容校验（PT-03 / PT-04）

| 构造 | 结果 | 错误码 |
| --- | --- | --- |
| db 尾字节被改 | 拒绝 | `db_sha_mismatch` |
| 缺 `complete.json` | 拒绝 | `missing_file` |
| `manifest.json` 破坏成 `{}` | 拒绝 | `manifest_sha_mismatch` + `structure_drift` + `tasks_ddl_drift` + 逐表 `count_mismatch` |
| 删 1 行（`logs` 1→0），并把 db/manifest/complete 三个签名**全部重签自洽** | 拒绝 | `count_mismatch: logs manifest=1 backup=0` |
| 改 `settings` 内容但行数不变（签名全部重签自洽） | 拒绝 | `digest_mismatch: settings 关键表摘要不一致` |
| 备份内业务表加列（签名重签自洽） | 拒绝 | `structure_profile_unregistered` |
| 备份内 `tasks` 加列（签名重签自洽） | 拒绝 | `tasks_ddl_drift` |

要点：即便篡改者把三个 sha 全部重算成自洽，L2 仍能从「manifest 计数/摘要 vs 备份文件实读」与「结构基准登记」两侧发现丢行与结构漂移；不存在「签名自洽即可蒙混」的路径。

### 3.3 停写窗口比对（PT-04b）

- 停写快照（`stop_write=True`，`PRAGMA data_version` 前后相同）→ `write_quiesced: true`，manifest 写入 `source_counts`。
- 快照后源库多写 1 行，`verify_set(set, live_source=源库)` → 拒绝，`source_count_mismatch: logs source=2 backup=1`。
- 同一源库对**在线**备份集调用 `verify_set(…, live_source=…)` → 通过，且 `l2.live_source_ignored=true`（在线备份禁止与实时源比对，不误报）。

### 3.4 恢复演练（L3 文件级）

```
restore_set 返回: {"ok": true, "db": ".../restore-target.db",
                  "from_set": "nodepool-20261126-143310-pre-migrate",
                  "pre_restore_set": "nodepool-20261126-143310-pre-restore"}
恢复后表结构/列序/行数指纹一致: True | 索引一致: True
恢复后 -wal: 存在 0 字节 | -shm: 存在 32768（init_db 以 WAL 重开库所致，无旧库帧）
临时恢复文件: 无 `restore-<nonce>.db` 残留（仅目标库自身）
PRAGMA integrity_check: ok
pre-restore 快照已生成: nodepool-20261126-143310-pre-restore
```

指纹口径：逐表「列名+类型+NOT NULL+主键序号（保持 ordinal）」+ 行数 + `sqlite_master` DDL，加全部索引 `(name, tbl_name)` 列表；恢复前后完全相等。

### 3.5 故障注入

| 场景 | 注入方式 | 期望 | 实测 |
| --- | --- | --- | --- |
| A 备份集结构损坏 | 备份副本 `DROP TABLE airports` 并重签三件 | 替换前拒绝，目标库零改动 | `backup_invalid`，目标库 sha 未变、19 表完整 |
| B 第三方进程持有库文件 | 独立 Python 子进程打开目标库并保持 | 拒绝恢复 | `restore_handles_present` |
| C 恢复后校验失败 | 替换后校验抛异常（monkeypatch） | 自动回退 pre-restore，库仍可用 | `restore_rolled_back`，回退后 19 表齐全、`airports` 行数与原库一致 |
| D 中断留下半成品 | 手工造 `.tmp-00112233445566/{db}` | 不算有效集、prune 不删 | `valid_sets` 不含它；`prune` 计入 `skipped`，目录保留 |
| E 空间不足 | 提高 `min_free_mb` 门槛 | 拒绝创建、不留垃圾 | 抛 `snapshot_failed`，备份目录无新增 |

---

## 4. 17 张基准业务表（含 tasks）不变证据

1. **代码层**：本阶段只新增两个文件，`git diff --stat` 为空；`db.py`、通用 `SCHEMA`、`init_db()`、`migrate.py`、`routes.py` 未改动 → 无任何建表/改表/删表语句进入运行路径。
2. **运行层（备份）**：`snapshot_set` 对源库只开 `mode=ro` 只读连接；备份前/后对 19 张表（17 业务 + `tasks` + `sqlite_sequence`）做「列序 + 行数 + DDL + 索引」指纹，实跑结果**完全一致**；备份目录只新增三件套。
3. **运行层（恢复）**：恢复目标为独立副本；恢复前后同一口径指纹一致（`True / True`），说明恢复不引入结构或行数变化。
4. **tasks 形态**：P-1.3 不创建、不删除、不改写 `tasks`；仅记录 `tasks_present / tasks_rows / tasks_hash`（DDL 归一化摘要）。备份内 `tasks` DDL 变化会被 `tasks_ddl_drift` 拒绝；`tasks` 缺失时 manifest 记 `tasks_present=false`，两种合法形态均被支持。
5. **生产侧**：本阶段**未连接、未写入生产库**，未在 NAS 部署代码，未创建/删除/覆盖任何生产备份。生产结构（`alter_history` vs `fresh_init`）归属仍待 NAS 只读实测确认，本材料不作"已验证"表述。

---

## 5. 与 P-1.1 风险项的对应

| 风险 | 本阶段处置 |
| --- | --- |
| R1 生产备份陈旧（最新 2026-11-22） | 提供 `snapshot_set("pre-migrate")` 作为生产写窗口前的强制前置；未自行在生产补备份（无授权窗口）。`pre-migrate` 受 prune 永久保护。 |
| R4 早期 tar.gz 体积异常、未证可恢复 | `verify_set` 给出可判定的有效性口径（三件套 + 双 sha + integrity + fk + 17 表）。旧 tar.gz **不纳入**有效集判定，也不标记为可恢复。 |
| WAL 一致性 | 统一用 `sqlite3.backup()`；测试固定了「`shutil.copyfile` 得到缺表/丢行副本」的反例。 |

---

## 6. 尚存问题（是否影响验收）

| 项 | 说明 | 影响 |
| --- | --- | --- |
| L3 容器级演练未做 | `PT-05`（起 8089 容器、`/healthz` 校验）属于后续阶段；本阶段为文件级恢复演练 + 回退注入 | 不阻断 P-1.3（P-1.3 判据 PT-01/03/04/04b/21） |
| 未接线到 API | `routes.py` 的 `/system/backup`、`/system/backup/download` 与 `NODEPOOL_BACKUP_IMPL` 切换点未接 | 不阻断；接口层接线安排在实施计划后续条目 |
| 生产结构归属未定 | `alter_history` / `fresh_init` 需 NAS 只读 `sqlite_master` 实测。测试库实测为 `alter_history`，生产不得据此推断 | 不阻断 P-1.3；P-1.4 前需实测 |
| 恢复后 `-shm` 残留 32KB | `init_db()` 以 WAL 重开库的正常副产物，`-wal` 为 0 字节，无旧库帧 | 不影响一致性 |
| `latest_set` 含 `pre-restore` | 预恢复快照本身是有效集，会被视为"最新"，语义上符合"最近有效集"定义 | 需在调用方按 `stage` 过滤使用时注意 |
| macOS 无 `/proc` | `holders_of` 在非 Linux 环境退化为空列表（容器内为 Linux，生产不受影响） | 已知限制，已注释 |

---

## 7. 复现方式

```bash
git clone https://github.com/laoXuHome/NodePoolME.git && cd NodePoolME
T=$(mktemp -d); python3 -c "import sqlite3;s=sqlite3.connect('file:data/nodepool.db?mode=ro',uri=True);d=sqlite3.connect('$T/nodepool.db');s.backup(d);d.close()"
NODEPOOL_DATA_DIR=$T NODEPOOL_DB=$T/nodepool.db python3 -m pytest -q                       # 234 passed
NODEPOOL_DATA_DIR=$T NODEPOOL_DB=$T/nodepool.db python3 -m pytest tests/test_backup_set.py -q  # 16 passed
```

> 注意：仓库 `data/nodepool.db` 是 gitignored 的开发实例；`tests/conftest.py` 会在每个测试前清空它。所有 P-1.3 测试均通过 `NODEPOOL_DB` 指向临时副本，不复用该文件。
