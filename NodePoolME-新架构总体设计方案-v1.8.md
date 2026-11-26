# NodePoolME 新架构总体设计方案 v1.8

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.7
**本轮性质**：纯设计修订。**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据。**
**本轮范围**：五项——迁移伪代码控制流、C12–C16 全阶段捕获与恢复连接顺序、R10 拆分、文件级备份顺序与 checkpoint 判定、测试夹具真实 DDL 与审计异常语义。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 修订索引（v1.7 → v1.8）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | 迁移改为显式阶段状态机；`except Exception: pass` 删除；COMMIT 结果不确定有专门判定 | §3.1–§3.3 | 重写 |
| P0-2 | C12–C16 全部纳入统一捕获；C15/C16 失败安全处理；恢复连接关闭顺序 | §3.4–§3.5 | 补齐 |
| P0-3 | R10 拆为 R10-A（底层反证）/ R10-B（业务入口） | §5.1 | 修正 |
| P1-1 | 文件级备份 9 步严格顺序；`wal_checkpoint` 返回值语义 | §2.3 | 修正 |
| P1-2 | 四张夹具表冻结 DDL + 可执行 INSERT；审计改用裸 `raise` 重抛 + 事件分型 | §5.2–§5.3 | 补齐 |

未修订：Q1–Q12、六个关系触发器判定逻辑（v1.7 已扩 `fingerprint`）、`trg_nodes_delete_guard`、"A 路径部分完整性、不等价 B"、C12 未确认且默认 A、C-2 入向检查与"任何入向即停"、17 步主序号、`valid=0` 隔离、30 天 missing、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式兼容、评分算法、前端布局。**C11–C20 全部未确认。**

---

## 0. 本轮修的是什么

| # | v1.7 的写法 | 缺陷 |
| --- | --- | --- |
| P0-1 | `except Exception: pass` 落到阶段 C | 预提交失败被吞，可能"回滚了却继续走 COMMIT 后流程" |
| P0-2 | `try` 只包住 C12–C14 | C15 写 success、C16 开放写入若失败，无捕获、无安全处理 |
| P0-3 | R10 只写 `recursive_triggers=OFF` 却期望 REPLACE 成功 | 缺 `foreign_keys=OFF` 条件，实测会被真外键拦 |
| P1-1 | C-1..C-6 是"条件清单"，不是"执行顺序"；`(0,N,N)` 被当固定格式 | 无法逐步执行；checkpoint 语义不清 |
| P1-2 | 夹具写"字段名以最终 DDL 为准"；审计伪代码 `raise IdentityConflict(e)` 无定义 | 不可执行；异常构造方式不成立 |

v1.8 的五句话：**迁移要有状态机，不要靠 catch；success 也在捕获范围内；底层破坏实验与业务入口必须分开测；checkpoint 要看 WAL 是否真为 0；夹具字段必须能直接跑。**

---

## 1. 保留的既定设计（摘要）

Q1–Q12 保留；指纹算法不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康 24h/72h；30 个版本；Q11 两次有效 Mihomo 成功间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式兼容；评分算法；前端布局不重做。

A 路径：不重建 `nodes`，7 个触发器，部分引用完整性，不等价 B；B 需 C12（**未确认**）。

v1.6/v1.7 已定稿、本轮不改：`node_identities`/`node_config_versions` DDL、六个关系触发器（含 v1.7 的 `fingerprint` 扩列与等值条件）、`trg_nodes_delete_guard`、`nodes` 禁 UPSERT 与 `upsert_node_identity_aware`、配置升级原子流程、连接五类型与 `write_guard`、C-2 判定、`valid=0` 隔离、17 步主序号。

---

## 2. P1-1：文件级备份的执行顺序与 checkpoint 判定

### 2.1 备份策略不变

**首选**：`sqlite3` Backup API（在线一致性快照）→ 次选 `VACUUM INTO` → 最后才是文件级复制。前两者**不需要**下面的 9 步，只需在 A1–A4（停写排空）完成后调用。

```sql
-- 可执行 SQL（事务外、停写后）
VACUUM INTO '/backup/nodepool-20261126T120000Z.db';
```

### 2.2 文件级备份：9 步严格顺序（可执行）

| 步 | 动作 | 通过条件 | 不通过 |
| --- | --- | --- | --- |
| F1 | 关闭**所有**原数据库连接（应用池、后台、CLI、迁移前置探测） | 连接对象全部 `closed`；池标记 `dead` | 中止 |
| F2 | 打开**专用 checkpoint 连接**（不与任何业务连接共用） | 连接可执行 PRAGMA | 中止 |
| F3 | `PRAGMA wal_checkpoint(TRUNCATE)` | 见 §2.3 判定 | 中止 |
| F4 | 读取 checkpoint 结果并判定 busy / 完成情况 | `busy=0` 且 WAL 已截断 | 中止（说明仍有读者/写者） |
| F5 | 关闭 checkpoint 连接 | `closed` | 中止 |
| F6 | 确认 WAL 文件为零字节 | 文件大小 == 0（或文件不存在） | 中止 |
| F7 | 确认不存在未完成的 rollback journal | 无 `-journal` 文件；或存在但 `hot` 头已清零（视为无效残留，记录后继续） | 中止 |
| F8 | **只复制主数据库文件**（不带 `-wal`/`-shm`） | 复制完成，大小 == 源文件 | 中止 |
| F9 | 打开副本：`quick_check`、Schema 基线、行数基线、SHA256 | 全过 | 删除副本，中止 |

