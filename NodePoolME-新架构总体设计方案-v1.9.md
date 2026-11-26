# NodePoolME 新架构总体设计方案 v1.9

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.8
**本轮性质**：纯设计修订。**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据。**
**本轮范围**：四项——COMMIT 异常后的事务隔离与最终状态判定、`FingerprintTaken` 审计捕获、phase 变更事件落地、R10-A 可执行性与四表快照。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 0. 修订索引（v1.8 → v1.9）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | COMMIT 异常后先隔离原连接，再做只读终态判定；不凭 `in_transaction` 或单次查询定案 | §2 | 修正 |
| P1-1 | `FingerprintTaken` 纳入审计捕获（`fingerprint_conflict` / `fingerprint_taken`） | §3 | 补齐 |
| P1-2 | `set_phase()` 统一状态切换并落事件；区分事务内易失事件与持久审计 | §4 | 落实 |
| P1-3 | R10-A 给可执行 SQL + 明确冲突约束；四表确定性快照 | §5 | 修正 |

未修订：Q1–Q12、七个触发器判定逻辑、`nodes` 禁 UPSERT 与身份感知写入口、配置升级原子流程、连接五类型与 `write_guard`、C-2 入向判定、`valid=0` 隔离、17 步主序号、备份首选策略与 F1–F9、C12–C16 捕获边界、时间与阈值类参数。**C11–C20 全部未确认；C12 未批准，默认 A 路径。**

---

## 1. 保留的既定设计（摘要）

Q1–Q12 保留；指纹算法不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康 24h/72h；30 个版本；Q11 两次有效 Mihomo 成功间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式兼容；评分算法；前端布局不重做。

A 路径：不重建 `nodes`，7 个触发器（六个关系触发器 + `trg_nodes_delete_guard`），**部分引用完整性、不等价于 B**；B 需 C12（**未确认**）。

v1.7/v1.8 已定稿、本轮不改：`node_identities`/`node_config_versions` DDL；`trg_nodes_rel_ins/upd`（含 `fingerprint` 扩列与等值条件）；`upsert_node_identity_aware` 四情形；`apply_config_change` 五步原子流程；连接五类型 / `write_guard`；备份首选 Backup API 与 `VACUUM INTO`，文件级 F1–F9；阶段 A/B/C 划分与 `MigrationTerminated` 终止语义；C12–C16 五步全捕获。

---

## 2. P0-1：COMMIT 异常后的事务隔离与最终状态判定

### 2.1 v1.8 的逻辑漏洞

v1.8 §3.2 的判定表写着："查不到 token，且迁移对象不存在 → 未提交（事务已回滚或从未生效）"。

**这个推断不成立**：若原迁移连接仍持有未提交事务（COMMIT 因锁/IO/中断失败但事务未结束），则该事务内的 token 行与 `CREATE TABLE` 对**其他连接完全不可见**（SQLite 的隔离性：未提交变更对其他连接不可见）。于是"新连接看不到 token、也看不到迁移对象"这组观测，在"事务仍挂着"与"事务已回滚"两种情况下**完全一样**。

因此必须先证明"原连接不再持有未决事务"，才允许用外部观测判定持久化状态。这是两个独立条件：

| 条件 | 含义 | 证明方式 |
| --- | --- | --- |
| K1 原连接事务已终止 | 该连接上不存在未提交事务 | 显式 `ROLLBACK`（若 `in_transaction`）→ 失败则 `close()` → 再验证 |
| K2 库最终状态已确认 | 持久化内容已定型 | 新连接只读查询 token/对象 + 写锁可立即获取 |

**只满足 K1 不足以判定**（关闭连接时 SQLite 会回滚未提交事务，但若回滚本身出错，进程内无法知晓），**只满足 K2 也不足以判定**（如 §2.1 所述）。二者必须同时成立。

### 2.2 判定顺序（严格七步）

