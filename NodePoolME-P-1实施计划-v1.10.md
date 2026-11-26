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
| P-3 | 表集合与行数 | 同 P-1 片段 | 每表 `count(*)`、`triggers` 列表、`tasks` 是否存在及行数 | 17 张基准表齐全；`tasks` 存在与否都合法（预期 0 行；非 0 只记录、**不阻迁移、不动它**） | **只读** |
| P-4 | WAL/SHM 物理状态 | `ls -l /data/nodepool.db*`；只读 `PRAGMA journal_mode`、`PRAGMA integrity_check`、`PRAGMA foreign_key_check` | `journal_mode`、`-wal` 字节数、`-shm` 字节数、`integrity`、`fk_violations` | `journal_mode=wal`；`integrity=ok`；`fk_violations=0` | **只读**——**不执行 `wal_checkpoint`**（见 §1.3 注） |
| P-5 | 句柄 / 锁 / 未提交事务（三项分开看） | ①`lsof -p <pid>` 或 `/proc/<pid>/fd` 扫描；②`fuser -v /data/nodepool.db`；③只读连接内 `PRAGMA data_version` 前后取值 | ①持 `nodepool.db*` 的进程数；②外部持有者列表；③`data_version` 是否变化 | ①除主进程外应无其他持有者；③同一连接两次读取 `data_version` 不变即"期间无其他连接提交写"——**只能证明"没有已提交的写入"，不能证明"没有未提交事务"** | ①②**只读**；③**只读**（`data_version` 是只读 PRAGMA） |
| P-6 | 备份目录与空间 | `ls -lht /backup`、`du -sh /backup`、`df -h /backup /data` | 文件数、最新 mtime、`/backup` 占用、两处 `avail` | `avail ≥ 3× 库大小` 且 `≥ 2048 MB` | **只读** |
| P-7 | `STATE_DIR` 原子写能力 | §1.3 第 5 段探针（**在最终实际使用的 `STATE_DIR` 上跑**） | `state_dir`、`db_st_dev`、`state_st_dev`、`fs_type`、各步骤结果 | 同卷（`st_dev` 相等）∧ 写入/文件 fsync/rename/目录 fsync/回读/删除/再目录 fsync 全通过 | **写操作**（64 字节探针文件 + 可能创建 `STATE_DIR` 目录），需用户明确批准；不触碰 `nodepool.db*` |
| P-8 | 运行身份与权限 | `id`、`ls -ld /data /data/state /backup` | `uid/gid`、属主、权限位 | 主进程 uid 可写 `STATE_DIR` 与 `BACKUP_DIR` | **只读** |
| P-9 | `sub_publish` 当前配置与最近发布 | 只读连接查 `settings`（§1.3 第 4 段） | `sub_publish_enabled`、`sub_publish_mode`、`sub_publish_time`、`sub_publish_interval_minutes`、`sub_publish_next_at`、`logs` 中最近一条含"发布/订阅"的记录时间 | 能取到上述五项；`next_at` 非空或按模式可推算 | **只读** |
| P-10 | 镜像与运行版本（四值） | ①`docker inspect nodepool --format '{{.Config.Image}}'`；②`docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' <image>`；③容器内 `python -c "import backend.config as c;print(c.VERSION)"`；④`curl -s localhost:8080/healthz` 并解析 `version` 字段（§1.3 第 0 段） | `image_tag`、`image_digest`、`app_version`、`healthz_version`、`healthz_raw` | 四值核对规则见下；若 `/healthz` 无版本字段 ⇒ 记 `healthz_version=ABSENT`，**降级为三值核对并标记为待补能力**，不得写成"四值已核对" | **只读** |

> **P-10 四值核对规则（写死，避免"看起来一致"）**：
> 1. `image_tag` 必须是**可解析到 digest 的引用**（`repo:tag`）；生产用 `latest`，则 tag 本身没有唯一性，**以 `image_digest` 为准**。
> 2. `image_digest` = 运行容器实际使用的镜像 digest（`RepoDigests` 中与 `Config.Image` 同 repo 的那一条；若有多条且与容器 `Image` 的 `sha256:` 不一致 ⇒ 判为 `digest_ambiguous`，停止并人工确认）。
> 3. `app_version` = 容器内 `config.VERSION`（读的是**镜像内代码**，不是宿主机仓库）。
> 4. `healthz_version` = `/healthz` 响应里的版本字段（若有）。基准代码的 `/healthz` 只返回 `{"status":"ok"}` 之类的存活标记（见审查报告 B14），**很可能没有版本字段**——这正是必须实测而不能假设的原因。
> 5. 判定：`app_version` 与 `image_tag` 的版本段一致（如 `1.8.7`）且 `image_digest` 与容器实际镜像一致 ⇒ 记 `baseline_verifiable=true`；`healthz_version` 存在时还必须与 `app_version` 相等。任一不等 ⇒ `baseline_unverifiable`，**禁止登记基线**。
> 6. `healthz_version=ABSENT` 时：三值核对通过即可登记基线，同时在 §10 空白项里保留"`/healthz` 增加版本字段"为**待补能力**（属 P0 之后的能力增强，不在 P-1 范围）。**禁止**用 `image_tag` 文本去冒充"healthz 已返回版本"。
>
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
docker exec nodepool python -c "import backend.config as c;print('app_version', c.VERSION, 'data_dir', c.DATA_DIR, 'db', c.DB_PATH)"
# P-10 ④：/healthz 原样响应 + 版本字段提取（无该字段时明确记 ABSENT，不猜测）
curl -s -o /tmp/hz.json -w 'healthz_http_code=%{http_code}\n' http://127.0.0.1:8080/healthz
cat /tmp/hz.json; echo
python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/hz.json", encoding="utf-8"))
except Exception as e:
    print("healthz_version", "UNPARSEABLE", e); raise SystemExit
v = d.get("version") if isinstance(d, dict) else None
print("healthz_version", v if isinstance(v, str) and v else "ABSENT")
print("healthz_keys", sorted(d.keys()) if isinstance(d, dict) else type(d).__name__)
PY
rm -f /tmp/hz.json   # 只在容器 /tmp 内清理，不触碰 /data

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

# 3) P-5：句柄 / 外部持有者 / data_version 双读（只读）
#     data_version 必须在【同一个只读连接】上读两次，比较 before/after/changed
docker exec nodepool python - <<'PY'
import sqlite3, os, time
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", "/data/nodepool.db"))
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)   # 同一连接，不做 checkpoint
before = c.execute("PRAGMA data_version").fetchone()[0]
time.sleep(2)
after  = c.execute("PRAGMA data_version").fetchone()[0]
print("data_version_before", before)
print("data_version_after ", after)
print("data_version_changed", before != after)
c.close()
PY
# 边界（必须保留）：只能判断"放到其他连接是否提交过写入"；不能证明不存在未提交事务
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
| P-10 版本核对 | `app_version` 与 tag 版本段一致 ∧ `image_digest` 与容器实际镜像一致；`healthz_version` 存在时还须相等 | 不一致 ⇒ `baseline_unverifiable`，不允许登记基线（§2.2）；`healthz_version=ABSENT` ⇒ 三值通过即可登记，同时记入待补能力 |
| P-5 `data_version_changed` | `false`（同一连接两次读一致） | `true` ⇒ 期间有其他连接提交过写，说明仍有活动写入方，必须先查明；**该结果不能反证"无未提交事务"** |

