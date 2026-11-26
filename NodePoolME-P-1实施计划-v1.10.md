# NodePoolME P-1 实施计划（对应总体设计 v1.10）

> 版本：P-1 计划 · 编制基准 commit `e721797`（v1.8.7）/ 总体设计 `NodePoolME-新架构总体设计方案-v1.10.md`（commit `589f4367`，blob `a240f1bc`，199,582 字节 / 1,990 行）
> 本轮性质：**只调查、只出计划**。未写业务代码、未执行迁移、未改生产数据或配置、未进入 P0–P6。

---

## 0. 边界与证据等级

本计划把所有结论分成三级，全文用标记区分，避免把推断写成事实：

| 标记 | 含义 | 本轮来源 |
| --- | --- | --- |
| **【实测】** | 我在可访问的执行环境真实跑过命令并得到输出 | 本会话 Linux 环境（`/tmp` 一次性库 + 仓库只读副本） |
| **【取证】** | 从代码库/文档静态读取确认（带文件行号） | 仓库 `/home/user/Doubao/chats/38455401923398914/NodePoolME`（只读） |
| **【待生产实测】** | 必须在生产 NAS 上跑只读探针才能确定，本轮**没有**数据 | 探针脚本见 §1.3，输出回填后计划才能定稿 |

明确约束（按任务书执行）：不改现有业务逻辑；不动节点身份/健康判断/评分/订阅下发；不删历史表与历史数据；不重写成熟模块；不执行真实迁移；不因实现方便改动 v1.10 已定稿的设计；不进入 P-1 之后的实施。

---

## 1. 生产环境调查

### 1.1 生产环境可达性（先说结论）

**【实测】我无法从当前会话访问生产 NAS。** 当前执行环境是云端 Linux 沙箱，没有到用户 NAS 的 SSH/文件通道，仓库里检出的 `data/` 是开发用实例，不是生产库。因此本节分两部分：能从代码与仓库确认的（【取证】）；必须由用户在生产上跑探针才能填的（【待生产实测】）。

**绝不把仓库内 `data/nodepool.db` 当作生产库。** 它的实测数据仅用于说明"结构长什么样"，见 §1.2.3，已被明确标注为非生产。

### 1.2 已确认事实

#### 1.2.1 数据路径与连接方式【取证】

| 项 | 事实 | 出处 |
| --- | --- | --- |
| 库路径 | 环境变量 `NODEPOOL_DB`，默认 `<DATA_DIR>/nodepool.db` | `backend/config.py:14` |
| 数据目录 | `NODEPOOL_DATA_DIR`，默认 `./data`，容器内固定 `/data` | `backend/config.py:8`、`docker-compose.yml` |
| 备份目录 | `NODEPOOL_BACKUP_DIR` → 容器 `/backup`，宿主 `${NODEPOOL_ROOT}/backup` | `backend/config.py:11` |
| 日志目录 | `NODEPOOL_LOG_DIR` → `/logs` | `backend/config.py:10` |
| 订阅目录 | `SUB_DIR = DATA_DIR/sub`（四格式文件 + `meta.json`） | `backend/config.py:13`、`data/sub/` |
| 连接 | 线程本地单连接 `sqlite3.connect(timeout=30, check_same_thread=False)`，`row_factory=Row` | `backend/database/db.py:279-290` |
| PRAGMA（连接级） | `journal_mode=WAL`、`synchronous=NORMAL`、`busy_timeout=30000` | `backend/database/db.py:283-286` |
| 事务 | `BEGIN IMMEDIATE` + `commit/rollback` 上下文 | `backend/database/db.py:291-301` |
| 连接重置 | `reset_connection()` 丢弃线程本地句柄（用于替换库文件前后） | `backend/database/db.py:302-313` |
| 建表 | `init_db()` → `executescript(SCHEMA)`（全部 `CREATE TABLE IF NOT EXISTS`） | `backend/database/db.py:314+` |

关键推论：**生产库必然处于 WAL 模式**（每个连接都会设置），因此"直接 `cp nodepool.db`"会拿到不一致快照（§2.4 有实测反例），备份必须走 SQLite 备份 API。

#### 1.2.2 表清单【取证】

`backend/database/db.py` 的 `SCHEMA` 定义 **17 张表**：`settings`、`airports`、`fetch_logs`、`nodes`、`airport_filtered_nodes`、`test_groups`、`results`、`latency_results`、`share_history`、`schedule_history`、`batches`、`logs`、`run_events`、`speed_sources`、`speed_source_checks`、`speed_runs`、`speed_samples`。

`tasks` 表：**代码零引用**（`grep` 全仓 `.py/.js/.html` 均无 `FROM tasks`/`INTO tasks`），且 `docs/项目说明.md:723` 明确记载 v1.5.0 已"删掉 … `tasks` 表"。因此生产库若仍存在该表，属 **v1.5.0 之前的遗留空表**：**保留不删**，P-1 只登记、不迁移、不清空。**【取证】**

#### 1.2.3 仓库内开发库快照（**非生产**，仅示意结构）【实测】

只读连接 `file:data/nodepool.db?mode=ro`，Python `sqlite3` 3.49.1：