| 步 | 动作 | 通过条件 | 不通过 |
| --- | --- | --- | --- |
| S1 | COMMIT 抛异常 → `phase=UNKNOWN`（**不判回滚**） | 已记事件 | — |
| S2 | **隔离原迁移连接**：置 `quarantined`，禁止其再执行任何语句（含迁移与业务） | 连接对象带隔离标记 | 标记失败 → 直接 S7 |
| S3 | 尝试终止未决事务：若 `in_transaction` → `ROLLBACK` | 返回无错 | 失败 → 记录后进 S4 |
| S4 | `close()` 原连接（关闭时 SQLite 对未提交事务执行隐式回滚） | `close()` 无错 | 抛出 → S7（不得假定已回滚） |
| S5 | 探测"无残留写者"：新探测连接 `BEGIN IMMEDIATE` → `ROLLBACK` → 关闭 | 能立即拿到写锁（`busy_timeout` 内成功） | 拿不到 → S7 |
| S6 | **新连接只读查询**：`SELECT result FROM schema_migrations WHERE migration_id=? AND token=?`；以及迁移对象是否存在的探测表 | 查询成功 | 查询失败 → S7 |
| S7 | 按 §2.3 判定；`UNKNOWN` 一律走 `handle_post_commit_failure`（保守恢复） | — | — |

**为什么 S5 是必需的**：`close()` 返回成功只证明"本进程认为连接已关闭"；若存在**另一进程**持有写锁（例如误开的 CLI），token 查询仍可信但恢复期的文件替换会被污染。S5 用写锁探测确认"当前没有任何写者"，与 `handle_post_commit_failure` 的第 3 步同源。

### 2.3 判定表（替换 v1.8 §3.2 的表）

| K1（原连接已终止） | K2（token 可见） | 迁移对象可见 | 判定 | 处理 |
| --- | --- | --- | --- | --- |
| 已终止 | 存在 | 存在 | `COMMITTED` | 进入阶段 C（C12–C16） |
| 已终止 | 不存在 | 不存在 | `TX_ROLLED_BACK` | 按预提交失败终止；库应为迁移前状态 |
| 已终止 | 不存在 | **存在** | `UNKNOWN` | 保守恢复 |
| 已终止 | 查询失败/超时 | — | `UNKNOWN` | 保守恢复 |
| **未终止 / 无法确认** | 任意 | 任意 | **`UNKNOWN`** | 保守恢复（**不得判 `TX_ROLLED_BACK`**） |

**三条硬规则**

1. 不得仅凭 `conn.in_transaction` 判定最终提交结果（该属性只反映连接对象状态，不反映磁盘持久化事实）；
2. 不得在原连接仍可能持有未决事务时，仅凭新连接查不到 token 就判 `TX_ROLLED_BACK`；
3. 不得把 `ROLLBACK` 失败当成"已回滚"——失败只会把状态推向 `UNKNOWN`。

### 2.4 伪代码（标注：伪代码）

```python
# 伪代码：替换 v1.8 中 COMMIT 异常分支
except CommitOutcomeUnknown as ce:
    set_phase(rec, Phase.COMMIT_ATTEMPTED, Phase.UNKNOWN, reason="commit_raised")

    # S2 隔离
    quarantine(conn)                      # 置标记，后续任何 execute 直接抛 QuarantinedError
    # S3 尝试终止未决事务
    try:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
    except Exception as rb:
        record_event("rollback_in_commit_path_failed", rb)     # 不据此判回滚
    # S4 关闭原连接（关闭即隐式回滚未提交事务）
    closed_ok = False
    try:
        conn.close(); closed_ok = True
    except Exception as cc:
        record_event("conn_close_failed", cc)
    # S5 写锁探测（证明无残留写者）
    probe_ok = False
    try:
        probe = sqlite3.connect(db_path, timeout=5, isolation_level=None)
        probe.execute("BEGIN IMMEDIATE"); probe.execute("ROLLBACK"); probe.close()
        probe_ok = True
    except Exception as pe:
        record_event("probe_write_lock_failed", pe)

    k1 = closed_ok and not conn_in_transaction(conn)   # K1
    k2 = probe_ok                                     # K2 的前置
    if not k1 or not k2:
        set_phase(rec, Phase.UNKNOWN, Phase.UNKNOWN, reason="cannot_confirm_isolation")
        handle_post_commit_failure(db_path, backup, ce)   # 不返回
        raise MigrationTerminated("commit_unknown_isolation")

    outcome = read_persisted_state(db_path, MID, token)   # 新连接只读：token + 对象探测
    if outcome == "committed":
        set_phase(rec, Phase.UNKNOWN, Phase.COMMITTED, reason="token_visible")
        # 继续阶段 C
    elif outcome == "rolled_back":
        set_phase(rec, Phase.UNKNOWN, Phase.TX_ROLLED_BACK, reason="token_absent_objects_absent")
        rollback_tx(ce)                                   # 记事件 + 终止
        raise MigrationTerminated("commit_not_effective")
    else:
        set_phase(rec, Phase.UNKNOWN, Phase.UNKNOWN, reason="token_absent_objects_present")
        handle_post_commit_failure(db_path, backup, ce)   # 不返回
```

