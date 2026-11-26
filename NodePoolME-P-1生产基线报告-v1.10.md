# NodePoolME P-1 生产基线报告（v1.10）

> 依据：已批准的《NodePoolME-P-1实施计划-v1.10》与《NodePoolME-新架构总体设计方案-v1.10》。
> 探针：`NodePoolME-P-1-生产探针-v1.10.sh`（r5，commit `ad6b11fb…`，blob `fa8a2bc8…`，20,155 字节 / 416 行）。
> 执行：用户于 2026-11-26 14:01–14:03（UTC+8）在 NAS（hostname `HomeVault`，fnOS）以 `root` 身份、经 Lucky Web 终端执行；`EXIT=0`。
> 证据形态：用户回传的 5 张终端截图，本报告为逐项转录。截图未覆盖的行以 `—` 标注，不做估算。

---

## 0. 结论摘要

1. **目标唯一且已确认**：容器 `nodepool`（镜像 `ghcr.io/laoxuhome/nodepoolme:v1.8.7`），无同类容器竞争，未使用任何硬编码路径，宿主路径全部来自 `docker inspect` 的 `Mounts`。
2. **五项目录在导入 `backend.config` 之前全部存在**，导入后逐项核对一致（`DATA_DIR /data`、`CONFIG_DIR /config`、`LOG_DIR /logs`、`BACKUP_DIR /backup`、`SUB_DIR /data/sub`），config 导入未产生副作用。
3. **`STATE_DIR` 尚不存在**（`<DATA_DIR>/state` → `/vol1/1000/docker/nodepoolme/data/state`）。属预期状态：迁移器入口创建；本探针与 P-7 均未创建。
4. **P-7 未执行**（未授权且目录不存在），`SKIPPED`，不记失败、不阻断 P-1.2。
5. **镜像四值一致且可溯源**：镜像 tag `v1.8.7`、容器配置版本 `1.8.7`、`config.VERSION 1.8.7`、`/healthz.version 1.8.7`；`RepoDigests` 按不可变 `image_id` 查询命中 1 条 digest。
6. **基线与设计假设存在 4 项实质差异**（见 §7）：无近期可用备份、生产写入在探针期间发生过（`data_version 2→3`）、`sub_publish_last_at/next_at` 未随发布更新、早期 tar.gz 备份体量异常。均为**事实记录**，处置建议列在 §8，等待项目负责人决策。

---

## 1. 执行环境与执行方式

| 项 | 实测值 |
|---|---|
| 主机 | `HomeVault`（fnOS NAS），内核构建日期 2026-10-30，`x86_64` |
| 执行身份 | `uid=0(root) gid=0(root) groups=0(root)`（`sudo -i` 后执行） |
| 目标容器 | `nodepool`，`running`，`started=2026-11-25T15:59:35Z`，`restart=unless-stopped` |
| 宿主机 docker | `/usr/bin/docker`，无需 `sudo docker` 前缀（`NODEPOOL_DOCKER` 默认） |
| 宿主机工具 | `sh/bash/sed/awk/cut/head/tail/printf/stat/curl` 均存在；`fuser`/`lsof` 不可用（已自动降级）；`grep` 为带色 alias（非交互脚本不受影响） |
| 容器内 Python | `3.12.16`（`docker exec` 可用） |
| 宿主机 Python | `/usr/bin/python3` 存在，但**未使用**（探针一律走容器内解释器） |
| 退出码 | `EXIT=0`（`bash -c 'set -o pipefail; … | tee …'`，退出码未被管道掩盖） |

---

## 2. P-1 目标识别与路径映射

**容器识别**：按 `nodepool` 关键字匹配到唯一容器 `nodepool`，未触发「容器不唯一」停止分支。

**`docker inspect` 真实挂载（bind）**：

| 宿主机路径 | 容器路径 | 类型 |
|---|---|---|
| `/vol1/1000/docker/nodepoolme/data` | `/data` | bind |
| `/vol1/1000/docker/nodepoolme/config` | `/config` | bind |
| `/vol1/1000/docker/nodepoolme/logs` | `/logs` | bind |
| `/vol1/1000/docker/nodepoolme/backup` | `/backup` | bind |

**探针推导结果**：