**为什么必须"先 F5 关连接，再 F6 判 WAL 为 0"**：v1.7 把"所有连接已关闭"与"checkpoint 连接仍打开"放在同一句里，是自相矛盾的表述。正确顺序是 checkpoint 由专用连接完成并**关闭**之后，才对文件系统做零字节判定与复制。

### 2.3 `PRAGMA wal_checkpoint` 返回值的真实语义

返回三列 `(busy, log, checkpointed)`：

| 列 | 含义 |
| --- | --- |
| `busy` | `1` 表示有其它连接/读者阻塞，checkpoint 未能完成全部帧；`0` 表示未被阻塞 |
| `log` | WAL 中当前的帧数（checkpoint 前的日志量） |
| `checkpointed` | 已回写主库的帧数 |

**不能把 `(0,N,N)` 当作"通用固定格式"**：`N` 的取值随数据量变化，两列相等只表示"日志帧全部已回写"，不表示"WAL 文件已清空"。`TRUNCATE` 模式在全部帧回写后会把 WAL 截断到 0 字节，**但前提是没有其他连接持有读标记**。

**因此判定条件是两条并列，缺一不可**：

1. `busy == 0`（无阻塞）；
2. WAL 文件大小为 **0 字节**（截断已实际生效）。

只有这两条同时成立，才能认为"主库文件即完整状态"。任一不成立 → 回退到 Backup API，不得继续文件级方案。

### 2.4 测试（RB 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| RB1 | 一个只读连接持有快照（阻塞 checkpoint） | 走 F1–F6 | `busy=1` 或 WAL 非 0 → **中止**，不复制 |
| RB2 | 正常停写 | 走 F1–F9 | `busy=0`、WAL=0、副本 `quick_check=ok`、sha256 与行数基线一致 |
| RB3 | 存在 `-journal` 残留 | 走 F7 | 有效残留 → 中止；无效残留（hot 头清零）→ 记录后继续 |
| RB4 | 走 Backup API 备份 | 对比 RB2 | 无需 F2–F8；副本一致性与 RB2 等价 |

---

## 3. P0-1 / P0-2：迁移控制流与全阶段捕获

### 3.1 阶段状态机（唯一的状态来源）

```python
class Phase(Enum):
    PREPARED         = 1   # 阶段 A 全部完成，尚未 BEGIN
    TX_OPEN          = 2   # BEGIN 成功，事务进行中
    TX_ROLLED_BACK   = 3   # ROLLBACK 成功，库回到迁移前
    COMMIT_ATTEMPTED = 4   # 已发出 COMMIT，结果未知
    COMMITTED        = 5   # 已证明提交成功（token 已落库）
    UNKNOWN          = 6   # 结果无法判定（COMMIT 异常 / ROLLBACK 失败）
```

**规则**：迁移流程的每一步分支**只看 `phase`**，不看异常类型、也不靠 `except` 兜底。任何分支改变 `phase` 时必须同时写一条 `system_events`（便于事后复盘）。

| phase | 允许的下一步 | 禁止 |
| --- | --- | --- |
| PREPARED | BEGIN | 直接进阶段 C |
| TX_OPEN | COMMIT / ROLLBACK | 进阶段 C |
| TX_ROLLED_BACK | 终止（非零退出） | 进阶段 C |
| COMMIT_ATTEMPTED | 用 token 判定 → COMMITTED 或 TX_ROLLED_BACK 或 UNKNOWN | 假定已提交 |
| COMMITTED | 阶段 C（C12–C16） | — |
| UNKNOWN | `handle_post_commit_failure`（保守恢复） | 开放写入、写 success |

### 3.2 COMMIT 结果判定机制（token）

**问题**：`COMMIT` 抛异常时，可能"其实已提交"（例如提交后 IO 报错），也可能"未提交且事务仍活动"。凭 `conn.in_transaction` 也不够可靠（连接可能已失效）。

**机制**：在 `COMMIT` 之前的**最后一条语句**写入提交凭据。

```sql
-- 在事务内最后执行（可执行 SQL）
INSERT INTO schema_migrations (migration_id, result, token, started_at)
VALUES (:mid, 'pending', :token, :ts);
```

`token` 为本次迁移生成的唯一随机串（如 16 字节 hex），与 `mid` 联合唯一。

**判定**（用**新连接**只读查询，不复用迁移连接）：

| 查询结果 | 判定 | 处理 |
| --- | --- | --- |
| 存在 `(mid, token, 'pending')` | **已提交**（COMMIT 生效） | `phase=COMMITTED`，进入阶段 C |
| 不存在该行，且迁移对象均不存在 | **未提交**（事务已回滚或从未生效） | `phase=TX_ROLLED_BACK`，按预提交失败终止 |
| 不存在该行，但迁移对象存在 | **UNKNOWN** | `handle_post_commit_failure`（保守恢复） |
| 无法连接 / 查询失败 | **UNKNOWN** | 同上；写入保持关闭 |

