# NodePoolME P-1 生产环境摸底报告（v1.10）

> 阶段：P-1.1（生产摸底）。依据《新架构总体设计方案 v1.10》§1.2.7 与《P-1 实施计划 v1.10》§1.3。
> 本报告**不含任何推测出的生产数值**。凡未实测的项，一律标"未执行/待填"，不给估计值。

---

## 0. 结论（三条，先看这里）

**① 生产环境在当前执行环境不可达，生产探针 0/10 执行。**
本会话运行在一台云沙箱主机上，没有 docker 守护进程、没有 `/data`、`/backup`、`/opt/nodepool`，没有 SSH 配置与凭据，也不在你的 NAS 网段内。因此 P-1 至 P-10 在**生产上没有一条被实际执行**。这是能力边界，不是技术选择——不能靠"换一种安全的检测方法"绕过。

**② 探针脚本已在沙箱完成自检：9/10 段跑通，P-7 依指令未执行。**
用仓库开发库（`…/NodePoolME/data/nodepool.db`，167,936 字节）做只读演练，验证脚本语法、SQL、字段名、判据解析均可用；`/healthz` 解析是在本地另起一个实例（端口 8089、库为 `/tmp` 副本）上验证的。**这些输出是沙箱值，不可当生产基线。**

**③ 代码复核发现计划里一条假设需要更正：`/healthz` 实际有 `version` 字段。**
`backend/api/routes.py:1603-1611` 返回 `{status, version, engine, db, scheduler}`；实测 `{"status":"ok","version":"1.8.7",…}`。因此 P-10 的**四值核对是可行的**，"很可能没有版本字段、降级三值"的预案不必启用。这是事实纠正，**未擅自修改**已通过的 P-1 计划文件，待你确认后再改。

---

## 1. 执行环境与能力边界（证据）

```
$ id
uid=1234(user) gid=1234(user) groups=1234(user)          # 普通用户，非 root

$ command -v docker
（无输出）                                                # 无 docker CLI / 无守护进程

$ ls -ld /opt/nodepool /data /backup
ls: cannot access '/opt/nodepool': No such file or directory
ls: cannot access '/data': No such file or directory
ls: cannot access '/backup': No such file or directory    # 生产挂载点不存在

$ ls -la ~/.ssh
ls: cannot access '/home/user/.ssh': No such file or directory   # 无 SSH 凭据

$ ip route | head -3
default via 169.254.112.1 dev eth1 onlink
9.0.0.0/8 via 9.118.0.1 dev eth0 onlink                  # 沙箱内网段，非你家网络
```

结论：任何"生产实测"都必须在**你的 NAS 宿主**（有 docker）或**容器内**执行。我已把全部探针打包成一个可直接跑的脚本（§8 交付物），你执行后把 log 回贴即可。

---

## 2. 代码与部署结构复核（这部分是可以在本地完成的真实检查）

| 项 | 复核结果 | 来源 |
| --- | --- | --- |
| `VERSION` | `1.8.7` | `backend/config.py:7` |
| `DATA_DIR` | `NODEPOOL_DATA_DIR`，默认 `./data` | `config.py:8` |
| `CONFIG_DIR` / `LOG_DIR` / `BACKUP_DIR` | 默认 `<DATA_DIR>/{config,logs,backup}` | `config.py:9-11` |
| `SUB_DIR` | `<DATA_DIR>/sub` | `config.py:13` |
| `DB_PATH` | `NODEPOOL_DB`，默认 `<DATA_DIR>/nodepool.db` | `config.py:14` |
| `STATE_DIR` | **代码中尚不存在**（P-1 新增）；compose 也**未设** `NODEPOOL_STATE_DIR` ⇒ P-7 的目标目录将是 `/opt/nodepool/data/state`（容器内 `/data/state`） | `docker-compose.yml` 环境段 |
| 容器镜像 | `ghcr.io/laoxuhome/nodepoolme:latest`（可由 `NODEPOOL_IMAGE` 覆盖） | `docker-compose.yml:3` |
| 挂载 | `/data /config /logs /backup` ← `${NODEPOOL_ROOT:-/opt/nodepool}/…`（4 个 bind） | `docker-compose.yml` volumes |
| 重启策略 | `unless-stopped`（→ 进程退出会被拉起，封锁不能靠"退出"） | 同上 |
| `/healthz` | **返回 5 字段，含 `version`**；HTTP 200，`db` 为 `DB_PATH.exists()` | `routes.py:1603-1611` |
| 备份实现现状 | `POST /api/system/backup` → `create_backup()`；恢复 `restore_backup()` 用 `copy2` 覆盖且不处理 WAL | `routes.py:1417/1434/1448` |
| `settings` 结构 | **只有 `key`,`value` 两列** | PRAGMA 实测（开发库） |
| `logs` 结构 | `id, ts, level, source, message` —— **无 `category` 列** | PRAGMA 实测（开发库） |