| 变量 | 容器内值 | 宿主机值 | 存在性 |
|---|---|---|---|
| `DATA_DIR` | `/data` | `/vol1/1000/docker/nodepoolme/data` | 存在 |
| `CONFIG_DIR` | `/config` | `/vol1/1000/docker/nodepoolme/config` | 存在 |
| `LOG_DIR` | `/logs` | `/vol1/1000/docker/nodepoolme/logs` | 存在 |
| `BACKUP_DIR` | `/backup` | `/vol1/1000/docker/nodepoolme/backup` | 存在 |
| `SUB_DIR` | `/data/sub` | —（映射到 `data/sub`） | 存在 |
| `DB_PATH` | `/data/nodepool.db` | `/vol1/1000/docker/nodepoolme/data/nodepool.db` | 存在 |
| `STATE_DIR` | `/data/state` | `/vol1/1000/docker/nodepoolme/data/state` | **不存在**（默认值 `<DATA_DIR>/state`，无 `NODEPOOL_STATE_DIR` 覆盖） |

**导入前后一致性核对**：`pre_import_dirs OK` → 五行 `path_check … OK`（`DATA_DIR/CONFIG_DIR/LOG_DIR/BACKUP_DIR/SUB_DIR` 预查路径与导入后的实际值逐项一致）。**未出现任何 `STOP`。**

**同卷确认（对 v1.10「`STATE_DIR` 必须与 `DB_PATH` 同 `st_dev`」的前置验证）**：`/data` 与 `/backup` 均落在同一 `dm` 设备 `/dev/mapper/trim_e99106a3-dd11-42c0-a1e4-abc3d6b6136b-0`（btrfs，block 4096）。`STATE_DIR` 位于 `data` 子目录内，与 `DB_PATH` 天然同卷 → 迁移前不触发「跨卷拒绝」。

---

## 3. P-10 镜像溯源与版本四值核对

| 项 | 实测值 |
|---|---|
| `image_ref`（`Config.Image`） | `ghcr.io/laoxuhome/nodepoolme:v1.8.7` |
| `image_id`（运行容器） | `sha256:3e77c3ac1839b11a6c31db76d83d037d425e46a96de45fcb931eebc1cf0b816a` |
| `image_id`（当前 tag 指向） | `sha256:3e77c3ac1839b11a6c31db76d83d037d425e46a96de45fcb931eebc1cf0b816a`（**与运行容器一致，tag 未漂移**） |
| `RepoDigests`（按 `image_id` 查询） | `ghcr.io/laoxuhome/nodepoolme@sha256:ca97a56640ad5111449bd09e7d7f81cde570f7ac1ac14df588ea8a6f3dfb76d1`（`digests_for_repo=1`） |
| 判定 | `VERDICT_digest OK：可溯源` |
| `config.VERSION` | `1.8.7` |
| `/healthz` | `http://127.0.0.1:8080/healthz` → `{"status":"ok","version":"1.8.7","engine":"mihomo","db":true,"scheduler":true}` |
| `/healthz.version` | `1.8.7`，键集 `['db','engine','scheduler','status','version']` |

**四值核对结论：一致**（镜像 tag `v1.8.7` = 容器 `Config.Image` = `config.VERSION 1.8.7` = `/healthz.version 1.8.7`）。基线 `<commit e721797 / v1.8.7>` 与生产实际运行版本相符，P-1.2 的迁移前提成立。

---

## 4. P-1 / P-3 / P-4 数据库物理与逻辑基线

### 4.1 文件与 PRAGMA（只读连接，未 checkpoint）

| 项 | 值 |
|---|---|
| 主库文件 | `/vol1/1000/docker/nodepoolme/data/nodepool.db` |
| 字节数 | `55,599,104`（≈ 53.0 MiB） |
| SQLite 版本 | `3.46.1` |
| `page_size` | `4096` |
| `page_count` | `13,575`（`page_bytes = 55,603,200`） |
| `freelist_count` | `0` |
| `journal_mode` | `wal` |
| `synchronous` | `2`（FULL） |
| `wal_autocheckpoint` | `1000` 页 |
| `page_bytes == file_bytes` | `False`（差 `4,096` = 1 页） |
| `integrity_check` | `ok` |
| `foreign_key_check` 违规数 | `0` |
| `data_version`（单次读连接内） | `3` |

### 4.2 WAL / SHM 物理实体（P-4b）

| 文件 | 字节 | mtime |
|---|---|---|
| `nodepool.db` | `55,599,104` | 2026-11-26 14:01 |
| `nodepool.db-wal` | `6,142,952`（≈ 5.86 MiB） | 2026-11-26 14:01 |
| `nodepool.db-shm` | `32,768` | 2026-11-26 14:01 |