### 3.3 完整伪代码（标注：伪代码；与 §3.1/§3.2/§3.4 逐条对齐）

```python
# 伪代码：结构示意，非最终实现
def migrate(db_path):
    phase = Phase.PREPARED
    backup = None
    conn = None
    token = make_token()

    # ===== 阶段 A =====
    try:
        enter_maintenance()                       # A1
        stop_background_writers()                 # A2
        drain_and_close_write_connections()       # A3
        require_no_active_writers()               # A4（D1/D2/D3）
        backup = consistent_backup(db_path)       # 首选 Backup API / VACUUM INTO
        verify_backup(backup)                     # 可开 + quick_check + 行数 + schema + sha256
        conn = open_migration_conn(db_path)       # A7：两 PRAGMA 读回
    except Exception as e:
        abort_before_tx(e)                        # 不建事务、库不变、非零退出
        raise MigrationTerminated("phase_a")      # 终止语义，不返回继续

    try:
        if c2_needs_fk_off(conn):
            conn.execute("PRAGMA foreign_keys=OFF")           # 事务外
        conn.execute("BEGIN IMMEDIATE")
        phase = Phase.TX_OPEN

        apply_ddl(conn)                           # B7
        backfill(conn)                            # B8
        assert_relations(conn)                    # B9
        if conn.execute("PRAGMA foreign_key_check").fetchall():
            raise PreCommitCheckFailed("fk_check")            # B10
        assert_counts_and_triggers(conn)          # B11
        conn.execute("INSERT INTO schema_migrations(migration_id,result,token,started_at) "
                     "VALUES (?, 'pending', ?, ?)", (MID, token, now()))   # 凭据
        phase = Phase.COMMIT_ATTEMPTED
        try:
            conn.execute("COMMIT")
            phase = Phase.COMMITTED               # 先置，稍后由 token 复核
        except Exception as ce:
            phase = Phase.UNKNOWN                 # 不假定结果
            raise CommitOutcomeUnknown(ce)

    except Exception as e:
        if phase is Phase.TX_OPEN:                # 预提交失败：能回滚
            try:
                conn.execute("ROLLBACK")
                phase = Phase.TX_ROLLED_BACK
            except Exception as rb:
                phase = Phase.UNKNOWN             # ROLLBACK 也失败
                record_event("rollback_failed", e, rb)
                safe_fault(e, rb)                 # 写入保持关闭，非零退出
                raise MigrationTerminated("rollback_failed")
            rollback_tx(e)                        # 记事件
            raise MigrationTerminated("pre_commit")   # 明确终止，绝不进阶段 C

        if phase in (Phase.COMMIT_ATTEMPTED, Phase.UNKNOWN):
            outcome = resolve_commit(db_path, MID, token)   # 新连接只读查询
            if outcome == "committed":
                phase = Phase.COMMITTED
            elif outcome == "rolled_back":
                phase = Phase.TX_ROLLED_BACK
                rollback_tx(e)
                raise MigrationTerminated("commit_not_effective")
            else:                                  # unknown
                phase = Phase.UNKNOWN
                handle_post_commit_failure(db_path, backup, e)
                raise MigrationTerminated("commit_unknown")

    # ===== 阶段 C：C12–C16 全部在捕获边界内 =====
    try:
        restore_fk_readback(conn)                 # C12：事务外 ON + 读回 == 1
        check_fk(conn)                            # C13：foreign_key_check 必须 0 行
        assert_all(conn)                          # C14：关系/行数/触发器/映射
        mark_success(conn, MID, token)            # C15：pending → success，rowcount 必须 1
        enable_business_writes()                  # C16
        verify_writes_open()                      # C16 校验：maintenance 已关、写入可用
    except Exception as e:
        handle_post_commit_failure(db_path, backup, e)   # 唯一退出点，内部不返回

    record_event("migration_success", MID)
```

**关键约束**

| # | 约束 |
| --- | --- |
| 1 | 不存在 `except Exception: pass`；所有捕获都必须改变 `phase` 或进入明确处理函数 |
| 2 | `rollback_tx()` 与 `abort_before_tx()` 都通过 `raise MigrationTerminated` 终止，**不允许返回后继续执行** |
| 3 | 顶层 `main()` 捕获 `MigrationTerminated` → 清理 → 非零退出；这是唯一允许 `sys.exit` 的位置 |
| 4 | `sys.exit` 不得出现在 `abort_before_tx` / `rollback_tx` / `handle_post_commit_failure` 内部（否则绕过清理） |
| 5 | 阶段 C 的 `try` 必须**覆盖 C12 到 C16 全部五步**，不得只包 C12–C14 |

### 3.4 C15 / C16 的失败处理（P0-2）

