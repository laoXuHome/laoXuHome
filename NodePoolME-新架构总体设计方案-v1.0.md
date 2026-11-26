# NodePoolME 新架构总体设计方案 v1.0

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.9
**本轮性质**：最终设计收尾。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：仅三项 P0（失败证据链、曾失败 vs 曾不可用、`verdict` 校验）。**未扩展任何架构。**
**文档状态**：**待最终审查**（本文未自行认定通过；C11–C17 未批准）

---

## 修订索引（v0.9 → v1.0）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-A | 连续失败证据链：全部记录须同窗口、同版本、遇 pass 即断 | §3 | 修正 |
| P0-B | `target_ever_fail`（诊断）与 `target_ever_unavailable`（触发 Q11）分离 | §9 | 修正 |
| P0-C | `apply_result` 的 `verdict` 枚举校验与 `invalid_verdict` | §4 | 补齐 |

未修订：Q1–Q12、零健康参与集合与零分母顺序（v0.9 §2）、`fresh()`、快照对齐、回池令牌与外键（含三期迁移）、stable_id 六边界、30 天 missing、不改指纹、per-node 30 分钟、业务 90 分钟、测速窗口与 50MB、骤减双条件、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`、评分算法、前端布局。**C11–C17 全部未确认。**

---

## 0. 三项修正的共同点

三项 P0 都指向同一个毛病：**用一个"累计量"替代"可核验的证据链"**。

| # | 被替代的东西 | 后果 |
| --- | --- | --- |
| P0-A | 用 `fail_streak` 这个计数器替代 results 里的连续失败记录 | 计数器无法证明"这 3 次失败是连续的、同版本的、都在窗口内" |
| P0-B | 用 `target_ever_fail`（曾失败）替代"曾真正进入 unavailable" | 一次偶发抖动就让该目标永久背上"两次恢复确认" |
| P0-C | 用"没见过的 verdict 就走默认分支"替代显式枚举校验 | 非法输入可能进入 `update_target_state` |

v1.0 的原则：**证据必须能从明细记录复核（可查询、可验时间链、可验版本）；状态迁移只由"真正跨过门槛"的事实触发；输入只接受白名单。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；`missing` 30 天（最短 7）；不改指纹算法；per-node 30 分钟 + 抖动；业务侧 90 分钟独立；测速 17:00–24:00 与 50MB；骤减"7 天中位降 ≥50% 且绝对减 ≥10" + 两次独立拉取确认；零健康最多保留上一版 24 小时、硬上限 72 小时；30 个完整可恢复版本；恢复需两次独立有效 Mihomo 成功且间隔 ≥30 分钟（Q11）；TCP-only 永不合格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不改。

---

## 2. 零健康判定（v0.9 定稿，不改）

判定顺序固定为九步，零分母在 `cov` 之前：

```
① 全停用 → all_disabled
② 异常机场（P_block）→ scope_blocked(invalid_window)
③ 空池未核实 → scope_blocked(empty_unverified)
④ 全空池（已核实）→ no_nodes
⑤ Σ|A_eff| = 0 → zero_denominator（此步不调用 cov）
⑥ 单机场 |A_eff| = 0 → scope_blocked(no_response)
⑦ cov / rep / U_unk 校验
⑧ 有可发布节点 → normal
⑨ 全部不可发布且证据齐全 → zero_health
```

集合口径（`P_disabled` / `P_enabled` / `P_block` / `P_eval` / `P_nonempty` / `P_empty_verified` / `P_empty_unverified` / `P_resp` / `P_noresp`）与 §2 状态表、计时器行为均沿用 v0.9，本节不再重复。**唯一改动是 §3 的 `U_unk` 判定变得更严格**：证据不足一律归入 `U_unk`，于是 `scope_blocked(evidence_short)`。

---

## 3. P0-A：连续失败证据链

### 3.1 v0.9 的缺口

v0.9 §3.2 只要求"`fail_streak ≥ T`"且"最新一次失败在 `(t-W, t]` 内"。没有保证**构成门槛的那几次失败**也都在窗口内、也没有保证它们是同一版本、更无法证明它们之间没有夹过 pass（P0-A）。`fail_streak` 是一个累计整数，**不能自证时间链**。

### 3.2 证据链的定义（从明细记录重建，不看计数器）

```python
def fail_chain(node, target, t, W, T):
    """按时间倒序取出该 (node, target, 当前版本) 的连续有效失败记录"""
    rows = sql("""
        SELECT * FROM results
         WHERE node_id = ? AND target = ?
           AND valid = 1
           AND mode = 'mihomo'
           AND failure_source NOT IN ('engine','scheduler','system','target_incident')
           AND config_version = ?          -- 当前 config_version
           AND rule_version   = ?          -- 当前有效 rule_version
         ORDER BY finished_at DESC
    """, node.id, target, node.config_version, active_rule_version(t))

    chain = []
    for r in rows:
        if r.finished_at <= t - W:        break      # 超出窗口 → 链到此终止（不计入）
        if r.last_result != "fail":       break      # 遇到有效 pass → 连续链断裂
        chain.append(r)                              # 只收窗口内的 fail
    return chain