| 项 | 值 |
| --- | --- |
| 文件大小 | 167,936 字节 |
| `journal_mode` | `wal`（`-wal` 0 字节、`-shm` 32,768 字节，均为空闲态） |
| 表数 | 18（17 张 SCHEMA 表 + 遗留 `tasks`） |
| 行数 | `settings` 51、`test_groups` 3、`speed_sources` 8、`sqlite_sequence` 3、`logs` 1，其余全 0 |
| `tasks` 结构 | `id / name / status / started_at / finished_at / detail`，0 行，无索引、无触发器 |
| 触发器 | 0 个 |

这张库是空的开发实例（0 节点），**不能**用于推断生产规模，也不能作为迁移演练的唯一依据。

#### 1.2.4 现有备份/恢复能力【取证】

| 既有能力 | 实现 | 缺口 |
| --- | --- | --- |
| 手工备份 | `POST /api/system/backup` → `sqlite3.backup()` 到 `BACKUP_DIR/nodepool-<stamp>.db`，再拷一份 `nodepool-latest.db` | 无自动调度、无完整性校验、无保留策略、无清单 |
| 下载备份 | `GET /api/system/backup/download`（同样先生成再回传，会在备份目录留文件，无清理） | 同上 |
| 恢复 | `POST /api/system/restore`（上传）：先 `pre-restore-<stamp>.db` 快照 → `reset_connection()` → `shutil.copy2` 覆盖 → `init_db()` → `builder.publish("restore")` | 覆盖前不校验源库 `integrity_check`；不校验行数；失败无自动回退；无 WAL 处理（`copy2` 覆盖主库时旧 `-wal` 可能残留） |

**这是 P-1 要补的核心缺口**：现有备份"能生成"但"不保证可恢复"，且恢复路径本身在 WAL 场景下不安全。

#### 1.2.5 两种 `sub_publish` 模式【取证】

| 模式 | 语义 | 实现位置 |
| --- | --- | --- |
| `time`（默认） | 每天固定时刻发布，`sub_publish_time` 默认 `04:30` | `backend/config.py:104-107`、`backend/api/routes.py:572-576` |
| `interval` | 固定间隔，`sub_publish_interval_minutes` 默认 `180` | 同上 |

设置项：`sub_publish_enabled` / `sub_publish_mode` / `sub_publish_time` / `sub_publish_interval_minutes` / `sub_publish_next_at`（`routes.py:1165-1237` 写入并重算 `next_at`）。发布写到 `DATA_DIR/sub`（四格式 + `meta.json`），**与数据库文件同目录树但不同文件**，因此"维护期禁写库"不影响订阅文件，但会阻塞 `builder.publish()` 触发的读库。

兼容性结论：两种模式都在同一调度器里读 `settings` 表，**P-1 不改其语义**；维护期只让调度器"本轮不运行"，不改模式判定。

#### 1.2.6 部署形态【取证】

`docker-compose.yml`：单容器 `ghcr.io/laoxuhome/nodepoolme:latest`，4 个 bind mount（`data/config/logs/backup` 均在 `${NODEPOOL_ROOT:-/opt/nodepool}` 下），healthcheck 打 `/healthz` 每 30s。→ **宿主文件系统与 NAS 卷类型决定 `os.replace`/`fsync` 是否可用**，见 §1.3 探针 P-7。

#### 1.2.7 必须由生产探针补齐的项【待生产实测】

| 编号 | 必测项 | 为什么影响计划 |
| --- | --- | --- |
| P-1 | 生产库绝对路径、字节数、`page_count`×`page_size`、`freelist_count` | 决定备份耗时预算、临时空间需求 |
| P-2 | `sqlite3` 版本（容器内 `python -c "import sqlite3;print(sqlite3.sqlite_version)"`） | v1.10 用到 `ALTER TABLE`/触发器等特性，需 ≥ 3.35（`RETURNING` 不依赖，但 `ALTER` 兼容性要看） |
| P-3 | 各表行数（17 张 + `tasks` 是否存在） | 决定迁移窗口与索引重建时间，也验证 §1.2.3 的"tasks 遗留空表"假设 |
| P-4 | `-wal`/`-shm` 存在与大小、`PRAGMA journal_mode`、`PRAGMA integrity_check` | WAL 残留大小决定 checkpoint 策略；integrity 决定是否允许动手 |
| P-5 | 当前是否存在未提交事务/长连接（`lsof nodepool.db`、`sqlite3 ... "PRAGMA wal_checkpoint(PASSIVE)"` 返回 0,0,N） | 决定"停写排空"需要多久 |
| P-6 | 备份目录现状（文件数、最新时间、总占用、`df` 剩余） | 决定保留策略与是否需要扩容 |
| P-7 | `STATE_DIR`/`data` 所在卷类型（`stat -f -c %T`、`mount`）与同目录 `os.replace`+`fsync` 实测 | v1.10 的 maintenance.json 原子写依赖同卷 rename |
| P-8 | 容器运行用户（`id`）、目录属主，能否在 `data/` 下建文件 | maintenance.json 与快照都要落盘 |
| P-9 | `sub_publish` 当前生效模式与 `next_at`、最近一次发布结果 | 升级窗口要避开发布时刻 |

### 1.3 生产探针脚本（只读，可直接复制执行）

> 约束：**P-1~P-6、P-8、P-9 全部只读**；**P-7 需要写一个临时文件**（约 64 字节，名字带随机后缀，测完立即删除，绝不触碰 `nodepool.db*`）——这一小步需用户明确批准后再跑。