| 失败点 | 判定 | 处理 |
| --- | --- | --- |
| C15 写 success 失败（`UPDATE ... SET result='success'` 抛错或 `rowcount != 1`） | 迁移事实已提交，但无成功标记 | `handle_post_commit_failure`：**恢复备份**（备份里没有本次迁移的任何记录，天然无 success）；`system_events(migration_rollback, reason='success_write_failed')` |
| C15 成功、C16 开放写入失败 | 库已是迁移后状态且有 success | 先 `enter_maintenance()` **重新封闭**，再 `handle_post_commit_failure` → 恢复备份 → 恢复后 `schema_migrations` 不含本次 success（备份即迁移前状态），断言 `COUNT(result='success' AND migration_id=:mid) == 0` |
| C16 成功但 `verify_writes_open()` 失败 | 同上（自相矛盾状态） | 同上，按"未确认开放"处理 |
| 恢复流程中断（备份不可用） | — | `abort_recovery()`：保持 maintenance、非零退出（码 4）、事件 `migration_recovery_failed`、**不尝试边修边跑** |

**"C15 已成功但 C16 失败，恢复后不得保留 success" 的实现方式**：不靠删除行（那是"掩盖"，且可能被并发读到），而是**用备份替换整个库**——备份是迁移前快照，天然不含 success；恢复后第 7 步比对时**必须显式断言**该 mid 的 success 计数为 0。

### 3.5 恢复期的连接关闭顺序（P0-2 特别要求）

| 序 | 动作 | 说明 |
| --- | --- | --- |
| R1 | 关闭**所有**原有连接：迁移连接、应用池全部句柄、后台任务连接、CLI 连接；池标记 `dead` 且禁止再 checkout | 旧句柄会持有旧 inode，替换文件后仍能读写旧库 |
| R2 | 创建**专用探测连接**（不与池共用、不缓存） | 仅用于 D3 |
| R3 | 在探测连接上 `BEGIN IMMEDIATE` → `ROLLBACK` | 拿到写锁说明当前无写者 |
| R4 | 关闭探测连接 | 不留下持锁句柄 |
| R5 | **再次**确认无活动连接、无活动事务（连接对象清点 + 池计数 + 文件句柄清点） | 与 R1 不同：R5 是"关闭之后"的复核 |
| R6 | 全部通过才允许替换数据库文件 | 任一步不过 → `abort_recovery` |

**D3 的定位必须写清**：`BEGIN IMMEDIATE` 只是一次**瞬时**写锁探测，只证明"此刻没有活跃写者"，**不等于对未来写入的永久封锁**。真正的封锁靠：

| 封锁通道 | 手段 |
| --- | --- |
| 应用进程 | `maintenance` 开关（存 DB 的 `settings`/状态表）+ 写入入口前置检查 → 503 |
| 后台任务 | 任务状态机 `stopped`；轮询任务在每轮开始检查 maintenance |
| 连接池 | 池 `dead`，`checkout` 直接抛 `PoolClosed` |
| CLI | 写命令要求 `--allow-write` 且先读 maintenance，为开则拒绝 |
| 新增进程（漏网） | 写前 `write_guard()` 读 maintenance 标志 + 两 PRAGMA；仍写则被触发器与外键拦，且事件可观测 |

**因此**：D3 是"清点过去"，maintenance 是"封住未来"，两者都不够时由库层约束兜底——三者缺一不可。

### 3.6 测试（MC / CR 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC1 | 阶段 B | DDL 执行失败 | `ROLLBACK` → `phase=TX_ROLLED_BACK` → 非零退出；**未进入阶段 C**；无 success |
| MC2 | 阶段 B | 回填失败 | 同上；库行数/触发器/映射等于基线 |
| MC3 | 阶段 B | 预提交 `foreign_key_check` 返回 1 行 | `ROLLBACK` → 终止；无 success；库回基线 |
| MC4 | 阶段 B | `ROLLBACK` 自身失败 | `phase=UNKNOWN` → 安全故障处理；写入保持关闭；非零退出 |
| MC5 | COMMIT 抛异常且事务仍活动 | — | `resolve_commit`：无 token 行且无迁移对象 → `TX_ROLLED_BACK`，按预提交失败终止；**不得**判为已提交 |
| MC6 | COMMIT 结果无法判定（模拟查询失败） | — | `phase=UNKNOWN` → `handle_post_commit_failure`；保持 maintenance；不写 success；不开放写入 |
| MC7 | COMMIT 成功 | token 行存在 | `phase=COMMITTED` → 进入阶段 C |
| MC8 | 阶段 A 任一步失败 | — | `abort_before_tx`；不建事务；未生成 success |
| CR1 | C15 写 success 失败 | — | 走恢复；恢复后该 mid 的 success 计数 == 0；写入仍关闭 |
| CR2 | C15 成功、C16 失败 | — | 先回 maintenance，再恢复备份；success 计数 == 0 |
| CR3 | C16 成功但 `verify_writes_open` 失败 | — | 同上 |
| CR4 | 恢复前有一条旧连接未关 | — | R1/R5 检出 → 拒绝替换文件（`abort_recovery`，退出码 4） |
| CR5 | 探测连接未关闭 | — | R4 检出 → 拒绝替换 |

---

## 4. 阶段划分复核（本轮要求交付第 5 项的一部分）

| 阶段 | 包含步骤 | 失败处理函数 | 是否可回滚 |
| --- | --- | --- | --- |
| A | A1–A7 | `abort_before_tx` | 未开事务，无需回滚 |
| B | B6–B11（含预提交 check 与凭据写入） | `rollback_tx` | **可以**（`ROLLBACK`） |
| B→C 边界 | `COMMIT` 与结果判定 | `resolve_commit` | 视判定：未生效按 B；未知按 C |
| C | C12–C16 | `handle_post_commit_failure` | **不可以**，只能备份恢复 |