---

## 2. P-1 七项方案

前提：v1.10 的设计已被批准，本轮只把它落成**可执行的工程步骤**，不重新设计。以下每项给"目的 / 做法 / 触碰面 / 判据 / 回滚"。

### 2.1 手动备份导出方案（v1.10 修订：单文件）

**目的**：用户手动执行一条命令，得到一个**独立、可校验、可交付**的数据库备份文件；允许在服务运行期执行。

**做法**：

1. 一律用 SQLite 在线备份 API（`src.backup(dst, pages=1024)`）。**禁止** `cp`/`shutil.copy2` 正在使用的库：WAL 下文件拷贝会得到缺表丢行的副本（§2.4 有实测反例）。
2. 备份源用**独立连接**：冻结文件用 `mode=ro&immutable=1`；活库必须 `mode=rw` + `PRAGMA query_only=1`（纯 `mode=ro` 在 WAL 有未 checkpoint 页时会读到旧数据，实测会丢已提交行），不复用业务线程连接。
3. **产物是单文件 + 同名元信息**，不再是"备份集目录"，也不再有三件套：

```
BACKUP_DIR/nodepool-YYYYMMDD-HHMMSS-<label>-<6位hex>.db    # 一致性快照（独立文件，可单独拷走）
BACKUP_DIR/nodepool-YYYYMMDD-HHMMSS-<label>-<6位hex>.json  # 元信息（与 .db 同基名，强制成对）：created_at/app_version/sqlite_version/
                                                 # db_bytes/sha256/integrity_check/structure_hash/
                                                 # structure_profile/schema_version/tasks/tables/key_digests
```

4. 发布顺序：`.tmp-<nonce>.db` 写入 → `fsync` → **独立只读连接**上 `integrity_check` + 表集合 + 结构摘要 → 全部通过才落名 → 目录 `fsync` → 写元信息（含 sha256）→ 目录 `fsync`。校验不过即删除临时文件，**不产生半成品文件**。
   落名用 `os.link(tmp, candidate)` 的**排他语义**：候选名自带 6 位随机后缀，`FileExistsError` 就换名重试（上限 64 次），**绝不 `os.replace` 覆盖已有备份**；同秒连续导出、并发导出都必须各自得到唯一文件名；程序不删任何旧备份。
5. **元信息强制成对且内容实配**：`.db` 与同名 `.json` 缺一即无效；`REQUIRED_META_FIELDS`（format=2、created_at、app_version、sqlite_version、db_bytes、sha256、integrity_check、structure_hash、structure_profile、schema_version、tasks、tables、key_digests）缺任一字段、JSON 不可解析、`format` 非 2、`db_bytes`/`sha256`/`structure_hash`/`integrity_check` 与实文件不匹配，一律 `verify` 失败。除存在性外，还要把可从数据库重算的 `tables`/`structure_profile`/`schema_version`/`tasks`/`key_digests` 与备份库实际结果**逐项比对**（`META_CONTENT_FIELDS`），任一不等即 `meta_<field>_mismatch`。`verify` 与 `import` 调用**同一函数**、同一严格规则；无效备份不得进入维护态、不得改目标库。
5. **不做滚动清理**：备份由用户保管，程序不自动删除、不生成 `nodepool-latest.db` 指针、不设 `pre-migrate`/`pre-restore` 保护标记。
6. CLI：`python -m backend.database.cli backup [--out DIR] [--label manual]`；`/api/system/backup` 与 `/download` 复用同一函数（`ok/file/size/sha256/integrity_check`）。

**判据**：PBT-01（导出单文件+元信息）、PBT-02（运行期导出一致性）、PBT-03（完整性校验）通过；100 MB 库导出 ≤5s。

**回滚**：删除 `backup.py` 的导出路径即可；产物是独立文件，不涉及库内状态。

### 2.2 Schema 版本管理方案

**目的**：让"库处于哪个版本、迁移是否完成"成为可查询的持久事实；且**排序不能靠字符串**。

**做法**：

1. **谁建这张表（必须钉死）**：`schema_migrations` **不得**进入 `db.py` 的通用 `SCHEMA`，`init_db()` 永不创建它。建表、基线登记、数量校验三件事只能由迁移器在同一个 `BEGIN IMMEDIATE` 事务内完成。理由：一旦普通初始化提前建出空表，下一次迁移 preflight 会读到"表存在但 0 行"，按 §2.2.5 直接拒绝迁移——形成"启动即把迁移入口焊死"的死锁式流程。

   启动顺序固定为：`selfcheck_state_dir()` → `maintenance_state()`（此时表不存在 ⇒ `migration_incomplete()`=`False`，与现状完全一致）→ `init_db()`（不建该表）→ 调度器。**迁移表只在 `run()`/`record_baseline()` 的入口事务里存在或不存在**，普通启动路径永远看不到它。

2. 表结构（比 v1.10 的表多一个排序键 `seq`，语义不变、DDL 仍由 P-1 独占；DDL 常量放 `migrate.py` 的 `SCHEMA_MIGRATIONS_DDL`，**不放 `db.py` 的 `SCHEMA`**）：

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
3. **建表与基线必须同一事务**：`BEGIN IMMEDIATE` → `CREATE TABLE IF NOT EXISTS` → `INSERT` 基线行 → `SELECT count(*)` 校验 `== 1` → `COMMIT`；任一步异常 → `ROLLBACK`，因此**不存在"表在、基线缺"的状态**（SQLite 的 DDL 在事务内可回滚，建表与插行同生共死）。
   若提交后仍读到 0 行（理论上不可达，例如别人手工 `DELETE`），按 §2.2.5 的 preflight 拒绝迁移；这条拒绝是**兜底**，不是正常路径。
   **不允许**任何"先 `init_db()` 建空表、下次启动再补基线"的两段式写法。
4. **基线值必须与生产实际状态核对，不能凭仓库 commit 推断**：
   - `version` 取 P-10 的实测值：`config.VERSION` 与 tag 版本段一致、`image_digest` 与容器实际镜像一致（`/healthz` 若有版本字段还需相等；无该字段则记 `healthz_version=ABSENT`，按三值核对，见 §1.2.7 P-10 规则）；
   - `detail_json` 记录 `{"baseline":true,"app_version":…,"image_digest":…,"structure_hash":…,"tables":[…],"tasks_present":bool}`；
   - `structure_hash` 的取法与 `tasks` 的处理（旧版把 `tasks` 算进唯一摘要，会与"`tasks` 可选存在"直接冲突，本轮修正）：
     * **主结构摘要**：对 `sqlite_master` 中除 `tasks` 及其索引/触发器之外的所有对象，按 name 排序、`sql` 去空白后拼串，取 sha256 ⇒ `structure_hash`。`tasks` 被**独立摘出**，不参与主摘要，因此"有 `tasks`"与"无 `tasks`"得到**同一个** `structure_hash`。
     * **`tasks` 单独记账**：`detail_json` 记 `tasks_present: bool`、`tasks_rows: int`；若存在，再记 `tasks_hash`（只对该表定义取 sha256）。
     * **合法结构双基准**：代码内保留 `BASELINE_STRUCTURE_HASH`（主摘要，不含 `tasks`）与两个合法 `tasks` 形态（`tasks_absent` / `tasks_empty_present`）。两者都算通过，只是记录不同；出现"`tasks` 存在但非空"或"主摘要不匹配"才拒绝。
     * **红线**：`tasks` **永远保留**——不 `DROP`、不 `DELETE`、不 `ALTER`、不迁移、不重命名、不写入；`LEGACY_IGNORED` 只让它不参与主摘要与迁移范围，不影响其存在。
