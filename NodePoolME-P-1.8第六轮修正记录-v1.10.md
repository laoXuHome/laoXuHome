# NodePoolME P-1.8 第六轮文档修正记录（v1.10）

- 日期：2026-11-26
- 依据：P-1.8 第六轮复审意见（四项设计缺口）
- 范围：总体设计 v1.10、P-1 实施计划 v1.10，新增本记录
- 未做：未改代码、未运行 pytest、未运行 Docker/迁移、未连接 NAS、未操作生产库/容器
- 前置提交：第五轮 `d857bf141b47d53009046ba5ff50bf38e1dca554`

## 1. 修正项与前后对照

| # | 问题 | 修正前 | 修正后 | 位置 |
| --- | --- | --- | --- | --- |
| 1 | R4-a 缺少确定性同步屏障 | 只能“读到 phase 后强杀”，存在竞态 | 新增测试专用屏障：`TX_ROLLED_BACK` 落盘后写 reached 文件并等待 release；测试确认后 SIGKILL；60s 超时退出码 70；关闭时零 I/O、零等待 | 计划 §8.5.5；设计 §12 |
| 2 | 重启分类只有模糊“其他任意组合” | 兜底不完整 | 新增 F-1…F-6 明确兜底：未知 phase、phase/DB 不匹配、维护文件损坏/不可读/非法、DB 行集合非法、不可信探测、锁不可用 | 计划 §8.7.1；设计 §12 |
| 3 | 入口归属与维护责任未闭环 | 只写“由施工时确定” | 选择 B 不变；明确离线 CLI 方案、锁获取/复用/释放、PREPARED 写入者、成功/失败清理者、应用运行时 CLI 拒绝行为 | 计划 §8.6；设计 §12 |
| 4 | 启动顺序未闭环 | 维护判定与 `init_db` 边界不清 | 明确七步：取锁→校验维护→先封锁→只读探测→分类→仅 INACTIVE 才初始化/调度/业务监听；恢复判定不依赖 `init_db` | 计划 §8.7；设计 §12 |

## 2. R4-a 测试同步屏障

| 项 | 结论 |
| --- | --- |
| 位置 | `TX_ROLLED_BACK` 持久化成功后、T2 开始前 |
| 启用 | 同时满足 `NODEPOOL_TEST_MODE=1` 与 `NODEPOOL_TEST_BARRIER=r4a_after_tx_rolled_back`；只设 barrier 不设 test mode ⇒ `test_barrier_forbidden` |
| 到达 | 原子写 `<STATE_DIR>/p18-r4a.reached`（tmp→fsync→rename→目录 fsync），内容含 migration_id/phase/nonce/pid |
| 等待 | 轮询 `<STATE_DIR>/p18-r4a.release`，50ms；测试看到 reached 后可 SIGKILL |
| 超时 | 60s 无 release ⇒ `barrier_timeout`，退出码 70，不继续 T2 |
| 清理 | 每轮测试前后删除 reached/release；正式环境不创建 |
| 正式路径 | 仅一次环境变量判断；无文件 I/O、无 sleep，事务语义不变 |

强杀轮断言：维护 phase=`TX_ROLLED_BACK`；DB 仅基线；重启分类 `RECOVERY_REQUIRED`（`rolled_back_without_failed_row`）；B 备份 `import --recover` 后 `INACTIVE`。

## 3. 重启分类兜底

| 编号 | 条件 | 结果/码 |
| --- | --- | --- |
| F-1 | phase 不在已知集合（空值/拼写/类型错误） | `RECOVERY_REQUIRED` / `phase_unknown` |
| F-2 | 已知 phase 与 DB 行集合不构成合法配对 | `RECOVERY_REQUIRED` / `state_mismatch` |
| F-3 | 维护文件 CORRUPT/UNREADABLE/JSON 非法/字段缺失或类型错/严格布尔失败 | `RECOVERY_REQUIRED` / `maintenance_invalid` |
| F-4 | DB 行集合不属于 `{DB_ABSENT, 仅基线, 基线+running, 基线+success, 基线+failed}` | `RECOVERY_REQUIRED` / `db_rows_unexpected` |
| F-5 | 查询失败、表存在性/`migration_id/version/seq` 冲突、WAL 不可信、连接状态不一致 | `RECOVERY_REQUIRED` / `probe_unverifiable` |
| F-6 | `flock` 不可用（ENOLCK/EOPNOTSUPP） | 启动失败 / `migration_lock_unsupported` |