存在约 5.86 MiB 未 checkpoint 的 WAL 帧 → **任何基于文件拷贝（`cp`/`shutil.copyfile`）的备份都会得到不完整或不可用副本**，与 v1.10 `restore_set()` 采用 `sqlite3.backup()` + 删 `-wal/-shm` 的设计一致，本项为设计正确性的生产侧证据。

### 4.3 表结构与行数（19 张，含 2 张非业务表）

| 表 | 行数 | 备注 |
|---|---|---|
| `results` | 169,714 | 旧结果表（v1.10 计划停写归档） |
| `latency_results` | 254,710 | 旧延迟表（含 `target`） |
| `logs` | 5,631 | 列 `id,ts,level,source,message`（**无 `category`**） |
| `share_history` | 1,504 | |
| `speed_samples` | 991 | |
| `speed_runs` | 392 | |
| `batches` | 371 | 截至批次 #370 |
| `nodes` | 244 | |
| `fetch_logs` | 169 | |
| `settings` | 69 | 列 `key,value` |
| `run_events` | 49 | |
| `airport_filtered_nodes` | 16 | |
| `speed_source_checks` | 29 | |
| `speed_sources` | 8 | |
| `airports` | 6 | |
| `test_groups` | 4 | |
| `schedule_history` | 1 | |
| `tasks` | 0 | **遗留表，仍存在于生产**（开发库同样为 0 行） |
| `sqlite_sequence` | 16 | 存在自增表 |

| 其它对象 | 数量 |
|---|---|
| 视图 `views` | `[]`（0） |
| 索引 `indexes` | 13 |
| 触发器 `triggers` | `[]`（**0**） |

**关键判读**：生产库 `triggers=0`，与 v1.10「六触发器 + `trg_nodes_delete_guard`」从零新增的开局一致；`target_results`、`detection_*`、`schema_migrations`、`system_events`、`migration_tx_notes` 均**不存在**（v1.10 迁移新建），未发现任何"部分迁移已发生"的痕迹。

### 4.4 P-5 持有者（谁打开着数据库）

- 容器内：`/proc/1/fd/12 → /data/nodepool.db`、`fd/13 → -wal`、`fd/14 → -shm`（容器主进程 `uvicorn`）。
- 宿主机：`uvicorn` PID `592,885`（`root`），`12u/13u/14u` 分别持有 `db`（inode 7987）/`-wal`（inode 10620）/`-shm`（inode 10621），路径均为 `/vol1/1000/docker/nodepoolme/data/*`。
- `fuser` 不可用（未安装），已按设计降级为 `/proc` + 宿主侧句柄视图，**未安装任何软件**。

**意义**：迁移前「停写排空 + 句柄确认」必须清到 PID 592,885 的三个 fd 全部关闭，`restore_set()` 的句柄断言有明确的基线对照值（inode 7987/10620/10621）。

### 4.5 P-5b `data_version` 双读（只读性证据，同时暴露生产活跃度）

| 项 | 值 |
|---|---|
| `data_version_before` | `2` |
| `data_version_after` | `3` |
| `data_version_changed` | `True` |

**判读**：在探针执行窗口内（秒级），其它连接**提交过写入**。这说明：
1. 生产处于活跃写入态（订阅 30 分钟发布 + 测试器回写），基线是"某一时刻的快照"，不是静止状态；
2. 迁移阶段的"停写排空"必须真实生效，不能假设低峰期无写入；
3. 探针本身仍是只读的——`data_version` 变化来自业务进程，不来自探针（探针无写路径、无事务）。

---

## 5. P-6 备份基线

目录：`/vol1/1000/docker/nodepoolme/backup`（`total 9.3M`）

| 文件 | 大小 | 属主 | mtime |
|---|---|---|---|
| `nodepool-latest.db` | 4.7M | root:root | 2026-11-22 16:07 |
| `nodepool-20261122-160721.db` | 4.7M | root:root | 2026-11-22 16:07 |
| `nodepool-20261121-145628.tar.gz` | 9.1K | root:root | 2026-11-21 14:56 |
| `nodepool-20261121-145603.tar.gz` | 9.1K | 1000:1001 | 2026-11-21 14:56 |
| `nodepool-20261121-145432.tar.gz` | 19K | root:root | 2026-11-21 14:54 |

**卷余量**（`df`）：