---

## 5. P0-3 / P1-2：测试用例与夹具

### 5.1 R10 拆分（P0-3）

| 用例 | PRAGMA | 路径 | 子表状态 | 预期 | 用途 |
| --- | --- | --- | --- | --- | --- |
| **R10-A** | `recursive_triggers=OFF` **且** `foreign_keys=OFF` | **直接执行 SQL**（绕过业务入口） | 四张子表各有真实 `node_id` 关联 | `INSERT OR REPLACE` **成功**；原 `nodes.id` 被替换（新 id）；子表 `node_id` 指向已不存在的节点（悬空） | 证明"触发器本身不能独立承担全部保护" |
| **R10-B1** | `recursive_triggers=OFF`、`foreign_keys=ON` | 正式业务入口 | 同上 | `write_guard` **在执行 SQL 前**抛 `ConnectionContractViolation`；节点与子表全部不变 | 证明入口契约有效 |
| **R10-B2** | `recursive_triggers=ON`、`foreign_keys=OFF` | 正式业务入口 | 同上 | 同上（两条件任一不满足即拒绝） | 同上 |

**v1.7 的错误**：R10 只关 `recursive_triggers`、保留 `foreign_keys=ON`，实测 REPLACE 会被子表的真外键拦（`FOREIGN KEY constraint failed`），根本走不到"悬空"结果——预期与条件不匹配。拆分后 A 组同时关两个开关，才能复现破坏；B 组则验证"这种连接根本进不了业务入口"。

**R10-B 的判定顺序必须写死**：`write_guard()` → 读 maintenance → 读两 PRAGMA → 任一不满足 → 抛错，**在构造 SQL 之前**。不允许"先执行、失败后回滚"，也不允许"自动 `SET ON` 后继续"。

### 5.2 四张夹具表：冻结 DDL（P1-2 A）

以下是本轮冻结的 P0 夹具列（与设计 DDL 一致；`nodes` 的复合外键父键为 `(id, identity_id)`，故子表带 `identity_id`）：

```sql
-- 可执行 DDL（P0 夹具口径；其余列必须可空或有默认，属 P0 验收项）
CREATE TABLE node_state_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id     INTEGER NOT NULL,
  identity_id INTEGER NOT NULL,
  target      TEXT,                    -- NULL = 节点级状态
  from_state  TEXT,
  to_state    TEXT NOT NULL,
  reason      TEXT,
  at          TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);

CREATE TABLE target_results (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id        INTEGER NOT NULL,
  identity_id    INTEGER NOT NULL,
  task_id        INTEGER,
  target         TEXT NOT NULL,
  mode           TEXT NOT NULL CHECK (mode IN ('mihomo','tcp_only')),
  valid          INTEGER NOT NULL CHECK (valid IN (0,1)),
  failure_source TEXT,
  config_version INTEGER,
  rule_version   INTEGER,
  latency_ms     INTEGER,
  message        TEXT,
  ts             TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id),
  CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))
);

CREATE TABLE detection_tasks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id     INTEGER NOT NULL,
  identity_id INTEGER NOT NULL,
  target      TEXT NOT NULL,
  rule_version INTEGER NOT NULL,
  state       TEXT NOT NULL DEFAULT 'pending',
  created_at  TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);

CREATE TABLE node_id_reservations (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id     INTEGER NOT NULL,
  identity_id INTEGER NOT NULL,
  token       TEXT NOT NULL,
  reserved_at TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  released_at TEXT,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);
```

**可执行 INSERT（每表一条真实关联）**

```sql
INSERT INTO node_state_history (node_id, identity_id, target, from_state, to_state, reason, at)
VALUES (:nid, :iid, NULL, 'unknown', 'available', 'probe', :t0);

INSERT INTO target_results (node_id, identity_id, task_id, target, mode, valid, failure_source, config_version, rule_version, latency_ms, message, ts)
VALUES (:nid, :iid, NULL, 'chatgpt', 'mihomo', 1, NULL, :cv, 1, 180, 'ok', :t0);

INSERT INTO detection_tasks (node_id, identity_id, target, rule_version, state, created_at)
VALUES (:nid, :iid, 'chatgpt', 1, 'pending', :t0);

INSERT INTO node_id_reservations (node_id, identity_id, token, reserved_at, expires_at, released_at)
VALUES (:nid, :iid, 'tok-fixture-1', :t0, :t0, NULL);
```

**四张表均支持 `node_id` 关联**（都是 `nodes(id, identity_id)` 的子表），不存在"某表不支持关联"的情形，无需调整测试对象。

**快照比较方式（操作前后各取一次）**

```sql
-- 行数与关联集合
SELECT 'nsh', COUNT(*) FROM node_state_history;
SELECT 'tr',  COUNT(*) FROM target_results;
SELECT 'dt',  COUNT(*) FROM detection_tasks;
SELECT 'nres',COUNT(*) FROM node_id_reservations;
SELECT group_concat(node_id) FROM node_state_history ORDER BY node_id;
-- 内容快照（用于逐字节比对）
SELECT * FROM node_state_history ORDER BY id;
SELECT * FROM target_results      ORDER BY id;
```

