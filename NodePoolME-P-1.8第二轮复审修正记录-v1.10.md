# NodePoolME P-1.8 第二轮复审修正记录（v1.10）

**性质**：仅文档与实施设计修订。未修改程序代码，未执行 pytest，未执行 Docker，未执行迁移，未连接 NAS。
**依据**：ChatGPT 第二轮独立复审意见（2026-11-26）——P-1.8 暂不批准施工，先清理生产残留、解决 R4 恢复路径矛盾、明确迁移内容与旧定义。
**日期**：2026-11-26

## 1. 修订总览

| # | 复审问题 | 修订落点 | 结果 |
| --- | --- | --- | --- |
| 1 | §6 第 4 步仍写"真机导入/维护窗口" | 计划 §6 第 4、5 步 | 改为独立 Docker 测试容器 `nodepool-p18-test`、测试路径 `/tmp/p18test/{data,backup,state}`、端口 8089；明确禁止生产容器/NAS/真实维护窗口 |
| 2 | R4 恢复路径矛盾 | 计划 §8.2、设计 §12 | 新增 `RECOVERY_REQUIRED` 授权导入分支、9 步状态转换表、R4-a…d 专项验收 |
| 3 | 未明确迁移内容 | 计划 §8.3、设计 §12 | 固定源/目标版本、唯一 DDL、结构差异、数据变化、成功/失败/重复判据；声明 P-1.6 空迁移不足以支撑 R1–R5 |
| 4 | 旧定义残留、计时不清 | 计划 §8.4、§10、修订记录 | 旧 P-1.1/P-7 停止条件标为历史；定义 `T_mig`/`T_block`；登记三处代码注释待施工修正 |

## 2. 清理生产操作残留（§6 第 4 步）

| | 内容 |
| --- | --- |
| 修订前 | "真机导入（仅在维护窗口）：停应用/容器 → `cli import --file …` → 重启 → 只读复核" |
| 修订后 | "导入演练（**仅独立 Docker 测试容器**）：容器 `nodepool-p18-test`，`DATA_DIR=/tmp/p18test/data`、`BACKUP_DIR=/tmp/p18test/backup`、`STATE_DIR=/tmp/p18test/state`、`NODEPOOL_DB` 指向测试库副本，端口 8089；停测试容器内应用进程 → 导入 → 重启测试容器 → 只读复核；**不得**在任何生产容器、NAS 目录或真实维护窗口执行" |
| 第 5 步 | "先看 `*.preimport-<stamp>.db` 与 `migration-fault.log`"补明"测试目录下" |

## 3. R4 恢复路径设计

### 3.1 问题定性

`cli._import()` 以 `gate.judge()` 必须为 `INACTIVE` 作为第一道闸；迁移 DDL 失败后 `schema_migrations.status='failed'` ⇒ `migration_incomplete()=True` ⇒ `RECOVERY_REQUIRED`。两条规则叠加使"失败后必须手动导入备份"的既定恢复手段无法执行。

### 3.2 设计结论

不删除 INACTIVE 检查，新增**仅限恢复态**的显式分支：

- 命令：`import --file <备份> --recover --reason "<说明>"`。
- `ACTIVE` 仍拒绝（`maintenance_active`，迁移仍在进行，须先停容器）。
- `RECOVERY_REQUIRED` 缺 `--recover` ⇒ `recovery_confirmation_required`；缺 `--reason` ⇒ `recovery_reason_required`。
- 授权审计写入 `migration-fault.log`（`recovery_import_started`：时间、`operator_uid`、备份名、sha256、reason）。
- 正常 `INACTIVE` 路径行为不变。

### 3.3 状态转换表

| 步 | 起始状态 | 动作 | 成功去向 | 失败去向 |
| --- | --- | --- | --- | --- |
| S0 | `RECOVERY_REQUIRED` | 解析参数、`gate.judge()` 复核 | S1 | 拒绝（退出码 2），状态不变 |
| S1 | `RECOVERY_REQUIRED` | `verify_backup()` 严格校验（成对元信息、字段齐全、内容实配、integrity） | S2 | `backup_invalid`；未进维护、目标库零改动，仍 `RECOVERY_REQUIRED` |
| S2 | `RECOVERY_REQUIRED` | 写恢复维护记录（`maintenance=true`、`reason=recovery_import`、`migration_id=recover-<stamp>`、phase `PREPARED`）+ 目录 fsync + 回读 | S3（`ACTIVE`） | `recovery_maintenance_unconfirmed`，封锁保持 |
| S3 | `ACTIVE` | `gate.apply_state(ACTIVE)` + `pool.block_writes` + `confirm_writes_blocked` | S4 | 退出码 4；维护文件保留，写封锁保持 |
| S4 | `ACTIVE` | `drain(rounds=2, min_interval=10)` | S5 | `drain_failed`，封锁保持 |
| S5 | `ACTIVE` | `close_all_connections_report()` 必须 `ok` | S6 | `connections_not_closed`，不替换文件 |
| S6 | `ACTIVE` | `import_backup()`：句柄复核（本进程 + 第三方）→ preimport（含 WAL）→ WAL/SHM 隔离 → 原子替换 → 完整性/结构/逐表计数复核 | S7 | `import_*`；尽力复原原失败库，封锁保持 |
| S7 | `ACTIVE` | 恢复后复核：`inspect_db` 完整性/结构；逐表计数与备份元信息一致；`schema_migrations` 不存在或全部 `success`，`current_version` 为基线或空 | S8 | `recovery_backup_incomplete` / `recovery_postcheck_failed`，封锁保持 |
| S8 | `ACTIVE` | 删 `maintenance.json` + 目录 fsync + 回读 `gate.judge()==INACTIVE` + `gate.release()` | S9 | 回读非 `INACTIVE` ⇒ 不解封，恢复维护文件，报 `recovery_release_refused` |
| S9 | `INACTIVE` | 退出码 0，提示重启并只读复核 | — | — |