5. **迁移器 preflight 判定矩阵**（运行前置检查，不改 `maintenance_state()` 的语义）：

| 观测 | 结论 | 动作 |
| --- | --- | --- |
| 表不存在 | 迁移从未开始（对应 v1.10"表不存在 ⇒ `migration_incomplete()`=False"） | 建表 + 登记基线（同一事务） |
| 表存在且 **0 行** | 异常：基线缺失 | **拒绝迁移** + `migration_table_empty`；维护态仍按 `migration_incomplete()`=False（v1.10 语义不改），但迁移入口关闭 |
| 表存在，只有 `success` 行 | 正常 | 取 `seq` 最大者；`version` 与实测运行版本不一致 ⇒ 拒绝迁移 + 报 `version_mismatch` |
| 表存在，存在 `running`/`failed` | 迁移未完成 | `migration_incomplete()`=True ⇒ `RECOVERY_REQUIRED`（v1.10 语义，不改）；**写入封锁，唯一解除路径见 §2.5.2-1** |

6. **表不存在时 `maintenance_state()` 的行为不变**：`ABSENT` 文件 → 查库 → `migration_incomplete()` 读到"表不存在" ⇒ `False` ⇒ `INACTIVE`。也就是说，**迁移从未开始时，维护判定与今天完全一致**，不会因为"没有这张表"而报错或误判。这条同时是修正 1 的正确性依据：把表推迟到迁移器创建，不改变任何既有判定路径。

7. `migration_incomplete()` 的实现口径**保持 v1.10 原样**：表不存在 ⇒ `False`；任一 `status <> 'success'` ⇒ `True`；查询异常 ⇒ 抛 `MaintUnverifiable`。本方案只增加"迁移器 preflight"这一层闸，不改变它的返回值。

**触碰面**：`db.py` 的 `SCHEMA` **不改**（只加 `table_exists()`、`close_all_connections()` 等函数）；新增 `migrate.py` 的 `SCHEMA_MIGRATIONS_DDL`、`VERSION_SEQ`、`ensure_schema_table_transactional()`、`current_version()`、`record_baseline()`、`preflight()`。

**判据**：PT-06/PT-06b/PT-06c/PT-06d 通过（幂等、原子性、`1.10` 与 `1.9` 排序正确、双合法结构）；17 张业务表结构与行数零变化；**PT-06e**：全新副本库先跑 `init_db()` 三次，断言 `schema_migrations` 不存在，再执行 `preflight()` 一次即建成且基线 1 行（证明无"先建空表"路径）。

**回滚**：`DROP TABLE schema_migrations`（仅此表由 P-1 创建）。

### 2.3 迁移与备份解耦（原"迁移前自动快照"已删除）

**目的**：明确"手动备份"和"结构迁移"是两件独立的事，迁移器不再替用户做备份决策。

**做法**：

1. `migrate.run()` **不再**接收 `snapshot`/`snapshot_stage` 参数，也不再在任何阶段调用备份函数；`running` 之前不再强制快照。
2. 升级前的备份由运维**手动**执行 `cli backup`（建议导到 NAS 之外或独立目录）；是否备份、备份放哪、保留多久，都由用户决定。
3. 迁移失败**不**自动恢复生产库、**不**自动寻找备份、**不**自动回退 `pre-restore`；失败只做三件事：写 `schema_migrations.status='failed'`、保持维护态与写封锁、写 `migration-fault.log`。
4. 解除失败态的唯一路径是运维**手动导入**（§2.5.2），导入命令本身才是"恢复"，且必须先停写、关连接、过校验。

**触碰面**：`migrate.py`（删 `snapshot` 分支）、`backup.py`（不再提供 `snapshot_set`）。

**判据**：PBT-09 通过（迁移 dry-run 期间备份目录零新增文件）。

**回滚**：恢复 `snapshot` 参数即可（本项不涉数据）。

### 2.4 备份完整性验证方案（单文件）

**目的**：杜绝"文件存在但打不开/缺表/结构不认识"的假安全；校验对象永远是**同一份文件**。

**做法**（两级 + 一次人工演练）：

1. **L1 结构验证**（`mode=ro`）：文件存在且非空 → `PRAGMA integrity_check == ok` → 17 张基准表齐全 → 结构摘要命中已登记 profile（`structure_profile_unregistered` ⇒ fail-closed）→ 若同名 `.json` 存在，则 `db_bytes` 与 `sha256` 必须与实文件相符。
2. **L2 内容验证**：逐表 `count(*)` 与元信息 `tables` 比对（元信息由**同一份备份文件**读出生成），不一致即失败。**禁止**拿备份与"备份完成后的实时源库"比较：在线导出期间源库仍在变，这种比较只会产生随机误报或掩盖真实丢失。
3. **L3 人工演练**：把备份文件复制到独立路径（`/tmp/restore-check/nodepool.db`），独立端口 8089 起临时实例（`NODEPOOL_MIGRATION_ENABLED=0`、独立 `STATE_DIR`），验证 `/healthz` 200、机场/节点/设置条数与元信息一致、订阅四格式可重建；完成后删副本。P-1.8 的 R1–R8 每一步都以此为基础，在独立 Docker 容器内执行（不涉及生产）。

**触碰面**：`backup.py` 的 `verify_backup()`、CLI `verify [--file]`。

**判据**：PBT-03/04/05 通过（截断、篡改头部、删表、改元信息 sha 都必须失败）。

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

1. `KNOWN_FAILED`（事务已 ROLLBACK，能只读确认表结构未变）⇒ 标记 `schema_migrations.status='failed'`、`detail_json` 记原因。**注意：一旦 `failed` 落库，`migration_incomplete()` 即为 `True`（v1.10 语义：任一 `status <> 'success'` ⇒ True），`maintenance_state()` 因此返回 `RECOVERY_REQUIRED`，写入保持封锁。**
   - 业务**不得**在 `failed` 状态下继续可写；即使"确认事务已回滚、表结构未变"，也只是"损坏范围可控"，不是"可以解封"。
   - P-1 唯一受支持的解除路径：运维**手动导入**迁移前自己导出的备份文件（`cli import --file <备份>`）→ 备份校验 → 维护保护 → 原子替换 → 复核 → 自动清维护态 → 重启 → 只读复核 → 才允许写入。程序不自动找备份、不自动恢复。
   - **不提供**"手工把 `failed` 改成 `success`"的 CLI 或自动改写；需要保留现场供分析时，就一直停在 `RECOVERY_REQUIRED`（只读 + 503），不牺牲正确性换取可用性。