| 比对项 | 判定 |
| --- | --- |
| 四表行数 | 与操作前相等 |
| 四表 `node_id` 集合 | 与操作前集合相等 |
| 四表内容快照（含 `id`、`ts/at`） | 逐行相等 |
| `nodes` 行 | 原 `id` 仍在；`identity_id`、`config_version`、`fingerprint`、`created_at`、`status`、`fail_count` 全部等于快照 |
| 全库 | `nodes` 总数不变；触发器数量与名称集合不变 |

### 5.3 IdentityConflict / ConfigVersionConflict 的审计语义（P1-2 B）

| 冲突类型 | 是否记审计 | 事件类型 | `reason` |
| --- | --- | --- | --- |
| C3 身份冲突 | **是** | `identity_conflict` | `identity_mismatch` |
| C4 版本冲突 | **是** | `config_version_conflict` | `config_version_mismatch` |
| 指纹被占用（配置升级） | **是** | `fingerprint_conflict` | `fingerprint_taken` |

**伪代码（修正重抛方式，标注：伪代码）**

```python
# 伪代码
try:
    with immediate_tx(conn):                    # 节点写入事务（业务连接）
        ...                                     # 检测冲突 → 抛 IdentityConflict / ConfigVersionConflict
except (IdentityConflict, ConfigVersionConflict) as e:
    # 1) 先确保写事务已结束（with 块异常退出时 sqlite 连接层需显式 ROLLBACK）
    ensure_tx_closed(conn)
    # 2) 独立连接、独立事务写审计
    try:
        with immediate_tx(audit_conn):
            audit_conn.execute(
                "INSERT INTO system_events(event, reason, node_id, airport_id, fingerprint, detail_json, ts) "
                "VALUES (?,?,?,?,?,?,?)",
                (e.event_type, e.reason, e.node_id, e.airport_id, e.fingerprint, e.detail_json, now()))
    except Exception as audit_err:
        log_error("audit_write_failed", audit_err)     # 只影响审计，不影响主结果
    # 3) 重新抛出原始异常（裸 raise，保留 traceback 与异常实例）
    raise
```

**必须修正的两点**

1. v1.7 的 `raise IdentityConflict(e)` 是**用异常实例构造异常**，语义不成立（`e` 不是构造参数）；正确做法是裸 `raise` 重抛，或用 `raise IdentityConflict(...) from e` 显式链式构造。本设计采用裸 `raise`。
2. 审计写入不得与被回滚的写事务共用连接或事务；`ensure_tx_closed(conn)` 必须在审计之前执行。

**审计失败的语义边界**

| 情形 | 节点写入结果 | 审计 | 日志 |
| --- | --- | --- | --- |
| 审计成功 | 拒绝（异常外抛） | 有事件 | — |
| 审计失败（连接错/约束错） | **仍然拒绝**（结果不变） | 无事件 | `audit_write_failed` |
| 审计失败后重试同一写入 | 仍拒绝 | 仍无事件（继续记日志） | 需要人工检查 `system_events` 缺失 |

**绝不允许**：因为审计写不进去就放行冲突写入，或把异常吞掉返回"成功"。

### 5.4 测试（FX / AU / R 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| FX1 | 四表 DDL 建好 | 执行 §5.2 四条 INSERT | 全部 OK；每表 1 行；`node_id` 均指向被测节点 |
| FX2 | 迁移后（含复合外键） | 同上四条 INSERT | 全部 OK（父键 `(id, identity_id)` 存在） |
| FX3 | 回填前（`identity_id` 为空） | 同上 | 插入失败（复合外键/NOT NULL）——夹具必须施加于回填后 |
| R2 | 节点 + 四表各 1 行 | `INSERT OR REPLACE` | `ABORT`；六类比对全等 |
| R3 | 同上 | `REPLACE INTO nodes (id, airport_id, fingerprint, identity_id, config_version, status, fail_count) VALUES (:nid, 1, 'F2', :iid, 1, 'unknown', 0)` | `ABORT`；六类比对全等 |
| R10-A | 同上 | `rt=OFF` + `fk=OFF`，直接 SQL REPLACE | **成功**；`nodes.id` 变；四表 `node_id` 悬空 |
| R10-B1 | 同上 | `rt=OFF`，走业务入口 | `write_guard` 抛 `ConnectionContractViolation`，**SQL 未执行**；六类比对全等 |
| R10-B2 | 同上 | `fk=OFF`，走业务入口 | 同上 |
| R10-B3 | 同上 | `write_guard` 抛错后检查连接 | PRAGMA 未被自动修复（仍为原值）；未继续写入 |
| AU1 | 节点 id=1（identity 10），四表各 1 行 | 提交 identity 11 | 抛 `IdentityConflict`；数据不变 |
| AU2 | 同 AU1 | 查 `system_events` | 1 条 `identity_conflict` / `identity_mismatch` |
| AU3 | 同 AU1 | 提交 cv 不一致（C4） | 抛 `ConfigVersionConflict`；1 条 `config_version_conflict` |
| AU4 | 配置升级撞指纹 | `apply_config_change` | `FingerprintTaken`；1 条 `fingerprint_conflict` |
| AU5 | 审计连接失败 | 提交 identity 11 | 仍抛 `IdentityConflict`；无事件；`audit_write_failed` 日志 |
| AU6 | 审计失败后重试 | 再提交 identity 11 | 仍拒绝；不因审计缺失而放行 |