```bash
# 0) 定位容器与挂载（只读）
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i nodepool
docker inspect nodepool --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}'

# P-1/P-3/P-4：库体量、表行数与完整性（只读，容器内跑，避免宿主无 sqlite3）
docker exec nodepool python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", "/data/nodepool.db"))
print("path", p, "bytes", p.stat().st_size)
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
print("sqlite", sqlite3.sqlite_version)
for k in ("page_size", "page_count", "freelist_count", "journal_mode", "synchronous", "foreign_keys"):
    print(k, c.execute(f"PRAGMA {k}").fetchone())
for (n,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    print(n, c.execute(f'SELECT count(*) FROM "{n}"').fetchone()[0])
print("triggers", [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='trigger'")])
print("integrity", c.execute("PRAGMA integrity_check").fetchone()[0])
print("fk_violations", len(c.execute("PRAGMA foreign_key_check").fetchall()))
PY

# P-4：WAL/SHM 实体与正在持锁的进程
docker exec nodepool sh -c 'ls -l /data/nodepool.db* 2>/dev/null'
docker exec nodepool sh -c 'python - <<PY
import sqlite3
c=sqlite3.connect("/data/nodepool.db", timeout=5)
print("checkpoint(passive)", c.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone())
PY'

# P-6：备份目录与磁盘余量
docker exec nodepool sh -c 'ls -lht /backup | head -20; du -sh /backup; df -h /backup /data'

# P-8：运行身份与目录权限
docker exec nodepool sh -c 'id; ls -ld /data /backup /data/config'

# P-7（需批准，唯一写操作）：同目录 rename + fsync 实测
docker exec nodepool python - <<'PY'
import os, uuid
from pathlib import Path
d = Path("/data")
t = d / f".p1probe.{uuid.uuid4().hex[:8]}.tmp"
tgt = d / f".p1probe.{uuid.uuid4().hex[:8]}.json"
try:
    t.write_text('{"probe":true}', encoding="utf-8")
    fd = os.open(str(t), os.O_RDONLY); os.fsync(fd); os.close(fd)
    os.replace(str(t), str(tgt))
    dfd = os.open(str(d), os.O_RDONLY); os.fsync(dfd); os.close(dfd)
    print("same-dir replace+fsync OK", tgt.stat().st_size)
finally:
    for p in (t, tgt):
        try: p.unlink()
        except FileNotFoundError: pass
print("cleanup done")
PY

# P-7 补充：卷类型
docker exec nodepool sh -c 'stat -f -c "fs_type=%T block=%s" /data; mount | grep -E " /data | /backup " || true'
```

**探针判据**：

| 判据 | 通过条件 | 不通过时怎么办 |
| --- | --- | --- |
| `integrity_check` | `ok` | 停止，先做只读抢救备份与磁盘排查，不进 P-1 |
| `fk_violations` | 0（基准库无外键，预期 0） | 记录，迁移前需分析来源 |
| `journal_mode` | `wal` | 若为 `delete`，说明有连接改过，需查明后统一 |
| P-7 输出 | `same-dir replace+fsync OK` 且 `fs_type` ∈ {`ext4`,`xfs`,`btrfs`,`overlayfs`(本地) } | 若为 `nfs`/`cifs`/`fuse.*` ⇒ maintenance.json 方案必须改为"落 `STATE_DIR` 本地卷 + 不做跨节点共享"，并在计划里记为已知限制 |
| 备份盘余量 | ≥ 3× 库大小 且 ≥ 2 GB | 先清理旧备份或扩盘 |

---

## 2. P-1 七项方案

前提：v1.10 的设计已被批准，本轮只把它落成**可执行的工程步骤**，不重新设计。以下每项给"目的 / 做法 / 触碰面 / 判据 / 回滚"。

### 2.1 SQLite 安全备份方案

**目的**：在 WAL 模式下得到**一致**快照，且不阻塞业务写入超过必要时间。

**做法**：

1. 一律用 SQLite 在线备份 API：`src.backup(dst, pages=...)`（Python `sqlite3.Connection.backup`），**禁止** `cp`/`shutil.copy2` 主库文件（§2.4 有实测反例：WAL 下 `copyfile` 直接得到"无表"的库）。
2. 备份源用**独立只读连接**（`mode=ro`），不复用业务线程本地连接，避免长时间持有业务连接。
3. 分页备份（`pages=1024`，约 4 MB/批）并在批间 `sleep(0)`，把写锁竞争降到最低；`backup()` 内部保证快照一致性。
4. 目标文件写 `BACKUP_DIR/<name>.db.tmp` → 完成后 `fsync` → `os.replace` 到最终名 → `fsync(BACKUP_DIR)`（与 maintenance.json 同一套原子写规则）。
5. 命名：`nodepool-YYYYMMDD-HHMMSS-<stage>.db`，`stage` ∈ {`pre-migrate`,`daily`,`manual`,`pre-restore`}；同步写一份 `*.manifest.json`（见 2.4）。

**触碰面**：新增 `backend/database/backup.py`（纯新增文件）；`routes.py` 的 `/system/backup`、`/system/backup/download` 改为调用它（保持响应字段 `ok/file/size` 不变，向后兼容）。

**判据**：备份可在独立进程 `PRAGMA integrity_check` 通过；行数与源库一致（逐表对比）；备份过程业务写入 P99 延迟不出现 > 1s 的毛刺（演练期测）。

**回滚**：新增文件可整体移除；两个路由接口在原实现与新版之间用配置开关 `NODEPOOL_BACKUP_IMPL=v2|legacy` 切换（默认 `legacy` 直到 P-1.8 演练通过）。

### 2.2 Schema 版本管理方案