def has_fail_evidence(node, target, t):
    c = fail_chain(node, target, t, W, T)
    if len(c) < T:                        return False , "chain_short"
    if not (t - W < c[0].finished_at <= t): return False, "chain_stale"
    return True, None
```

**六条硬条件（全部满足才算证据）**：

| # | 条件 | 实现点 |
| --- | --- | --- |
| 1 | 连续有效失败 **≥ T 条**（`T = settings.fail_threshold`，默认 3） | `len(c) >= T` |
| 2 | 这 T 条**全部**落在 `(t-W, t]` | 循环在越界处 `break`，因此链内元素天然全在窗口 |
| 3 | 同 `node` + 同 `target` + 同 `config_version` + 同 `rule_version` | SQL 四个等值过滤 |
| 4 | 期间**任何有效 pass 立即清零** | `last_result != 'fail'` → `break` |
| 5 | 四类系统故障与 `tcp_only` **既不计数、也不断链** | SQL 的 `valid/mode/failure_source` 过滤（它们被剔除，等于对链"不可见"） |
| 6 | 记录不足 / 部分过期 / 版本不一致 → 不作证据 | 返回 `chain_short` / `chain_stale` |

> 条件 5 的语义要写清：系统异常行被 `WHERE` 排除，因此它既不增加失败次数，也不会把链打断——一个"引擎异常"夹在两次真实失败之间，不影响这两次仍属连续失败链。只有**有效 pass** 才断链。

### 3.3 `fail_streak` 的角色降级

| 用途 | 是否允许 |
| --- | --- |
| 目标状态迁移（`observe → unavailable` 的门槛判断） | **允许**（它是状态机的触发器，由 `apply_result` 在同事务内维护） |
| 证明"全池失效"（`has_fail_evidence`） | **不允许**（必须走 §3.2 的链查询） |
| UI 显示"连续失败 N 次" | 允许（标注"计数"而非"证据"） |

**为什么必须双轨**：计数器只证明"累计次数"，无法证明"连续"（中间可能有 pass 被旧实现漏记）、无法证明"窗口"（可能跨越 `W`）、无法证明"版本"（升级前的失败可能被继承）。链查询每次从 `results` 重建，天然满足三者。

### 3.4 查询与索引（P0-A 的"可验证"要求）

```sql
CREATE INDEX idx_results_chain
  ON results(node_id, target, finished_at DESC);