优先级：维护文件损坏/非法 → `maintenance=true`（`stale_maintenance`，一律恢复态）→ 合法配对表自上而下首条；异常直接转 `RECOVERY_REQUIRED`，不得落到 `INACTIVE`。

## 4. D2 入口闭环（选择 B）

P-1.8 不提供应用内迁移接口。迁移/导入均为停应用后 CLI 持锁执行。

| 动作 | 入口 | 锁 | 维护文件 |
| --- | --- | --- | --- |
| 应用启动 | `main.lifespan` 第一段 | 获取并持有至进程退出 | 不写 |
| 迁移 | `cli run --apply` → `_migration_session()` | 命令开始获取 | 写 `PREPARED`（`manual_migration`）并回读 |
| `migrate.run()` | 仅 CLI 调用 | 复用令牌，禁止二次 `flock` | 只改 phase，不建/删 |
| 导入 | `cli import --recover` | 命令开始获取 | 写 `manual_import` 并回读 |
| 应用运行时 CLI | 同上 | `EWOULDBLOCK` → `already_running`，退出码 2 | 不写、不执行 |
| 迁移成功 | CLI `_finish_migration_success()` | 命令结束释放 | 复核 DB → 删文件 → fsync → 回读 `INACTIVE` → `gate.release()` |
| 迁移失败 | CLI 不清理 | 进程退出释放 | 保持文件；重启判 `RECOVERY_REQUIRED` |
| 导入成功 | `_clear_maintenance_and_release()` | 命令结束释放 | 删文件 → 复核 → 解封 |
| 导入失败 | CLI 不清理 | 进程退出释放 | 保持文件；重启判 `RECOVERY_REQUIRED` |

固定序列：`run --apply` = 取锁 → 判 `INACTIVE` → 写 `PREPARED` 回读 → `gate.apply_state(ACTIVE)` + `pool.block_writes` + 确认 → `migrate.run(token)` → 成功清理/失败保持 → 释放锁退出。

## 5. D3 启动顺序

| 步 | 动作 |
| --- | --- |
| 1 | 获取进程生命周期锁（失败 `already_running`，退出码 2，不绑端口） |
| 2 | 严格读取/校验维护文件 |
| 3 | 无条件建立写封锁并确认 |
| 4 | 只读探测 `schema_migrations`（`mode=rw`+`query_only=1`，缺失记 `DB_ABSENT`） |
| 5 | phase+DB 分类（合法配对 + F-1…F-6） |
| 6 | 仅 `INACTIVE`：解封 → `init_db()` → 调度器/引擎 → 业务 HTTP 监听 |
| 7 | `RECOVERY_REQUIRED`：保持封锁，不 `init_db`、不启调度器、不启业务 HTTP；仅允许独立只读诊断监听 |

`init_db()`/`ensure_schema_table_transactional()`/`record_baseline()` 均不得出现在步骤 1–5。

## 6. 未解决问题

1. D1–D3 仍需 ChatGPT 明确批准；批准前 R3/R4-b 不得判通过。
2. R4-a 测试夹具触发器是否被接受尚未确认；不接受则按零 DDL 设计缺口处理。
3. `run --apply`、`instance_lock.py`、`bootstrap.py`、`_migration_session()` 均尚未实现（本轮禁止改代码），属 P-1.8 施工范围。

恢复态监听边界已定：只允许独立只读诊断监听（仅 `/healthz` 与迁移状态），不挂载业务写路由，不启动调度器，不调用 `init_db()`。

## 7. 本轮声明

本轮只做文档修订；无代码 diff、无测试输出、无 Docker 运行记录。完成后停止，等待第六轮独立复审，不进入 P-1.8 代码施工。