> 由上表得到两个实用结论：① P-7 的目录就是你 `data` 卷下的 `state` 子目录，`st_dev` 必然与库相同（除非你把它指到别的卷）；② 检索"最近发布记录"只能按 `message`/`source` 文本，因为 `logs` 没有 `category`。第二点是我在自检时踩出来的真 bug（初版脚本按 `category` 查询，直接 `no such column`），已修。

---

## 3. P-1 至 P-10 逐项状态

| 编号 | 生产状态 | 沙箱自检（仅证明脚本可用） | 生产待填字段 |
| --- | --- | --- | --- |
| P-1 库体量与页数 | **未执行** | `bytes=167936`、`page_size=4096`、`page_count=41`、`freelist_count=0`，`page_size*page_count=167936 == bytes` ✔ | `path/bytes/page_size/page_count/freelist_count` |
| P-2 SQLite 版本 | **未执行** | 沙箱 `3.49.1`（仓库依赖无关；**生产版本只能实测**） | `sqlite_version`（判据 ≥3.35.0） |
| P-3 表集合与行数 | **未执行** | 19 张表 = 17 业务 + `sqlite_sequence` + `tasks`(0 行)；13 个显式索引；0 触发器 | 每表计数、`tasks` 是否存在及行数 |
| P-4 WAL/完整性 | **未执行** | `journal_mode=wal`、`synchronous=2`、`wal_autocheckpoint=1000`、`integrity=ok`、`fk_violations=0`（`mode=ro` 打开，未 checkpoint） | `journal_mode / -wal 字节 / -shm 字节 / integrity / fk_violations` |
| P-5 句柄/锁/事务 | **未执行** | `data_version_before=2`、`after=2`、`changed=False`（同一只读连接，间隔 2s） | 持有者数量、外部持有者列表、`changed` |
| P-6 备份与空间 | **未执行** | 开发库 `data/backup` 为空目录；沙箱 `/tmp` 可用 9,892 MB（无参考意义） | 文件数、最新 mtime、占用、两处 avail |
| P-7 原子写 + 同卷 | **未执行（等待批准）** | 未运行（依指令不执行任何写测试） | `state_dir / db_st_dev / state_st_dev / fs_type`、七步结果 |
| P-8 身份与权限 | **未执行** | 沙箱 `uid=1234`（非容器内真实 uid） | 容器内 `uid/gid`、目录属主与权限位 |
| P-9 发布配置 | **未执行** | 开发库：`enabled=0`、`mode=time`、`time=04:30`、`interval=180`、`next_at=NULL`、近 30 条日志无发布记录 | 五项 + 最近发布记录 |
| P-10 镜像与版本 | **部分可核（脚本已备）** | `app_version=1.8.7`、`healthz_version=1.8.7`（本地实例）；`image_tag=…:latest`（compose）；**digest 无法在沙箱取得** | `image_tag / image_digest / app_version / healthz_version` |

**四值核对规则（依据实测修正版）**：`app_version` 与 tag 版本段一致 ∧ `image_digest` 与容器实际 `Image`（`sha256:…`）一致 ∧ `healthz_version == app_version` ⇒ `baseline_verifiable=true`。缺 digest ⇒ **不可登记基线**，因为 `latest` 标签本身没有唯一性。

---