### 2.5 测试（MC9–MC12，编号延续 v1.8 的 MC1–MC8）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC9 | COMMIT 抛异常，原事务仍活动（模拟锁失败） | 触发判定 | 先执行 S2–S5；观测到 `probe` 成功且 `close` 成功后才做 token 查询；**不得**在隔离前判定 |
| MC10 | 同上，`in_transaction=True` 且 `ROLLBACK` 也失败 | 触发判定 | `close()` 尝试；若 close 成功且探测成功 → 允许继续判定；若任一失败 → `UNKNOWN` + 保守恢复 |
| MC11 | 原连接未能确认终止（close 抛错） | 触发判定 | **判 `UNKNOWN`**；不得判 `TX_ROLLED_BACK`；不写 success；写入保持关闭 |
| MC12 | token 不存在但某迁移对象可见（半提交迹象） | 触发判定 | 判 `UNKNOWN` + 保守恢复（备份替换 + success 计数断言 0） |

**阶段状态表的更新**（替换 v1.8 §3.1 中 `COMMIT_ATTEMPTED` 一行）

| phase | 允许的下一步 | 前置条件 | 禁止 |
| --- | --- | --- | --- |
| `COMMIT_ATTEMPTED` | `COMMITTED` / `TX_ROLLED_BACK` / `UNKNOWN` | **K1 且 K2 均成立** | 在隔离确认前给出任何结论 |
| `UNKNOWN` | `handle_post_commit_failure`（唯一出路） | maintenance 仍生效 | 写 success、开放写入、判回滚 |

---

## 3. P1-1：`FingerprintTaken` 纳入审计

### 3.1 问题

v1.8 §5.3 的审计表已包含"指纹被占用（配置升级）→ `fingerprint_conflict` / `fingerprint_taken`"，但 §5.3 的伪代码 `except (IdentityConflict, ConfigVersionConflict)` 没有捕获 `FingerprintTaken`——该冲突发生时不会留下审计记录。

### 3.2 修正后的捕获与审计

| 异常 | 捕获 | 事件类型 | reason | 记录字段 |
| --- | --- | --- | --- | --- |
| `IdentityConflict` | 是 | `identity_conflict` | `identity_mismatch` | node_id, airport_id, fingerprint, current/incoming identity, current/incoming cv |
| `ConfigVersionConflict` | 是 | `config_version_conflict` | `config_version_mismatch` | 同上 |
| **`FingerprintTaken`** | **是（本轮补齐）** | **`fingerprint_conflict`** | **`fingerprint_taken`** | node_id（被升级节点）、airport_id、`current_fingerprint`、`requested_fingerprint`、`occupying_node_id` |

```python
# 伪代码
try:
    with immediate_tx(conn):
        ...                                     # 可能抛三种冲突
except (IdentityConflict, ConfigVersionConflict, FingerprintTaken) as e:
    ensure_tx_closed(conn)                      # 主事务先结束（不留未决事务）
    try:
        with immediate_tx(audit_conn):          # 独立连接 + 独立事务
            audit_conn.execute(
                "INSERT INTO system_events(event, reason, node_id, airport_id, fingerprint, detail_json, ts) "
                "VALUES (?,?,?,?,?,?,?)",
                (e.event_type, e.reason, e.node_id, e.airport_id, e.fingerprint, e.detail_json, now()))
    except Exception as audit_err:
        log_error("audit_write_failed", audit_err)     # 只影响审计
    raise                                        # 裸 raise：原样重抛，保留 traceback
```

**约束不变**：主写入一律拒绝（不因审计参与而改变结论）；审计用独立连接独立事务；审计前主事务必须已结束；审计失败只记日志，不得放行写入。

### 3.3 测试（AU7–AU9）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| AU7 | 节点 id=1（`F1`, cv=1）；同机场另一节点 id=2 已占用 `F1b` | `apply_config_change(node 1 → F1b)` | 抛 `FingerprintTaken`；`nodes`/版本表/子表全不变；异常未被包装（traceback 指向 `apply_config_change`） |
| AU8 | 同 AU7 | 查 `system_events` | **恰好 1 条** `fingerprint_conflict` / `fingerprint_taken`；`detail_json` 含 `occupying_node_id=2` |
| AU9 | 同 AU7，审计连接注入失败 | 同上 | 主写入仍被拒绝（`FingerprintTaken` 外抛）；无事件；日志 `audit_write_failed` |

---