2. `OUTCOME_UNKNOWN`（`COMMIT` 已发出但结果不明）⇒ **不重试、不重放**，直接 `halt_migration("commit_outcome_unknown")`：写 maintenance + 封锁写入 + 非 DB 日志；`halt_tail` 显式校验 `maintenance_ok ∧ writes_blocked`，否则 `fatal_lockdown + fatal_exit`。
3. 恢复动作由运维**手动导入**执行（`cli import --file <备份文件>`），顺序固定：校验备份文件 → 维护态（已是 ACTIVE 则拒绝）→ 写封锁确认 → 排空 → 关闭全部业务连接 → `/proc` 句柄复核（有第三方持有 ⇒ 中止且不动文件）→ 移开 `-wal`/`-shm` → 同卷临时文件 + fsync → `os.replace` + 目录 fsync → 复核完整性/结构/逐表计数 → 成功才清维护态并解封。**没有**自动多级回退、没有恢复子进程、没有 `pre-restore` 链。
   - 导入失败：原库以单个 `*.preimport-<stamp>.db` 副本留存并尽力复原；维护态与写封锁保持，报告 `import_*` 机器码；运维确认后才可再次导入或人工处置。
4. **禁止**：迁移中途"再试一次"；halt 中追加任何数据库写入；`DROP` 任何业务表；用 `VACUUM` 代替恢复；把"确认未提交"当成"提交成功"。

**触碰面**：`migrate.py`（`run()` / `set_phase_memory()` / `halt_migration()`）、`backup.py`（`import_backup()`）、`db.py`（`close_all_connections()`，见 §3.3）。

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
| `backend/database/db.py` | 修改（增量，**不动 `SCHEMA`**） | 新增 `connect_readonly()`、`table_exists()`、`close_all_connections()`（关闭全部线程连接，供恢复/迁移使用） |
| `backend/config.py` | 修改（增量） | 新增 `STATE_DIR`（默认 `DATA_DIR/state`）、备份/迁移相关配置项 |
| `backend/database/maint.py` | 新增 | `MAINT_FILE`、`MaintState`/`MaintRead`、`read_maint_file()`、`maintenance_state()`、`set_maintenance()`、`confirm_maint_write()`、`migration_incomplete()`、`selfcheck_state_dir()` |
| `backend/database/backup.py` | 新增 | `export_backup()`（单文件 + 元信息 + 导出即校验）、`verify_backup()`（L1/L2）、`import_backup()`（手动导入的文件级安全替换）、`holders_of()`、`latest_backup()` |
| `backend/database/migrate.py` | 新增 | `Phase`、`LEGAL_TRANSITIONS`、`VERSION_SEQ`、`current_version()`、`preflight()`、`record_baseline()`、`set_phase_memory()`、`halt_migration()`、`halt_tail()`、`run()`；`write_event()` 仅为**占位**（`raise NotImplementedError`）。**不含** `rollback_to_snapshot()` / 恢复子进程 / `RESTORE_SEQUENCE` |
| `backend/api/routes.py` | 修改（薄） | `/system/backup`、`/system/backup/download`、`/system/restore` 改调 `backup.py`；新增 `GET /api/system/migration/status`（只读） |
| `backend/main.py` | 修改（薄） | 启动顺序：`selfcheck_state_dir()` → `maintenance_state()` → `init_db()` → 调度器；`/healthz` 加 `migration` 字段（状态码语义不变） |
| `backend/scheduler/manager.py` | 修改（一行判定） | 每轮开始前 `maintenance_state()`，非 `INACTIVE` 直接 return（不读文件、不自行查库） |
| CLI（`python -m backend.database.cli`） | 新增 | `status/verify/backup/import/run`；`import` 自带维护保护，其余命令不写库（`run` 仅 dry-run 副本） |

**不碰**：`backend/services/`（fetcher、builder）、`backend/testers/`、`backend/scoring/`、前端全部。节点身份、健康判定、评分、订阅下发规则零改动（`builder.publish()` 只在恢复后复用，语义不变）。

### 3.2 数据库表

| 表 | P-1 动作 |
| --- | --- |
| 17 张基准表 | **零 DDL 改动**，只读/校验 |
| `tasks`（遗留） | 登记、保留、不动；迁移 `LEGACY_IGNORED` 显式忽略 |
| `schema_migrations` | 由**迁移器入口事务**创建（§2.2，含 `seq` 排序键）；**不进 `init_db()` 的 `SCHEMA`**；唯一写入者 = 迁移器与基线登记 |
| `system_events` / `migration_tx_notes` | **P-1 不建**。因此 P-1 **不实现** v1.10 的持久化事件链（§2.5.1），halt 只写 `migration-fault.log` 与 maintenance 文件 |

> 这一条必须明确：v1.10 的 `system_events`（8 列 + 两个唯一约束 + 哈希链）属 P0 阶段。P-1 的 phase 痕迹只落在 `schema_migrations.status`，**不足以**承载 A/B/C 三分类与 `settle_uncertain`。任何"用 `schema_migrations` 冒充事件表"的写法都在本轮被禁止。

### 3.3 接口

| 接口 | 变化 |
| --- | --- |
| `POST /api/system/backup`、`GET /api/system/backup/download` | 改调 `export_backup()`（单文件 + 导出即校验）；响应字段 `ok/file/size/sha256/integrity_check`，`file` 为文件名 |
| `POST /api/system/restore` | **下线为 409**（`manual_import_required`）：运行中进程不得在连接/写入活动时覆盖库文件，恢复统一走 CLI `import` |
| `GET /api/system/migration/status` | 新增只读：`app_version`、`image_digest`、`schema_version`、`phase`、`maintenance_state`、`state_dir_ok`、`last_backup`（脱敏，不暴露绝对路径） |
| `GET /healthz` | 增加 `migration` 字段；**状态码语义不变**（避免 docker healthcheck 抖动） |
| 所有业务写接口 | 维护期 503（新增中间件，带 `reason`） |

**`import` 的完整安全流程（逐步，缺一不可）**