**目的**：让"当前库处于哪个版本、迁移是否完成"成为可查询的持久事实，供 maintenance 判定与重启恢复使用。

**做法**：

1. 新增表（v1.10 §2.1 已定稿，DDL 不改）：

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  migration_id TEXT NOT NULL,
  version      TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('running','failed','success')),
  started_at   TEXT NOT NULL,
  finished_at  TEXT,
  detail_json  TEXT,
  UNIQUE(migration_id)
);
```

2. 版本探测：`current_version()` 取 `status='success'` 的 `version` 最大者；无表/无行 ⇒ `"1.8.7-baseline"`（视为未开始）。
3. 基线登记（P-1.2 唯一写入）：首次启动若表不存在，则**只建表**并写入一行 `version='1.8.7-baseline'`、`status='success'`、`detail_json='{"baseline":true}'`，不触碰任何业务表。
4. `schema_migrations` **只允许**由迁移执行器与 `init_db()` 写入；业务代码不得写（v1.10 §3.3 已规定它不承担维护态存储职责）。

**触碰面**：`backend/database/db.py` 的 `SCHEMA` 追加建表语句（幂等）；新增 `backend/database/migrate.py` 中的 `current_version()` / `record_migration()`。

**判据**：重复启动 N 次，`schema_migrations` 行数不增；`status` 分布只有 `success`（演练期）；15 张业务表结构与行数逐项不变。

**回滚**：`DROP TABLE schema_migrations`（只有该表是自己建的）即可回到原状；业务数据零影响。

### 2.3 迁移前自动快照方案

**目的**：任何 `ALTER`/重建之前，先有一份"已验证可恢复"的快照；快照失败即禁止继续。

**做法**：

1. 触发点：迁移器在写入 `status='running'` **之前**调用 `snapshot(reason='pre-migrate')`。
2. 快照 = §2.1 的安全备份 + 完整性校验 + 恢复抽样（§2.4），三步全过才算成功。
3. 快照成功后写 `snapshot_manifest.json`（含 `sha256`、字节数、`schema_version`、逐表行数、`created_at`、`sqlite_version`），并 `fsync`。
4. **停写排空后再做快照**（v1.10 既定顺序：先停写 → 排空 WAL → 再快照），排空判据见 2.7。
5. 保留策略：`pre-migrate` 与最近 3 份 `daily` 永久保留，其余按总量上限（默认库大小 ×10）滚动删除；**不允许**删除 `pre-migrate` 与 `pre-restore`。

**触碰面**：`backup.py`、`migrate.py`；新增 CLI `python -m backend.database.migrate snapshot --reason pre-migrate`。

**判据**：快照耗时 ≤ 60s（生产库 < 200 MB 时应 ≤ 5s，实测 5,000 行库 0.002s）；失败时迁移器必须 `halt_migration("snapshot_failed")`，不写 `running`。

**回滚**：删除本次快照文件即可（不涉及业务状态）。

### 2.4 备份完整性验证与恢复验证方案

**目的**：杜绝"备份存在但打不开/数据不全"的假安全。

**做法**（三级验证，逐级可独立执行）：

1. **L1 结构验证**：备份文件以 `mode=ro` 打开 → `PRAGMA integrity_check` 必为 `ok` → `PRAGMA foreign_key_check` 0 行 → 17 张基准表（+ 可选 `tasks`）全部存在。
2. **L2 内容验证**：逐表 `count(*)` 与源库快照时计数比对（允许 `logs`/`fetch_logs` 这类滚动表在快照后有 ≤ N 行差异，其余表必须完全相等）；关键表（`airports`、`nodes`、`settings`、`test_groups`）做 `sha256` 级摘要比对（`SELECT * ORDER BY rowid` 规范化后哈希）。
3. **L3 恢复演练**：把备份恢复到**独立路径**（`/tmp/restore-check/nodepool.db`，绝不覆盖生产），用**独立容器端口**（如 `8089`）以只读方式起一份实例，验证：`/healthz` 200、登录可用、机场/节点列表条数与备份一致、订阅文件能重建。完成后停容器、删副本。
4. 每次 `pre-migrate` 快照必须过 L1+L2；L3 至少每次升级窗口前做一次（P-1.8 演练）。

**触碰面**：`backup.py`（`verify_backup()`）、CLI `migrate verify --file <path>`。

**判据**：L1/L2 全绿；L3 中"节点条数、机场条数、设置项数"三项与源一致；任一不绿 ⇒ 迁移不得开始。

**回滚**：验证是只读行为，不影响生产。

### 2.5 迁移失败保护与回滚方案

**目的**：任何一步失败都能停在"可解释、可恢复"的状态，绝不出现"半迁移且继续对外服务"。

**做法**（与 v1.10 §1.2/§2.1/§2.2 一一对应，不新增状态）：

1. 迁移按 v1.10 的 `Phase` 状态机推进，每次转换走 `set_phase()`，事件走 `write_event()`（A/B/C 三分类）。
2. 失败分流：
   - `ABSENT`（确认未写入）⇒ `PhaseResult.REJECTED`，回滚事务、删 `schema_migrations` 的 `running` 行、恢复快照（若已动过表），重启服务；
   - `UNRESOLVED`（无法确认）⇒ `PhaseResult.HALTED`，进 `halt_migration`：写 maintenance、封锁写入、非 DB 日志；
   - `HALTED` 上行后，`halt_tail()` 显式校验 `maintenance_ok ∧ writes_blocked`，否则 `fatal_lockdown + fatal_exit`。
3. 回滚动作顺序（严格）：停写 → 排空 → 用 `pre-migrate` 快照恢复到同路径（`reset_connection()` → 原子替换 → `init_db()`）→ 校验 L1/L2 → 清理 `maintenance.json`（人工确认后）→ 重启 → 只读复核 → 允许写入。
4. **禁止**：迁移中途"再试一次"、在 halt 中追加事件、`DROP` 任何业务表、用 `VACUUM` 代替恢复。

**触碰面**：`migrate.py`（`run()` / `rollback_to_snapshot()`）、`db.py`（`reset_connection()` 已有，复用）。

**判据**：演练注入 12 类故障（§6）后，最终状态只能是"已回滚并正常服务"或"halt 且拒绝写入"，不允许第三种。

**回滚**（针对本项自身）：删 `migrate.py` 与 CLI 入口，业务代码零改动。

### 2.6 maintenance.json 持久化及文件系统兼容性验证方案

**目的**：把 v1.10 的三态判定（`ACTIVE`/`INACTIVE`/`RECOVERY_REQUIRED`）落到真实文件系统上，并先证明该文件系统支持原子替换。

**做法**：

1. 路径：`MAINT_FILE = <STATE_DIR>/maintenance.json`，`STATE_DIR` 取 `DATA_DIR`（与库同目录，保证同卷 rename），环境变量 `NODEPOOL_STATE_DIR` 可覆盖；`STATE_DIR` **不得**指向 SMB/NFS 共享目录。
2. 写入：`tmp.<nonce>` → `flush` + `os.fsync(fd)` → `os.replace` → `fsync(dir)`；`nonce` 每次随机；`confirm_maint_write()` 回读校验（`maintenance is True ∧ migration_id ∧ phase ∧ since ∧ nonce`）。
3. 读取：`read_maint_file()` 四态（`ABSENT`/`PRESENT`/`CORRUPT`/`UNREADABLE`）+ `maintenance_state()` 三态，业务写入/后台任务/CLI/`write_guard`/重启恢复**只调这一个入口**。
4. **启动自检**（只跑一次，失败即拒绝启动迁移）：在 `STATE_DIR` 建 `probe-<nonce>.tmp` → fsync → replace → fsync dir → 回读 → 删除。任一环节失败 ⇒ 日志 `maint_fs_unsupported` ⇒ 迁移功能不可用（业务照常，但 `start_migration()` 拒绝执行）。
5. 回读失败/权限错误/IO 异常 ⇒ `UNREADABLE` ⇒ `RECOVERY_REQUIRED`（不查库、不放行），对应 v1.10 已定稿语义。

**触碰面**：新增 `backend/database/maint.py`；`main.py` 启动钩子加自检（失败只禁用迁移，不影响业务启动）。

**判据**：自检通过；`chmod 000` 后读取返回 `UNREADABLE`；截断文件返回 `CORRUPT`；文件缺失且 DB 全 `success` 返回 `INACTIVE`（查库 1 次）。

**回滚**：删 `maint.py` 与启动钩子；`maintenance.json` 手工删除即回到原行为（但此时 P-1 的封锁能力不可用，需一并回退代码）。

### 2.7 生产数据库升级期间的写入封锁与恢复流程

**目的**：升级窗口内保证"没有任何业务写落到库里"，且窗口外一切照旧。

**做法**（六通道，全部读同一 `maintenance.json`）：

| 通道 | 动作 | 判据 |
| --- | --- | --- |
| 应用写入 | 中间件读 `maintenance_state()`，`ACTIVE`/`RECOVERY_REQUIRED` ⇒ 503（`reason` 区分） | 请求返回 503 且 body 标 `reason` |
| 后台任务 | 调度器每轮开始前判定，非 `INACTIVE` ⇒ 本轮 `stopped` | 日志无 `batch_started` |
| 连接池 | 维护期标 `dead`，`checkout` 抛 `PoolClosed` | 池异常计数 > 0，无新连接 |
| CLI | 写命令前判定，`--allow-write` 不绕过维护态 | CLI 退出码非零 |
| `write_guard()` | 正式入口写前判定 + 两项 PRAGMA 检查（`foreign_keys=ON`、`recursive_triggers=ON`） | 违规写抛 `WriteRefused` |
| 重启恢复 | 启动第一步判定 | 维护期重启后仍 503 |

排空判据（停写后必须满足才可快照/迁移）：

1. `PRAGMA wal_checkpoint(TRUNCATE)` 返回 `(0, 0, 0)`（全部帧已回写、WAL 已截断）；
2. `lsof`/`fuser` 无其他进程持有 `nodepool.db*`；
3. 业务侧 `WRITES_BLOCKED` 已置位且 `confirm_writes_blocked()` 回读通过（全局闸 + 写句柄关闭 + 只读连接 `query_only=1`）；
4. 连续 2 次探测间隔 ≥ 10s 均满足。

**回滚/恢复**：清除维护态的唯一合法路径是"迁移 `success` 落库 + 人工确认 + 删 `maintenance.json` + 重启"，任何一步缺失都走 `RECOVERY_REQUIRED` 保守恢复。

---

## 3. 涉及的代码文件、表、接口、配置

### 3.1 代码文件

| 文件 | 改动性质 | 内容 |
| --- | --- | --- |
| `backend/database/db.py` | 修改（增量） | `SCHEMA` 追加 `schema_migrations`；提供 `connect_readonly()`/`table_exists()` 供 `migration_incomplete()` 使用 |
| `backend/database/maint.py` | 新增 | `MAINT_FILE`、`MaintState`/`MaintRead`、`read_maint_file()`、`maintenance_state()`、`set_maintenance()`、`confirm_maint_write()`、`migration_incomplete()` |
| `backend/database/backup.py` | 新增 | `snapshot()`、`verify_backup()`（L1/L2）、`restore_to()`、manifest 读写 |
| `backend/database/migrate.py` | 新增 | `Phase`、`LEGAL_TRANSITIONS`、`TRANSITION_DISPATCH`、`check_dispatch_invariants()`、`write_event()`、`set_phase()`、`halt_migration()`、`halt_tail()`、`run()`、`rollback_to_snapshot()` |
| `backend/api/routes.py` | 修改（薄） | `/system/backup`、`/system/backup/download` 改调 `backup.py`；新增 `GET /api/system/migration/status`（只读） |
| `backend/main.py` | 修改（薄） | 启动顺序：maint 自检 → 维护态判定 → `init_db()` → 调度器；`/healthz` 增加 `migration` 字段（保持 200 语义不变） |
| `backend/scheduler/manager.py` | 修改（一行判定） | 每轮开始前 `maintenance_state()`，非 `INACTIVE` 直接 return |
| CLI（`python -m backend.database.migrate`） | 新增 | `status/verify/snapshot/run/rollback` 子命令，全部受维护态约束 |

**不碰**：`backend/services/`（fetcher、builder）、`backend/testers/`、`backend/scoring/`、前端全部。节点身份、健康判定、评分、订阅下发规则零改动（`builder.publish()` 只被 `restore` 复用，语义不变）。

### 3.2 数据库表

| 表 | P-1 动作 |
| --- | --- |
| 17 张基准表 | **零 DDL 改动**，只读/校验 |
| `tasks`（遗留） | 登记，保留，不动；迁移里显式忽略 |
| `schema_migrations` | 新建（§2.2），唯一写入者为 `migrate.py` / `init_db()` 基线 |
| `system_events` / `migration_tx_notes` | **P-1 不建**（属 P0–P6 的 v1.10 实施）；P-1 的 halt 只写 `migration-fault.log` 与 maintenance 文件 |

> 这一条要强调：v1.10 的事件链（哈希链、`system_events` 8 列）属于后续阶段。P-1 先把"备份/版本/封锁/回滚"这套地基做实，避免一次引入过多新表。

### 3.3 接口

| 接口 | 变化 |
| --- | --- |
| `POST /api/system/backup`、`GET /api/system/backup/download` | 实现换新，响应字段保持 `ok/file/size` |
| `POST /api/system/restore` | 增加：源库 L1 校验、WAL 清理、失败自动回退 pre-restore |
| `GET /api/system/migration/status` | 新增只读：`version`、`phase`、`maintenance_state`、`last_backup`（脱敏，不含路径全量） |
| `GET /healthz` | 增加 `migration` 字段；**状态码语义不变**（避免 docker healthcheck 抖动） |
| 所有业务写接口 | 维护期 503（新增中间件，`reason` 字段） |

### 3.4 配置

| 变量 | 默认 | 用途 |
| --- | --- | --- |
| `NODEPOOL_STATE_DIR` | `NODEPOOL_DATA_DIR` | maintenance 文件目录（必须本地卷） |
| `NODEPOOL_BACKUP_IMPL` | `legacy` | 备份实现开关，`v2` 才走新模块 |
| `NODEPOOL_BACKUP_KEEP_DAYS` | `30` | 备份保留 |
| `NODEPOOL_SNAPSHOT_MIN_FREE_MB` | `2048` | 空间不足时拒绝迁移 |
| `NODEPOOL_MIGRATION_ENABLED` | `0` | 迁移入口总开关（默认关，演练/正式窗口才开） |

---

## 4. 数据兼容性与历史数据保护

| 风险 | 保护措施 |
| --- | --- |
| 迁移改表导致历史数据丢失 | P-1 不改任何业务表 DDL；真正改表只发生在 P0 之后，且必带 `pre-migrate` 快照 + L1/L2 验证 |
| 遗留 `tasks` 表被误删 | 迁移器中列入 `LEGACY_IGNORED = {"tasks"}`，任何 `DROP`/重命名白名单为空 |
| `sqlite_sequence` 被重排 | 禁止对业务表做 `VACUUM INTO` 后替换主库；如需空间回收，单独评估且不在本阶段 |
| 订阅文件与库不一致 | 维护期禁止发布；恢复后统一 `builder.publish("restore")`（沿用现有逻辑） |
| 时间戳/时区 | 库内时间戳沿用现有 `now()`（本地时区字符串），P-1 不改口径；已知 B11（清理按 UTC 比较）留待 P-1 后期单独修，不在本轮 |
| WAL 残留导致恢复不干净 | `restore_to()` 必须：`reset_connection()` → 删除 `-wal`/`-shm`（确认无连接）→ 原子替换主库 → `init_db()` → `wal_checkpoint(TRUNCATE)` |
| 备份被误删 | `pre-migrate`/`pre-restore` 标记为受保护，滚动清理跳过 |

---

## 5. 测试用例与通过判据

全部在**副本库**（生产库的备份）与一次性库上执行，不碰生产。

| 编号 | 场景 | 通过判据 |
| --- | --- | --- |
| PT-01 | `snapshot()` 在 WAL 且有并发写时执行 | 备份 `integrity_check=ok`；行数与源一致；未提交行不出现（【实测】已验证 5,000 行库 0.002s、`dirty` 行未进备份） |
| PT-02 | `cp nodepool.db` 与备份 API 对比（教学用） | 证明 `cp` 得到"无表"库（【实测】已复现），写入计划文档防回归 |
| PT-03 | `verify_backup()` L1 | 良好备份全绿；截断 1 KB / 篡改页 / 删除表 三种坏备份必须失败 |
| PT-04 | L2 行数与摘要比对 | 故意少 1 行 ⇒ 失败并报出表名 |
| PT-05 | L3 恢复演练（独立端口 8089） | `/healthz` 200；机场/节点/设置条数与源一致；订阅四格式可重建 |
| PT-06 | `schema_migrations` 幂等 | 连续启动 5 次，行数恒为 1；`status='success'` |
| PT-07 | 迁移注入"备份失败" | `halt_migration("snapshot_failed")`；不写 `running`；退出码非零；写入仍被拒 |
| PT-08 | 迁移注入"`ALTER` 中途抛错" | 事务回滚；`running` → `failed`；快照恢复后 L1/L2 通过；服务可写 |
| PT-09 | 注入 `set_maintenance()` 抛错但封锁成功（对应 MC63） | `maintenance_ok=False` ⇒ `fatal_exit("maintenance_unconfirmed")`；不返回正常 `HALTED`；无 DB 事件 |
| PT-10 | 持久化成功但回读不一致（改 `nonce`/`phase`/截断）（MC64） | 同 PT-09 结论；`guard_log` 降级链有效 |
| PT-11 | 文件四态（MC68 a–p） | `ACTIVE/INACTIVE/RECOVERY_REQUIRED` 与查库次数逐项符合 §2.1 矩阵；`10**1000` 不抛 `OverflowError` |
| PT-12 | 分派表自检（MC67） | 普通模式与 `-O` 均 `DispatchTableBroken` 拒绝启动 |
| PT-13 | 事件接口无裸 bool（MC65） | 返回 `WriteOutcome`；`LOCAL` 只在 tx_local |
| PT-14 | P-7 文件系统自检 | 同目录 replace + fsync 通过；跨设备 rename 报 `EXDEV`（【实测】errno 18）⇒ 明确拒绝跨卷 `STATE_DIR` |
| PT-15 | 六通道封锁 | 维护期：HTTP 503、调度器停、池 `PoolClosed`、CLI 非零、`write_guard` 抛、重启仍 503 |
| PT-16 | 停写排空 | `wal_checkpoint(TRUNCATE)=(0,0,0)`；两次探测间隔 ≥10s 均满足 |
| PT-17 | 回滚剧本 | 从 `pre-migrate` 恢复后：行数/摘要一致、无 `-wal` 残留、订阅重建成功、`maintenance.json` 需人工确认才移除 |
| PT-18 | 保守恢复（MC66(4)） | 删文件 + 非 `success` 行 ⇒ 五入口一致 `RECOVERY_REQUIRED`，写入不开放 |
| PT-19 | 迁移窗口内重启 | 重启后仍 `RECOVERY_REQUIRED`/`ACTIVE`，不自动推进 phase、不补写事件 |
| PT-20 | 性能预算 | 100 MB 库：快照 ≤ 5s、排空 ≤ 30s、总停写窗口 ≤ 60s（演练实测后回填实际值） |

判据统一口径：**每一项必须给出"命令 + 期望输出 + 不通过时的处置"**；"跑通了"不算通过，必须贴输出。

---

## 6. 备份恢复验证步骤（可照做）

1. 停写：置维护态（`maintenance.json`）→ 等后台任务本轮结束 → `wal_checkpoint(TRUNCATE)`。
2. 快照：`migrate snapshot --reason pre-migrate` → 得到 `nodepool-<stamp>-pre-migrate.db` + manifest。
3. 验证：`migrate verify --file <备份>` → L1 结构 + L2 行数/摘要。
4. 副本演练：把备份拷到 `/tmp/restore-check/`（或另一块盘），起临时容器 `-p 8089:8080`、`NODEPOOL_DB` 指向副本、`NODEPOOL_MIGRATION_ENABLED=0`。
5. 核对：登录 → 机场数/节点数/设置项数 → 打开一个订阅 URL 取四种格式 → 与生产计数比对。
6. 收尾：停临时容器、删副本、删临时备份目录；生产仍保持维护态。
7. 正式迁移：`migrate run` → phase 推进 → `success` 落库。
8. 解除维护：人工确认 → 删 `maintenance.json` → 重启 → 只读接口核对 → 允许写入 → 观察 30 分钟（`logs` 中 5xx 与 503 计数归零、批次正常）。

每步都有独立的中止点：1–6 任一失败 ⇒ 回滚到步骤 1 之前的状态（生产从未被写过），不影响服务。

---

## 7. 失败处理与回滚矩阵

| 编号 | 失败点 | 立即动作 | 最终状态 | 恢复手段 |
| --- | --- | --- | --- | --- |
| F1 | 快照失败（空间/IO） | `halt_migration("snapshot_failed")` | 写入封锁 + `HALTED` | 清维护态前先修磁盘；业务保持只读 |
| F2 | 快照验证 L1/L2 失败 | 同上 | 同上 | 换备份策略，不迁移 |
| F3 | `schema_migrations` 写 `running` 失败 | `REJECTED`（确认未写） | 服务可继续 | 直接重启，无需恢复 |
| F4 | DDL 执行抛错 | 事务 ROLLBACK → 判 `ABSENT` | `REJECTED` | 从快照恢复（若已部分动表） |
| F5 | 提交结果不确定 | `UNRESOLVED` → `HALTED` | 写入封锁 | 只读比对事件/表结构 → 人工决策 |
| F6 | `set_maintenance` 失败 | 继续封锁 → `fatal_exit("maintenance_unconfirmed")` | 进程退出，写入已被挡 | 修复后重启，走 `RECOVERY_REQUIRED` |
| F7 | 写入封锁无法确认 | `fatal_lockdown` + `fatal_exit("writes_block_unconfirmed")` | 进程退出 | 停容器（`docker stop`）后离线恢复 |
| F8 | 维护文件损坏/不可读 | `RECOVERY_REQUIRED` | 只读 + 503 | 人工修复或按 DB 判定后清理 |
| F9 | 恢复后订阅重建失败 | 记 `WARN`，不阻断启动 | 业务可写，订阅可能是旧版 | 手动重发 `builder.publish` |

原则：**任何失败都不允许"继续以可写状态对外服务"**；退出的进程绝不靠上层重试拉起（`restart: unless-stopped` 会让容器重启，但那只是重启，不是解封）。

---

## 8. 实施顺序与验收条件

| 步骤 | 内容 | 可回退性 | 验收条件 |
| --- | --- | --- | --- |
| P-1.1 | 生产探针（§1.3）与基线存档 | 只读（P-7 除外） | 探针输出回填本计划 §1.2.7 表格，全部判据通过 |
| P-1.2 | `schema_migrations` 表 + 基线登记 | 可 `DROP TABLE` | PT-06 通过；15 张业务表零变化 |
| P-1.3 | `backup.py`（`snapshot`/`verify`） | 删文件 + 开关回退 | PT-01/03/04 通过 |
| P-1.4 | `maint.py` + 启动自检 | 删文件 | PT-11/14 通过 |
| P-1.5 | 六通道封锁接线 | 拆中间件 | PT-15/16 通过 |
| P-1.6 | `migrate.py` 骨架（状态机 + 空迁移 dry-run） | 删文件 | PT-12/13/19 通过 |
| P-1.7 | 全链路演练（副本库 + 临时容器 8089） | 不影响生产 | PT-05/07/08/17/18/20 通过 |
| P-1.8 | 生产窗口（**需二次确认**，本轮不做） | 快照 + 回滚剧本 | 步骤 §6 全程无 5xx 毛刺，30 分钟观察通过 |

每步之间必须停下汇报，不得连做。P-1.1 之前不允许写任何代码。

---

## 9. 可能影响生产服务的操作与风险

| # | 操作/风险 | 影响面 | 缓解 |
| --- | --- | --- | --- |
| 1 | 维护期 503 | 全部业务写接口 | 窗口选在 `sub_publish` 之外（查 `next_at`），时长 ≤ 60s |
| 2 | 停写导致后台批次中断 | 当轮测试/评分缺失 | 允许丢失一轮（90 分钟 TTL 内自然补上），不做补偿写入 |
| 3 | 容器重启 | `restart: unless-stopped` 会拉起，前端短暂不可用 | 窗口内提前通知；重启后先只读观察 |
| 4 | 备份占用磁盘 | `data`/`backup` 同盘时可能写满 | 快照前检查余量 ≥ 3× 库大小且 ≥ 2 GB，超限拒绝迁移 |
| 5 | NAS 卷不支持原子 rename | maintenance 失效、`RECOVERY_REQUIRED` 误判 | P-7 自检前置；不支持则禁用迁移入口（业务不受影响） |
| 6 | WAL 未截断就恢复 | 恢复后库"看起来旧" | 恢复流程强制删 `-wal`/`-shm` 并 `checkpoint(TRUNCATE)` |
| 7 | `tasks` 等遗留表被误动 | 历史数据丢失 | 迁移白名单 + 明确忽略清单 + 演练逐表比对 |
| 8 | 迁移器 bug 导致半写 | 库结构不可用 | phase 状态机 + `halt` + 快照回滚，三保险 |
| 9 | 订阅文件与库版本错位 | 用户拿到旧订阅 | 恢复后统一 `publish("restore")`，并在 `/api/system/migration/status` 暴露 `last_publish` |
| 10 | 探针写测试（P-7）误伤 | 极低（64 字节临时文件） | 随机文件名、`finally` 清理、不触碰 `nodepool.db*` |

---

## 10. 交付物与停止点

本轮交付：**本计划文档**（不含代码）。已上传 GitHub 仓库根目录，文件名 `NodePoolME-P-1实施计划-v1.10.md`。

停止点：等总体审查确认 + 用户对 §1.3 探针（尤其 P-7 那一处写测试）的批准。**未获确认前不写任何业务代码、不动生产、不执行迁移、不进入 P-1.2。**

需要用户回填的空白（共 9 项，对应 §1.2.7 的 P-1–P-9）：生产库体量与行数、SQLite 版本、WAL 状态、未完成事务、备份现状、卷类型与原子性、运行身份、`sub_publish` 生效模式与 `next_at`。这些数据不回来，§2.3 的快照预算、§2.7 的排空窗口、§9 的时长都无法定稿，只能给区间。