```

| 校验问题 | 如何回答 |
| --- | --- |
| "这 3 次失败是连续的吗" | 倒序扫描，链内没有 pass（遇 pass 即 `break`） |
| "都在窗口内吗" | 每条 `finished_at > t-W`；越界即不计入 |
| "是同一台机器同一版本吗" | SQL 等值过滤 `node_id`、`config_version`、`rule_version` |
| "中间有没有系统故障被混入" | `WHERE` 排除四类 `failure_source` 与 `tcp_only` |
| "能复现吗" | 同一 `t`、同一 `W`、同一 `T` 查询结果确定；审计可打印链的 `result_id` 列表 |

`system_events` 需记录 `evidence_chain=[result_id...]`，使"为什么判它失效"可在事后逐条复核。

### 3.5 全池证据条件（接入 §2 的 ⑦）

`U_unk = A_scope \ (E ∪ F_ev)`，其中：

```
F_ev = { n ∈ A_scope : ∃ 必需目标 g，has_fail_evidence(n,g,t)=True ∧ 无任何其他必需目标新鲜有效 pass }
```

`U_unk` 必须为空；`rep ≥ 0.90` 只是代表性，**不能替代链**。因此：

- 118 池、107 观测且 107 个都建成 T 条链、11 个无链 → `scope_blocked(evidence_short)`；
- 118 个全部建成链 → `zero_health`。

### 3.6 测试（FE5–FE10）

| # | 场景 | 预期 |
| --- | --- | --- |
| FE5 | 三次连续有效失败均在 `(t-W,t]` | `has_fail_evidence=True`，`chain=[r1,r2,r3]` |
| FE6 | 三次连续失败跨越窗口（最早一条 `t-W-5min`） | `False`，`chain_stale`/`chain_short`；`U_unk(U4)` |
| FE7 | 两条旧失败（`t-W-1h`、`t-W-30min`）+ 一条新失败（`t-10min`） | `chain` 只有 1 条 → `False`；**不构成当前三次连续证据** |
| FE8 | 链中出现有效 pass（fail, pass, fail, fail） | 倒序遇 pass 即断 → 只有 2 条 → `False` |
| FE9 | 链中夹一条引擎异常（fail, engine-fail, fail, fail） | 引擎行被过滤 → 3 条有效失败 → `True` |
| FE10 | `config_version` 从 1 升到 2，链含 v1 的两条 + v2 的一条 | SQL 过滤后只有 1 条 → `False`；不得拼接 |

---

## 4. P0-C：`apply_result` 的 `verdict` 校验

### 4.1 合法枚举（唯一来源）

```python
VERDICTS = ("pass", "fail", "invalid", "stale")     # 应用层常量
```

```sql
-- 数据库 CHECK 必须与此完全一致
CHECK (outcome IN ('pass','fail','invalid','stale'))
```

**一致性要求**：应用层 `VERDICTS` 与 DDL 的 `CHECK` 列表必须逐项相同，且由同一个版本的迁移建立；任何一侧新增值都必须双边同改（`M11` 断言）。

### 4.2 权威伪代码（唯一流程，含 verdict 校验）

```python
def apply_result(task_id, exec_cv, exec_rv, exec_target, verdict, finished_at):
    with tx():                                   # BEGIN IMMEDIATE
        # ── 0. 幂等前置：任何状态变更之前
        if exists("detection_task_runs", task_id=task_id):
            return "duplicate_ignored"

        # ── 1. 事务内重读任务
        task = q("SELECT * FROM detection_tasks WHERE task_id=?", task_id)
        if task is None:
            insert_run(task_id, None, "invalid", reason="unknown_task"); return

        # ── 2. 执行侧与固化值三比对
        if exec_cv != task.config_version:
            insert_run(task_id, task.node_id, "stale", reason="config_version"); return
        if exec_rv != task.rule_version:
            insert_run(task_id, task.node_id, "stale", reason="rule_version"); return
        if exec_target != task.target:
            insert_run(task_id, task.node_id, "stale", reason="target"); return

        # ── 3. 事务内重读节点与规则
        node = q("SELECT * FROM nodes WHERE id=?", task.node_id)
        rule = q("SELECT version FROM detection_rules WHERE active=1")

        # ── 4. 权威校验
        if node is None or node.identity_id != task.identity_id:
            insert_run(task_id, task.node_id, "stale", reason="identity"); return
        if node.lifecycle != "active":
            insert_run(task_id, task.node_id, "stale", reason="lifecycle"); return
        if task.target not in required_targets(node):
            insert_run(task_id, task.node_id, "stale", reason="target"); return
        if task.config_version != node.config_version:
            insert_run(task_id, task.node_id, "stale", reason="config_version"); return
        if task.rule_version != rule.version:
            insert_run(task_id, task.node_id, "stale", reason="rule_version"); return

        # ── 5. verdict 白名单校验（在写状态之前，唯一入口）
        if verdict not in VERDICTS:
            insert_run(task_id, task.node_id, "invalid", reason="invalid_verdict"); return
        if verdict == "invalid":
            insert_run(task_id, task.node_id, "invalid", reason="reported_invalid"); return

        # ── 6. 登记
        insert_run(task_id, task.node_id, verdict, applied=(verdict in ("pass","fail")))

        # ── 7. 状态更新（仅 pass/fail）
        if verdict in ("pass", "fail"):
            update_target_state(node, task.target, verdict, finished_at)
```

**八条规则**：

| # | 规则 |
| --- | --- |
| 1 | 幂等（步骤 0）最早，且与后续写同事务 |
| 2 | `verdict` 校验在**任何** `update_target_state` 之前（步骤 5 早于步骤 6/7） |
| 3 | 非法 verdict → `outcome='invalid'`、`reason='invalid_verdict'`、`applied=0` |
| 4 | 提交者自报 `invalid` → 同样 `applied=0`，原因 `reported_invalid`（与非法枚举区分） |
| 5 | `stale` 由系统判定（版本/身份/目标），提交者也可报 `stale`，但一律 `applied=0` |
| 6 | 非法 verdict **不得**触发数据库异常，也**不得**落入任何默认分支 |
| 7 | 同一 `task_id` 已登记为 invalid → 再提交任何值都返回 `duplicate_ignored` |
| 8 | DB `CHECK` 与应用层 `VERDICTS` 清单同版本、同内容 |

### 4.3 为什么不能靠数据库抛错兜底

若依赖 `CHECK` 抛 `IntegrityError`：① 错误分类变成 500/异常，而不是 `invalid_verdict` 的可审计登记；② 事务回滚会连"这次非法提交发生过"的记录一起抹掉；③ 不同 SQLite 版本的错误信息不一致。因此**应用层必须先判**，`CHECK` 只作为最后一道防线（两层都要有）。

### 4.4 测试（TV1–TV4）

| # | 场景 | 预期 |
| --- | --- | --- |
| TV1 | `verdict="timeout"`（非法枚举） | run 行 `invalid/invalid_verdict`、`applied=0`；目标状态不变 |
| TV2 | 同一非法 `task_id` 重复提交 `"timeout"` | 第二次 `duplicate_ignored`；run 仍 1 行；无第二条事件 |
| TV3 | 非法 verdict 提交后检查全部健康字段 | `last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`state`、`node_state_history` 全部不变 |
| TV4 | 应用层 `VERDICTS` 与 `detection_task_runs.outcome` 的 `CHECK` 对比 | 集合完全相同（`M11` 用 `PRAGMA`/DDL 解析断言） |