## 4. 关键原始输出（沙箱自检，非生产）

```
===== 1) P-1 / P-3 / P-4 =====
path /home/…/NodePoolME/data/nodepool.db exists True
file_bytes 167936
sqlite_version 3.49.1
page_size (4096,)  page_count (41,)  freelist_count (0,)
journal_mode ('wal',)  synchronous (2,)  wal_autocheckpoint (1000,)
page_bytes 167936
table_count 19
  airports 0 / nodes 0 / results 0 / latency_results 0 / settings 51
  test_groups 3 / speed_sources 8 / logs 1 / tasks 0 / 其余 0
indexes 13   triggers []   views []
integrity ok   fk_violations 0
===== 3b) data_version 双读 =====
data_version_before 2 / after 2 / changed False
===== 4) P-9 =====
settings_cols ['key','value']
sub_publish_enabled 0 / mode time / time 04:30 / interval 180 / next_at None
logs_cols ['id','ts','level','source','message']
last_publish_log NONE_IN_LAST_30
===== 0) P-10 healthz（本地 8089 实例）=====
{"status":"ok","version":"1.8.7","engine":"tcp","db":true,"scheduler":true}
healthz_version 1.8.7
===== 5) P-7 =====
SKIPPED: 未获批准（需设置 NODEPOOL_P7_APPROVED=1）
```

---

## 5. 风险分析（基于已确认事实，不含猜测）

| # | 风险 | 依据 | 处置 |
| --- | --- | --- | --- |
| 1 | 现在**没有**可用于登记基线的生产证据 | P-1~P-10 全未执行 | 必须先跑脚本；在此之前 P-1.2 不得开始 |
| 2 | `latest` 标签不可溯源 | compose 用 `latest`，无 digest | P-10 必须取 `RepoDigests` 并与容器 `Image` 比对；不一致即 `digest_ambiguous` |
| 3 | 只读打开 WAL 库可能失败 | WAL 需要 `-shm` 可访问；`mode=ro` 在极端权限下会 `unable to open` | 脚本遇 `OPEN_FAILED` **立即停止**，禁止改用 `immutable=1`（会忽略 WAL，读到过期数据） |
| 4 | 共享卷不支持 fsync/rename | NAS 常见 NFS/CIFS/SMB 挂载 | 只能靠 P-7 实证；不支持 ⇒ 迁移功能禁用，业务照常 |
| 5 | 容器 uid 与宿主目录权限不符 | bind mount + 非 root 运行是常见组合 | P-8 实测 `uid`；`STATE_DIR` 需可写，否则自检失败即禁用迁移 |
| 6 | 备份与 data 同盘写满 | compose 中 `backup` 与 `data` 都在 `/opt/nodepool` 下（可能同一块盘） | P-6 必须同时看 `df /data` 与 `df /backup`；`avail < 3×库 或 <2GB` ⇒ 拒绝迁移 |
| 7 | 有 `-wal` 残留 + 未提交事务 | 进程运行时常态 | 只做记录；**不 checkpoint、不清 WAL**；写入封锁阶段再处理 |
| 8 | `tasks` 表存在与否影响基线摘要 | 开发库有 `tasks`（0 行）；生产未知 | 主结构摘要已排除 `tasks`，两形态都合法（计划 §2.2/PT-06d） |
| 9 | 恢复路径现状不安全 | `restore_backup()` 用 `copy2`、无 WAL 处理，`reset_connection()` 只关当前线程 | 已在计划 §3.3 改为九步 `restore_set()`；**P-1 不动现有接口行为** |
| 10 | `/healthz` 的 `db` 只判"文件存在" | `routes.py:1609` | 健康检查不能当数据完整性证据；完整性只认 `integrity_check` |

**未越界确认**：本轮未执行 checkpoint、未改库、未改配置、未启停服务、未做迁移/恢复/清理、未删除任何文件。

---

## 6. 未解决问题与推进路径

