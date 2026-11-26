# NodePoolME P-1.8 第五轮文档修正记录（v1.10）

- 日期：2026-11-26
- 依据：P-1.8 第五轮复审意见（三项）
- 范围：总体设计 v1.10、P-1 实施计划 v1.10，新增本记录
- 未做：未改代码、未运行 pytest、未运行 Docker、未执行迁移、未连接 NAS、未接触生产库/容器
- 前置提交：第四轮 `0b7c121c1be503aa9a9dda348af74234bee1477a`

## 1. 修正项与前后对照

| # | 问题 | 修正前 | 修正后 | 位置 |
| --- | --- | --- | --- | --- |
| 1 | R4-a 未覆盖 `TX_ROLLED_BACK` 落盘后、`failed` 行写入前的 SIGKILL | 只描述“回滚→写 failed→恢复”，隐含 failed 一定可写 | 明确 T1/T2 独立连接与事务边界；新增崩溃窗口表：`TX_ROLLED_BACK`+仅基线 → `RECOVERY_REQUIRED`；T2 失败保持封锁；未定义组合统一保守判定 | 计划 §8.5.3、§8.5.5、§7 F3/F4；设计 §12 |
| 2 | D2 采用“启动分类后释放、迁移入口再获取”，不能保证进程单实例 | A/B 未定；释放后存在第二实例窗口 | 明确选择 **B**：同一 `STATE_DIR` 只允许一个应用实例；锁由启动持有到进程退出，迁移复用同一 fd 令牌不得二次 `flock`，补 FD 继承防护与第二实例退出码 | 计划 §8.5.6；设计 §12 D2 |
| 3 | R4-a 两个事务的失败路径未拆开 | 只写“第二事务写 failed” | 分别定义 T1（迁移连接、`BEGIN`→`INSERT`→`ROLLBACK`→复核→关闭）与 T2（新连接、独立 `BEGIN`→`UPDATE`/`INSERT`→`COMMIT`）；明确 `TX_ROLLED_BACK` 落盘时点及 T2 成功/失败/SIGKILL 的 DB 状态 | 计划 §8.5.5；设计 §12 |

## 2. R4-a 事务与崩溃窗口

| 事务 | 连接 | 边界 |
| --- | --- | --- |
| T1 | 迁移入口 `open_connection(target)` | `BEGIN IMMEDIATE` → `INSERT running`（夹具 ABORT）→ 异常 → `ROLLBACK` → 独立只读复核 → 关闭连接 |
| T2 | `_mark_failed()` 新开连接 | `BEGIN IMMEDIATE` → `UPDATE running→failed`（0 行）→ `INSERT failed(seq=2,1.10)` → `COMMIT` → `close` |

`TX_ROLLED_BACK` 在 T1 回滚确认、结构复核未变、迁移连接关闭后落盘；成功后才进入 T2。

| 中断点 | phase | DB 实际 | 判定 |
| --- | --- | --- | --- |
| 回滚后、`TX_ROLLED_BACK` 落盘前 SIGKILL | `TX_OPEN` | 仅基线 | `RECOVERY_REQUIRED`（`interrupted_in_tx`） |
| `TX_ROLLED_BACK` 落盘后、T2 `BEGIN` 前 SIGKILL | `TX_ROLLED_BACK` | 仅基线 | `RECOVERY_REQUIRED`（`rolled_back_without_failed_row`） |
| T2 `BEGIN` 后、`COMMIT` 前 SIGKILL | `TX_ROLLED_BACK` | 仅基线 | 同上 |
| T2 `COMMIT` 成功后退出/SIGKILL | `TX_ROLLED_BACK` | 基线 + `failed` | `RECOVERY_REQUIRED`（`migration_failed`） |
| T2 写失败（进程存活） | `TX_ROLLED_BACK` | 仅基线 | `halt(failed_row_unwritable)`，重启同上 |
| `TX_ROLLED_BACK` 落盘失败 | 保持 `TX_OPEN` | 仅基线 | `RECOVERY_REQUIRED`（`interrupted_in_tx`） |

所有未列入的组合统一 `RECOVERY_REQUIRED`（`unclassified_state`），不自动解封；恢复只用迁移前 B 备份 `import --recover`。

## 3. D2 选择 B 的理由与协议

选择 B（同一 `STATE_DIR` 单应用实例）：

1. 部署为单容器单 `uvicorn` 进程，未启用 `--workers`；调度器、维护态与写封锁均在进程内。
2. `maintenance.json`/锁/故障日志以 `STATE_DIR` 为唯一事实源；多实例会破坏维护态与 `K1_β` 的单实例前提。
3. SQLite 单写者不适合多实例并发写同一库。

| 项 | 结论 |
| --- | --- |
| 获取/生命周期 | 启动引导、早于 `init_db()` 与端口监听；持有到进程退出；正常关闭 `LOCK_UN`+`close` |
| 迁移复用 | `InstanceLock` 单例保存 fd；`migrate.run()` 校验令牌，不得二次 `flock`（同进程新 fd 会与自身冲突） |
| 第二实例 | `EWOULDBLOCK` ⇒ `already_running`，退出码 2，不绑定端口、不初始化 DB |
| 独立 CLI | `run`/`import` 自行获取；应用运行中则拒绝，必须先停应用 |
| SIGKILL/残留 | 内核释放；锁文件保留无锁属正常；永不删除/截断/重命名 |
| FD 继承 | `O_CLOEXEC`；`subprocess close_fds=True`；`fork` 子进程立即 `close(fd)` 或改用 `spawn` |
| 不支持 | `ENOLCK`/`EOPNOTSUPP` ⇒ `migration_lock_unsupported`，fail-closed |

## 4. 未解决问题

1. D1–D3 仍待 ChatGPT 明确批准；批准前 R3/R4-b 不得判通过。
2. R4-a 触发器夹具是否被接受仍未确认；不接受则按设计缺口处理（零 DDL 下无稳定业务失败场景）。
3. 选择 B 后，迁移/导入入口归属（应用进程内执行，或停应用后由 CLI 持锁执行）尚未在代码层落地，施工前须明确，否则 B 与现有 CLI 调用方式冲突。
4. 迁移前谁写维护文件仍未在代码层定义（CLI `run` 不写，测试用 `_activate()`）。
5. 代码注释中的“P-1.8 生产迁移窗口”旧表述留待施工修正。

## 5. 本轮声明

本轮只做文档修订；无代码 diff、无测试输出、无 Docker 运行记录。完成后停止，等待第五轮独立复审，不进入 P-1.8 代码施工。