---

## 5. 结果有效性函数 `fresh()`（沿用 v0.9）

```python
SYSTEM_SOURCES = {"engine", "scheduler", "system", "target_incident"}

def result_valid(n, g, t, now):
    return (t.last_result == "pass"
            and t.config_version == n.config_version
            and t.rule_version == active_rule_version(now)
            and t.mode == "mihomo"
            and t.failure_source not in SYSTEM_SOURCES
            and t.valid == 1
            and t.last_pass_at + t.ttl > now)
```

三处复用（健康、恢复、发布资格）不变。`fresh()` 与 §3.2 的 `fail_chain()` 互为对称：一个要求"新鲜有效成功且全目标通过"，一个要求"同版本同窗口的 T 条连续有效失败且无新鲜成功"。

---

## 6. presence 快照对齐（沿用 v0.9）

- 快照 `W_snap(D) = (D-7d 00:00, D 00:00]`，`snapshot_as_of` 精确到秒；仅当请求窗口完全一致才可直接回退。
- `U_before(t)` 一律用 log；`U7_prev(t)` 仅 `t = 某日 00:00:00` 且 log 不足时可用快照；`median7` 只允许快照，缺行 → log 重放 → 仍不足 → `baseline_insufficient`。
- `baseline_insufficient` 时不判骤减、不判 rolling；`snapshot_mismatch` / `snapshot_lagging` / `tz_mismatch` 分别处理。

---

## 7. 外键与迁移三期（沿用 v0.9）

目标 DDL：`restore_authorizations.token` 为主键；`nodes.restore_token TEXT REFERENCES restore_authorizations(token) ON DELETE RESTRICT ON UPDATE RESTRICT`（加列带 FK，默认 NULL，无需关闭外键）；`uq_nodes_restore_token`；回池三触发器。

### 7.1 三期划分（唯一正确姿势）

| 期 | 允许操作 | 禁止 |
| --- | --- | --- |
| `before-begin` | 备份、`quick_check`、记录 `foreign_keys` 原值、**必要时**（仅重建表）设 `foreign_keys=OFF`、设 `busy_timeout` | 做任何 DDL |
| `in-tx` | `BEGIN IMMEDIATE`、DDL、触发器、`PRAGMA foreign_key_check`（只读） | **任何 PRAGMA 切换**（事务内设置被忽略） |
| `after-commit` | 恢复 `foreign_keys` 原值并校验、再查一次 `foreign_key_check`、写 `schema_migrations(success)` | 再次 DDL |

### 7.2 中断、回滚、重启

| 情形 | 恢复 |
| --- | --- |
| 第二期异常 | `ROLLBACK` + `finally` 恢复原值 |
| 提交前崩溃 | 自动回滚；无 success 行 → 重跑 |
| 提交后崩溃 | 启动钩子统一 `foreign_keys=ON`；后置 `foreign_key_check` |
| `nodes_new` 残留 | 启动扫描，未提交则 `DROP` |
| 日志 | `migration_journal(step, started_at, finished_at, result)`；有 start 无 finish = 中断 |

外键负向测试 FK1–FK5 沿用（不存在的令牌 / 删除被引用授权 / 无效令牌 / id 不匹配 / 重复使用）。

---

## 8. stable_id 六种边界（沿用 v0.9）

`claim_candidate`（历史提示）与 `node_assignment`（本次结论）两路独立；B1 多 live → `hold`；B2 配置与 live 冲突（H1）→ 释放 `reused` + 新建；B3 `reused` → 禁止 readopt；B4 `absent` + 配置一致 → readopt；B5 同轮竞争 → 保留 `occurrence_seq` 最小者；B6 不可判定 → `hold`，**不得静默继承**。

---

## 9. P0-B：曾失败 ≠ 曾不可用

### 9.1 v0.9 的过度触发

v0.9 用 `target_ever_fail` 驱动恢复确认：只要该目标**曾经**有过一次有效失败，就必须走 Q11 两次成功 + 30 分钟（P0-B.1）。一次瞬时抖动（`fail_streak=1`，远未达 `T=3`、从未进 `unavailable`）就让该目标永久背上恢复流程，既慢又不符合 Q11 的原意——Q11 针对的是"进入不可用状态后的恢复"。

### 9.2 两个历史事实，职责分明

| 字段 | 含义 | 写入时机 | 用途 |
| --- | --- | --- | --- |
| `target_ever_fail` | 该目标**是否曾发生**有效失败（≥1 次） | 任一有效 fail 发生时置 1，永不清零 | **仅诊断/审计**；不驱动恢复流程 |
| `target_ever_unavailable` | 该目标**是否曾真正达到不可用门槛并进入 `unavailable`** | `fail_streak ≥ T` 触发 `observe→unavailable` 时置 1，永不清零 | **唯一**决定是否需要 Q11 恢复确认 |
| `ever_valid_fail`（节点级） | 该节点是否曾发生有效失败 | 任一目标有效 fail 时置 1 | 仅诊断 |
| `ever_unavailable`（节点级） | 该节点是否曾进入 `unavailable` | 节点 `state → unavailable` 时置 1 | 节点级显示与人工复核 |