| # | 问题 | 建议 |
| --- | --- | --- |
| 1 | 生产不可达（本报告的根本限制） | **路径 A（推荐）**：你在 NAS 宿主跑 `NodePoolME-P-1-生产探针-v1.10.sh`，把 log 回贴，我据此出正式基线报告并回填 §1.2.7。**路径 B**：提供 SSH（host/user/key 或临时口令）授权我远程只读执行。**路径 C（不够）**：仅靠 `/api/system/*` 只读端点，覆盖不到 P-4/P-7/P-8 |
| 2 | P-7 未执行 | 见 §7 审批包；需"生产可达 + 你批准"两个条件同时满足 |
| 3 | 计划里"`/healthz` 很可能无版本字段"与代码不符 | 建议批准后把 §1.2.7 P-10 的降级预案改为"已确认存在 `version`，四值核对为标准路径" |
| 4 | `logs` 无 `category` 列 | 探针与后续"发布日志检索"只能按 `source`/`message` 文本；计划 §1.3 若引用 `category` 需一并更正（本轮未改计划） |
| 5 | 生产 SQLite 版本未知 | 若 <3.35.0，需先评估 `ALTER`/触发器相关能力，P-1.2 前给出替代方案 |
| 6 | `sub_publish_next_at` 在开发库为 `NULL` | 生产若同为 `NULL`，说明"下次发布时间"是运行时推算而非落库；升级窗口只能按 `time`/`interval` 人工避让，需在基线报告里写清推算规则 |

---

## 7. P-7 审批包（状态：未执行，等待批准）

**目标目录**：`/opt/nodepool/data/state`（容器内 `/data/state`）。当前**不存在**（代码尚未引入 `STATE_DIR`，compose 也未设该变量）。

**将创建**：
1. 空目录 `state/`（仅当不存在时创建）；
2. `state/p1probe.<8位hex>.tmp`（13 字节）；
3. `state/p1probe.<8位hex>.json`（同内容，rename 目标）；
4. 随后删除上述两个文件；若 `state/` 是本次创建且为空，再 `rmdir` 删除该目录。

**完整命令**（脚本第 5 段，`NODEPOOL_P7_APPROVED=1` 才执行）：

```sh
NODEPOOL_P7_APPROVED=1 sh NodePoolME-P-1-生产探针-v1.10.sh
# 等价的核心动作（容器内）：
#   stat st_dev 比对（不等即退出，不写）
#   open('…tmp','wb').write(b'{"probe":true}') → flush → os.fsync(fd)
#   os.replace('…tmp','…json')
#   os.open(STATE_DIR, O_RDONLY|O_DIRECTORY) → os.fsync(dfd)
#   json.loads(回读) → unlink('…json') → 再 open(dir) → fsync
```

**影响范围**：仅在 `data` 卷下新增/删除 2 个 13 字节文件，可能新增 1 个空目录；**不触碰** `nodepool.db`、`-wal`、`-shm`、`config`、`backup`、`logs`；不改库、不改配置、不重启服务；失败路径也会在 `finally` 清理。

**判据**：`db_st_dev == state_st_dev` ∧ 七步全 OK ⇒ `ATOMIC_WRITE_SUPPORTED`；`st_dev` 不等 ⇒ 直接退出并判"拒绝迁移"；任一步抛错 ⇒ `maint_fs_unsupported`（记录 `errno`），迁移入口禁用、业务不受影响。

---

## 8. 交付物与变更

| 文件 | 说明 |
| --- | --- |
| `NodePoolME-P-1生产环境摸底报告-v1.10.md` | 本报告 |
| `NodePoolME-P-1-生产探针-v1.10.sh` | 可直接在 NAS 宿主执行的探针（`EXEC`/`PROBE_MODE`/`NODEPOOL_HEALTHZ` 可覆盖；P-7 默认跳过） |

**未修改**：总体设计 v1.10、P-1 实施计划 v1.10、任何业务代码、生产数据与配置。

**P-7 状态**：`未执行（等待批准）`，且需生产可达后重跑第 5 段。

**下一步**：等你在 NAS 上跑一次并把 log 回贴（或给 SSH 授权），我据此产出"生产基线报告 + §1.2.7 回填表 + 能否进入 P-1.2 的结论"。本轮到此停止，不进入 P-1.2。