### 3.4 R4 专项验收

| 编号 | 场景 | 断言 |
| --- | --- | --- |
| R4-a | DDL 失败后恢复 | 注入非法语句 ⇒ `failed` + `RECOVERY_REQUIRED` + 503；`import --recover` 迁移前备份 → 成功 → `INACTIVE` → 只读复核通过 |
| R4-b | `docker kill` 中断后恢复 | DDL 阶段强杀 ⇒ 重启 `RECOVERY_REQUIRED`；`import --recover` 成功；无自动恢复痕迹 |
| R4-c | 恢复态坏备份 | 截断/元信息篡改 ⇒ 退出码 2；目标库 sha 与逐表计数不变；状态仍 `RECOVERY_REQUIRED` |
| R4-d | 恢复过程异常 | S3–S7 注入失败 ⇒ 维护文件仍在、`writes_blocked=True`、业务 503；重启仍 `RECOVERY_REQUIRED` |

## 4. 迁移内容与前后结构差异

| 项 | 定义 |
| --- | --- |
| 源版本 | `1.8.7-baseline`（`VERSION_SEQ=1`）：17 张基准业务表 + 可选 `tasks` |
| 目标版本 | `1.10`（`VERSION_SEQ=2`），版本标记，无业务结构变更 |
| 唯一 DDL | `CREATE TABLE IF NOT EXISTS schema_migrations`（9 列、`status` CHECK、`migration_id`/`seq` 唯一）；`ensure_schema_table_transactional()` 在同一 `BEGIN IMMEDIATE` 内建表 + 基线行 + 行数校验 |
| 数据转换 | 无业务数据转换；`migrate.run()` 事务内插 `running`（`seq=2, version=1.10`），提交后置 `success` |
| 结构前后差异 | 17 张业务表零变化，`structure_hash` 相同；新增 `schema_migrations`（辅助表，不计入 `BASE_TABLES`）；`tasks` 原样 |
| 数据变化 | `schema_migrations` 1 行 → 2 行；所有业务表计数不变 |
| 不变项 | 节点身份/健康/评分/订阅、`settings`/`airports`/`nodes` 等全部行内容 |
| 成功判据 | 提交成功；success 行恰一条且 `current_version='1.10'`；无 running/failed；结构与计数不变 |
| 失败判据 | 事务内异常 → `ROLLBACK` 确认 → `failed` → `RECOVERY_REQUIRED`；回滚/复核不可确认 → halt 不写伪造行 |
| 重复执行判据 | 已成功后 `preflight` 返回 `version_mismatch`（期望 `1.8.7-baseline`，实际 `1.10`）⇒ 拒绝且不新增行 |

**代码现状说明**：`migrate.run()` 仍是 P-1.6 空迁移框架，`dry_run=False` 抛 `p17_required`，默认零 DDL。R1–R5 施工前必须由项目方确认本节，并在代码层补齐演练入口；本轮只定义，不改代码。

## 5. 其他旧定义清理

| 位置 | 处理 |
| --- | --- |
| 计划 §10 原停止点（P-1.1 前置审查 + P-7 批准） | 标记为"历史停止条件（P-1.1 阶段，仅存档）"，声明不适用于 P-1.8 |
| 计划 §10 当前停止点 | 补"第二轮修订后，等待复审；收到施工指令才施工" |
| 迁移窗口 ≤60s | 新增 §8.4：`T_mig` = 写封锁确认成功 → `run()` 返回 committed 且连接关闭确认；不含备份导出、人工清维护与重启。`T_block` 含人工与重启，仅记录，不参与判定 |
| `backend/config.py:25` | 登记："生产迁移窗口（P-1.8）才由运维显式置 1"待施工修正 |
| `backend/database/migrate.py:1204`、`:1207` | 登记："生产/开发主库要等 P-1.8"、"真实迁移在 P-1.7/P-1.8"待施工修正 |

## 6. 修改位置汇总

| 文件 | 位置 | 修改 |
| --- | --- | --- |
| 计划 v1.10 | §6 第 4、5 步 | 生产表述 → Docker 测试容器演练 |
| 同上 | §8 阶段表 P-1.8 行 | 验收补 R4-a…d、`T_mig` |
| 同上 | §8.2（新增） | 恢复路径设计、状态转换表、R4 验收 |
| 同上 | §8.3（新增） | 迁移内容与结构差异 |
| 同上 | §8.4（新增） | 计时口径 |
| 同上 | §10 | 历史停止条件、当前停止点、代码注释登记 |
| 同上 | §10 修订记录 | 第 21 次修订条目 |
| 设计 v1.10 | §12 | 补 R4 设计、迁移内容、计时口径 |
| 同上 | 结尾修订统计 | "二十一次修订" + 第 21 次说明 |
| 本记录 | 新文件 | 复审问题、前后对照、状态表、结构差异 |

## 7. 未改动项与边界

- 程序代码零改动（git status 干净）；未运行 pytest、Docker、迁移、NAS 操作。
- P-1.7 已验收实现（`a62aeb2`）及其交付材料未修改。
- 原有 INACTIVE 检查保留，仅新增恢复分支设计。
- 未新增任何未批准的业务数据迁移内容。

## 8. 交付与停止

| 项 | 值 |
| --- | --- |
| 文档仓库 | `laoXuHome/laoXuHome`，`main` |
| 文档提交 | 见本次交付回复中的 commit SHA |
| 代码提交 | 无（未改代码） |

**停止**：等待 ChatGPT 第二轮独立复审；复审通过并收到施工指令前，不进入 P-1.8 施工。