1. **前置校验**：维护态必须是 `INACTIVE`（已在维护中说明有迁移未收尾，拒绝写第二个维护记录）；备份文件先过 L1/L2，无效即拒绝，此时**尚未**进入维护态、目标库零改动。
2. **进入维护**：`set_maintenance()`（`migration_id=import-<stamp>`，`reason=manual_import`）→ 回读确认；失败即退出，不做文件操作。
3. **停写**：`gate.apply_state(ACTIVE)` + `pool.block_writes()` + `confirm_writes_blocked()`；未确认 ⇒ 非零退出，绝不动文件。
4. **排空**：`drain(rounds=2, min_interval=10.0)`；未通过 ⇒ 中止，维护态与封锁保持。
5. **关闭全部连接并逐条确认**：`db.close_all_connections_report()` 返回 `{closed, failed:[{label,error}], remaining, ok}`；**只有关闭成功**的连接才从登记表移除，关闭失败/未关闭的一律留在表内并计入 `remaining`；线程本地 `conn`/`ro` 同规则处理。任一条 `failed`/`remaining` 非空或 `ok=False` ⇒ `connections_not_closed`，**中止导入**，维护态与写封锁保持，不替换任何文件。
6. **句柄复核（含本进程）**：`holders_of(target)` 扫 `/proc/*/fd` 找第三方持有；`self_handles_of(target)` 扫 `/proc/self/fd` 复核本进程自身对目标库与 `-wal/-shm` 的句柄；任一命中 ⇒ `import_handles_present` / `import_self_handles_present`，中止且不替换。不能确认"全部关闭"时不得替换数据库。
7. **WAL/SHM 与替换**：先用 SQLite 在线备份 API 生成原库副本 `*.preimport-<stamp>.db`（不是 `copyfile` 主库：主库可能缺少尚未 checkpoint 的已提交 WAL 页）；副本用 `_probe_file(immutable=True)` 校验 + 与当前库**活库读法** `_probe_file(target, immutable=False)`（`mode=rw` + `PRAGMA query_only=1`，能看到 WAL 未 checkpoint 页）逐表计数比对，不等即 `preimport_incomplete` 且不动替换；副本完好后才把 `-wal`/`-shm` 改名隔离（不删除）；备份文件复制到同卷 `.import-<nonce>.db` + fsync + 复核；`os.replace` + 目录 fsync。preimport 副本保留，不自动删除。
8. **替换后复核**：独立只读连接 `integrity_check` → 表集合 → 结构摘要 → 逐表计数与**源备份文件**比对；不一致即复原并报 `import_verify_failed`。
9. **收尾**：成功 ⇒ 清理空的 `-wal/-shm`、保留 `*.preimport-*.db` 供人工确认、删 `maintenance.json` + 目录 fsync + 复核 INACTIVE + 解除写封锁；失败 ⇒ 维护态与写封锁保持，报 `import_failed` / `import_rolled_back` / `import_failed_leftover`。
10. 全程禁止：`reset_connection()` 后 `shutil.copy2` 覆盖（旧实现做法）、在仍有连接/句柄时删 `-wal`、把"上传文件"直接当恢复源、自动多级回退或恢复子进程。

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
| 迁移改表导致历史数据丢失 | P-1 不改任何业务表 DDL；真正改表只发生在 P0 之后，且升级前必须由运维手动导出 + 校验（程序不自动备份） |
| 遗留 `tasks` 表被误删 | 迁移器中列入 `LEGACY_IGNORED = {"tasks"}`，任何 `DROP`/重命名白名单为空 |
| `sqlite_sequence` 被重排 | 禁止对业务表做 `VACUUM INTO` 后替换主库；如需空间回收，单独评估且不在本阶段 |
| 订阅文件与库不一致 | 维护期禁止发布；恢复后统一 `builder.publish("restore")`（沿用现有逻辑） |
| 时间戳/时区 | 库内时间戳沿用现有 `now()`（本地时区字符串），P-1 不改口径；已知 B11（清理按 UTC 比较）留待 P-1 后期单独修，不在本轮 |
| WAL 残留导致导入不干净 | `import` 必须：停写/排空 → `close_all_connections()` → 句柄复核 → `-wal`/`-shm` 改名隔离 → 同卷临时文件 + fsync → `os.replace` + 目录 fsync → 完整性/计数复核（详见 §3.3） |
| 备份被误删 | 程序不自动清理、不自动删除；文件由用户保管，建议放独立目录并定期抽查 `verify` |

---

## 5. 测试用例与通过判据

全部在**副本库**（生产库的备份）与一次性库上执行，不碰生产。

| 编号 | 场景 | 通过判据 |
| --- | --- | --- |
| PBT-01 | `export_backup()` 正常导出 | 生成单个 `.db` + 同名 `.json`；`integrity_check=ok`；元信息 `sha256/db_bytes` 与实文件一致；目录里没有子目录/三件套；文件名含 6 位随机后缀 |
| PBT-02 | 运行期导出一致性（WAL + 并发写） | 备份 `integrity_check=ok`；未提交行不出现；行数介于导出起止之间；**不要求**与实时源库相等 |
| PBT-03 | `verify_backup()` L1 + 严格元信息 | 良好备份全绿；截断 / 头部损坏 / 删表 / 改元信息 sha / 缺 `.json` / JSON 损坏 / 缺必备字段 七种坏文件必须失败；`import` 与 `verify` 同一规则 |
| PBT-04 | 元信息自洽（L2） | 元信息 `tables` 与备份文件逐表计数不符 ⇒ 失败；`structure_hash` 不符 ⇒ `meta_structure_mismatch` |
| PBT-05 | 人工恢复演练（独立端口 8089） | 导入到独立副本 + 独立 `STATE_DIR` 起临时实例：`/healthz` 200、机场/节点/设置条数与元信息一致、订阅四格式可重建 |
| PT-05 | L3 恢复演练（独立端口 8089） | `/healthz` 200；机场/节点/设置条数与源一致；订阅四格式可重建 |
| PT-06 | `schema_migrations` 幂等 | 连续启动 5 次，行数恒为 1；`status='success'`；`seq` 不变 |
| PT-06b | 版本排序 | 手工插入 `seq=1 version='1.9'`、`seq=2 version='1.10'`（均 success）⇒ `current_version()` 必须返回 `1.10`；把实现改成 `MAX(version)` 的负向对照必须失败 |
| PT-06c | 基线原子性 | 在 `INSERT` 基线行前注入异常 ⇒ 事务回滚 ⇒ 表与基线**同时不存在**（不出现"表在行缺"）；再启动一次正常登记，行数 1 |
| PT-06d | 基线核对 + `tasks` 双合法结构 | ① 摘要不一致 / `app_version` 与 P-10 不一致 ⇒ 拒绝登记并报 `baseline_structure_mismatch` / `version_mismatch`；② **无 `tasks`** 的库 ⇒ 登记通过，`tasks_present=false`；③ **有 `tasks`（0 行）** 的库 ⇒ 同样通过，`tasks_present=true`、`tasks_rows=0`，且两者 `structure_hash` **完全相等**；④ `tasks` 有 1 行 ⇒ 仍通过登记（只记录 `tasks_rows=1`，不拒绝、不动它）；⑤ 断言登记前后 `tasks` 的 `sqlite_master` 定义与行数**逐字节不变** |
| PT-06e | 建表时机 | `init_db()` 连跑 3 次后 `schema_migrations` 必须不存在（`table_exists()`=False，且 `migration_incomplete()` 仍为 `False`）；随后 `preflight()` 一次即建表 + 基线 1 行，全程无"空表被拒"路径 |
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
| PBT-06 | 正常导入 | 导入后逐表计数与备份一致；`maintenance.json` 已清、写封锁已解；导入后仍可继续写 |
| PT-18 | 保守恢复（MC66(4)） | 删文件 + 非 `success` 行 ⇒ 五入口一致 `RECOVERY_REQUIRED`，写入不开放 |
| PT-19 | 迁移窗口内重启 | 重启后仍 `RECOVERY_REQUIRED`/`ACTIVE`，不自动推进 phase、不补写事件 |
| PBT-10 | 性能预算 | 100 MB 库：导出 ≤ 5s、排空 ≤ 30s、导入总停写窗口 ≤ 60s（实测回填） |
| PBT-07 | 无效备份拒绝导入 | 坏文件/不存在 ⇒ `import` 非零退出且**不进入维护态**、目标库字节不变 |
| PBT-08 | 导入期封锁与失败现场 | 替换瞬时断言 `writes_blocked` 且业务拿不到写槽；注入替换失败 ⇒ 原库复原、`*.preimport-<stamp>.db` 留存、维护态与封锁保持；有第三方句柄 ⇒ 中止且不改文件 |
| PT-23 | A/B 职责分离（五入口 + 二次级机制） | 连接池与 `halt_tail` 的代码路径中**静态扫描**无 `MAINT_FILE`/`read_maint_file` 引用；五入口全部引用同一 `maintenance_state()` |
| PT-24 | 探针脚本副作用审计 | 第 1–4、6–8 段在一次性副本库上执行，前后 `sha256(db)`、`-wal` 大小、`mtime` 均不变；第 5 段只在 `STATE_DIR` 造文件、不触碰 `nodepool.db*` |
| PT-25 | `migration_incomplete()` 语义保持 | 表不存在 ⇒ `False`；有 `running`/`failed` ⇒ `True`；查询异常 ⇒ `MaintUnverifiable`；空表的"拒绝迁移"只由 preflight 产生，不改该函数返回值 |
| PBT-09 | WAL/SHM 与迁移解耦 | 目标库带遗留 `-wal/-shm`（伪造脏帧）时导入成功且旧帧不残留；迁移 dry-run 期间 `BACKUP_DIR` 零新增文件 |
| PBT-11 | 连接关闭逐条确认 | 关闭失败的连接留在登记表、`ok=False`；CLI 在 `close_connections` 判定失败即 `connections_not_closed` 中止，库不变、维护态与封锁保持 |
| PBT-12 | 本进程遗留句柄 | 本进程持有目标库/`-wal`/`-shm` 句柄 ⇒ `import_self_handles_present`，中止且不替换 |
| PBT-13 | 元信息严格校验 | 缺 `.json` / JSON 损坏 / 缺必备字段 三态均拒绝，且不进入维护态、目标库零改动 |
| PBT-14 | 同秒导出不覆盖 | 固定时间戳连导 3 次，得到 3 个不同文件名、3 份可校验备份，旧文件 sha 不变 |
| PBT-15 | 并发导出不覆盖 | 6 线程同时导出，文件名互不相同、全部可校验、无失败 |
| PBT-16 | preimport 完整性 | 子进程写入后保持连接（或 `os._exit(0)`）造未 checkpoint 的已提交 WAL 页；`immutable=True` 读法看不到该行、`immutable=False` 活库读法看到；preimport 副本逐表计数等于活库且含该行，副本保留 |
| PBT-17 | 活库读法钉死 | 导入路径对目标库的 preimport 复核必须调用 `_probe_file(immutable=False)`（spy 断言） |
| PBT-18 | 元信息内容篡改 | 分别篡改 `tables`/`structure_profile`/`schema_version`/`tasks`/`key_digests` ⇒ `verify` 报对应 `meta_*_mismatch`；`import` 退出码 2、未进维护态、目标库零改动 |

