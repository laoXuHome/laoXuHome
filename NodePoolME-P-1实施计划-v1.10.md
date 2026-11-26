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

#### 1.2.7 待生产实测项（每项都必须有命令、输出字段、判据、副作用）

> 一张表管到底：**每项能否算"只读"要说清楚**，不允许存在"标着只读但实际会改库/改文件"的命令。

| 编号 | 必测项 | 命令（容器内执行） | 必须记录的输出字段 | 判据 | 副作用 |
| --- | --- | --- | --- | --- | --- |
| P-1 | 库体量与页数 | 只读连接 Python 片段（§1.3 第 1 段） | `path`、`bytes`、`page_size`、`page_count`、`freelist_count` | `page_size*page_count` ≈ `bytes`（差值 < 1 页）；`bytes > 0` | **只读**（`mode=ro`） |
| P-2 | SQLite 版本 | `python -c "import sqlite3;print(sqlite3.sqlite_version)"` | `sqlite_version` | ≥ 3.35.0（`ALTER TABLE`/触发器/`CHECK` 相关特性可用） | **只读** |
| P-3 | 表集合与行数 | 同 P-1 片段 | 每表 `count(*)`、`triggers` 列表、`tasks` 是否存在 | 17 张基准表齐全；`tasks` 若存在应为 0 行 | **只读** |
| P-4 | WAL/SHM 物理状态 | `ls -l /data/nodepool.db*`；只读 `PRAGMA journal_mode`、`PRAGMA integrity_check`、`PRAGMA foreign_key_check` | `journal_mode`、`-wal` 字节数、`-shm` 字节数、`integrity`、`fk_violations` | `journal_mode=wal`；`integrity=ok`；`fk_violations=0` | **只读**——**不执行 `wal_checkpoint`**（见 §1.3 注） |
| P-5 | 句柄 / 锁 / 未提交事务（三项分开看） | ①`lsof -p <pid>` 或 `/proc/<pid>/fd` 扫描；②`fuser -v /data/nodepool.db`；③只读连接内 `PRAGMA data_version` 前后取值 | ①持 `nodepool.db*` 的进程数；②外部持有者列表；③`data_version` 是否变化 | ①除主进程外应无其他持有者；③同一连接两次读取 `data_version` 不变即"期间无其他连接提交写"——**只能证明"没有已提交的写入"，不能证明"没有未提交事务"** | ①②**只读**；③**只读**（`data_version` 是只读 PRAGMA） |
| P-6 | 备份目录与空间 | `ls -lht /backup`、`du -sh /backup`、`df -h /backup /data` | 文件数、最新 mtime、`/backup` 占用、两处 `avail` | `avail ≥ 3× 库大小` 且 `≥ 2048 MB` | **只读** |
| P-7 | `STATE_DIR` 原子写能力 | §1.3 第 5 段探针（**在最终实际使用的 `STATE_DIR` 上跑**） | `state_dir`、`db_st_dev`、`state_st_dev`、`fs_type`、各步骤结果 | 同卷（`st_dev` 相等）∧ 写入/文件 fsync/rename/目录 fsync/回读/删除/再目录 fsync 全通过 | **写操作**（64 字节探针文件 + 可能创建 `STATE_DIR` 目录），需用户明确批准；不触碰 `nodepool.db*` |
| P-8 | 运行身份与权限 | `id`、`ls -ld /data /data/state /backup` | `uid/gid`、属主、权限位 | 主进程 uid 可写 `STATE_DIR` 与 `BACKUP_DIR` | **只读** |
| P-9 | `sub_publish` 当前配置与最近发布 | 只读连接查 `settings`（§1.3 第 4 段） | `sub_publish_enabled`、`sub_publish_mode`、`sub_publish_time`、`sub_publish_interval_minutes`、`sub_publish_next_at`、`logs` 中最近一条含"发布/订阅"的记录时间 | 能取到上述五项；`next_at` 非空或按模式可推算 | **只读** |
| P-10 | 镜像与运行版本 | `docker inspect`（镜像 tag + `RepoDigests`）、容器内 `python -c "import backend.config as c;print(c.VERSION)"`、`curl /healthz` | `image_tag`、`image_digest`、`app_version`、`healthz.version` | 三者一致（tag 指 `latest` 时以 digest 为准）；记入基线 | **只读** |

> P-5 的诚实边界：SQLite 没有对外的"未提交事务清单"接口。`lsof`/`fuser` 只能回答"谁打开了文件"，`PRAGMA data_version` 只能回答"别的连接有没有提交过写"，**都不能完整识别未提交事务**。因此 §2.7 的排空判据不依赖"证明没有未提交事务"，而是依赖"取得写锁成功 + `wal_checkpoint(TRUNCATE)` 返回 `(0,0,0)` + 连续两次探测"——这是**操作性判据**，不是事务级证明。

### 1.3 生产探针脚本（可直接复制执行）

> 只读/写边界写在每段注释里：第 1–4、6–8 段**只读**；第 5 段（P-7）是**唯一写操作**，必须用户批准后执行。
> **重要：任何 `PRAGMA wal_checkpoint(...)` 都不是只读操作**——它会回写 WAL 帧、可能截断 `-wal` 文件，从而改变磁盘状态。本探针脚本**不含** checkpoint；checkpoint 只在 §2.7 的停写窗口内、由迁移流程执行。