## 4. P1-2：`set_phase()` 与事件持久化

### 4.1 统一状态切换函数（唯一入口）

```python
# 伪代码
def set_phase(rec, old, new, reason, *, durability="tx_local"):
    """唯一允许修改 phase 的入口。durability: tx_local | durable"""
    assert rec.phase is old          # 设计期约束（运行时用 if 判并抛错，不用 assert）
    if rec.phase is not old:
        raise PhaseMismatch(rec.phase, old)
    rec.phase = new
    payload = dict(migration_id=MID, old_phase=old.name, new_phase=new.name,
                   reason=reason, ts=now())
    if durability == "tx_local":
        try:
            rec.conn.execute("INSERT INTO system_events(event,detail_json,ts) "
                             "VALUES ('migration_phase',?,?)", (json.dumps(payload), payload["ts"]))
        except Exception as e:
            log_error("phase_event_tx_local_failed", e)     # 事务内事件：失败只记日志
    else:
        write_phase_event_durable(payload)                  # 独立连接独立事务
```

### 4.2 事件的两类持久性（必须区分）

| 类型 | 何时使用 | 事务可见性 | 是否算"已持久化审计" |
| --- | --- | --- | --- |
| `tx_local` | 事务内状态变化（`PREPARED→TX_OPEN`） | 写在迁移事务内，**随 `ROLLBACK` 一起消失** | **否**。只能描述为"事务内提示"，不能描述为审计记录 |
| `durable` | 事务边界之外的变化（`TX_OPEN→TX_ROLLED_BACK`、`→COMMITTED`、`→UNKNOWN`、恢复结果） | 独立连接独立事务 | 是 |

**明确要求**：`TX_ROLLED_BACK` 之后的审计必须用 `durable` 重写一条（因为 `tx_local` 的 `TX_OPEN` 事件已随回滚消失），否则会留下"有开始无结束"的事件孤岛。

### 4.3 全状态转换覆盖表

| 转换 | 触发点 | durability | 失败处理 |
| --- | --- | --- | --- |
| `PREPARED → TX_OPEN` | `BEGIN IMMEDIATE` 成功 | `tx_local` | 日志；**不回退**（事务已开，无法"假装没开"） |
| `TX_OPEN → COMMIT_ATTEMPTED` | 发出 COMMIT 前 | `tx_local` | 日志；继续执行 COMMIT（凭据行已在事务内） |
| `TX_OPEN → TX_ROLLED_BACK` | `ROLLBACK` 成功 | **`durable`**（事务外补写） | 事件失败 → **仍终止**（不写 success、不开写入）；只记日志 |
| `COMMIT_ATTEMPTED → COMMITTED` | token 可见 + K1/K2 成立 | **`durable`** | 事件失败 → **判 `UNKNOWN`**，走保守恢复（**不得**进阶段 C） |
| `COMMIT_ATTEMPTED → TX_ROLLED_BACK` | token 不可见 + 对象不可见 + K1/K2 成立 | `durable` | 失败 → 仍终止；日志 |
| `COMMIT_ATTEMPTED → UNKNOWN` | COMMIT 抛异常 / 无法确认隔离 / 半提交迹象 | `durable` | 失败 → 仍走 `handle_post_commit_failure`（保守恢复本身不需要该事件成功） |
| `UNKNOWN → COMMITTED` | 隔离后 token 可见 | `durable` | 失败 → 回退为 `UNKNOWN` + 保守恢复 |
| `UNKNOWN → TX_ROLLED_BACK` | 隔离后 token 与对象均不可见 | `durable` | 失败 → 仍终止 |
| 恢复结束（`rollback_ok` / `recovery_failed`） | 恢复流程末步 | `durable` | 失败 → 仍保持 maintenance 并非零退出 |

**核心原则（对任务书"事件失败不得使系统错误继续"的落实）**：

- 事件失败**从不**导致"进入下一阶段"或"开放业务写入"；它只可能导致**更保守**的结果（`UNKNOWN` / 终止）；
- 唯一"必须成功才能继续"的事件是 `COMMIT_ATTEMPTED → COMMITTED`：写不进去就不认"已提交"，宁可恢复。

### 4.4 独立审计连接的并发安全（防死锁）