判据统一口径：**每一项必须给出"命令 + 期望输出 + 不通过时的处置"**；"跑通了"不算通过，必须贴输出。

---

## 6. 备份与导入验证步骤（可照做）

1. 导出：`python -m backend.database.cli backup --out /backup/manual` → 得到 `nodepool-<stamp>-manual.db` 与同名 `.json`；命令输出 `integrity_check=ok`。
2. 校验：`python -m backend.database.cli verify --file <文件>` → `ok=true`；再故意截断一份副本，确认 `ok=false` 且报 `integrity_check`/`sqlite_error`。
3. 演练：把该 `.db` 复制到 `/tmp/restore-check/`，起临时实例（`-p 8089:8080`、`NODEPOOL_DB` 指向副本、`NODEPOOL_STATE_DIR` 指向临时空目录、`NODEPOOL_MIGRATION_ENABLED=0`），验证 `/healthz` 200、机场/节点/设置条数与元信息一致、订阅四格式可重建；完成后停实例、删副本。
4. 真机导入（仅在维护窗口）：停应用/容器 → `python -m backend.database.cli import --file <文件>` → 观察 `steps` 依次为 `source_verified/maintenance/stop_writes/drain/close_connections/import_atomic/verify_imported/release` → 重启 → 只读复核（`status` 为 `INACTIVE`、`verify` 为 `ok`）。
5. 失败处置：命令以非零退出并给出 `import_*` 机器码时，**不要**改库、不要重复导入；先看 `*.preimport-<stamp>.db` 与 `migration-fault.log`，人工确认后再决定。

## 7. 失败处理与回滚矩阵

| 编号 | 失败点 | 立即动作 | 最终状态 | 恢复手段 |
| --- | --- | --- | --- | --- |
| F1 | 手动导出失败（空间/IO/校验不过） | 删除临时文件、非零退出且不改库 | 业务不受影响 | 换目录/清理空间后重导 |
| F2 | 导出后校验失败 | 不落名、删临时文件 | 业务不受影响 | 重新导出；持续失败查磁盘/库 |
| F3 | `schema_migrations` 写 `running` 失败 | 事务已回滚，只读确认**无** `running`/`failed` 行残留 | 可返回原状（服务可写） | 直接重启；若复查发现残留行 ⇒ 立即降级为 F4 |
| F4 | DDL 执行抛错 | 事务 ROLLBACK → 判 `KNOWN_FAILED` → 标 `failed` | **写入封锁**：`failed` ⇒ `migration_incomplete()`=True ⇒ `RECOVERY_REQUIRED`（503） | 运维手动 `import --file <迁移前导出>` → 复核 → 自动清维护 → 重启 → 只读复核 → 才解封（无自动恢复链） |
| F5 | 提交结果不确定 | 判 `OUTCOME_UNKNOWN` → `halt_migration("commit_outcome_unknown")` | 写入封锁 | 只读比对表结构与 `schema_migrations` → 人工决策（P-1 无事件表可重查） |
| F6 | `set_maintenance` 失败 | 继续封锁 → `fatal_exit("maintenance_unconfirmed")` | 进程退出，写入已被挡 | 修复后重启，走 `RECOVERY_REQUIRED` |
| F7 | 写入封锁无法确认 | `fatal_lockdown` + `fatal_exit("writes_block_unconfirmed")` | 进程退出 | 停容器（`docker stop`）后离线恢复 |
| F8 | 维护文件损坏/不可读 | `RECOVERY_REQUIRED` | 只读 + 503 | 人工修复或按 DB 判定后清理 |
| F9 | 恢复后订阅重建失败 | 记 `WARN`，不阻断启动 | 业务可写，订阅可能是旧版 | 手动重发 `builder.publish` |
| F10 | 导入时仍有第三方句柄 | 中止（`import_handles_present`），原库不动 | 维护态保持 | 停容器/停进程后重试 |
| F11 | 备份文件损坏/被截断 | `import` 前置校验拒绝（`backup_invalid`） | 业务不受影响、库零改动 | 换可用备份 |

原则：**任何失败都不允许"继续以可写状态对外服务"**；退出的进程绝不靠上层重试拉起（`restart: unless-stopped` 会让容器重启，但那只是重启，不是解封）。

---

## 8. 实施顺序与验收条件