```bash
# 0) 容器、挂载、镜像（只读）
docker ps --format '{{.Names}}	{{.Image}}	{{.Status}}' | grep -i nodepool
docker inspect nodepool --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}'
# P-10：镜像 tag / digest / 运行版本
docker inspect nodepool --format '{{.Config.Image}}'
docker inspect nodepool --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'NODEPOOL_(DATA_DIR|STATE_DIR|DB|BACKUP_DIR)' || true
docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$(docker inspect nodepool --format '{{.Config.Image}}')"
docker exec nodepool python -c "import backend.config as c;print('app_version', c.VERSION)"

# 1) P-1/P-3/P-4：库体量、表行数、WAL 与完整性（只读，不 checkpoint）
docker exec nodepool python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", "/data/nodepool.db"))
print("path", p, "bytes", p.stat().st_size)
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
print("sqlite", sqlite3.sqlite_version)
for k in ("page_size", "page_count", "freelist_count", "journal_mode", "synchronous"):
    print(k, c.execute(f"PRAGMA {k}").fetchone())
for (n,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    print("table", n, c.execute(f'SELECT count(*) FROM "{n}"').fetchone()[0])
print("triggers", [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='trigger'")])
print("integrity", c.execute("PRAGMA integrity_check").fetchone()[0])
print("fk_violations", len(c.execute("PRAGMA foreign_key_check").fetchall()))
print("data_version", c.execute("PRAGMA data_version").fetchone()[0])
PY

# 2) P-4：WAL/SHM 物理实体（只读）
docker exec nodepool sh -c 'ls -l /data/nodepool.db* 2>/dev/null || true'

# 3) P-5：句柄与外部持有者（只读；只说明"谁打开了文件"，不说明"有无未提交事务"）
docker exec nodepool sh -c 'for f in /proc/[0-9]*/fd/*; do t=$(readlink "$f" 2>/dev/null); case "$t" in */nodepool.db*) echo "$f -> $t";; esac; done' | head -30
docker exec nodepool sh -c 'command -v fuser >/dev/null && fuser -v /data/nodepool.db 2>&1 || echo "fuser not installed"'

# 4) P-9：sub_publish 当前配置与最近发布（只读）
docker exec nodepool python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", "/data/nodepool.db"))
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
keys = ("sub_publish_enabled","sub_publish_mode","sub_publish_time",
        "sub_publish_interval_minutes","sub_publish_next_at")
for k in keys:
    r = c.execute("SELECT value FROM settings WHERE key=?", (k,)).fetchone()
    print("setting", k, None if r is None else r[0])
for r in c.execute("SELECT ts, level, category, message FROM logs ORDER BY id DESC LIMIT 20"):
    if any(x in str(r[3]) for x in ("发布","订阅","publish")):
        print("last_publish_log", tuple(r))
PY

# 5) P-7【唯一写操作，需批准】在最终 STATE_DIR 上验证原子写全链路
docker exec nodepool python - <<'PY'
import json, os, uuid
from pathlib import Path
DB   = Path(os.getenv("NODEPOOL_DB", "/data/nodepool.db"))
SD   = Path(os.getenv("NODEPOOL_STATE_DIR", "/data/state"))
created = False
if not SD.exists():
    SD.mkdir(parents=True); created = True          # 目录创建也属写，已在本段批准范围内
print("state_dir", SD, "created", created)
print("db_st_dev", os.stat(DB).st_dev, "state_st_dev", os.stat(SD).st_dev)
assert os.stat(DB).st_dev == os.stat(SD).st_dev, "STATE_DIR 与数据库不在同一文件系统"
n   = uuid.uuid4().hex[:8]
t   = SD / f"p1probe.{n}.tmp"
tgt = SD / f"p1probe.{n}.json"
ok  = {}
try:
    # ① 文件写入 + 文件 fsync（必须用可写 fd，不能 O_RDONLY 后 fsync）
    with open(t, "wb") as f:
        f.write(b'{"probe":true}')
        f.flush()
        os.fsync(f.fileno())
    # ② 同目录原子替换
    os.replace(str(t), str(tgt))
    # ③ 目录 fsync（目录只能用 O_RDONLY|O_DIRECTORY 打开，这是 fsync 的合法用法）
    dfd = os.open(str(SD), os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dfd); os.close(dfd)
    # ④ 回读
    ok["readback"] = json.loads(tgt.read_text(encoding="utf-8"))
    # ⑤ 删除 + 清理后目录 fsync
    tgt.unlink()
    dfd = os.open(str(SD), os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dfd); os.close(dfd)
    ok["cleanup"] = "done"
    print("probe OK", ok)
finally:
    for q in (t, tgt):
        try: q.unlink()
        except FileNotFoundError: pass
    if created:
        try: SD.rmdir()
        except OSError as e: print("keep empty STATE_DIR:", e)
PY

# 6) P-6：备份目录与磁盘余量（只读）
docker exec nodepool sh -c 'ls -lht /backup | head -20; du -sh /backup; df -h /backup /data'

# 7) P-8：运行身份与目录权限（只读）
docker exec nodepool sh -c 'id; ls -ld /data /data/state /backup /data/config 2>&1 || true'

# 8) 卷类型（只读）
docker exec nodepool sh -c 'stat -f -c "state_fs=%T block=%s" /data; stat -f -c "backup_fs=%T block=%s" /backup; mount | grep -E " /data | /backup " || true'
```

**探针判据汇总**：

| 判据 | 通过条件 | 不通过时怎么办 |
| --- | --- | --- |
| `integrity_check` | `ok` | 停止，先做只读抢救备份与磁盘排查，不进 P-1 |
| `fk_violations` | 0（基准库无外键，预期 0） | 记录来源，迁移前必须分析 |
| `journal_mode` | `wal` | 若为 `delete`，说明有连接改过设置，需查明 |
| `db_st_dev == state_st_dev` | 相等 | **不等 ⇒ 迁移功能永久禁用**（业务照常），不得改为共享目录 |
| P-7 全链路 | 写入/文件 fsync/rename/目录 fsync/回读/删除/再 fsync 全 `OK` | 任一失败（如共享卷返回 `EINVAL`）⇒ `maint_fs_unsupported` ⇒ 拒绝迁移 |
| `fs_type` | `ext4`/`xfs`/`btrfs`/本地 `overlayfs` | `nfs`/`cifs`/`fuse.*` ⇒ 同"拒绝迁移"，并在计划里记为已知限制 |
| 备份盘余量 | ≥ 3× 库大小 且 ≥ 2 GB | 先清理/扩盘，否则不改 |
| P-10 三值一致 | tag（或 digest）与实际 `app_version` 一致 | 不一致 ⇒ 不允许登记基线（§2.2） |

---

## 2. P-1 七项方案

前提：v1.10 的设计已被批准，本轮只把它落成**可执行的工程步骤**，不重新设计。以下每项给"目的 / 做法 / 触碰面 / 判据 / 回滚"。

### 2.1 SQLite 安全备份方案

**目的**：在 WAL 模式下得到**一致**快照，并且保证"拿到的备份一定配得上一份完整的清单"。

**做法**：

1. 一律用 SQLite 在线备份 API：`src.backup(dst, pages=1024)`，**禁止** `cp`/`shutil.copy2` 主库（§2.4 有实测反例：WAL 下 `copyfile` 得到"连表都没有"的库）。
2. 备份源用**独立只读连接**（`mode=ro`），不复用业务线程本地连接；分页备份，批间让出调度权。
3. **备份以"备份集目录"交付**，而不是单个 `.db` 文件：

```
BACKUP_DIR/nodepool-YYYYMMDD-HHMMSS-<stage>/
    db                 # SQLite 一致性快照
    manifest.json      # 逐表行数、关键表摘要、schema 版本、sqlite_version、created_at
    complete.json      # {db_sha256, manifest_sha256, bytes, finished_at, stage}
```

4. 发布顺序（必须严格按此，否则会出现"有 db 没清单"的假备份）：
   ① 在 `BACKUP_DIR/.tmp-<nonce>/` 内写 `db`、写 `manifest.json`、写 `complete.json`；
   ② 三个文件逐个 `flush + fsync`；
   ③ 计算 `db`/`manifest` 的 sha256 并写进 `complete.json`，再 `fsync` `complete.json`；
   ④ 对 `.tmp-<nonce>/` 目录 `fsync`；
   ⑤ `os.replace(".tmp-<nonce>", "nodepool-<stamp>-<stage>")`（同卷目录 rename，原子）；
   ⑥ `fsync(BACKUP_DIR)`。
