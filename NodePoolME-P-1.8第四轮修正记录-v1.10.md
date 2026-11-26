# NodePoolME P-1.8 第四轮文档修正记录（v1.10）

- 日期：2026-11-26
- 依据：P-1.8 第四轮复审意见（四项逻辑缺陷）
- 范围：只修订总体设计 v1.10、P-1 实施计划 v1.10，新增本记录
- 未做：未改程序代码、未运行 pytest、未运行 Docker、未执行迁移、未连接 NAS、未接触生产库/容器
- 前置提交：第三轮 `36d2e8c6684f94263252ae0cafd7386cdd665578`（计划 94,510 B / 设计 209,891 B / 第三轮记录 9,036 B）

## 1. 修正项与前后对照

| # | 问题 | 修正前 | 修正后 | 位置 |
| --- | --- | --- | --- | --- |
| 1 | `COMMIT_ATTEMPTED` 被当作存在 `running` 行 | 旧文把该 phase 直接映射为“已插入 running、待收尾”；重启按 phase 推断 | 明确 phase 位于 `INSERT running` 与 `COMMIT` 之间，SIGKILL 后 DB 可能仅剩基线；重启**只读 DB**，按四类实际行集合判定 | 计划 §8.5.1、§8.5.3；设计 §12 |
| 2 | SIGKILL 与 `UNKNOWN` 混淆 | 旧 D1 写“halt 写 `UNKNOWN`”，未区分进程是否还能执行代码 | `UNKNOWN` 仅在进程存活、捕获异常且落盘回读成功时成立；SIGKILL 不执行 halt、不写 `UNKNOWN`；phase 落盘失败 fail-closed | 计划 §8.5.2；设计 §12 |
| 3 | R4-a 要求注入 DDL，与零 DDL 矛盾 | “注入 `ALTER`/非法语句”“DDL 阶段强杀” | R4-a 改为零 DDL 下真实的 `INSERT running` 失败（测试夹具触发器）；R4-b 改为 `TX_OPEN`/`COMMIT_ATTEMPTED` 两时点 SIGKILL；并声明夹具不被接受时的设计缺口 | 计划 §8.1、§8.2 R4-a/R4-b、§8.5.4、§8.5.5；设计 §12 |
| 4 | D2 锁协议缺路径/类型/生命周期/竞态 | 仅“锁空闲 + 维护文件存在 ⇒ 判中断” | 补全 `flock` 协议：路径、持有者、生命周期、原子判定、检查-启动竞态、SIGKILL 释放、残留文件、多实例、`ENOLCK` fail-closed | 计划 §8.5.6；设计 §12 |

## 2. 重启判定：phase 与真实 DB 解耦

事实顺序：`BEGIN IMMEDIATE` → 持久化 `TX_OPEN` → `INSERT running`（未提交）→ 持久化 `COMMIT_ATTEMPTED` → `COMMIT` → 第二事务置 `success`。

`COMMIT_ATTEMPTED` 与 `COMMIT` 之间被 SIGKILL 时，未提交事务由 SQLite 崩溃回滚，`running` 行不存在。因此：

| 实际 DB 行集合 | 对应 phase | 判定 |
| --- | --- | --- |
| 仅基线 | `PREPARED` / `TX_OPEN` / `COMMIT_ATTEMPTED` | `RECOVERY_REQUIRED`（`interrupted_before_tx` / `interrupted_in_tx` / `commit_not_applied_or_rolled_back`） |
| 基线 + `running` | `COMMIT_ATTEMPTED` | `RECOVERY_REQUIRED`（`committed_not_finalized`），禁止重跑 |
| 基线 + `success` | `COMMIT_ATTEMPTED` / `COMMITTED` | `RECOVERY_REQUIRED`（`success_pending_release`），人工确认后收尾 |
| 基线 + `failed` | `TX_OPEN` / `COMMIT_ATTEMPTED` / `TX_ROLLED_BACK` | `RECOVERY_REQUIRED`（`migration_failed`），走 `import --recover` |

任何“维护文件未释放”的情况均不自动开放写入；锁被持有一律拒绝启动。

## 3. R4-a 重新定义（零 DDL）

| 项 | 内容 |
| --- | --- |
| 注入点 | 迁移事务内 `INSERT INTO schema_migrations (… status='running')` |
| 手段 | 测试夹具触发器 `BEFORE INSERT … WHEN NEW.status='running' … RAISE(ABORT,'p18_injected_failure')`；非迁移内容、非业务 DDL、不进交付物 |
| 事务结果 | `BEGIN` 已成功；`INSERT` 抛 ABORT；`ROLLBACK` 确认；结构复核未变 |
| DB 实际记录 | 无 `running`；`failed` 行（`1.10`）；17 表计数不变 |
| 进入恢复态 | 维护文件仍在 + 锁空闲 + `failed` 行 ⇒ 重启判 `migration_failed` |
| 恢复 | `import --recover --file <迁移前 B 备份>` → 仅基线 success → `INACTIVE` → 计数回 B |
| 缺口 | 若夹具被拒，零 DDL 下无稳定“业务 DDL 失败”；ENOSPC 等环境故障常使 `failed` 行也不可写，只能覆盖 halt + 人工导入，须如实记为设计缺口 |

## 4. D2 锁协议摘要

| 项 | 结论 |
| --- | --- |
| 路径/类型 | `<STATE_DIR>/migration.lock`，`open(O_RDWR|O_CREAT,0600)` + `fcntl.flock(LOCK_EX|LOCK_NB)` |
| 持有者/生命周期 | 迁移执行进程；`BEGIN` 前获取，结束/halt/退出释放；启动分类持锁判定，`RECOVERY_REQUIRED` 持锁到退出，`INACTIVE` 释放后迁移入口重新获取并双检 |
| 原子判定/竞态 | 只认 `flock` 结果；禁止文件存在/PID/mtime；分类与启动同一持锁区间；第二实例拒绝启动 |
| SIGKILL/残留 | 内核自动释放；文件保留但无锁正常；永不删除/截断/重命名锁文件 |
| 多实例/不支持 | 仅一个成功，其余 `already_running`（退出码 2）；`ENOLCK`/`EOPNOTSUPP` ⇒ `migration_lock_unsupported` fail-closed |

## 5. 未解决问题

1. D1–D3 仍需 ChatGPT 明确批准；批准前 R3/R4-b 不得判通过。
2. R4-a 的测试夹具触发器是否被项目方接受，尚未确认；不接受则按设计缺口处理。
3. 迁移入口由谁写维护文件仍未在代码层落地（CLI `run` 不写，测试用 `_activate()`），施工时需明确编排。
4. 代码注释中仍有“P-1.8 生产迁移窗口”旧表述，留待施工修正（第三轮已登记）。

## 6. 本轮声明

本轮只做文档修订；无代码 diff、无测试输出、无 Docker 运行记录。完成后停止，等待 ChatGPT 第四轮独立复审，不进入 P-1.8 代码施工。