---

## 6. 关闭证明

### 6.1 P0-1（迁移控制流）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 阶段 A 失败 → `abort_before_tx`，不进事务 | §3.3 | MC8 | 已关闭 |
| 阶段 B 失败 → `ROLLBACK` → 确认结束 → `rollback_tx` → 立即终止 | §3.3 | MC1–MC3 | 已关闭 |
| COMMIT 成功才置 `COMMITTED` 并进阶段 C | §3.1/§3.2 | MC7 | 已关闭 |
| COMMIT 抛异常不假定结果，用 token 判定 | §3.2 | MC5 | 已关闭 |
| 无法判定 → 保守恢复，不开放写入 | §3.2/§3.3 | MC6 | 已关闭 |
| 禁 `except Exception: pass` | §3.3 约束 1 | 代码评审 | 已关闭 |
| `rollback_tx` 有终止语义 | §3.3 约束 2（`raise MigrationTerminated`） | MC1 | 已关闭 |
| 七条新增测试 | §3.6 | MC1–MC7 | 已关闭 |

### 6.2 P0-2（C12–C16）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| C12–C16 全部在捕获边界内 | §3.3 阶段 C 段 | CR1–CR3 | 已关闭 |
| C15 失败不留虚假成功 | §3.4 | CR1 | 已关闭 |
| C16 失败重新封闭 maintenance | §3.4 | CR2/CR3 | 已关闭 |
| C15 成功后 C16 失败 → 恢复后无 success | §3.4（备份替换 + 计数断言） | CR2 | 已关闭 |
| 恢复未完成不得开放写入 | §3.4/§3.5 | CR1–CR5 | 已关闭 |
| 恢复连接顺序 6 步（关→探测→BEGIN/ROLLBACK→关探测→复核→替换） | §3.5 | CR4/CR5 | 已关闭 |
| D3 只是瞬时探测，非永久封锁 | §3.5 | — | 已关闭 |
| maintenance 覆盖应用/后台/池/CLI | §3.5 通道表 | CV1/CV4 | 已关闭 |

### 6.3 P0-3（R10）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 拆为底层实验与业务入口 | §5.1 | R10-A / R10-B1,B2 | 已关闭 |
| R10-A 同时关两开关、子表非空、验证悬空 | §5.1/§5.2 | R10-A | 已关闭 |
| R10-B 两条件分别测 | §5.1 | R10-B1/B2 | 已关闭 |
| `write_guard` 在执行 SQL 前拒绝 | §5.1 判定顺序 | R10-B1/B2 | 已关闭 |
| 数据全不变、记录违规 | §5.2 比对 | R10-B3 | 已关闭 |
| 不自动修复 PRAGMA 继续写 | §5.1 | R10-B3 | 已关闭 |

### 6.4 P1-1（文件级备份）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 9 步严格顺序（关连接→专用 checkpoint 连接→checkpoint→判定→关连接→WAL=0→journal→复制主库→验证副本） | §2.2 | RB2 | 已关闭 |
| 不在 checkpoint 连接打开时宣称已关闭 | §2.2 F5→F6 | — | 已关闭 |
| `wal_checkpoint` 返回值语义（busy/log/checkpointed） | §2.3 | RB1 | 已关闭 |
| 以"busy=0 且 WAL=0 字节"为前置，不把 `(0,N,N)` 当固定格式 | §2.3 | RB1/RB2 | 已关闭 |
| Backup API / VACUUM INTO 仍为首选 | §2.1 | RB4 | 已关闭 |

### 6.5 P1-2（夹具与审计）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 四表冻结 DDL + 可执行 INSERT | §5.2 | FX1/FX2 | 已关闭 |
| 明确四表均支持 `node_id` 关联 | §5.2 | FX1 | 已关闭 |
| 快照比较方式可执行 | §5.2 SQL + 比对表 | R2/R3 | 已关闭 |
| C3/C4 审计分型与 reason | §5.3 表 | AU2/AU3 | 已关闭 |
| 裸 `raise` 重抛，不构造异常 | §5.3 伪代码 + 说明 1 | AU1 | 已关闭 |
| 审计独立连接/事务、先结束写事务 | §5.3 说明 2 | AU2/AU5 | 已关闭 |
| 审计失败不改主结果 | §5.3 边界表 | AU5/AU6 | 已关闭 |

---

## 7. 测试矩阵（增量）