```sql
-- node_target_state 追加（沿用 v0.9 的 target_ever_fail，新增一项）
target_ever_fail        INTEGER NOT NULL DEFAULT 0,
target_ever_unavailable INTEGER NOT NULL DEFAULT 0,
```

### 9.3 目标层规则（唯一判定表）

| 目标条件 | 是否需要 Q11 | 恢复判定 |
| --- | --- | --- |
| `target_ever_unavailable = 0`（含"曾失败但未达门槛"） | **否** | 当前 `config_version` + 当前规则下存在新鲜有效 pass 即可（`fresh()` 通过） |
| `target_ever_unavailable = 1` 且 `recovery_state='none'` | 是 | 需要重新建立：首次成功 → `observing`（计数 1、记 `first_success_at`） |
| `target_ever_unavailable = 1` 且 `observing` | 是 | 第二次成功且与 `first_success_at` 间隔 **≥30 分钟** → `confirmed`（计数 2、记 `confirmed_at`） |
| `target_ever_unavailable = 1` 且间隔 <30 分钟 | 是 | 计数**不增加**（视为同一次事件的重试），仍 `observing` |
| `observing` 期间出现有效失败 | 是 | **重置**：`success_count=0`、`first_success_at=NULL`、`recovery_state='observing'`；若失败达门槛则回 `unavailable` |
| `confirmed` 之后再次有效失败达门槛 | 是 | 重新故障：`recovery_state='observing'`、计数 0、`first_success_at=NULL`；`target_ever_unavailable` 保持 1 |
| 系统异常 / 引擎 / 调度 / TCP-only / `stale` / 过期结果 | — | **一律不推进** `success_count`，也不重置（它们不算证据；`stale` 连状态都不写） |

### 9.4 配置升级（按新 `config_version` 重建）

| 升级前状态 | 升级后 |
| --- | --- |
| `target_ever_unavailable = 0` | 只需新版本下**一次**新鲜有效 pass |
| `target_ever_unavailable = 1` 且 `confirmed` | **恢复证据作废**：`recovery_state='observing'`、计数 0、`first_success_at=NULL`；必须在新版本下重新两次 |
| `target_ever_unavailable = 1` 且 `observing` | 计数清零，重新开始 |

**注意**：`target_ever_unavailable` **不随配置升级清零**——"这台机器曾不可用"是历史事实；作废的只是"恢复证据"。

### 9.5 节点级聚合（唯一顺序）

```python
def aggregate_node(node, now):
    targets = required_targets(node)
    # ① 全体新鲜（fresh 已排除系统故障/TCP/stale/过期）
    if not all(fresh(node, g, now) for g in targets):
        return downgrade(node)
    # ② 曾进入 unavailable 的目标必须已确认
    for g in targets:
        st = target_state(node, g)
        if st.target_ever_unavailable and st.recovery_state != "confirmed":
            return set_state(node, "recovering")
    # ③ 全部满足
    return set_state(node, "healthy")
```

**关键差别**：② 的条件是 `target_ever_unavailable`，不是 `target_ever_fail`。因此"曾失败但没进 unavailable"的目标不会拦住节点恢复（P0-B 的核心）。

### 9.6 测试（RG10–RG14，新增；RG1–RG9 沿用但判据换成 `target_ever_unavailable`）

| # | 场景 | 预期 |
| --- | --- | --- |
| RG10 | 单次有效失败（`fail_streak=1`，未达门槛，从未 `unavailable`）→ 一次新鲜 pass | `state='healthy'`；`recovery_state='none'`；**不创建** `observing` |
| RG11 | 连续失败达门槛 → `unavailable` → 两次成功（间隔 ≥30 分钟） | 第 1 次 `observing`；第 2 次 `confirmed`；节点 `healthy` |
| RG12 | G 进入 `unavailable`、W 从未进入 | 只需 G 完成两次；W 只需一次 pass；节点在 G 未确认前为 `recovering` |
| RG13 | 曾 `unavailable` 的目标配置升级 | 升级后 `recovery_state='observing'`、计数 0；旧版本两次成功不继承；需新版本重新两次 |
| RG14 | `observing` 期间再次有效失败 | 计数归零、`first_success_at=NULL`；需重新两次 |

---

## 10. 迁移与兼容

### 10.1 变更清单（仅设计）