| 规则 | 说明 |
| --- | --- |
| 只在写事务**结束后**使用 | `COMMIT`/`ROLLBACK` 已返回，或原连接已 `close()`；绝不在持有写锁时开第二个写连接 |
| 短 `busy_timeout`（≤500ms） | 避免审计写把迁移路径拖住；超时即记日志、不重试 |
| 单次尝试，不循环重试 | 重试会放大锁竞争；失败即降级为日志 |
| 审计连接不复用迁移连接 | 独立连接对象，用完即关 |
| 若原连接仍可能持有写锁 | 先按 §2.2 的 S2–S5 隔离，再做任何 `durable` 写 |

### 4.5 测试（PH1–PH4）

| # | 路径 | 预期事件 |
| --- | --- | --- |
| PH1 | 正常提交 | `PREPARED→TX_OPEN`（tx_local，已随事务提交而留存）、`TX_OPEN→COMMIT_ATTEMPTED`、`COMMIT_ATTEMPTED→COMMITTED`（durable）；共 3 条可查 |
| PH2 | 预提交回滚（`foreign_key_check` 失败） | `TX_OPEN→TX_ROLLED_BACK`（durable）存在；`TX_OPEN` 那条已随回滚消失；**不存在**任何 `→COMMITTED` |
| PH3 | COMMIT 不确定 | `COMMIT_ATTEMPTED→UNKNOWN`（durable）+ 恢复事件；不存在 `→COMMITTED`、不存在 success |
| PH4 | 恢复失败 | `migration_recovery_failed`（durable）存在；无 success；写入保持关闭；进程非零退出 |
| PH5 | `→COMMITTED` 事件写失败（注入） | 判 `UNKNOWN` + 保守恢复；无 success |

---

## 5. P1-3：R10-A 可执行化与四表确定性快照

### 5.1 R10-A：完整可执行 SQL 与冲突来源

**冲突来源是唯一约束 `UNIQUE(airport_id, fingerprint)`**（不是主键）：`INSERT OR REPLACE` 命中该唯一键 → SQLite 删除冲突行（原 `id=1`）→ 插入新行（`AUTOINCREMENT` 分配 `id=2`）。

```sql
-- 前置（rt=OFF, fk=OFF；四子表各 1 行，node_id=1, identity_id=10）
PRAGMA recursive_triggers = OFF;
PRAGMA foreign_keys = OFF;

-- 可执行：重放同一 (airport_id, fingerprint)
INSERT OR REPLACE INTO nodes
       (airport_id, fingerprint, identity_id, config_version, status, fail_count)
VALUES (1,          'F1',        10,          1,              'available', 0);

-- 变体：incoming 身份不同（同样命中同一唯一键）
INSERT OR REPLACE INTO nodes
       (airport_id, fingerprint, identity_id, config_version, status, fail_count)
VALUES (1,          'F1',        11,          1,              'available', 0);
```

**逐项验证（必须按顺序取数，且都在 REPLACE 之后）**

```sql
-- ① nodes 的 id 是否变化（应为 2；原 1 已不存在）
SELECT id FROM nodes WHERE airport_id = 1 AND fingerprint = 'F1';

-- ② nodes.identity_id（等于 incoming 值：10 或 11）
SELECT identity_id FROM nodes WHERE airport_id = 1 AND fingerprint = 'F1';

-- ③ 子表 node_id 是否仍指向存在的 nodes 行（应为 0 —— 悬空）
SELECT COUNT(*) FROM node_state_history h
  LEFT JOIN nodes n ON n.id = h.node_id WHERE n.id IS NULL;

-- ④ 子表复合键 (node_id, identity_id) 是否仍有父记录（应为 0）
SELECT COUNT(*) FROM target_results t
  LEFT JOIN nodes n ON n.id = t.node_id AND n.identity_id = t.identity_id
 WHERE n.id IS NULL;

-- ⑤ 行数对比（四表各 1 行应保留，仅关联失效）
SELECT (SELECT COUNT(*) FROM node_state_history),
       (SELECT COUNT(*) FROM target_results),
       (SELECT COUNT(*) FROM detection_tasks),
       (SELECT COUNT(*) FROM node_id_reservations);
```

**预期必须与 SQL 行为一致**（不能笼统写"id 被替换"）：

| 观测 | 同身份变体 | 不同身份变体 |
| --- | --- | --- |
| `nodes.id` | 1 → **2** | 1 → **2** |
| `nodes.identity_id` | 仍 **10**（值相同但**是新行**） | 变为 **11** |
| 子表 `node_id=1` 悬空 | 是（父行已删） | 是 |
| 子表 `(1,10)` 复合父键 | **不存在**（父行 id 已变） | 不存在 |
| 四表行数 | 不变（1/1/1/1） | 不变 |
| 结论 | **档案被替换、关联失效** | 同左，且身份被改写 |