5. **有效备份的唯一判据**：目录内 `db`、`manifest.json`、`complete.json` **三件齐全**，且 `complete.json` 里的两个 sha256 与实文件相符。缺任一件 ⇒ 视为**未完成/无效**：不计入可用备份、不参与恢复候选、不被清理策略删除（保留 24 小时后由人工处置）。
6. `nodepool-latest.db` 的兼容副本改为"指向最近一个完整备份集的软链接/复制件"，只有该备份集三件齐全时才更新；缺失时保持上一份不动。

**触碰面**：新增 `backend/database/backup.py`；`routes.py` 的 `/system/backup`、`/system/backup/download` 改调它（响应字段仍是 `ok/file/size`，`file` 传目录名）。

**判据**：PT-01/PT-02/PT-03/PT-03b 通过；`ok/file/size` 字段不破坏现有前端调用（前端只展示文件名与体积）。

**回滚**：删 `backup.py` + `NODEPOOL_BACKUP_IMPL=legacy` 回旧实现；已生成的备份集目录可直接删除（不影响业务）。

### 2.2 Schema 版本管理方案

**目的**：让"库处于哪个版本、迁移是否完成"成为可查询的持久事实；且**排序不能靠字符串**。

**做法**：

1. 表结构（比 v1.10 的表多一个排序键 `seq`，语义不变、DDL 仍由 P-1 独占）：

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  migration_id TEXT    NOT NULL,
  seq          INTEGER NOT NULL UNIQUE,      -- 唯一排序键：1,2,3… 单调递增
  version      TEXT    NOT NULL,             -- 仅展示，如 "1.8.7-baseline" / "1.10"
  status       TEXT    NOT NULL CHECK (status IN ('running','failed','success')),
  started_at   TEXT    NOT NULL,
  finished_at  TEXT,
  detail_json  TEXT,
  UNIQUE(migration_id)
);
```

2. **排序规则**：`current_version()` = `SELECT version FROM schema_migrations WHERE status='success' ORDER BY seq DESC LIMIT 1`。
   **禁止** `MAX(version)`、禁止 `ORDER BY version`——字符串比较会把 `1.10` 排在 `1.9` 之前。`seq` 由版本注册表（代码内常量 `VERSION_SEQ = {"1.8.7-baseline": 1, "1.10": 2, …}`）唯一分配，禁止运行时自增猜测。
3. **建表与基线必须同一事务**：`BEGIN IMMEDIATE` → `CREATE TABLE IF NOT EXISTS` → `INSERT` 基线行 → 校验 `SELECT count(*) == 1` → `COMMIT`；任一步异常 → `ROLLBACK`，因此**不存在"表在、基线缺"的状态**。若提交后发现表空（理论上不可达），按 §2.2.5 的 preflight 拒绝迁移。
4. **基线值必须与生产实际状态核对，不能凭仓库 commit 推断**：
   - `version` 取 P-10 的实测值（镜像 digest + 容器内 `config.VERSION` + `/healthz` 三者一致）；
   - `detail_json` 记录 `{"baseline":true,"app_version":…,"image_digest":…,"structure_hash":…,"tables":[…],"tasks_present":bool}`；
   - `structure_hash` = 对 `sqlite_master` 中所有表/索引的 `sql` 规范化（按 name 排序、去空白）后 sha256；与代码内 `BASELINE_STRUCTURE_HASH` 比对，不一致 ⇒ **拒绝登记**并报 `baseline_structure_mismatch`。
5. **迁移器 preflight 判定矩阵**（运行前置检查，不改 `maintenance_state()` 的语义）：

| 观测 | 结论 | 动作 |
| --- | --- | --- |
| 表不存在 | 迁移从未开始（对应 v1.10"表不存在 ⇒ `migration_incomplete()`=False"） | 建表 + 登记基线（同一事务） |
| 表存在且 **0 行** | 异常：基线缺失 | **拒绝迁移** + `migration_table_empty`；维护态仍按 `migration_incomplete()`=False（v1.10 语义不改），但迁移入口关闭 |
| 表存在，只有 `success` 行 | 正常 | 取 `seq` 最大者；`version` 与实测运行版本不一致 ⇒ 拒绝迁移 + 报 `version_mismatch` |
| 表存在，存在 `running`/`failed` | 迁移未完成 | `migration_incomplete()`=True ⇒ `RECOVERY_REQUIRED`（v1.10 语义，不改） |

6. `migration_incomplete()` 的实现口径**保持 v1.10 原样**：表不存在 ⇒ `False`；任一 `status <> 'success'` ⇒ `True`；查询异常 ⇒ 抛 `MaintUnverifiable`。本方案只增加"迁移器 preflight"这一层闸，不改变它的返回值。

**触碰面**：`db.py` 的 `SCHEMA` 追加该表；新增 `migrate.py` 的 `VERSION_SEQ`、`current_version()`、`record_baseline()`、`preflight()`。

**判据**：PT-06/PT-06b/PT-06c 通过（幂等、原子性、`1.10` 与 `1.9` 排序正确）；15 张业务表结构与行数零变化。

**回滚**：`DROP TABLE schema_migrations`（仅此表由 P-1 创建）。

### 2.3 迁移前自动快照方案

**目的**：任何 `ALTER`/重建之前先有"已验证可恢复"的快照；快照不可用即禁止继续。

**做法**：

1. 触发点：迁移器在写 `status='running'` **之前**调用 `snapshot(stage='pre-migrate')`。
2. 顺序固定为：置维护态 → 确认写入封锁（`confirm_writes_blocked`）→ `wal_checkpoint(TRUNCATE)` 且返回 `(0,0,0)` → 两次探测间隔 ≥10s → 备份 → L1+L2 → 才允许写 `running`。
3. 快照产物 = §2.1 的**完整备份集**（`db` + `manifest.json` + `complete.json`）；`manifest.json` 由**同一份备份文件**读出生成（不读实时源库），见 §2.4。
4. **同一快照一致性锚**：备份前后各取一次源库 `PRAGMA data_version`（只读连接）。两次相等 ⇒ 源库在备份期间无其他连接提交写 ⇒ 允许把 `manifest` 的行数与"停写后读到的源库计数"做等值比较（这是 L2 的唯一合法比较场景）。两次不等 ⇒ 只做备份内部自洽校验，禁止与源库比较。
5. 保留策略：`pre-migrate`/`pre-restore` 永不自动删除；`daily` 保留最近 3 份；其余按总量上限（默认库大小 ×10）滚动删除，删除前必须 `complete.json` 校验通过（防止把半成品当垃圾清掉）。

**触碰面**：`backup.py`、`migrate.py`；CLI `python -m backend.database.migrate snapshot --stage pre-migrate`。

**判据**：PT-07 通过（备份失败 ⇒ `halt_migration("snapshot_failed")`、不写 `running`、退出码非零、写入仍被拒）；快照 ≤60s（100 MB 库实测回填）。

**回滚**：删本次备份集目录即可。

### 2.4 备份完整性验证与恢复验证方案

**目的**：杜绝"备份存在但打不开/数据不全"的假安全，也杜绝"用实时库计数比备份造成误报或放宽"。

**做法**（三级，逐级独立）：

1. **L1 结构验证**：`mode=ro` 打开 `db` → `PRAGMA integrity_check` 必须 `ok` → `PRAGMA foreign_key_check` 0 行 → 17 张基准表齐全（`tasks` 若在则登记存在与否）→ `complete.json` 的两个 sha256 与实文件一致。
2. **L2 内容验证（严格限定比较对象）**：

| 场景 | 允许的比较 | 禁止 |
| --- | --- | --- |
| 停写后快照（`data_version` 前后相同） | 备份逐表 `count(*)` **与停写后读到的源库计数**逐表等值；关键表（`airports`/`nodes`/`settings`/`test_groups`）用规范化摘要比对 | —— |
| 在线备份（`data_version` 变化或未测） | 只做**备份内部自洽**：`manifest` 的计数必须由**同一份备份文件**读出并与之相符；`complete.json` 的 sha256 相符 | **禁止**拿备份与"备份完成后的实时源库"比较；也不得用实时计数"放宽"允许差异 |

   > 记一条硬规则：**L2 的参照物只能是同一快照**。实时源库在备份完成后仍在变，任何"实时计数 vs 备份计数"的比较都会产生随机差异，既可能误报也可能掩盖真实丢失。
3. **L3 恢复演练**：把备份集恢复到**独立路径**（`/tmp/restore-check/nodepool.db`），用**独立端口 8089** 起临时实例（`NODEPOOL_MIGRATION_ENABLED=0`），验证 `/healthz` 200、登录、机场/节点/设置条数与 `manifest` 一致、订阅四格式可重建；完成后停容器、删副本。
4. 门槛：`pre-migrate` 必须过 L1+L2；L3 在每次升级窗口前至少做一次。

**触碰面**：`backup.py` 的 `verify_set()`（L1+L2）、CLI `migrate verify --set <dir>`。

**判据**：PT-03/PT-04/PT-04b/PT-05 通过；构造"实时库比备份多 3 行"的场景，在线备份模式必须**不报错**（因为不做此比较），停写模式必须**报错**（因为参照物是同快照）。

**回滚**：验证是只读行为。

### 2.5 迁移失败保护与回滚方案（含 P-1 状态机能力边界）

**目的**：失败必须停在"可解释、可恢复"的状态，绝不出现"半迁移且继续对外服务"。

#### 2.5.1 P-1 到底实现哪一层状态机（边界必须写死）

v1.10 的完整事件链依赖 `system_events` / `migration_tx_notes` / 哈希链 / `token_fp` / `s5_failed_ever` / `settle_uncertain` / `reconcile_event`。P-1 **不建这两张表**，因此**只能实现最小状态机**，不得宣称完整实现：

| 能力 | P-1 是否实现 | 落地方式 |
| --- | --- | --- |
| `Phase` 枚举 + `LEGAL_TRANSITIONS` + 转换合法性检查 | ✅ | `migrate.py`，纯代码常量 |
| 单进程内存 phase 推进（`rec.phase` + `phase_epoch`） | ✅ | `set_phase_memory()`：先判合法转换，再赋值，异常即 `halt` |
| 阶段结果的**持久痕迹** | ✅（但有界） | 只写 `schema_migrations.status`（`running`/`failed`/`success`）+ `detail_json`，不写事件表 |
| 失败二分：`KNOWN_FAILED`（确认未提交）/ `OUTCOME_UNKNOWN`（无法确认） | ✅ | 由"事务是否已 BEGIN、`COMMIT` 是否已发出、能否只读复查"三个本地事实判定 |
| `halt_migration()` / `halt_tail()` / `fatal_lockdown` / `fatal_exit` / `migration-fault.log` | ✅ | 完全按 v1.10 §2.1/§2.2 的故障安全骨架 |
| `write_event()` A/B/C 三分类 | ❌ **不实现** | 占位函数**必须** `raise NotImplementedError("write_event requires system_events (P0)")`；**禁止**返回模拟 `COMMITTED`、禁止写空事件、禁止用 `schema_migrations` 冒充事件表 |
| 哈希链（`seq`/`prev_sha`/`token_fp`/`s5_failed_ever`） | ❌ | 属 P0 阶段；P-1 不建列、不校验 |
| `migration_tx_notes` / `note_or_stop` | ❌ | 同上 |
| `settle_uncertain()` / `reconcile_event()` | ❌ | 没有事件表就没有"重查事件"这回事；P-1 的不确定结果**直接进 halt** |

**依赖门（写进代码注释，防后人误以为已完整）**：
- `write_event` / `set_phase`（durable 分支）只有在 P0 建好 `system_events`（8 列 + 两个唯一约束 + 哈希链）并经审查后，才允许接入；
- P-1 的 `migrate.py` 中，任何调用 `write_event()` 的路径**必须**在 P0 之前不可达（默认 `NODEPOOL_MIGRATION_ENABLED=0`，且 `run()` 的 phase 推进只走内存 + `schema_migrations` 记录）；
- 报告口径：P-1 交付物描述为"**最小迁移状态机 + 故障安全 halt**"，**不得**写成"实现 v1.10 持久化事件链"。

#### 2.5.2 失败分流与回滚

1. `KNOWN_FAILED`（事务已 ROLLBACK，能只读确认表结构未变）⇒ 标记 `schema_migrations.status='failed'`、`detail_json` 记原因，恢复快照（若已动过表），清维护态（人工确认），重启。
2. `OUTCOME_UNKNOWN`（`COMMIT` 已发出但结果不明）⇒ **不重试、不重放**，直接 `halt_migration("commit_outcome_unknown")`：写 maintenance + 封锁写入 + 非 DB 日志；`halt_tail` 显式校验 `maintenance_ok ∧ writes_blocked`，否则 `fatal_lockdown + fatal_exit`。
3. 回滚动作顺序（严格）：停写 → 排空 → 关闭全部连接（不止线程本地）→ 用 `pre-migrate` 备份集恢复到同路径（原子替换 + 处理 `-wal`/`-shm`）→ L1/L2 校验 → 人工确认后清 `maintenance.json` → 重启 → 只读复核 → 允许写入。
4. **禁止**：迁移中途"再试一次"；halt 中追加任何数据库写入；`DROP` 任何业务表；用 `VACUUM` 代替恢复；把"确认未提交"当成"提交成功"。

**触碰面**：`migrate.py`（`run()` / `rollback_to_snapshot()` / `set_phase_memory()`）、`db.py`（新增 `close_all_connections()`，见 §3.3）。

**判据**：PT-08/PT-09/PT-09b 通过；注入 12 类故障后，最终状态只能是"已回滚并正常服务"或"halt 且拒绝写入"。

**回滚**（针对本项自身）：删 `migrate.py` 与 CLI 入口，业务代码零改动。

### 2.6 maintenance.json 持久化及文件系统兼容性验证方案

**目的**：把 v1.10 的三态判定落到真实文件系统；并先证明该目录支持"原子替换 + fsync"。

**做法**：

1. **状态目录必须独立，但不能跨卷**：

```
STATE_DIR = os.getenv("NODEPOOL_STATE_DIR", str(DATA_DIR / "state"))
MAINT_FILE = STATE_DIR / "maintenance.json"
```

   - `STATE_DIR` **不得**等于 `DATA_DIR`（v1.10 要求维护文件与业务 SQLite 分离；放同一目录会让"清理 data 目录"类操作误删维护文件，也不利于权限收紧）；
   - 但必须与 `DB_PATH` 在**同一文件系统**：启动时校验 `os.stat(STATE_DIR).st_dev == os.stat(DB_PATH).st_dev`，不等 ⇒ `state_dir_cross_device` ⇒ **拒绝迁移**（业务照常运行，不 503 全局）；
   - `NODEPOOL_STATE_DIR` 覆盖时同样必须过这条校验；覆盖路径不存在则创建（仅创建空目录，不写任何业务文件）。
2. 写入：`tmp.<nonce>`（以 `wb` 打开，`write` → `flush` → `os.fsync(f.fileno())` → `close`）→ `os.replace` → 目录 `fsync`（目录 fd 用 `O_RDONLY|O_DIRECTORY` 打开后 fsync，这是目录 fsync 的合法用法）→ `confirm_maint_write()` 回读校验。**注意：文件 fd 必须是可写 fd 才能 fsync，不能 `O_RDONLY` 打开后 fsync**。
3. 读取：`read_maint_file()` 四态（`ABSENT`/`PRESENT`/`CORRUPT`/`UNREADABLE`）+ `maintenance_state()` 三态；五个直接读取者只调这一个入口（§2.7）。
4. **启动自检**（每次启动跑一次，结果缓存；失败只禁用迁移）：在**真实 `STATE_DIR`** 上执行完整序列——建目录（若缺）→ 写探针文件 → 文件 fsync → `os.replace` → 目录 fsync → 回读比对 → 删除 → 再目录 fsync。任一步失败 ⇒ 日志 `maint_fs_unsupported`（附 `errno`）⇒ `start_migration()` 拒绝执行，`/api/system/migration/status` 暴露 `state_dir_ok=false`。
5. 回读失败/权限错误/IO 异常 ⇒ `UNREADABLE` ⇒ `RECOVERY_REQUIRED`（不查库、不放行）；文件缺失 ⇒ `ABSENT` ⇒ 才允许查库；损坏 ⇒ `CORRUPT` ⇒ 不查库。均按 v1.10 已定稿语义。

**触碰面**：新增 `backend/database/maint.py`；`config.py` 加 `STATE_DIR`；`main.py` 启动钩子（失败只禁用迁移）。

**判据**：PT-11/PT-14/PT-14b 通过（含跨卷拒绝、权限注入、自检失败降级）。

**回滚**：删 `maint.py` + 启动钩子 + `STATE_DIR` 目录；`maintenance.json` 手工删除即回到原行为（封锁能力一并回退）。

### 2.7 生产数据库升级期间的写入封锁与恢复流程

**目的**：窗口内保证"没有任何业务写落到库里"，窗口外一切照旧；并按 v1.10 的 **A/B 职责**组织，不让次级机制去读维护文件。

**A 类：维护态直接判定入口（只调 `maintenance_state()`，共用 `MAINT_FILE` 与唯一的 `migration_incomplete()`）**

| 入口 | 判定时点 | `ACTIVE` 行为 | `RECOVERY_REQUIRED` 行为 |
| --- | --- | --- | --- |
| 应用写入中间件 | 每个写请求进业务逻辑前 | 503 `reason=maintenance` | 503 `reason=recovery_required` |
| 后台任务（调度器） | 每轮开始前 | 本轮不运行，状态机 `stopped` | 不运行，且不得自行重试迁移 |
| CLI 写命令 | 执行前 | 拒绝；`--allow-write` 不绕过 | 同样拒绝 |
| `write_guard()` | 正式入口写前 | 抛 `WriteRefused("maintenance")`；另检 `foreign_keys=ON`、`recursive_triggers=ON` | 抛 `WriteRefused("recovery_required")` |
| 重启恢复 | 启动第一步（先于 `init_db()`） | 进入维护态、503 | 进入 `migration_recovery` 只读 |

**B 类：次级封锁机制（不读 maintenance.json，由 A 的结果驱动）**

| 机制 | 手段 | 与 A 的关系 |
| --- | --- | --- |
| 连接池 | `ACTIVE`/`RECOVERY_REQUIRED` 时池标 `dead`，`checkout` 抛 `PoolClosed` | 只接收 A 的判定结果，自身不去读文件 |
| `halt_tail()` | 只用 `halt_migration` 已回读确认的 `rec.maintenance_ok ∧ rec.writes_blocked` | 不重复读文件、不使用未验证状态 |
| 库层约束 + 巡检 | 触发器/外键 + `foreign_key_check` 事后巡检 | 兜底可观测，非维护态判定者 |

> 边界：A 回答"现在是否维护中"；B 回答"即使判错，写能不能落库"。B 不承担 A 的职责，A 不得用"已 503"替代 B 的硬封锁。

**排空判据**（停写后必须全部满足才可快照/迁移）：

1. `confirm_writes_blocked()` 通过：全局闸置位 ∧ 全部业务写连接已关闭 ∧ 只读连接 `PRAGMA query_only=1`；
2. `PRAGMA wal_checkpoint(TRUNCATE)` 返回 `(0, 0, 0)`；
   > 注意：checkpoint **会回写/截断 `-wal`**，属写操作，只能在停写窗口内由迁移流程执行，绝不能出现在只读探针里。
3. 无外部进程持有 `nodepool.db*`（容器内 `/proc/*/fd` 扫描或 `fuser`）；
4. 以上三条连续 2 次探测、间隔 ≥10s 均满足。

> 诚实说明：这四条是**操作性判据**。"没有未提交事务"无法被外部完整证明（§1.2.7 P-5 已说明 `lsof`/`data_version` 的局限）；因此排空的真正保证来自"我方取得写锁 + WAL 已截断 + 无其他持有者 + 连续两次稳定"，而不是事务级证明。若第 2 条拿不到 `(0,0,0)`，一律视为排空失败，走 `halt_migration("drain_failed")`。

**回滚/恢复**：清除维护态的唯一合法路径是"迁移 `success` 落库 + 人工确认 + 删 `maintenance.json` + 重启"；任何一步缺失都走 `RECOVERY_REQUIRED` 保守恢复。

---

## 3. 涉及的代码文件、表、接口、配置

### 3.1 代码文件

| 文件 | 改动性质 | 内容 |
| --- | --- | --- |
| `backend/database/db.py` | 修改（增量） | `SCHEMA` 追加 `schema_migrations`（带 `seq`）；新增 `connect_readonly()`、`table_exists()`、`close_all_connections()`（关闭全部线程连接，供恢复/迁移使用） |
| `backend/config.py` | 修改（增量） | 新增 `STATE_DIR`（默认 `DATA_DIR/state`）、备份/迁移相关配置项 |
| `backend/database/maint.py` | 新增 | `MAINT_FILE`、`MaintState`/`MaintRead`、`read_maint_file()`、`maintenance_state()`、`set_maintenance()`、`confirm_maint_write()`、`migration_incomplete()`、`selfcheck_state_dir()` |
| `backend/database/backup.py` | 新增 | `snapshot_set()`（备份集三件套 + 原子发布）、`verify_set()`（L1/L2）、`restore_set()`（安全恢复全流程）、`prune()` |
| `backend/database/migrate.py` | 新增 | `Phase`、`LEGAL_TRANSITIONS`、`VERSION_SEQ`、`current_version()`、`preflight()`、`record_baseline()`、`set_phase_memory()`、`halt_migration()`、`halt_tail()`、`run()`、`rollback_to_snapshot()`；`write_event()` 仅为**占位**（`raise NotImplementedError`） |
| `backend/api/routes.py` | 修改（薄） | `/system/backup`、`/system/backup/download`、`/system/restore` 改调 `backup.py`；新增 `GET /api/system/migration/status`（只读） |
| `backend/main.py` | 修改（薄） | 启动顺序：`selfcheck_state_dir()` → `maintenance_state()` → `init_db()` → 调度器；`/healthz` 加 `migration` 字段（状态码语义不变） |
| `backend/scheduler/manager.py` | 修改（一行判定） | 每轮开始前 `maintenance_state()`，非 `INACTIVE` 直接 return（不读文件、不自行查库） |
| CLI（`python -m backend.database.migrate`） | 新增 | `status/verify/snapshot/run/rollback`，全部受维护态约束 |

**不碰**：`backend/services/`（fetcher、builder）、`backend/testers/`、`backend/scoring/`、前端全部。节点身份、健康判定、评分、订阅下发规则零改动（`builder.publish()` 只在恢复后复用，语义不变）。

### 3.2 数据库表

| 表 | P-1 动作 |
| --- | --- |
| 17 张基准表 | **零 DDL 改动**，只读/校验 |
| `tasks`（遗留） | 登记、保留、不动；迁移 `LEGACY_IGNORED` 显式忽略 |
| `schema_migrations` | 新建（§2.2，含 `seq` 排序键）；唯一写入者 = 迁移器与基线登记 |
| `system_events` / `migration_tx_notes` | **P-1 不建**。因此 P-1 **不实现** v1.10 的持久化事件链（§2.5.1），halt 只写 `migration-fault.log` 与 maintenance 文件 |

> 这一条必须明确：v1.10 的 `system_events`（8 列 + 两个唯一约束 + 哈希链）属 P0 阶段。P-1 的 phase 痕迹只落在 `schema_migrations.status`，**不足以**承载 A/B/C 三分类与 `settle_uncertain`。任何"用 `schema_migrations` 冒充事件表"的写法都在本轮被禁止。

### 3.3 接口

| 接口 | 变化 |
| --- | --- |
| `POST /api/system/backup`、`GET /api/system/backup/download` | 实现换新（备份集），响应字段仍 `ok/file/size`，`file` 为备份集目录名 |
| `POST /api/system/restore` | 改为走 `restore_set()` 的完整安全流程（见下） |
| `GET /api/system/migration/status` | 新增只读：`app_version`、`image_digest`、`schema_version`、`phase`、`maintenance_state`、`state_dir_ok`、`last_backup`（脱敏，不暴露绝对路径） |
| `GET /healthz` | 增加 `migration` 字段；**状态码语义不变**（避免 docker healthcheck 抖动） |
| 所有业务写接口 | 维护期 503（新增中间件，带 `reason`） |

**`restore_set()` 的完整安全流程（逐步，缺一不可）**

1. **停服**：把实例置于维护态并停止调度器；如为外部恢复，`docker stop nodepool` 之后再做文件操作（避免文件被打开）。
2. **关闭所有数据库连接**：`close_all_connections()` 遍历并关闭本进程所有线程连接（不是只关当前线程的 `reset_connection()`），并置"连接池不可用"，此后任何 `connect()` 直接抛 `PoolClosed`。
3. **确认没有其他进程句柄**：容器内 `/proc/*/fd` 扫描或 `fuser`，必须无 `/data/nodepool.db*` 的第三方持有者；有 ⇒ 中止恢复（`restore_handles_present`），不做任何文件替换。
4. **处理 WAL/SHM**：确认无持有者后，删除 `nodepool.db-wal`、`nodepool.db-shm`（它们属于旧库）；此步必须在"无连接、无进程"前提下，否则会损坏数据。
5. **临时恢复文件**：把上传/选定的备份集 `db` 复制到 `STATE_DIR` 同卷的临时文件 `restore-<nonce>.db`，`flush + fsync`，回读 `PRAGMA integrity_check` 与表集合校验。
6. **原子替换**：`os.replace(tmp, DB_PATH)`（同卷 rename；跨设备会 `EXDEV`，因此临时文件必须落在同一文件系统），随后 `fsync(DB_PATH 所在目录)`。
7. **失败回退**：替换前先做 `pre-restore` 备份集（同样三件套）；替换后若 `init_db()` 或 L1 校验失败 ⇒ 立即用 `pre-restore` 备份集再走一次 1–6，恢复原状；回退也失败 ⇒ 进入 `halt_migration("restore_failed")`，写入保持封锁，等人工处理。
8. **恢复后校验**：`init_db()` → `PRAGMA integrity_check` → 逐表计数与备份 `manifest` 比对 → `builder.publish("restore")` → 解除维护态（人工确认）→ 重启 → 只读复核。
9. 全程禁止：只 `reset_connection()` 就 `shutil.copy2` 覆盖（现有实现的做法）、在仍有连接时删 `-wal`、把 `latest.db` 当恢复源。

### 3.4 配置

| 变量 | 默认 | 用途 |
| --- | --- | --- |
| `NODEPOOL_STATE_DIR` | `<DATA_DIR>/state` | maintenance 文件目录：**独立目录、与库同卷**；跨卷即拒绝迁移 |
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
| WAL 残留导致恢复不干净 | `restore_set()` 必须：停服/停调度 → `close_all_connections()`（全部线程，不止当前线程）→ 确认无其他进程句柄 → 删 `-wal`/`-shm` → 临时文件 fsync → 同卷原子替换 → 目录 fsync → `init_db()` → `checkpoint(TRUNCATE)` → L1 校验（详见 §3.3） |
| 备份被误删 | `pre-migrate`/`pre-restore` 标记为受保护，滚动清理跳过 |

---

## 5. 测试用例与通过判据

全部在**副本库**（生产库的备份）与一次性库上执行，不碰生产。

| 编号 | 场景 | 通过判据 |
| --- | --- | --- |
| PT-01 | `snapshot_set()` 在 WAL 且有并发写时执行 | 备份 `integrity_check=ok`；未提交行不出现（【实测】5,000 行库 0.002s、`dirty` 行未进备份）；**不要求**与实时源库行数相等（在线模式见 PT-04b） |
| PT-02 | `cp nodepool.db` 与备份 API 对比（教学用） | 证明 `cp` 得到"无表"库（【实测】已复现），写入计划文档防回归 |
| PT-03 | `verify_backup()` L1 | 良好备份全绿；截断 1 KB / 篡改页 / 删除表 三种坏备份必须失败 |
| PT-04 | L2（停写场景）行数与摘要比对 | 故意少 1 行 ⇒ 失败并报出表名 |
| PT-04b | L2 参照物规则（在线备份场景） | 在线备份**不得**与"备份完成后的实时源库"比较：构造"实时库多 3 行" ⇒ 仍通过且不报警；停写场景同一构造 ⇒ 必须报警。用来钉死"参照物只能是同一快照" |
| PT-05 | L3 恢复演练（独立端口 8089） | `/healthz` 200；机场/节点/设置条数与源一致；订阅四格式可重建 |
| PT-06 | `schema_migrations` 幂等 | 连续启动 5 次，行数恒为 1；`status='success'`；`seq` 不变 |
| PT-06b | 版本排序 | 手工插入 `seq=1 version='1.9'`、`seq=2 version='1.10'`（均 success）⇒ `current_version()` 必须返回 `1.10`；把实现改成 `MAX(version)` 的负向对照必须失败 |
| PT-06c | 基线原子性 | 在 `INSERT` 基线行前注入异常 ⇒ 事务回滚 ⇒ 表与基线**同时不存在**（不出现"表在行缺"）；再启动一次正常登记，行数 1 |
| PT-06d | 基线核对 | 故意把 `structure_hash` 与实测 `sqlite_master` 摘要不一致 / `app_version` 与 P-10 不一致 ⇒ 拒绝登记并报 `baseline_structure_mismatch` / `version_mismatch` |
| PT-07 | 迁移注入"备份失败" | `halt_migration("snapshot_failed")`；不写 `running`；退出码非零；写入仍被拒 |
| PT-08 | 迁移注入"`ALTER` 中途抛错" | 事务回滚；`running` → `failed`；快照恢复后 L1/L2 通过；服务可写 |
| PT-09 | 注入 `set_maintenance()` 抛错但封锁成功（对应 MC63） | `maintenance_ok=False` ⇒ `fatal_exit("maintenance_unconfirmed")`；不返回正常 `HALTED`；零 DB 写入 |
| PT-09b | P-1 状态机边界 | 调用 `write_event()` 必须抛 `NotImplementedError`；`run()` 在 `NODEPOOL_MIGRATION_ENABLED=0` 时不可达；`schema_migrations` 只有 `running/failed/success`，无事件表、无哈希链列 |
| PT-10 | 持久化成功但回读不一致（改 `nonce`/`phase`/截断）（MC64） | 同 PT-09 结论；`guard_log` 降级链有效 |
| PT-11 | 文件四态（MC68 a–p） | `ACTIVE/INACTIVE/RECOVERY_REQUIRED` 与查库次数逐项符合 §2.1 矩阵；`10**1000` 不抛 `OverflowError` |
| PT-12 | 分派表自检（MC67） | 普通模式与 `-O` 均 `DispatchTableBroken` 拒绝启动 |
| PT-13 | 事件接口无裸 bool（MC65） | 返回 `WriteOutcome`；`LOCAL` 只在 tx_local |
| PT-14 | P-7 文件系统自检 | 在**真实 `STATE_DIR`** 上：写入/文件 fsync/rename/目录 fsync/回读/删除/再目录 fsync 全通过；跨设备 rename 报 `EXDEV`（【实测】errno 18） |
| PT-14b | `STATE_DIR` 同卷校验 | `STATE_DIR` 与 `DB_PATH` 的 `st_dev` 不等 ⇒ `start_migration()` 拒绝（`state_dir_cross_device`），业务仍 200；`STATE_DIR == DATA_DIR` 的配置必须被拒绝启动检查拦下 |
| PT-15 | 五入口 + 两会话封锁（A/B 表） | 维护期：HTTP 503、调度器停、池 `PoolClosed`、CLI 非零、`write_guard` 抛、重启仍 503；`RECOVERY_REQUIRED` 与 `ACTIVE` 行为分别命中 |
| PT-16 | 停写排空 | `wal_checkpoint(TRUNCATE)=(0,0,0)`；两次探测间隔 ≥10s 均满足 |
| PT-17 | 回滚剧本 | 从 `pre-migrate` 恢复后：行数/摘要一致、无 `-wal` 残留、订阅重建成功、`maintenance.json` 需人工确认才移除 |
| PT-18 | 保守恢复（MC66(4)） | 删文件 + 非 `success` 行 ⇒ 五入口一致 `RECOVERY_REQUIRED`，写入不开放 |
| PT-19 | 迁移窗口内重启 | 重启后仍 `RECOVERY_REQUIRED`/`ACTIVE`，不自动推进 phase、不补写事件 |
| PT-20 | 性能预算 | 100 MB 库：快照 ≤ 5s、排空 ≤ 30s、总停写窗口 ≤ 60s（演练实测后回填实际值） |
| PT-21 | 备份集原子交付 | 只留 `db` 不留 `manifest.json` ⇒ 该备份集判为无效、不进可用列表、不被清理删除；只留 `manifest` 不留 `db` 同样无效；`complete.json` 的 sha256 与实文件不符 ⇒ 无效 |
| PT-22 | 恢复全流程 | 注入"仍有第三方句柄"⇒ 中止且不改文件；注入"替换后 `init_db()` 失败"⇒ 自动回退 `pre-restore` 且回到原库；全程断言 `-wal`/`-shm` 在替换前已清、替换是 `os.replace` 而非 `copy2` |
| PT-23 | A/B 职责分离（五入口 + 二次级机制） | 连接池与 `halt_tail` 的代码路径中**静态扫描**无 `MAINT_FILE`/`read_maint_file` 引用；五入口全部引用同一 `maintenance_state()` |
| PT-24 | 探针脚本副作用审计 | 第 1–4、6–8 段在一次性副本库上执行，前后 `sha256(db)`、`-wal` 大小、`mtime` 均不变；第 5 段只在 `STATE_DIR` 造文件、不触碰 `nodepool.db*` |
| PT-25 | `migration_incomplete()` 语义保持 | 表不存在 ⇒ `False`；有 `running`/`failed` ⇒ `True`；查询异常 ⇒ `MaintUnverifiable`；空表的"拒绝迁移"只由 preflight 产生，不改该函数返回值 |
| PT-26 | 清理策略保护 | `pre-migrate`/`pre-restore` 在滚动清理中永不被删；半成品备份集 24 小时内不被删 |

判据统一口径：**每一项必须给出"命令 + 期望输出 + 不通过时的处置"**；"跑通了"不算通过，必须贴输出。

---

## 6. 备份恢复验证步骤（可照做）

1. 停写：置维护态（`maintenance.json`）→ 等后台任务本轮结束 → `wal_checkpoint(TRUNCATE)`。
2. 快照：`migrate snapshot --stage pre-migrate` → 得到备份集目录 `nodepool-<stamp>-pre-migrate/`（`db` + `manifest.json` + `complete.json` 三件齐全）。
3. 验证：`migrate verify --set <备份集目录>` → L1 结构 + L2（停写场景下与同快照的源库计数等值；`manifest` 的计数必须由同一份备份文件读出）。
4. 副本演练：把备份集的 `db` 拷到 `/tmp/restore-check/`，起临时容器 `-p 8089:8080`、`NODEPOOL_DB` 指向副本、`NODEPOOL_MIGRATION_ENABLED=0`、`NODEPOOL_STATE_DIR` 指向临时空目录。
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
| F3 | `schema_migrations` 写 `running` 失败 | 记 `KNOWN_FAILED`（事务已回滚、只读确认未写） | 服务可继续 | 直接重启，无需恢复 |
| F4 | DDL 执行抛错 | 事务 ROLLBACK → 判 `KNOWN_FAILED` | 标 `failed`，服务可继续 | 从快照恢复（若已部分动表） |
| F5 | 提交结果不确定 | 判 `OUTCOME_UNKNOWN` → `halt_migration("commit_outcome_unknown")` | 写入封锁 | 只读比对表结构与 `schema_migrations` → 人工决策（P-1 无事件表可重查） |
| F6 | `set_maintenance` 失败 | 继续封锁 → `fatal_exit("maintenance_unconfirmed")` | 进程退出，写入已被挡 | 修复后重启，走 `RECOVERY_REQUIRED` |
| F7 | 写入封锁无法确认 | `fatal_lockdown` + `fatal_exit("writes_block_unconfirmed")` | 进程退出 | 停容器（`docker stop`）后离线恢复 |
| F8 | 维护文件损坏/不可读 | `RECOVERY_REQUIRED` | 只读 + 503 | 人工修复或按 DB 判定后清理 |
| F9 | 恢复后订阅重建失败 | 记 `WARN`，不阻断启动 | 业务可写，订阅可能是旧版 | 手动重发 `builder.publish` |
| F10 | 恢复时仍有第三方句柄 | 中止恢复（`restore_handles_present`） | 原库不动 | 停容器后重试 |
| F11 | 备份集缺 `manifest`/`complete` | 判无效，不进恢复候选 | 业务不受影响 | 重新备份 |

原则：**任何失败都不允许"继续以可写状态对外服务"**；退出的进程绝不靠上层重试拉起（`restart: unless-stopped` 会让容器重启，但那只是重启，不是解封）。

---

## 8. 实施顺序与验收条件

| 步骤 | 内容 | 可回退性 | 验收条件 |
| --- | --- | --- | --- |
| P-1.1 | 生产探针（§1.3，P-1~P-10）与基线存档 | 只读（P-7 例外） | 十项输出逐项回填 §1.2.7；每项判据通过；P-7 与 P-10 缺一即不得进 P-1.2 |
| P-1.2 | `schema_migrations`（含 `seq`）+ 原子基线登记 | 可 `DROP TABLE` | PT-06/06b/06c/06d 通过；基线 `version` 由 P-10 实测值确定；17 张业务表零变化 |
| P-1.3 | `backup.py`（备份集三件套 + `verify_set`） | 删文件 + 开关回退 | PT-01/03/04/04b/21 通过 |
| P-1.4 | `maint.py` + `STATE_DIR` 同卷校验 + 启动自检 | 删文件 | PT-11/14/14b/24 通过 |
| P-1.5 | 五入口 + 二次级机制接线（A/B 分离） | 拆中间件 | PT-15/16/23 通过 |
| P-1.6 | `migrate.py` 最小状态机（无事件链）+ 空迁移 dry-run | 删文件 | PT-09b/12/13/19/25 通过；`write_event()` 抛 `NotImplementedError` |
| P-1.7 | 全链路演练（副本库 + 临时容器 8089） | 不影响生产 | PT-05/07/08/17/18/20/22/26 通过 |
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
| 10 | 探针写测试（P-7）误伤 | 极低（64 字节临时文件 + 可能新建空 `STATE_DIR`） | 随机文件名、`finally` 清理、不触碰 `nodepool.db*`、目录为空则一并删除 |
| 11 | 把 `wal_checkpoint` 当只读操作误用 | 会在任意时刻改动 `-wal`，干扰排查甚至抢锁 | 只读探针禁止 checkpoint；checkpoint 只出现于停写窗口（PT-24 审计） |
| 12 | 恢复时只关当前线程连接 | 其他线程句柄仍持有旧库，替换后读到旧 inode | `close_all_connections()` + 句柄扫描 + 替换前中止条件（PT-22） |
| 13 | 基线版本猜错（凭 commit 推断） | 版本记录与真实运行版本不符，后续迁移误判 | 基线必须用 P-10 实测（tag/digest/`config.VERSION`/`healthz`）并核对结构摘要 |
| 14 | 备份集"有库无清单"被当有效 | 恢复时缺校验依据 | 三件齐全判据 + 半成品 24h 保护（PT-21） |

---

## 10. 交付物与停止点

本轮交付：**本计划文档**（不含代码）。已上传 GitHub 仓库根目录，文件名 `NodePoolME-P-1实施计划-v1.10.md`。

停止点：等总体审查确认 + 用户对 §1.3 探针（尤其 P-7 那一处写测试）的批准。**未获确认前不写任何业务代码、不动生产、不执行迁移、不进入 P-1.2。**

需要用户回填的空白（共 10 项，对应 §1.2.7 的 P-1–P-10）：库体量与页数、SQLite 版本、表集合与行数、WAL/SHM 物理状态、句柄与外部持有者（含"未提交事务不可外部完整证明"这一限制）、备份目录与空间、`STATE_DIR` 同卷与原子性、运行身份与权限、`sub_publish` 当前配置与 `next_at`、镜像 digest 与 `app_version`。

其中三项直接决定门槛，缺任一项不得进 P-1.2：
① **P-7**（`STATE_DIR` 同卷 + 原子写全链路）——决定 maintenance 方案能不能用；
② **P-10**（镜像 digest + `app_version`）——决定基线 `version` 写什么，不能凭 commit 推断；
③ **P-4**（`integrity_check` 与 `journal_mode`）——决定库本身是否允许动手。

本轮修正说明（相对上一版）：P-5 拆成"句柄/锁/未提交事务"三件事并删除只读探针里的 `wal_checkpoint`；P-7 修正 fsync 的 fd 用法并补齐"写入→文件 fsync→rename→目录 fsync→回读→删除→再 fsync"，且强制在真实 `STATE_DIR` 上跑；`STATE_DIR` 改为独立子目录 + 同卷校验；六通道按 A/B 重排；P-1 明确只实现最小状态机（不建事件表、不冒充完整事件链）；`schema_migrations` 增加 `seq` 排序键、基线原子登记并强制与实测版本核对；L2 参照物限定为同一快照；备份改为"三件套 + 原子发布"；恢复流程补全停服/全连接关闭/句柄确认/WAL 处理/原子替换/失败回退。