| 变更 | 对象 | 性质 |
| --- | --- | --- |
| `target_ever_unavailable` | `node_target_state` | 加列（默认 0） |
| `ever_unavailable` | `nodes` | 加列（默认 0） |
| `idx_results_chain(node_id,target,finished_at DESC)` | `results` | 索引（供 §3.2 链查询） |
| `stale_reason` 扩 `invalid_verdict` / `reported_invalid` | `detection_task_runs` | 枚举扩展 |
| `outcome` CHECK 与 `VERDICTS` 同版 | `detection_task_runs` | 约束一致性 |
| 事件字段 `evidence_chain` | `system_events` | 语义 |

历史行默认：`target_ever_unavailable=0`、`ever_unavailable=0`（历史不可追认——**不猜测**过去是否进过 `unavailable`；仅在后续首次达门槛时置 1）。

### 10.2 顺序（三期）

```
[before-begin] 备份 + quick_check + 记录 foreign_keys
[in-tx]        node_target_state 加列 → nodes 加列 → 建 idx_results_chain
               → detection_task_runs 扩枚举与 CHECK → foreign_key_check(只读)
[after-commit] 恢复 foreign_keys → 复查 foreign_key_check → 写 schema_migrations(success)
```

### 10.3 兼容承诺

- 全部加法或语义收紧；历史数据不迁移、不重算。
- 四种格式、四 URL、UA、Token、两种 `sub_publish`、测速、评分、前端布局**未改**。
- 前端增量展示：连续失败链长度、`target_ever_unavailable` 标记、`invalid_verdict` 计数、`zero_health` 原因码。

---

## 11. 测试矩阵

### 11.1 汇总

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务 T | 14 | T1–T14 |
| 有效性 V | 4 | V1–V4 |
| 并发 CT | 3 | CT1–CT3 |
| 约束 FT | 23 | FT1–FT23 |
| 令牌 F/FK | 27 | F1–F22 + FK1–FK5 |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP12 |
| 零健康 Z | 30 | Z1–Z30 |
| 失败链 FE | 10 | FE1–FE10 |
| 恢复 RG | 14 | RG1–RG14 |
| verdict TV | 4 | TV1–TV4 |
| 迁移 M | 11 | M1–M11 |

### 11.2 逐项详测（新增与改动项）

> 每条五段：**初始数据 / 步骤 / 预期数据库 / 预期业务 / 失败时必须保持不变**。

**FE5｜三次连续失败全在窗口内**

- 初始：节点 N（`config_version=2`）、目标 G；`results` 三条 fail：`t-50m / t-40m / t-30m`，均 `valid=1`、`mode='mihomo'`、`failure_source='timeout'`、`rule_version=4`；`fail_streak=3`；`W=6h`、`T=3`。
- 步骤：调用 `has_fail_evidence(N, G, t)`。
- 预期库：返回 `True`；`system_events.evidence_chain=[r1,r2,r3]`（按时间倒序）；不修改任何表。
- 预期业务：该节点进入 `F_ev`，可参与全池证据。
- 不变项：`fail_streak`、`results` 行。

**FE6｜三次连续失败跨越窗口**

- 初始：同上，但三条为 `t-W-5m / t-40m / t-30m`（最早一条越界）。
- 步骤：同上。
- 预期库：返回 `False(chain_short)`——越界记录在循环里被 `break` 排除，链长仅 2；节点归 `U_unk(U4)`。
- 预期业务：不构成当前失效证据；`scope_blocked(evidence_short)`。
- 不变项：`fail_streak` 仍 3（计数器不改）。

**FE7｜两旧一新不构成三次连续**

- 初始：`t-W-1h` fail、`t-W-30m` fail（均越界）、`t-10m` fail；`fail_streak=3`。
- 步骤：同上。
- 预期库：`chain` 仅 1 条（只有 `t-10m` 在窗口）；`False`。
- 预期业务：**不得**因"总失败次数 = 3"就判失效（这正是 v0.9 的漏洞）。
- 不变项：`fail_streak=3`。

**FE8｜链中出现 pass**

- 初始：倒序为 fail(`t-10m`)、fail(`t-20m`)、pass(`t-30m`)、fail(`t-40m`)。
- 步骤：同上。
- 预期库：倒序第 3 条为 pass → `break`；`chain=2` → `False`。
- 预期业务：连续链断裂，需重新累计 3 次。
- 不变项：`fail_streak` 若为 3 也不改（计数器与证据解耦）。

**FE9｜链中夹系统异常**

- 初始：倒序 fail(`t-10m`)、engine-fail(`t-20m`)、fail(`t-30m`)、fail(`t-40m`)。
- 步骤：同上。
- 预期库：engine 行被 `WHERE` 排除（既不计数也不断链）→ `chain=3` → `True`。
- 预期业务：系统故障不阻断真实失败链的连续性。
- 不变项：`fail_streak` 不受 engine 行影响。

**FE10｜版本变化不得拼接**

- 初始：v1 时代两条 fail（`t-40m`、`t-30m`）→ 升级 v2 → v2 时代一条 fail（`t-10m`）。
- 步骤：同上（当前 `config_version=2`）。
- 预期库：SQL 过滤 `config_version=2` → `chain=1` → `False`。
- 预期业务：旧版本失败不继承。
- 不变项：v1 的 `results` 行不被改写。