| 步骤 | 内容 | 可回退性 | 验收条件 |
| --- | --- | --- | --- |
| P-1.1 | 生产探针（§1.3，P-1~P-10）与基线存档 | 只读（P-7 例外） | 十项输出逐项回填 §1.2.7；每项判据通过；P-7 与 P-10 缺一即不得进 P-1.2 |
| P-1.2 | `schema_migrations`（含 `seq`）+ **迁移器事务内**建表与原子基线登记 | 可 `DROP TABLE` | PT-06/06b/06c/06d/06e 通过；`init_db()` 不建该表；基线 `version` 由 P-10 实测值确定；17 张业务表零变化 |
| P-1.3 | `backup.py`（单文件导出 + 完整性校验） | 删文件 | PBT-01/02/03/04/05 通过 |
| P-1.4 | `maint.py` + `STATE_DIR` 同卷校验 + 启动自检 | 删文件 | PT-11/14/14b/24 通过 |
| P-1.5 | 五入口 + 二次级机制接线（A/B 分离） | 拆中间件 | PT-15/16/23 通过 |
| P-1.6 | `migrate.py` 最小状态机（无事件链）+ 空迁移 dry-run | 删文件 | PT-09b/12/13/19/25 通过；`write_event()` 抛 `NotImplementedError` |
| P-1.7 | 手动导入 + 维护保护 + 失败现场（隔离演练 8089） | 不影响生产 | PBT-05/06/07/08/09/10 通过；P-1.6 迁移测试不回归；无自动恢复链残余 |
| P-1.8 | **Docker 迁移演练与交付验证**（隔离容器，不碰生产） | 删除容器与测试目录即可，无生产副作用 | §8.1 R1–R8 全通过；迁移窗口 ≤60s；中断/失败路径均 fail-closed；四格式订阅可重建；30 分钟容器内观察无 5xx |

每步之间必须停下汇报，不得连做。P-1.1 之前不允许写任何代码。

### 8.1 P-1.8 定义：Docker 迁移演练与交付验证

> 本节按项目方裁决（2026-11-26）修订。原 P-1.8 定义为"生产窗口（需二次确认）"，与"仅开发和交付 Docker 版本"的项目范围不符，已废止；原定义仅保留在历史交付材料中作为修改记录。

**目标**：在**独立 Docker 测试环境**中，用旧版数据库副本（v1.8.7 结构）完整演练"迁移前备份 → 迁移执行 → 完整性校验 → 异常中断 → 失败处理 → 手动回滚 → 恢复服务"全链路，验证交付镜像与运维流程可用、可回退；不接触 NAS。

**实施范围**（全部在测试容器内）：

| 编号 | 演练项 | 关键断言 |
| --- | --- | --- |
| R1 | 正常迁移 | 迁移前 `cli backup` 成功；迁移 `success` 唯一；重启后只读复核通过；四格式订阅重建；`/healthz` 200 |
| R2 | 重复执行幂等 | 已迁移库再次启动不重复 DDL；显式拒绝或明确 no-op，不产生第二条 success |
| R3 | 迁移中断 | 在 DDL 阶段 `docker kill`/`kill -9`；重启后 `RECOVERY_REQUIRED` + 写入 503；无自动恢复、无自动找备份 |
| R4 | 迁移失败处理 | 注入 DDL 错误 ⇒ `failed` + 写封锁；`cli import` 迁移前备份 → 逐表计数复核 → 清维护 → 重启 → 只读复核 → 解封 |
| R5 | 手动回滚演练 | 迁移成功后用迁移前备份 `cli import` 回退旧结构；表集合/逐表计数/结构摘要与备份一致；订阅按旧版重建 |
| R6 | 坏备份拒绝 | 截断/篡改/元信息缺失或内容不实配 ⇒ `verify` 与 `import` 均拒绝，目标库零改动 |
| R7 | 句柄与写封锁 | 容器内仍有连接/句柄时导入中止（`import_self_handles_present`/`import_handles_present`），维护态保持 |
| R8 | 观察窗口 | 迁移完成后容器内 30 分钟健康检查与合成读写流量，无 5xx 毛刺；`/healthz` 持续 200 |

**前置条件**：

1. P-1.7 已验收（提交 `a62aeb2`，含最终验收修正），P-1.3–P-1.6 回归全绿；
2. Docker 可用，测试容器使用独立 bridge 网络、独立端口（8089）、独立 bind 目录与独立 `STATE_DIR`，禁用 `restart: unless-stopped`；
3. 测试库来自**离线副本**（P-1.1 基线或同构合成库），以只读方式复制进测试目录；禁止直接挂载生产 `data`/`backup`；
4. 宿主/卷支持 `os.replace` 与目录 `fsync`；该自检只在测试目录执行，不在 NAS 上执行 P-7；
5. 镜像可由当前 main 构建，记录 image digest 与 `config.VERSION`。

**验收标准**：R1–R8 全部通过并留存日志、命令输出与失败记录；迁移窗口 ≤60s；迁移后逐表计数与备份元信息一致；中断与失败路径均为 fail-closed（503 + 维护态保持 + 无自动恢复）；回滚后数据与迁移前备份逐表一致；文档与实测一致。

**明确排除**（不属本阶段，另行立项并单独审批）：生产数据库迁移、NAS 停机窗口、生产切换/部署、生产 `STATE_DIR` 的 P-7 写探针、生产备份目录读写、生产配置与容器变更。

**停止条件**：R1–R8 完成并交付后立即停止；不执行 NAS 部署或生产迁移，不进入下一阶段，等待独立复审。

---

## 9. 可能影响生产服务的操作与风险

> 本节保留原始风险分析，适用于**未来的生产部署阶段**；P-1.8 只在隔离 Docker 容器内演练，不产生下列生产影响。