**这就是 R10-A 的用途**：证明"关闭两个 PRAGMA 后，数据库层自身无法阻止档案替换"，因此 §2 的 `write_guard`（入口契约）是必需防线。**R10-B1/B2 不变**：`write_guard` 必须在 SQL 执行前拒绝，且不自动修复 PRAGMA。

### 5.2 四表确定性完整快照

**排序规则**：每张表按 `id` 升序（`id` 为自增主键，唯一且稳定）；关联集合按 `node_id, identity_id` 双列升序。**不使用 `GROUP_CONCAT` 外层 `ORDER BY`** 来保证聚合输入顺序（SQLite 不保证该语义）；聚合仅作快速提示，最终比较以逐行快照为准。

```sql
-- 完整内容快照（逐行，确定性排序）
SELECT id, node_id, identity_id, target, from_state, to_state, reason, at
  FROM node_state_history ORDER BY id;

SELECT id, node_id, identity_id, task_id, target, mode, valid, failure_source,
       config_version, rule_version, latency_ms, message, ts
  FROM target_results ORDER BY id;

SELECT id, node_id, identity_id, target, rule_version, state, created_at
  FROM detection_tasks ORDER BY id;

SELECT id, node_id, identity_id, token, reserved_at, expires_at, released_at
  FROM node_id_reservations ORDER BY id;

-- 关联集合（用子查询内排序，不依赖聚合外层排序）
SELECT (SELECT group_concat(node_id) FROM
          (SELECT node_id FROM node_state_history ORDER BY node_id, id)) AS nsh_ids,
       (SELECT group_concat(node_id) FROM
          (SELECT node_id FROM target_results ORDER BY node_id, id)) AS tr_ids,
       (SELECT group_concat(node_id) FROM
          (SELECT node_id FROM detection_tasks ORDER BY node_id, id)) AS dt_ids,
       (SELECT group_concat(node_id) FROM
          (SELECT node_id FROM node_id_reservations ORDER BY node_id, id)) AS nres_ids;

-- nodes 关键字段与触发器集合
SELECT id, airport_id, identity_id, config_version, fingerprint, status, fail_count
  FROM nodes WHERE id = :nid;
SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name;
```

### 5.3 比较项清单（R2 / R3 / R10-A / R10-B 共用）

| # | 比较项 | 数据来源 | 判定 |
| --- | --- | --- | --- |
| 1 | 四表行数 | 四表 `COUNT(*)` | 与操作前相等 |
| 2 | 四表完整内容快照 | §5.2 四条 `SELECT ... ORDER BY id` | 逐行逐列相等 |
| 3 | 四表 `node_id` 集合 | 子查询内排序的 `group_concat` + 逐行比对 | 集合相等 |
| 4 | 四表 `(node_id, identity_id)` 关联 | 复合键 `LEFT JOIN nodes` 计数 | 悬空数 == 操作前值（正常应为 0） |
| 5 | `nodes` 原关键字段 | `id, airport_id, identity_id, config_version, fingerprint, status, fail_count` | 全等 |
| 6 | 触发器名称集合 | `sqlite_master` 按名排序 | 名称集合与数量相等 |
| 7 | 全库节点数 | `COUNT(*) FROM nodes` | 相等 |

**R10-A 是例外**：它预期第 1/2/3 项"行数不变但内容关联失效"、第 4 项悬空数由 0 变 1、第 5 项 `id` 变化——这正是"破坏已发生"的证据。**R2/R3/R10-B 则要求七项全部相等**。

### 5.4 测试补充（R10-A1 / R10-A2 拆分，编号不与现有冲突）

| # | 初始 | 步骤 | 预期（按 §5.1 表） |
| --- | --- | --- | --- |
| R10-A1 | `rt=OFF, fk=OFF`；节点 id=1/`F1`/identity 10/cv 1；四表各 1 行 | 执行同身份变体 REPLACE | `id`→2；`identity_id`=10（新行）；四表行数不变；四项悬空计数 = 1/0/1/1（分别对应四表） |
| R10-A2 | 同上 | 执行不同身份变体 REPLACE | `id`→2；`identity_id`→11；悬空同上 |
| R10-B1 | `rt=OFF, fk=ON`；四表非空 | 走业务入口 | `write_guard` 抛 `ConnectionContractViolation`；七项比较全等 |
| R10-B2 | `rt=ON, fk=OFF`；四表非空 | 走业务入口 | 同上 |
| R10-B3 | 同上，`write_guard` 抛错后 | 检查连接 PRAGMA | 仍为原值（未自动修复）；无 SQL 执行痕迹 |