**RG10｜单次失败→一次 pass 即 healthy**

- 初始：N `target_ever_fail=1`、`target_ever_unavailable=0`、`fail_streak=1`、`state='observe'`。
- 步骤：G 来一条当前版本 `mihomo` pass。
- 预期库：`state='healthy'`；`recovery_state='none'`；`success_count=0`、`first_success_at=NULL`；`fail_streak=0`。
- 预期业务：不进入 `observing`，不需两次确认。
- 不变项：`target_ever_unavailable` 仍 0；`recovery_*` 不被创建。

**RG11｜达门槛进 unavailable → 两次成功**

- 初始：`fail_streak=3` → `state='unavailable'`；`target_ever_unavailable=1`。
- 步骤：pass(`t0`) → pass(`t0+10m`) → pass(`t0+40m`)。
- 预期库：`t0`: `observing`、count=1、`first_success_at=t0`；`t0+10`: 仍 `observing`、count 仍 1；`t0+40`: `confirmed`、count=2、`confirmed_at=t0+40`；`nodes.state='healthy'`。
- 预期业务：满足 Q11 才恢复发布。
- 不变项：`target_ever_unavailable` 保持 1；`fail_streak` 已归零。

**RG12｜单目标故障（G）与正常目标（W）**

- 初始：G `target_ever_unavailable=1`、`observing`、count=0；W `target_ever_fail=0`、`target_ever_unavailable=0`。
- 步骤：G pass（count=1）；W pass 两次（间隔 5 分钟）。
- 预期库：W 的 `recovery_state` 恒 `none`、`success_count` 恒 0；节点 `state='recovering'`（G 未确认）；G 第二次后 `confirmed` → `healthy`。
- 预期业务：只有 G 需要两次；W 不被强制。
- 不变项：W 的 `recovery_*` 整行为默认值。

**RG13｜曾 unavailable 目标配置升级**

- 初始：G `target_ever_unavailable=1`、`confirmed`（`confirmed_at` 有值，v1 时代两次）；节点升到 `config_version=2`。
- 步骤：v2 下 G 一次 pass。
- 预期库：升级时 G 置 `recovery_state='observing'`、count=0、`first_success_at=NULL`；一次 pass 后 count=1、仍 `observing`；节点 `recovering`。
- 预期业务：旧版本恢复成功不继承。
- 不变项：`target_ever_unavailable` 仍 1；v1 的 `results` 保留。

**RG14｜恢复期间再次有效失败**

- 初始：G `observing`、count=1、`first_success_at=t0`。
- 步骤：`t0+20m` 来一条有效 fail（`failure_source='timeout'`）。
- 预期库：`success_count=0`、`first_success_at=NULL`、`recovery_state='observing'`（若 `fail_streak≥3` 则 `unavailable`）。
- 预期业务：必须重新两次成功。
- 不变项：`target_ever_unavailable` 仍 1。

**TV1｜非法 verdict**