| # | 操作/风险 | 影响面 | 缓解 |
| --- | --- | --- | --- |
| 1 | 维护期 503 | 全部业务写接口 | 窗口选在 `sub_publish` 之外（查 `next_at`），时长 ≤ 60s |
| 2 | 停写导致后台批次中断 | 当轮测试/评分缺失 | 允许丢失一轮（90 分钟 TTL 内自然补上），不做补偿写入 |
| 3 | 容器重启 | `restart: unless-stopped` 会拉起，前端短暂不可用 | 窗口内提前通知；重启后先只读观察 |
| 4 | 备份占用磁盘 | `data`/`backup` 同盘时可能写满 | 导出前检查余量 ≥ 2× 库大小 + 8 MB；不足即拒绝导出 |
| 5 | NAS 卷不支持原子 rename | maintenance 失效、`RECOVERY_REQUIRED` 误判 | P-7 自检前置；不支持则禁用迁移入口（业务不受影响） |
| 6 | WAL 残留导致导入后读旧数据 | 导入后库"看起来旧"或损坏 | 导入先把 `-wal/-shm` 改名隔离（不删，供复原），替换后再复核完整性/计数 |
| 7 | `tasks` 等遗留表被误动 | 历史数据丢失 | 迁移白名单 + 明确忽略清单 + 演练逐表比对 |
| 8 | 迁移器 bug 导致半写 | 库结构不可用 | phase 状态机 + `halt` + 运维手动导入备份，三保险 |
| 9 | 订阅文件与库版本错位 | 用户拿到旧订阅 | 恢复后统一 `publish("restore")`，并在 `/api/system/migration/status` 暴露 `last_publish` |
| 10 | 探针写测试（P-7）误伤 | 极低（64 字节临时文件 + 可能新建空 `STATE_DIR`） | 随机文件名、`finally` 清理、不触碰 `nodepool.db*`、目录为空则一并删除 |
| 11 | 把 `wal_checkpoint` 当只读操作误用 | 会在任意时刻改动 `-wal`，干扰排查甚至抢锁 | 只读探针禁止 checkpoint；checkpoint 只出现于停写窗口（PT-24 审计） |
| 12 | 恢复时只关当前线程连接 | 其他线程句柄仍持有旧库，替换后读到旧 inode | `close_all_connections()` + 句柄扫描 + 替换前中止条件（PT-22） |
| 13 | 基线版本猜错（凭 commit 推断） | 版本记录与真实运行版本不符，后续迁移误判 | 基线必须用 P-10 实测（tag/digest/`config.VERSION`/`healthz`）并核对结构摘要 |
| 15 | `/healthz` 无版本字段却被当作"已核对" | 四值核对失真 | 实测无该字段即记 `ABSENT`，降级三值 + 标记待补能力，不得宣称四值完成 |
| 16 | 通用 `init_db()` 提前建空 `schema_migrations` | 迁移器读到空表永久拒绝迁移（启动即锁死） | 该表不进 `SCHEMA`，只由迁移器入口事务创建（PT-06e 钉住） |
| 14 | 备份文件损坏仍被当有效 | 导入后数据不全 | 导出入即校验 + 导入前复校 + 元信息 sha（PBT-03/04/07） |

---

## 10. 交付物与停止点

本轮交付：**本计划文档**（不含代码）。已上传 GitHub 仓库根目录，文件名 `NodePoolME-P-1实施计划-v1.10.md`。

停止点：等总体审查确认 + 用户对 §1.3 探针（尤其 P-7 那一处写测试）的批准。**未获确认前不写任何业务代码、不动生产、不执行迁移、不进入 P-1.2。**

**当前停止点（P-1.8 修订后）**：P-1.8 定义已修订为隔离 Docker 演练；本轮只交文档，未写代码、未执行迁移、未做 Docker 操作。等待 ChatGPT 复审；复审通过且收到施工指令后才进入 P-1.8 施工。

需要用户回填的空白（共 10 项，对应 §1.2.7 的 P-1–P-10）：库体量与页数、SQLite 版本、表集合与行数、WAL/SHM 物理状态、句柄与外部持有者（含"未提交事务不可外部完整证明"这一限制）、备份目录与空间、`STATE_DIR` 同卷与原子性、运行身份与权限、`sub_publish` 当前配置与 `next_at`、镜像 digest 与 `app_version`。

其中三项直接决定门槛，缺任一项不得进 P-1.2：
① **P-7**（`STATE_DIR` 同卷 + 原子写全链路）——决定 maintenance 方案能不能用；
② **P-10**（镜像 digest + `app_version`）——决定基线 `version` 写什么，不能凭 commit 推断；
③ **P-4**（`integrity_check` 与 `journal_mode`）——决定库本身是否允许动手。

**待补能力（本轮不改，登记备查）**：若 P-10 实测显示 `/healthz` 没有版本字段，则"健康端点自带版本"属能力缺口，记为待补（P-1 后的独立小改动，不进本轮范围）；在此之前基线版本只能靠 `config.VERSION` + image digest 三值确定，且**不得**对外声称已做四值核对。

**P-1.8 定义修订（第 20 次修订，2026-11-26）**：应项目方裁决，P-1.8 由"生产窗口（需二次确认，本轮不做）"改为"**Docker 迁移演练与交付验证**"，新增 §8.1 定义目标、R1–R8 范围、前置条件、验收标准与排除项；§8 阶段表与 §6 L3、§9 风险适用范围同步修订。生产库迁移、NAS 停机窗口、生产切换明确排除在本阶段之外；P-1.7 已验收内容（`a62aeb2`）未改动，历史交付材料中的"P-1.8 停机窗口/生产窗口"表述视为已被本次修订取代，仅作修改记录保留。

**P-1.7 验收修正（本版追加）**：① `close_all_connections` 改为返回逐条关闭报告的 `close_all_connections_report()`，失败连接不出表、CLI 以 `ok` 判定中止，并把本进程 `self_handles_of()` 纳入复核；② 元信息强制成对且字段齐全、sha/大小/结构摘要实配，`verify` 与 `import` 共用同一严格校验；③ 备份落名改 `os.link` 排他 + 6 位随机后缀，同秒/并发唯一、绝不覆盖、不删旧；④ preimport 改用在线备份 API 生成（含未 checkpoint 的 WAL 已提交页）并做逐表计数比对，副本保留；专项测试增至 19 项（PBT-11…16）。架构仍为"手动导出单文件 + 完整性校验 + 手动导入 + 导入期维护保护"，未重新引入自动恢复链/多级快照/恢复子进程。

**v1.10 备份/导入简化修订（本版）**：删除自动恢复体系——`snapshot_set()` 三件套/`complete.json`/`restore_set()`/`prune()`/`pre-restore` 多级回退/恢复子进程/`rollback_to_snapshot()`/`RESTORE_SEQUENCE`/`migrate.run(snapshot=True)` 全部移除；改为"手动导出单文件 + 手动导入 + 完整性校验 + 导入期维护保护"。备份与迁移彻底解耦：迁移失败不自动恢复、不自动找备份。测试编号 PT-01/02/03/04/04b/17/21/22/26 由 PBT-01…09 取代（原编号保留在历史交付材料中，不再对应当前实现）。更早的修正说明（相对上上版）：P-10 补齐 `/healthz` 实测命令与"四值核对规则"（无版本字段则降级三值并标待补）；P-5 改为同一只读连接双读 `data_version` 并输出 `before/after/changed`；`schema_migrations` 从 `db.py` 的 `SCHEMA` 移出，改由迁移器入口事务建表+基线+计数校验（PT-06e 钉死无"先建空表"路径）；`structure_hash` 把 `tasks` 摘出主摘要、独立记账并保留双合法结构（PT-06d 增四个子用例）；`failed` 状态统一为"写入封锁 + `RECOVERY_REQUIRED`"，唯一解封路径=恢复 `pre-migrate` 备份集。更早一轮的修正：P-5 拆成"句柄/锁/未提交事务"三件事并删除只读探针里的 `wal_checkpoint`；P-7 修正 fsync 的 fd 用法并补齐"写入→文件 fsync→rename→目录 fsync→回读→删除→再 fsync"，且强制在真实 `STATE_DIR` 上跑；`STATE_DIR` 改为独立子目录 + 同卷校验；六通道按 A/B 重排；P-1 明确只实现最小状态机（不建事件表、不冒充完整事件链）；`schema_migrations` 增加 `seq` 排序键、基线原子登记并强制与实测版本核对；L2 参照物限定为同一快照；备份改为"三件套 + 原子发布"；恢复流程补全停服/全连接关闭/句柄确认/WAL 处理/原子替换/失败回退。