| 组 | v1.7 | v1.8 | 变化 |
| --- | --- | --- | --- |
| A 路径关系 A | 10 | 10 | — |
| R（REPLACE/UPSERT/入口） | 10（R1–R10） | **14** | R10 拆为 R10-A/B1/B2/B3，R2/R3 夹具强化 |
| FK（连接契约/迁移验证） | 15 | 15 | — |
| CV | 5 | 5 | — |
| M（迁移） | 32 | 32 | — |
| BA（备份顺序） | 6 | 6 | — |
| RB（文件级备份/checkpoint） | — | **4（RB1–RB4）** | 新增 |
| RC（COMMIT 后恢复） | 6 | 6 | — |
| CF（配置升级） | 8 | 8 | — |
| AU（审计） | 4 | **6（AU1–AU6）** | +AU5/AU6 |
| **MC（迁移控制流）** | — | **8（MC1–MC8）** | 新增 |
| **CR（C15/C16 失败）** | — | **5（CR1–CR5）** | 新增 |
| **FX（夹具 DDL）** | — | **3（FX1–FX3）** | 新增 |

其余组（I 30 / S 34 / T 14 / V 4 / CT 3 / FT 23 / F 22 / FKA 5 / P 14 / RP 12 / Z 30 / FE 19 / RG 24 / SF 7 / TV 4）不变。

**跨组一致性用例**

| 用例 | 断言 |
| --- | --- |
| MC6 + CR1 | 两条"结果不明/失败"路径都不写 success、都不开放写入 |
| MC7 + RC1 | 只有 `COMMITTED` 才可能产生 success；C15 失败则 success 必须为空 |
| R10-A + R10-B1 | 同一条 SQL，绕过入口能破坏、走入口被拒——证明保护来自入口契约而非单一触发器 |
| FX2 + CF1 | 配置升级后四表夹具仍可插入（复合外键仍满足） |
| AU3 + R8 | 版本冲突拒绝后，审计事件存在且库不变 |

---

## 8. 一致性复核（伪代码 / 流程表 / 测试矩阵）

| 复核项 | 伪代码位置 | 流程表 | 测试 |
| --- | --- | --- | --- |
| 阶段 A 失败终止 | `abort_before_tx` → `raise MigrationTerminated` | §3.1 表（PREPARED 只能 BEGIN） | MC8 |
| 阶段 B 失败回滚终止 | `if phase is TX_OPEN` 分支 | §3.1/§4.4 | MC1–MC3 |
| ROLLBACK 失败 | `phase=UNKNOWN` + `safe_fault` | §3.1（UNKNOWN 只能恢复） | MC4 |
| COMMIT 不确定 | `COMMIT_ATTEMPTED` + `resolve_commit` | §3.2 判定表 | MC5/MC6 |
| 阶段 C 全覆盖 | 单个 `try` 包 C12–C16 | §4 阶段表 | CR1–CR3 |
| C15 失败 | `mark_success` 抛 → 捕获 | §3.4 表 | CR1 |
| C16 失败 | `enable_business_writes` 抛 → 捕获 | §3.4 表 | CR2/CR3 |
| 恢复连接顺序 | R1–R6 | §3.5 | CR4/CR5 |
| 备份 9 步 | F1–F9 | §2.2 | RB1–RB3 |
| 夹具四表 | §5.2 DDL + INSERT | — | FX1–FX3 |
| 审计重抛 | 裸 `raise` | §5.3 边界表 | AU1/AU5 |

**逐条比对结论**：伪代码的每个分支都能在流程表中找到唯一对应行，每个流程行都有至少一条测试；未发现"代码能做但流程未定义"或"流程要求但代码无路径"的项。

---

## 9. C11–C20 确认状态（不变）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（获批才走 B） | **未确认（本轮未假设已批准）** |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口 | 6h 优先 | 未确认 |
| C15 | `rep` 门槛 | 0.90 / 0.60 | 未确认 |
| C16 | retired 回归复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| C18 | TCP-only 允许存、不参与判定 | 按 v1.6 §8 | 未确认 |
| C19 | 旧结果表停写切换 | 先验证、单开关、可回滚 | 未确认 |
| C20 | A 路径"物理可空 + 触发器"是否接受 | 建议接受为过渡 | 未确认 |

---

## 10. 风险（更新）

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | 迁移分支遗漏导致"回滚了还继续走阶段 C" | 显式 phase + 终止异常；禁宽泛捕获 | MC1–MC4 |
| 2 | COMMIT 结果误判 | token 凭据 + 新连接只读判定 | MC5/MC6 |
| 3 | C15/C16 失败留下 success 或半开放写入 | 统一捕获 + 备份替换 + success 计数断言 | CR1–CR3 |
| 4 | 恢复时旧句柄写旧库 | 六步关闭顺序 + 连接纪元 | CR4/CR5 |
| 5 | 误信 `(0,N,N)` 即备份成功 | 以 busy=0 且 WAL=0 字节为前置 | RB1/RB2 |
| 6 | 夹具字段与 DDL 不符 | 冻结 DDL + 可执行 INSERT + FX 组 | FX1–FX3 |
| 7 | 审计异常构造错误导致重抛失真 | 裸 `raise` | AU1 |
| 8 | 只靠触发器保护档案 | R10-A 反证 + R10-B 入口契约 | R10-A/B |
| 9 | C-2 误停导致迁移中断 | 误停只影响单表，事件给快照 | M30/M32 |

---

**v1.8 到此结束。** 本轮**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据**；仅修订五项问题。**C11–C20 全部未确认，C12 仍未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