- 初始：`task_9` 未登记；节点 N cv=2、目标 G `last_pass_at=t-5m`。
- 步骤：`apply_result(task_9, 2, 4, 'G', 'timeout', now)`。
- 预期库：run 行 `outcome='invalid'`、`stale_reason='invalid_verdict'`、`applied=0`；`node_target_state` 无变化；无 `state_history` 新行。
- 预期业务：非法输入被拒，不进入健康判定。
- 不变项：`last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`state`。

**TV2｜同一非法 verdict 重复提交**

- 初始：同 TV1 已登记 `invalid`。
- 步骤：原样再提交 3 次。
- 预期库：run 仍 1 行；`system_events` 中 `invalid_verdict` 仍 1 条。
- 预期业务：`duplicate_ignored`，不抛异常。
- 不变项：全部字段。

**TV3｜非法 verdict 不改变健康字段**

- 初始：N `healthy`、G `fail_streak=0`、`success_streak=2`、`recovery_state='confirmed'`。
- 步骤：提交非法 verdict。
- 预期库：上述四字段与 `ttl`、`state_since` 全不变；仅 run 表 +1 行。
- 预期业务：非法输入零副作用。
- 不变项：同左。

**TV4｜CHECK 与枚举一致**

- 初始：迁移后的 `detection_task_runs` DDL。
- 步骤：解析 `CHECK(outcome IN (...))` 与 `VERDICTS` 常量。
- 预期库：两集合完全相同（4 项，顺序无关）。
- 预期业务：无"应用放行、DB 拒绝"的错位。
- 不变项：不写任何数据。

---

## 12. v0.9 → v1.0 修订对照

| # | v0.9 | v1.0 | 章节 |
| --- | --- | --- | --- |
| P0-A | `fail_streak ≥ T` + 最新失败在窗口 → 即证据（无法证明连续/同版本/全窗口） | 从 `results` 重建连续链：T 条全在窗口、四维等值、遇 pass 断链、系统故障透明；`fail_streak` 降级为状态机触发器 | §3 |
| P0-B | `target_ever_fail` 直接驱动 Q11 | 新增 `target_ever_unavailable` 作为唯一触发；`target_ever_fail` 仅诊断；节点聚合判据同步替换 | §9 |
| P0-C | verdict 无白名单，靠默认分支 | `VERDICTS` 白名单 + `invalid_verdict` 登记 + 与 DB CHECK 同版 | §4 |

---

## 13. 三项 P0 关闭清单

| 来源 | 问题 | 处理 | 状态 |
| --- | --- | --- | --- |
| P0-A.1 | 门槛未保证全部记录在窗口 | `fail_chain()` 越界即 `break`，链内元素天然全在窗口 | 已关闭 |
| P0-A.2 | 未保证同 node/target/版本 | SQL 四个等值过滤 | 已关闭 |
| P0-A.3 | pass 未清零 | `last_result != 'fail'` → `break` | 已关闭 |
| P0-A.4 | 系统/TCP 可能计入 | `WHERE` 排除四类 `failure_source` 与 `tcp_only` | 已关闭 |
| P0-A.5 | 不足/过期/异版本仍算证据 | 返回 `chain_short` / `chain_stale`，一律 `U_unk` | 已关闭 |
| P0-A.6 | 依赖不可验证的计数器 | 明细查询 + `idx_results_chain` + `evidence_chain` 审计 | 已关闭 |
| P0-B.1 | 一次失败即永久 Q11 | 拆 `target_ever_unavailable` | 已关闭 |
| P0-B.2 | 未进 unavailable 也要求两次 | §9.3 首行：只需新鲜 pass | 已关闭 |
| P0-B.3 | 曾 unavailable 需 Q11 | §9.3 第 2–5 行 | 已关闭 |
| P0-B.4 | 中间失败未重置 | §9.3 重置行 + RG14 | 已关闭 |
| P0-B.5 | 系统/TCP/stale 推进计数 | §9.3 末行 | 已关闭 |
| P0-B.6 | 配置升级未重建 | §9.4 三行表 + RG13 | 已关闭 |
| P0-B.7 | 节点级聚合未同步 | §9.5 改判据为 `target_ever_unavailable` | 已关闭 |
| P0-C.1 | 无白名单 | `VERDICTS` + 步骤 5 | 已关闭 |
| P0-C.2 | 幂等与校验顺序 | 步骤 0 → 2/4 → 5 → 6/7 | 已关闭 |
| P0-C.3 | 非法 verdict 写状态 | `invalid` 分支 `applied=0`，早于步骤 7 | 已关闭 |
| P0-C.4 | CHECK 与应用层不一致 | TV4 + M11 断言 | 已关闭 |
| P0-C.5 | 重复 invalid 未处理 | 步骤 0 先判 → `duplicate_ignored` | 已关闭 |
| P0-C.6 | 靠 DB 异常兜底 | §4.3 说明为何必须应用层先判，CHECK 仅兜底 | 已关闭 |

---

## 14. 未解决问题与待确认

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（重建走 §7.1 三期） | 未确认 |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口（6h / 最近 3 次） | 6h 优先 | 未确认（`W` 同时作为失败链窗口） |
| C15 | `rep` 门槛（0.90 / 0.60） | 0.90 确认 | 未确认 |
| C16 | retired 回归是否复用原 identity | 允许（新建 config_version） | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |

**本文未能消解、需实机验证的四项**（不属待确认决策，属事实缺口）：机场 `stable_id` 覆盖率；生产库重复配置比例；NAS `fsync`/`rename` 语义；presence log / results 表 30 天体量与 `idx_results_chain` 的实际查询代价（链查询每条最多扫 `T×k` 行，需压测）。

**已知无解项**：SQLite 无法证明调用者身份，回池令牌只能做到"数据绑定 + 一次性 + 审计"，不能宣称数据库级鉴权（v0.9 §7 已声明，v1.0 不改）。

---

## 15. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | 链查询频次高导致评估变慢 | `idx_results_chain`；按机场批量预取；`W` 内行数有限 | 压测（事实缺口 4） |
| 2 | `fail_streak` 与链长度不一致（计数器 bug） | 判定只用链；不一致时写 `system_events(counter_mismatch)` | FE7/FE8 |
| 3 | `target_ever_unavailable` 历史值不可追认 | 默认 0，仅后续达门槛置 1；UI 标注"历史未追认" | RG10–RG13 |
| 4 | 非法 verdict 被上游反复重投 | `duplicate_ignored` + 任务侧告警；不阻断流程 | TV2 |
| 5 | 配置升级后恢复变慢（需两次） | 属 Q11 本意；升级窗口可与人工复核并行 | RG13 |

---

**v1.0 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅修订三项 P0，未扩展架构。C11–C17 全部待确认。文档交回最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