---

## 6. 逐项关闭说明（含实际逻辑，不只是标"已关闭"）

### 6.1 P0-1 COMMIT 异常判定

| 要求 | 落实方式 | 为什么这样就成立 | 测试 |
| --- | --- | --- | --- |
| COMMIT 抛异常 → UNKNOWN，禁判回滚 | §2.2 S1 只置 `UNKNOWN` | 抛异常意味着"提交结果未知"，任何结论都缺证据 | MC9 |
| 隔离原连接 | S2 `quarantine(conn)`，后续 execute 直接抛 | 防止原连接继续参与，也防止其锁被误用 | MC9 |
| 尝试终止未决事务 / 关闭隔离 | S3 `ROLLBACK`（若 `in_transaction`）→ S4 `close()` | `ROLLBACK` 成功直接终止；失败时 `close()` 触发 SQLite 隐式回滚 | MC10 |
| 确认已终止再查询 | S5 写锁探测后才 S6 查询 | 探测能立即拿写锁 ⇒ 无任何进程持写者，包括原连接 | MC10 |
| 终态判定四分支 | §2.3 表 | token/对象两条观测在"已终止"前提下才有判别力 | MC7/MC12 |
| 无法确认即 UNKNOWN 保守恢复 | `k1 and k2` 不成立 → `handle_post_commit_failure` | 保守恢复不动 success、不开写入 | MC11 |
| 不凭 `in_transaction` 定案 | §2.3 硬规则 1 | 该属性只反映对象状态 | 代码评审 |
| 不把 ROLLBACK 失败当已回滚 | S3 失败仅记事件、继续 S4 | 失败 ≠ 成功；只能推向 UNKNOWN | MC10 |

### 6.2 P1-1 FingerprintTaken

| 要求 | 落实方式 | 测试 |
| --- | --- | --- |
| 纳入捕获 | `except (IdentityConflict, ConfigVersionConflict, FingerprintTaken)` | AU7 |
| 事件类型/reason 保持 | `fingerprint_conflict` / `fingerprint_taken` | AU8 |
| 独立连接独立事务 | `with immediate_tx(audit_conn)` | AU8 |
| 主事务先结束 | `ensure_tx_closed(conn)` 先于审计 | AU7 |
| 审计失败不放行 | 裸 `raise`，与审计结果无关 | AU9 |
| 裸 raise 保留 traceback | `raise`（不带参数） | AU7 |

### 6.3 P1-2 phase 事件

| 要求 | 落实方式 | 测试 |
| --- | --- | --- |
| 统一切换函数 | `set_phase()` 唯一入口，旧值不符即抛 `PhaseMismatch` | PH1–PH3 |
| 五字段记录 | `migration_id / old_phase / new_phase / ts / reason` | PH1 |
| 覆盖六状态 | §4.3 九行转换表 | PH1–PH4 |
| 事件失败不推进 | 仅 `→COMMITTED` 强制成功；其余失败只会更保守 | PH5 |
| 事务内事件随回滚消失 | `tx_local` 明确标注，回滚后补 `durable` | PH2 |
| 独立连接防死锁 | §4.4 五条规则（事务结束才用、短超时、单次、不复用、先隔离） | PH3 |

### 6.4 P1-3 R10-A 与快照

| 要求 | 落实方式 | 测试 |
| --- | --- | --- |
| 可执行 SQL + 冲突约束明确 | §5.1：`UNIQUE(airport_id, fingerprint)` 触发删行 | R10-A1/A2 |
| 四项分别验证（id/身份/子表关联/复合键） | §5.1 ①–⑤ 查询 | R10-A1/A2 |
| 预期与 SQL 行为一致 | §5.1 表（同身份 id 变、身份值不变但行是新的） | R10-A1 |
| 稳定复现破坏 | `rt=OFF` + `fk=OFF` + 子表非空 | R10-A1/A2 |
| 四表完整快照 | §5.2 四条逐行查询 | R2/R3 |
| `group_concat` 不依赖外层排序 | 子查询内 `ORDER BY node_id, id` | R2/R3 |
| 七项比较覆盖 | §5.3 清单 | R2/R3/R10-B |

---

## 7. 测试矩阵（增量）