| Filesystem | Size | Used | Avail | Use% | Mounted |
|---|---|---|---|---|---|
| `/dev/mapper/trim_e99106a3-…-0` | 175G | 47G | **126G** | 28% | `/backup`、`/data` |

**判读（对 v1.10 的直接输入）**：

- `NODEPOOL_SNAPSHOT_MIN_FREE_MB=2048` 的余量门槛**满足**（126 GiB 可用）。
- 现存备份形态为「裸 `.db` 文件 + 早期 `tar.gz`」，**不是** v1.10 的备份集目录（`<BACKUP_DIR>/nodepool-YYYYMMDD-HHMMSS-<stage>/{db,manifest.json,complete.json}`）→ 属于 `legacy` 实现，与 `NODEPOOL_BACKUP_IMPL=legacy|v2` 的双实现切换一致，需在 P-1.4 前后按计划切换。
- **最新备份为 2026-11-22 16:07，距执行时点（11-26 14:02）约 4 天**，而订阅发布每 30 分钟一次（见 §6）→ 日备份链路疑似自 11-22 起中断。详 §7-R1。
- 早期 `tar.gz` 仅 9.1K / 19K，与 11-22 的 4.7M 数据库体量差三个数量级 → 内容形态不明（可能仅含配置或旧库极早期状态）。详 §7-R4。

---

## 6. P-9 订阅发布基线

| 设置键 | 值 |
|---|---|
| `sub_publish_enabled` | `1` |
| `sub_publish_mode` | `interval` |
| `sub_publish_time` | `04:30` |
| `sub_publish_interval_minutes` | `30` |
| `sub_publish_next_at` | `2026-11-26 13:57:01` |
| `sub_publish_last_at` | `None` |

`logs` 表最近两次发布记录：

| id | ts | level | source | message |
|---|---|---|---|---|
| 5623 | 2026-11-26 13:57:51 | INFO | 下发 | 订阅已下发（81 个节点，过滤 82 个，原因：批次 #370） |
| 5608 | 2026-11-26 13:27:01 | INFO | 下发 | 订阅已下发（82 个节点，过滤 80 个，原因：批次 #369） |

**判读**：发布链路**正常工作**（30 分钟一档，`#369 → #370` 连续），但 `settings` 中的 `sub_publish_last_at=None`、`next_at` 停留在 `13:57:01`（已过期未推进）→ **`settings` 表未随发布更新**，调度时间戳由内存态驱动。这不影响 P-1 基线，但影响 v1.10 中依赖 `next_at`/`last_at` 的「发布保留/零健康窗口」判定，列为 §7-R2，待 P-1.2+ 处置。

`inputs`：`logs` 表无 `category` 列，与阶段 0 审查结论一致；后续 `system_events` 作为唯一事件通道的设计不依赖 `logs` 扩展。

---

## 7. 与 v1.10 设计假设的差异（事实清单，供项目负责人决策）

| 编号 | 事实 | 影响 | 建议处置（不自行执行） |
|---|---|---|---|
| **R1** | 最新备份 `2026-11-22 16:07`，距执行约 4 天；日备份疑似中断 | 迁移前无"近期可恢复点"，P-1.4 的 `pre-migrate` 备份若无新基线，回滚承诺缺参照 | 在 P-1.2 开工前补做一次 `pre-migrate` 备份（走容器内 `sqlite3.backup()`，非文件拷贝），并核查日备份失败原因 |
| **R2** | `data_version` 在探针秒级窗口内 `2→3`；`sub_publish_last_at=None`、`next_at` 过期未推进 | 基线为动态快照；任何依赖 `next_at` 的窗口判定会读到陈旧值 | 迁移按「停写排空」执行；`next_at/last_at` 语义问题列入 P-1.2 施工项（非 P-1 验收项） |
| **R3** | `page_count=13,575` 而文件实容 13,574 页（差 1 页 / 4,096 B） | 头部页计数与文件长度不完全对应；结合 5.86 MiB 未 checkpoint WAL，属 WAL 活跃期的常见表现 | 不使用文件拷贝做备份/校验基准；`integrity_check=ok` 已排除损坏，不阻断 |
| **R4** | 早期 `tar.gz` 备份仅 9.1K / 19K，且其中一个属主为 `1000:1001` | 备份形态不统一、可用性未经证实 | P-1.4 前做一次恢复演练取样（只读解包核对内容），不覆盖任何现有文件 |
| **R5** | 遗留 `tasks` 表仍存在（0 行）；`sqlite_sequence` 存在；`triggers=0` | v1.10 迁移需处理遗留表与自增序列，且六触发器从零建 | 按 v1.10 迁移脚本既定处理，无需额外决策 |
| **R6** | 目录权限显示为 `d---------`（`/config`、`/data`、`/backup`），容器与宿主均为 `uid=0` | 备份/恢复写入必须以 root（或容器内 root）执行；非 root 进程会 `EACCES` | 备份与恢复实现统一在容器内以 root 执行（与现有部署一致） |
| **R7** | `STATE_DIR` 不存在，`maintenance.json` 必为 `ABSENT` | 符合"迁移未开始"的期望初态 | 由迁移器入口创建目录并写入 `maintenance.json`；P-7 需单独授权后再验证原子写 |

