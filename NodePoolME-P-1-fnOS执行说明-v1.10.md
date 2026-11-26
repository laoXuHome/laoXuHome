# NodePoolME P-1 探针 · fnOS NAS 执行说明（v1.10 / r5）

> 目标：用户只复制两段命令就能跑完 P-1，不需要装 Python、Git、编译器或任何开发工具。
> P-7 保持未授权、不会执行；脚本默认 `NODEPOOL_P7_APPROVED=0`。

---

## 1. 依赖清单：到底需要什么

| 依赖 | 谁在用 | 是否必须 | 说明 |
| --- | --- | --- | --- |
| `/bin/sh`（dash/bash 均可） | 宿主机跑脚本 | **必须** | fnOS 自带；脚本按 POSIX 写，无 bash 专属语法 |
| `docker` CLI | 定位容器、读挂载与镜像、进容器 | **必须** | fnOS 自带 Docker 引擎 |
| docker 访问权限 | 同上 | **必须** | 当前用户在 `docker` 组，或用 `NODEPOOL_DOCKER="sudo docker"` |
| `printf/sed/awk/grep/cut/head/tail` | 路径解析、字段提取 | 必须（基础工具） | fnOS 自带；已去掉对 `sort -k` 的依赖，busybox 也可用 |
| `python3`（**容器内**） | 只读查库、读配置、healthz | 必须（容器内） | 应用镜像自带，**宿主机不需要 Python** |
| `bash` | 只为 `set -o pipefail` 保留退出码 | 可替代 | 无 bash 时用"先落盘再打印"的写法（见 §3） |
| `curl` | 仅下载脚本 | 可替代 | 捆绑 curl 缺失时可用 `docker cp`/scp 传脚本 |
| `stat -f -c` | 卷类型（仅供参考） | 可替代 | 非 GNU 时脚本自动跳过该项（`|| echo`） |
| `lsof` / `fuser` | 句柄旁证 | 可替代 | 缺失只影响"谁打开了文件"的旁证，不影响判定 |
| Git / gcc / pip / venv | —— | **不需要** | 脚本不构建、不安装任何东西 |
| 宿主机 Python | —— | **不需要** | 所有 Python 都在 `docker exec` 里跑 |

**结论**：fnOS 上唯一"必须有"的是 `docker` + 权限 + POSIX shell；其余缺了都有替代或可跳过。

---

## 2. 先做环境检查（只读，零副作用，不安装任何东西）

```sh
echo "== identity =="; id
echo "== docker cli =="; command -v docker || echo "docker CLI MISSING"
echo "== docker access (non-sudo) =="; docker ps --format '{{.Names}}	{{.Image}}' 2>&1 | head -5
echo "== docker access (sudo -n, 仅尝试) =="; sudo -n docker ps --format '{{.Names}}' 2>&1 | head -3
echo "== shell & tools =="; for t in sh bash sed awk grep cut head tail printf stat curl; do printf '%-8s %s\n' "$t" "$(command -v $t || echo MISSING)"; done
echo "== host python (应当缺失也没关系) =="; command -v python3 || echo "host python3 ABSENT (OK)"
echo "== container python =="; C=$(docker ps --format '{{.Names}}|{{.Image}}' | grep -i nodepool | head -1 | cut -d'|' -f1); echo "container=$C"; [ -n "$C" ] && docker exec "$C" python -V 2>&1
echo "== mounts on host =="; ls -ld /opt/nodepool /opt/nodepool/data /opt/nodepool/backup 2>&1
echo "== disk =="; df -h /opt/nodepool/data /opt/nodepool/backup 2>&1 | tail -3
```

判定：

| 观测 | 结论 |
| --- | --- |
| `docker ps` 正常列出 nodepool | 可以直接用 §3 的第一条命令 |
| `docker ps` 报 `permission denied`，但 `sudo -n docker ps` 正常 | 用 `NODEPOOL_DOCKER="sudo docker"` 执行 |
| 两者都失败 | 停：先处理 docker 权限（把用户加入 `docker` 组或配置 sudo），**不要为此装软件** |
| `container python -V` 失败 | 停：容器内没有 Python ⇒ 该镜像不是正常 NodePoolME 镜像，先确认镜像来源 |
| `/opt/nodepool/data` 不存在 | 停：`NODEPOOL_ROOT` 不是默认值，先确认 compose 里的实际根目录 |

---

## 3. 正式执行（复制即用）

**默认（当前用户在 docker 组）**

```sh
cd /tmp && curl -fsSL -o /tmp/np-p1-probe.sh https://raw.githubusercontent.com/laoXuHome/laoXuHome/main/NodePoolME-P-1-%E7%94%9F%E4%BA%A7%E6%8E%A2%E9%92%88-v1.10.sh && bash -c 'set -o pipefail; sh /tmp/np-p1-probe.sh 2>&1 | tee /tmp/p1-probe-$(date +%Y%m%d-%H%M%S).log'; echo "EXIT=$?"
```