| 组 | v1.8 | v1.9 | 变化 |
| --- | --- | --- | --- |
| A 路径关系 A | 10 | 10 | — |
| R（REPLACE/UPSERT/入口/快照） | 14 | **16** | R10-A 拆 R10-A1/A2；R2/R3 补七项比较 |
| FK | 15 | 15 | — |
| CV | 5 | 5 | — |
| M | 32 | 32 | — |
| BA | 6 | 6 | — |
| RB | 4 | 4 | — |
| RC | 6 | 6 | — |
| CF | 8 | 8 | — |
| AU | 6 | **9** | +AU7–AU9（FingerprintTaken） |
| MC | 8 | **12** | +MC9–MC12（COMMIT 隔离判定） |
| CR | 5 | 5 | — |
| FX | 3 | 3 | — |
| **PH（phase 事件）** | — | **5（PH1–PH5）** | 新增 |

其余组（I 30 / S 34 / T 14 / V 4 / CT 3 / FT 23 / F 22 / FKA 5 / P 14 / RP 12 / Z 30 / FE 19 / RG 24 / SF 7 / TV 4）不变。

**跨组一致性用例**

| 用例 | 断言 |
| --- | --- |
| MC11 + PH3 + CR1 | 三条"不确定/失败"路径都不写 success、都不开放写入，且都有 durable 事件 |
| MC9 + PH1 | 只有在隔离确认后才可能产生 `→COMMITTED`；`→COMMITTED` 事件失败则回退 UNKNOWN |
| AU8 + CF5 | 指纹冲突：主写入失败 + 恰好一条审计 + 库不变 |
| R10-A1 + R10-B1 | 同一 SQL：绕过入口可破坏、走入口被拒——保护来自入口契约 |
| PH2 + MC3 | 预提交回滚后：无 `→COMMITTED` 事件、无 success、库回基线 |

---

## 8. 一致性复核（伪代码 / 流程表 / 测试矩阵）

| 复核项 | 伪代码 | 流程/规则表 | 测试 |
| --- | --- | --- | --- |
| COMMIT 异常先隔离 | `quarantine` → `ROLLBACK` → `close` → `probe` | §2.2 S1–S7 | MC9/MC10 |
| 隔离未确认不判回滚 | `if not k1 or not k2 → UNKNOWN` | §2.3 第 5 行 | MC11 |
| 半提交迹象 | `token_absent_objects_present → UNKNOWN` | §2.3 第 3 行 | MC12 |
| phase 事件统一入口 | `set_phase()` | §4.3 九行表 | PH1–PH5 |
| `→COMMITTED` 事件失败 | 回退 `UNKNOWN` + 恢复 | §4.3 | PH5 |
| 三类冲突审计 | `except (A,B,C)` | §3.2 表 | AU7–AU9 |
| R10-A 冲突约束 | `UNIQUE(airport_id,fingerprint)` | §5.1 | R10-A1/A2 |
| 七项快照比较 | §5.2 四条 + §5.3 清单 | §5.3 | R2/R3/R10-B |

**逐条比对结论**：伪代码中的每个判定分支都能在 §2.2/§2.3/§4.3 找到唯一对应行；每个规则行至少有一条测试；未出现"代码有路径但规则未定义"或"规则要求但代码无分支"的项。

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
| 1 | COMMIT 异常被误判为已回滚 | S1–S7 + K1/K2 双条件 | MC9–MC12 |
| 2 | 隔离前查询导致假回滚 | `k1 and k2` 门禁 | MC11 |
| 3 | 半提交（对象在、token 不在） | 显式 UNKNOWN 分支 | MC12 |
| 4 | `FingerprintTaken` 无审计 | 三类冲突同一捕获 | AU7–AU9 |
| 5 | phase 事件缺失或误报"已持久化" | `tx_local`/`durable` 分离 + 回滚后补写 | PH1–PH3 |
| 6 | `→COMMITTED` 事件失败仍进阶段 C | 失败即回退 UNKNOWN | PH5 |
| 7 | 审计连接与原写锁死锁 | 事务结束后才写 + 短超时 + 单次 | §4.4、PH3 |
| 8 | R10-A 预期与 SQL 不符 | 明确唯一约束 + 四项查询 | R10-A1/A2 |
| 9 | 快照比较不完整（聚合顺序不可靠） | 逐行 `ORDER BY id` + 子查询内排序 | R2/R3 |
| 10 | C-2 误停导致迁移中断 | 误停只影响单表，事件给快照 | M30/M32 |

---

**v1.9 到此结束。** 本轮**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据**；仅修订四项问题。**C11–C20 全部未确认，C12 仍未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