---

## 8. P-1 至 P-10 判定（按 v1.10 原口径，不自行加码）

| 项 | 内容 | 判定 | 依据 |
|---|---|---|---|
| P-1 | 目标容器识别 | **PASS** | 唯一容器 `nodepool`，无硬编码路径 |
| P-2 | 版本一致性（四值） | **PASS** | `1.8.7` / `1.8.7` / `1.8.7` / `1.8.7` |
| P-3 | 数据库体量与 PRAGMA | **PASS** | 53.0 MiB、WAL、FULL、autocheckpoint 1000 |
| P-4 | WAL/SHM 与完整性 | **PASS** | `integrity ok`、`fk_violations 0`、WAL 5.86 MiB（含观察项 R3） |
| P-5 | 句柄/外部持有者 | **PASS** | `/proc` + 宿主句柄双向确认；`fuser` 不可用已降级 |
| P-6 | 备份目录与余量 | **PASS**（数据已取得） | 9.3M / 126G 可用；暴露 R1、R4 |
| P-7 | 原子写测试 | **SKIPPED（未授权）** | `state` 目录不存在且未批准；按新验收规则**不记失败、不阻断 P-1.2** |
| P-8 | 运行身份与权限 | **PASS** | `uid=0/gid=0`，容器 root 执行 |
| P-9 | 订阅发布配置与最近发布 | **PASS**（数据已取得） | interval 30 分钟、#369/#370 正常；暴露 R2 |
| P-10 | 镜像溯源 | **PASS** | digest 命中 1 条、tag 未漂移、四值一致 |

**P-1 生产基线：数据采集完成，10 项中 9 项 PASS、1 项按规则 SKIPPED。** 未伪造、未估算任何未采集值。

---

## 9. 未执行 / 未采集项（如实声明）

1. **P-7 未执行**：未写任何文件，`state/` 未创建；需单独授权 + `STATE_DIR` 存在后重跑该段。
2. **未采集**：生产 `sub_publish` 的实际 URL/UA/Token 配置内容（只读探针只取开关与时间戳，不取凭据）；备份集内部结构（未解包）；`nodes.status` 分布与 `fail_count` 分布（不在 P-1 采集范围，留给 P-1.2）。
3. **日志为截图转录**：若需逐字节核对（如 `df` 的 blocks、`ls` 的 inode），需回传 `/tmp/p1-probe-*.log` 原文。
4. **未修改生产任何配置**：未重启容器、未改 compose、未改环境变量、未安装软件、未 checkpoint、未动备份文件。

---

## 10. 交接给下一阶段的最小事实集

- 容器/路径：`nodepool`、`/vol1/1000/docker/nodepoolme/{data,config,logs,backup}` ↔ `/data,/config,/logs,/backup`。
- 迁移目标路径：`DB_PATH=/vol1/…/data/nodepool.db`，`STATE_DIR=/vol1/…/data/state`（待创建），同卷 btrfs 4096。
- 版本锚点：`v1.8.7` / `sha256:3e77c3ac…` / digest `sha256:ca97a566…`。
- 起始 schema：19 表、13 索引、**0 触发器**、无 `schema_migrations` / `system_events` / `target_results`。
- 停写断言基线：`uvicorn` PID `592,885`、fd `12/13/14`、inode `7987/10620/10621`。
- 备份现状：`legacy` 形态、最新 `2026-11-22 16:07`、余量 126G。
- 发布现状：`interval` 30 分钟、批次 `#370`、`settings` 时间戳未更新。

---

*报告版本：v1.10-baseline-r1｜生成日期：2026-11-26｜依据探针 EXIT=0 输出｜不修改总体设计 v1.10 与 P-1 实施计划 v1.10*