**需要 sudo 时**（只在命令前加一个变量，其余不变）

```sh
cd /tmp && curl -fsSL -o /tmp/np-p1-probe.sh https://raw.githubusercontent.com/laoXuHome/laoXuHome/main/NodePoolME-P-1-%E7%94%9F%E4%BA%A7%E6%8E%A2%E9%92%88-v1.10.sh && bash -c 'set -o pipefail; NODEPOOL_DOCKER="sudo docker" sh /tmp/np-p1-probe.sh 2>&1 | tee /tmp/p1-probe-$(date +%Y%m%d-%H%M%S).log'; echo "EXIT=$?"
```

**没有 bash / curl 时**（PATH 里手动放脚本，先落盘再打印）

```sh
sh /tmp/np-p1-probe.sh > /tmp/p1-probe.log 2>&1; rc=$?; cat /tmp/p1-probe.log; echo "EXIT=$rc"
```

说明：

- 命令用 `-o /tmp/np-p1-probe.sh` 固定落盘名，避免 `curl -O` 把 URL 里的百分号编码保留成文件名（那会导致后面找不到脚本）。
- 脚本只写 `/tmp`（日志与探针临时文件），不写 `data/`、`config/`、`backup/`。
- P-7 段永远打印 `SKIPPED: 未执行（等待批准）`，不会写任何文件。

---

## 4. 权限说明

| 操作 | 需要 | 备注 |
| --- | --- | --- |
| `docker ps` / `inspect` / `image inspect` | docker socket 访问权 | 等价于 root 级权限，但只读 |
| `docker exec`（只读查库） | 同上 | 容器内默认以 root 执行，只做 `mode=ro` 打开与 `PRAGMA` 查询 |
| 写 `/tmp` 日志 | 普通用户即可 | 建议 `/tmp` 有空间（日志 < 100 KB） |
| P-7（未授权） | 额外显式授权 | 本轮不执行，命令里不要加 `NODEPOOL_P7_APPROVED=1` |

---

## 5. 预期输出（照这个比对）

```
container_name  nodepool
running started=... restart=unless-stopped
/tmp/...|/data|bind            ← 挂载行，实际是 /opt/nodepool/...
app_version       1.8.7
container_db      /data/nodepool.db
container_state   /data/state   (来源：默认 <DATA_DIR>/state)
host_db           /opt/nodepool/data/nodepool.db
pre_import_dirs OK（DATA_DIR/CONFIG_DIR/LOG_DIR/BACKUP_DIR/SUB_DIR 均存在…）
path_check DATA_DIR OK …       ← 五行，全 OK
image_id(running)       sha256:…
digests_for_repo(...) 1
VERDICT_digest OK：可溯源
healthz_version 1.8.7
sqlite_version …, journal_mode ('wal',), integrity ok, fk_violations 0
data_version_changed False
setting sub_publish_mode time …
P-7 状态：未执行（等待批准）
脚本退出码：0
```

`EXIT=0` 且上述关键行齐全 ⇒ 本次探针成功，把整段日志回贴即可。

---

## 6. 失败处理

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `EXIT=2` + `STOP: docker ps 里没有运行中的 nodepool 容器` | 容器名不含 `nodepool` 或未运行 | `docker ps -a` 找到真实名，用 `NODEPOOL_CONTAINER=<name>` 重跑 |
| `EXIT=2` + `STOP: 匹配到 N 个候选容器` | 同时有新旧容器 | 指定 `NODEPOOL_CONTAINER=` 明确一个 |
| `EXIT=2` + `STOP: 存在会被 backend.config 导入自动 mkdir 的目录（"LOG_DIR"）` | 某个数据/日志/备份/子目录挂载缺失 | 先查挂载是否正确；脚本故意不替你建目录 |
| `EXIT=2` + `STOP: 数据库路径映射不到宿主机` | 容器内路径不在任何 mount 下 | 查 compose 挂载；不要改用 `docker cp` 绕 |
| `EXIT=2` + `STOP: 容器内 import backend.config 失败` | 容器里不是完整应用镜像 | 确认镜像 tag/digest 与部署记录一致 |
| `permission denied ... docker.sock` | 用户不在 docker 组 | 加组或用 `NODEPOOL_DOCKER="sudo docker"` |
| `curl: command not found` | 无 curl | 用 scp 传脚本，再执行 §3 第三条 |
| `EXIT=3` | 仅在批准 P-7 后才可能出现 | 本轮不应出现；出现即说明 P-7 失败，把 `STEP_FAILED` 行贴出来 |

---

## 7. 本次明确不做的事

- 不安装 Python / Git / 编译工具，不改 `docker-compose.yml`，不重启服务。
- 不执行 P-7，不加 `NODEPOOL_P7_APPROVED=1`。
- 不修改数据库（只读 + 不 checkpoint；`mode=ro` 打开 WAL 库时 SQLite 可能补建 `-shm/-wal` 空文件，主库字节与 mtime 不变）。
