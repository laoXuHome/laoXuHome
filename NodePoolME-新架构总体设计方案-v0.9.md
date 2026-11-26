# NodePoolME 新架构总体设计方案 v0.9

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.8
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**修订依据**：v0.8 第八轮审查（P0-1～P0-5、P1-1）
**文档状态**：**待最终设计审查**（本文未自行认定通过；C11–C17 未批准）

---

## 修订索引（v0.8 → v0.9）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | 零健康：零分母前置与单机场无响应阻断 | §2 | 修正 |
| P0-2 | 全池失效证据的失败门槛 `fail_streak ≥ T` | §3 | 修正 |
| P0-3 | 任务应用唯一权威流程（合并 §4 与旧 §6） | §4 | 合并重写 |
| P0-4 | 迁移三期：`foreign_keys` 只能在 BEGIN 前后切换 | §7 | 修正 |
| P0-5 | 多目标恢复聚合与重置规则 | §9 | 补齐 |
| P1-1 | stable_id 冲突六种边界 | §8 | 补充 |

未修订：Q1–Q12、30 天 missing、不改指纹、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件 + 两次独立确认、30 个可恢复版本、恢复两次有效成功间隔 ≥30 分钟、TCP-only 永不合格、四格式/四 URL/UA/Token/两种 `sub_publish`、评分算法、前端布局。**C11–C17 全部待确认。**

---

## 0. 本轮修正的共同点

第八轮指出的五个 P0 都是**顺序错误**导致的：

| # | 顺序错误 | 后果 |
| --- | --- | --- |
| P0-1 | 先算 `cov` 再查零分母 | `cov` 的除数就是 `|A_eff|`；除零在前，`zero_denominator` 永不可达 |
| P0-2 | 先定义"有失败"再用"连续 3 次"测 | 一次瞬时失败被当成失效证据 |
| P0-3 | §4 与 §6 各有伪代码，顺序不同 | 两套流程各说各话，重复提交可能在状态变更之后才被识别 |
| P0-4 | 把 `PRAGMA foreign_keys=OFF` 写进迁移事务 | SQLite 在事务内**不生效**，迁移看起来成功、实际约束失效 |
| P0-5 | 用 `recovery_state(node)` 概括多目标 | 一个目标恢复就放行整个节点 |

v0.9 只做一件事：**把"先判什么、后判什么"钉死，让每条规则在代码里只有一种执行顺序。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；`missing` 30 天（最短 7）；不改指纹算法；per-node 30 分钟 + 抖动；业务侧 90 分钟独立；测速 17:00–24:00 与 50MB；骤减"7 天中位降 ≥50% 且绝对减 ≥10" + 两次独立拉取确认；零健康最多保留上一版 24 小时、硬上限 72 小时；30 个完整可恢复版本；恢复需两次独立有效 Mihomo 成功且间隔 ≥30 分钟（Q11）；TCP-only 永不合格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不改。

---

## 2. P0-1：零健康判定的零分母与无响应

### 2.1 v0.8 的不可达逻辑

v0.8 §2.4：

```python
for a in P_nonempty:
    if cov(a) < 0.90: return "scope_blocked"          # cov 的分母是 |A_eff|
...
if sum(|A_eff(a)|) == 0: return "zero_denominator"    # 永远到不了
```

`cov(a) = |合格节点| / |A_eff|`，当该机场本次没有返回任何节点时 `|A_eff| = 0`，`cov` 要么除零、要么被判 `cov_low` 提前 `scope_blocked`，于是 `zero_denominator` 在代码里**不可达**（P0-1.1、P0-1.2）。

### 2.2 三个层次必须先分开

| 层次 | 量 | 含义 |
| --- | --- | --- |
| 单机场 | `|A_eff(a)|` | 本次响应中该机场返回的节点数。为 0 = **该机场本轮无有效响应** |
| 全局 | `Σ_{a∈P_nonempty}|A_eff(a)|` | 全部参与机场本轮返回的节点总数。为 0 = **全局无有效响应** |
| 分母可用性 | `cov` 是否可算 | 只在 `|A_eff| > 0` 时有意义 |

**"单机场无响应"≠"全局无响应"**：前者是缺一块，后者是整轮没有数据。二者的结论完全不同（前者阻断、后者 `zero_denominator`）。

### 2.3 集合定义（与 v0.8 一致，仅补 `A_eff=0` 的显式处理）

```
评估时点 t：一次只读事务快照，全部集合按 t 计算，事件写 as_of=t

P_disabled        = { a : enabled=0 ∨ airport_removed=1 }          （不进任何分母）
P_enabled         = { a : enabled=1 ∧ airport_removed=0 }
P_block           = { a ∈ P_enabled : 处于 invalid_window }
P_eval            = P_enabled \ P_block
A_scope(a,t)      = { n : lifecycle='active' ∧ airport=a ∧ last_present_at ≥ t-7d }
A_eff(a,t)        = { n ∈ A_scope : last_seen_pull_id = 当前 pull }
P_nonempty        = { a ∈ P_eval : |A_scope(a,t)| > 0 }
P_empty_verified  = { a ∈ P_eval : |A_scope|=0 ∧ 7 天内有 applied=1 的成功拉取 }
P_empty_unverified= { a ∈ P_eval : |A_scope|=0 ∧ 不满足上一行 }
P_responsive      = { a ∈ P_nonempty : |A_eff(a,t)| > 0 }
P_noresp          = P_nonempty \ P_responsive
```

其余（`W_obs`、`rep`、`E`、`F_ev`、`U_unk`、`cov`）定义同 §3。

### 2.4 判定流程（唯一顺序，零分母前置）

```python
def evaluate_global_zero_health(t):
    # ① 全停用（仅由"用户明确停用"触发）
    if not P_enabled:                    return "all_disabled"

    # ② 异常机场阻断（不统计，但阻断确认）
    if P_block:                          return "scope_blocked", "invalid_window:" + ids(P_block)

    # ③ 空池未核实阻断
    if P_empty_unverified:               return "scope_blocked", "empty_unverified:" + ids(...)

    # ④ 全部空池（已核实）
    if not P_nonempty:                   return "no_nodes"

    # ⑤ 全局零分母：必须在任何 cov / rep / E 计算之前
    if sum(|A_eff(a,t)| for a in P_nonempty) == 0:
        return "zero_denominator"

    # ⑥ 单机场无响应阻断（此时全局分母 > 0，但仍有机场缺块）
    if P_noresp:                         return "scope_blocked", "no_response:" + ids(P_noresp)

    # ⑦ 现在分母都非零，cov 可安全计算
    for a in P_nonempty:
        if cov(a) < 0.90:                return "scope_blocked", f"cov_low:{a}"
        if rep(a) < 0.90:                return "scope_blocked", f"rep_low:{a}"
        if U_unk(a):                     return "scope_blocked", f"evidence_short:{a}:{len(U_unk)}"

    # ⑧ 有可发布节点 → 正常
    if any(len(E(a)) for a in P_nonempty): return "normal"

    # ⑨ 全部不可发布且证据齐全
    return "zero_health"
```

**P0-1 的四个要求逐一落地**：

| 要求 | 落地 |
| --- | --- |
| 区分单机场 `A_eff=0` 与全局 `Σ=0` | ⑤ 与 ⑥ 是两个独立分支，判定顺序固定 |
| 计算 `cov` 前处理零分母 | ⑤⑥ 在任何 `cov` 调用之前 |
| 单机场无响应如何阻断 | ⑥ `scope_blocked(no_response)` |
| 全局无响应返回 `zero_denominator` | ⑤，且**不计算**任何 `cov` |

### 2.5 状态表（与 §2.4 一一对应）

| 状态 | 触发分支 | 24h 计时 | 订阅 |
| --- | --- | --- | --- |
| `all_disabled` | ① | 不启动 | 不发布（人工确认） |
| `scope_blocked` | ②`invalid_window` / ③`empty_unverified` / ⑥`no_response` / ⑦`cov_low`、`rep_low`、`evidence_short` | 不启动 | 维持当前 active |
| `no_nodes` | ④ | 不启动 | 无节点可发 |
| `zero_denominator` | ⑤ | 不启动 | 维持当前 active，记 `no_response_global` |
| `normal` | ⑧ | 若计时中则 `canceled` | 正常发布 |
| `zero_health` | ⑨ | **启动** | 到期发 `minimal` |

**必须保持的不变项**（②③⑤⑥⑦ 全部适用）：`publish_versions` 指针、`empty_confirmed` 任何已有行、订阅产物、`airports.enabled`。

### 2.6 计时器（与 v0.8 一致，补 `zero_denominator` 行为）

| 当前 | 事件 | 变化 |
| --- | --- | --- |
| 无 | `zero_health` | `confirmed_at`（只写一次）、`deadline=+24h`、`hard=+72h` |
| 计时中 | `scope_blocked` / `zero_denominator` | `paused` 累加，不取消 |
| 计时中 | 任一口机场 `E ≠ ∅` | `canceled` |
| 到期 | 重验仍 `zero_health` | 发 `minimal` |
| `hard` | 未解除 | `manual_review`，停自动发布 |

### 2.7 被修正的 Z 测试口径

| # | 场景 | v0.8 断言 | v0.9 断言 |
| --- | --- | --- | --- |
| Z27 | 全部参与机场 `A_eff=0`（本轮无任何节点返回） | 未定义 | `zero_denominator`；**未**调用 `cov` |
| Z28 | A 机场 `A_eff=0`，B 机场 `A_eff=40` 且全失败 | 可能 `cov_low` | `scope_blocked(no_response:A)`（⑥ 先于 ⑦） |

---

## 3. P0-2：全池失效证据的失败门槛

### 3.1 v0.8 的定义缺口

v0.8 §3.2：

```
has_fail_evidence(n,t) = ∃ g：最新有效结果 = fail ∧ … ∧ finished_at ∈ (t-W, t]
```

只要求"一次失败"，**未要求达到节点不可用门槛**；而 Z22 的初始数据写的是 `fail_streak≥3`（`T = settings.fail_threshold = 3`）。定义与测试不一致（P0-2.1），一次抖动就会被记成"该节点已失效"（P0-2.2）。

### 3.2 完整定义（五条件，缺一即不算证据）

```
has_fail_evidence(n,t, g) =
   ① n.fail_streak ≥ T                                  T = settings.fail_threshold（默认 3）
   ② n.fail_streak 的计数只累加"有效失败"：
        result.valid = 1
      ∧ result.mode = 'mihomo'
      ∧ result.failure_source ∉ ('engine','scheduler','system','target_incident')
      ∧ result.config_version = n.config_version
      ∧ result.rule_version   = active_rule_version(t)
   ③ 最新一次有效失败 finished_at ∈ ( t - W , t ]        （失败结果不得过期）
   ④ 不存在任何必需目标拥有新鲜有效 pass（否则节点属"部分可用"）
   ⑤ 该目标仍在必需目标集内（规则变更后移除的目标不计）
```

节点级：`has_fail_evidence(n,t) = ∃ g ∈ required_targets(n) : has_fail_evidence(n,t,g) ∧ ¬∃ 其他目标新鲜 pass`

**与 TCP / 系统故障的关系（P0-2.3）**：`engine`、`scheduler`、`system`、`target_incident` 四类 `failure_source` 与 `mode='tcp_only'` 的结果**不进入 `fail_streak`**。因此它们既不能把 `fail_streak` 抬到 `T`，也不能作为证据；它们在 `system_events` 与 `results(failure_source)` 中留痕，但不影响节点健康判定。

**`fail_streak` 的语义收紧**：它不再是"任意失败次数"，而是**连续有效失败次数**（任一次有效 pass 归零；无效/系统失败不改动）。这一点与 v0.8 一致，但 v0.9 把它写成 `has_fail_evidence` 的显式前提，而不是隐含约定。

### 3.3 四种失败状态的归类（P0-2.5 的测试基础）

| 情形 | `fail_streak` | 最新失败时间 | 归类 |
| --- | --- | --- | --- |
| 单次失败 | 1 | 窗口内 | `U_unk`（U5 未达门槛） |
| 两次失败 | 2 | 窗口内 | `U_unk`（U5） |
| 达到门槛 | ≥3 | 窗口内 | `F_ev` |
| 达到门槛但过期 | ≥3 | ≤ t-W | `U_unk`（U4 证据陈旧） |
| 达门槛但另一目标新鲜 pass | ≥3 | 窗口内 | `U_unk`（部分可用，④） |

`U_unk` 的子类编号（仅用于诊断与 UI，判定上等价）：`U1` 未观测、`U2` 结果过期、`U3` 无当前版本结果、`U4` 失败证据陈旧、`U5` 未达失败门槛。

### 3.4 全池证据条件（沿用 §2.4 的 ⑦）

`U_unk = A_scope \ (E ∪ F_ev)` 必须为空。因此"118 池、107 观测且都达门槛、11 个无证据"仍判 `scope_blocked(evidence_short)`；只有 118 个全部满足 ①–⑤ 才允许 `zero_health`。

### 3.5 与 `rep` 的关系（不重复）

| 条件 | 回答的问题 |
| --- | --- |
| `rep ≥ 0.90` | 我们看到的够不够多 |
| `U_unk = 0` | 没看到的那些是否也已确认失效（含门槛） |

两者独立，任一不成立 → `scope_blocked`。`rep` 达标**不能**替代 `fail_streak ≥ T`。

---

## 4. P0-3：任务应用的唯一权威流程

### 4.1 全文只保留这一套

v0.8 的 §4 与 §6 各写了一份流程（一份先校验后登记、一份先登记后判定），顺序不同（P0-3.1）。v0.9 合并为**唯一** `apply_result()`；§4.5 只给交错结果表，不再给第二份伪代码。

### 4.2 权威伪代码

```python
def apply_result(task_id, exec_cv, exec_rv, exec_target, verdict, finished_at):
    with tx():                                   # BEGIN IMMEDIATE（唯一读写边界）
        # ── 0. 幂等前置：任何状态变更之前识别重复 ──
        if exists("detection_task_runs", task_id=task_id):
            return "duplicate_ignored"           # 零写入、零事件、零状态变化

        # ── 1. 事务内重读任务 ──
        task = q("SELECT * FROM detection_tasks WHERE task_id=?", task_id)
        if task is None:
            insert_run(task_id, None, "invalid", reason="unknown_task"); return

        # ── 2. 执行侧与任务固化值三比对（cv / rv / target 各自独立）──
        if exec_cv != task.config_version:
            insert_run(task_id, task.node_id, "stale", reason="config_version"); return
        if exec_rv != task.rule_version:
            insert_run(task_id, task.node_id, "stale", reason="rule_version"); return
        if exec_target != task.target:
            insert_run(task_id, task.node_id, "stale", reason="target"); return

        # ── 3. 事务内重读节点与规则（不得用缓存对象）──
        node = q("SELECT * FROM nodes WHERE id=?", task.node_id)
        rule = q("SELECT version FROM detection_rules WHERE active=1")

        # ── 4. 权威校验 ──
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

        # ── 5. 登记（applied=1 仅对 pass/fail）──
        insert_run(task_id, task.node_id, verdict, applied=(verdict in ("pass","fail")))

        # ── 6. 状态更新（同一事务；stale/invalid 永不执行本步）──
        if verdict in ("pass", "fail"):
            update_target_state(node, task.target, verdict, finished_at)
```

**九条不可让渡的规则**：

| # | 规则 |
| --- | --- |
| 1 | 幂等检查在任何写之前（步骤 0），且与后续写在同一事务 |
| 2 | `task`、`node`、`rule` 全部事务内 `SELECT`，事务外只能持有 `task_id` 与执行侧五个标量 |
| 3 | `exec_cv` / `exec_rv` / `exec_target` 三者**分别**比对，不接受"合并成一个布尔"的写法 |
| 4 | `task.target` 与 `exec_target` 必须完全一致；`task.target` 还必须在 `required_targets(node)` 内（规则可能已移除该目标） |
| 5 | 所有 outcome 共用 `detection_task_runs.task_id` 主键（唯一闸门） |
| 6 | stale / invalid 只写登记行，不碰 `last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`state`、`node_state_history` |
| 7 | 同一 `task_id` 重复提交：零写入、零事件、零状态变化，返回 `duplicate_ignored` |
| 8 | 事务内任何分支失败 → 整事务回滚，登记行也不留（保证"要么完整登记，要么完全没发生"） |
| 9 | 不得在事务内切换 `PRAGMA foreign_keys`（见 §7） |

### 4.3 SQLite 并发行为（P0-3.9）

| 机制 | 行为 |
| --- | --- |
| `BEGIN IMMEDIATE` | 立刻取写锁；同一库同时只有一个写事务。两个 `apply_result` 天然串行 |
| `busy_timeout` | 建议 5s；超时返回 `SQLITE_BUSY`，应用层按"可重试"处理（重试会命中步骤 0 的幂等） |
| `detection_task_runs.task_id` 主键 | 即使有连接绕过写锁（如 `DEFERRED` 误用），第二次 `INSERT` 抛 `UNIQUE` 冲突 |
| `UNIQUE` 冲突处理 | 捕获后返回 `duplicate_ignored`，**不得**把它当成 `500`，也不得回滚后重试写入 |
| WAL | 读不阻塞写；本流程是"一个写事务内读+写"，读一致性由事务自身保证 |

### 4.4 幂等交错（唯一结果表）

| 交错 | run 行最终状态 | 节点状态 | 事件 |
| --- | --- | --- | --- |
| pass → pass | 第一次的 pass，`applied=1` | 已应用一次 | 1 条 |
| pass → stale | pass，`applied=1` | 不变（保持 pass 效果） | 0 条新增 |
| stale → pass | stale，`applied=0` | **不变**（永久无证据） | 1 条（首次 stale） |
| stale → stale | stale，`applied=0` | 不变 | 1 条 |
| invalid → pass | invalid，`applied=0` | 不变 | 1 条 |
| 不同 task 各自 stale | 各自独立一行 | 不变 | 各 1 条 |

> "stale → pass 仍为 stale" 是**有意**设计：一次在某版本上被判 stale 的任务，其结果永久不可用于该节点；要获得新证据必须**新建任务**。

---

## 5. 结果有效性函数 `fresh()`（沿用 v0.8，仅补门槛联动）

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

def fresh(n, g, now):
    return result_valid(n, g, target_state(n, g), now)
```

三处复用（健康、恢复、发布资格）不变。`fresh()` 与 §3 的 `has_fail_evidence()` 构成一对**对称定义**：一个要求"新鲜有效成功且全目标通过"，一个要求"达门槛的连续有效失败且无新鲜成功"。

---

## 6. presence 快照对齐（沿用 v0.8）

- 快照 `W_snap(D) = (D-7d 00:00, D 00:00]`，`snapshot_as_of` 精确到秒。
- 仅当请求窗口与快照窗口**完全一致**才可直接回退；任意时刻（如 `t=15:00`）不得用日快照替代。
- `U_before(t)` 一律用 log；`U7_prev(t)` 仅在 `t = 某日 00:00:00` 且 log 不足时允许快照；`median7` 只允许快照，缺行 → log 重放 → 仍不足 → `baseline_insufficient`。
- 降级：`baseline_insufficient` 时不判骤减、不判 rolling；`snapshot_mismatch` / `snapshot_lagging` / `tz_mismatch` 各自处理。

---

## 7. P0-4：SQLite 外键与迁移三期

### 7.1 目标 DDL（真实约束，不是"裸 TEXT"）

```sql
CREATE TABLE restore_authorizations (
  token            TEXT PRIMARY KEY,
  node_id          INTEGER NOT NULL,
  filtered_id      INTEGER NOT NULL,
  identity_id      INTEGER NOT NULL,
  fingerprint      TEXT    NOT NULL,
  tx_marker        TEXT    NOT NULL,
  issued_at        TEXT    NOT NULL,
  expires_at       TEXT    NOT NULL,
  consumed_at      TEXT,
  consumed_by_node INTEGER,
  CHECK (expires_at > issued_at)
);
CREATE UNIQUE INDEX uq_auth_live ON restore_authorizations(node_id)
  WHERE consumed_at IS NULL;
CREATE UNIQUE INDEX uq_auth_consumed_by ON restore_authorizations(consumed_by_node)
  WHERE consumed_by_node IS NOT NULL;

ALTER TABLE nodes ADD COLUMN restore_token TEXT
  REFERENCES restore_authorizations(token) ON DELETE RESTRICT ON UPDATE RESTRICT;
-- SQLite 允许 ADD COLUMN 带 REFERENCES，条件是默认值为 NULL、父键有 PK/UNIQUE
-- （本设计 token 即 PK），且加列时不要求关闭 foreign_keys。

CREATE UNIQUE INDEX uq_nodes_restore_token ON nodes(restore_token)
  WHERE restore_token IS NOT NULL;
```

### 7.2 v0.8 的错误：PRAGMA 不能在事务内切换

v0.8 §5.3 写"`PRAGMA foreign_keys=OFF` 仅限迁移事务内"。**这是错的**：SQLite 的 `foreign_keys` 是连接级开关，**在事务进行中设置无效**（官方语义：事务内修改该 PRAGMA 被静默忽略，事务结束后按当前值执行）——写成事务内关闭，会得到一个"以为关了、其实没关"或"以为恢复了、其实没恢复"的迁移（P0-4.1–P0-4.4）。

### 7.3 三期划分（唯一正确姿势）

**第一期：迁移事务开始之前**

```python
conn = pool.get()                       # 连接池钩子已设 foreign_keys=ON
orig_fk = conn.pragma("foreign_keys")   # 记为 1
need_off = requires_table_rebuild       # 只有重建 nodes 才需要关
if need_off:
    conn.execute("PRAGMA foreign_keys=OFF")   # 必须在 BEGIN 之前
conn.execute("PRAGMA busy_timeout=5000")
conn.execute("PRAGMA journal_mode=WAL")
backup_and_quick_check()
```

**第二期：迁移事务执行期间**

```python
conn.execute("BEGIN IMMEDIATE")
try:
    create_or_alter_tables()            # 建授权表、加列、建索引
    create_or_rebuild_triggers()        # 回池三支 + 既有五支（重建时全部重建）
    conn.execute("PRAGMA foreign_key_check")   # 只读检查，允许在事务内
    if rows(): raise MigrationError("fk_check failed")
    mark_journal("phase=ddl_done")
    conn.execute("COMMIT")
except:
    conn.execute("ROLLBACK")
```

**第三期：提交之后**

```python
if need_off:
    conn.execute("PRAGMA foreign_keys=ON")     # 恢复原值（orig_fk）
verify: conn.pragma("foreign_keys") == orig_fk
conn.execute("PRAGMA foreign_key_check")       # 提交后再查一次，必须为空
conn.close()
```

**五个阶段的边界必须写进迁移脚本注释**：`before-begin` / `in-tx` / `after-commit`；任何 PRAGMA 只允许出现在第一或第三期。

### 7.4 不关闭外键的方案（首选）

加列路径（`ALTER ... ADD COLUMN ... REFERENCES`）**无需关闭外键**即可完成：父键已存在、默认 NULL、不重建表。因此：

- **默认路径**：全程 `foreign_keys=ON`，只在第二期做 DDL，第三期做 `foreign_key_check`。
- **仅当**需要重建 `nodes`（C12 待确认）时才用"关闭—重建—恢复"，且必须三期分明。

| 路径 | 是否关 FK | 条件 |
| --- | --- | --- |
| A 加列 | 否 | 默认；`nodes` 不重建 |
| B 重建 | 是（仅第一期关、第三期恢复） | 仅在 C12 批准后 |

### 7.5 中断、回滚、重启（P0-4.7）

| 情形 | 状态 | 恢复方式 |
| --- | --- | --- |
| 第二期异常 | `ROLLBACK` 后库回到迁移前；`foreign_keys` 仍是第一期设的值 | 脚本 `finally` 必须恢复 `orig_fk`；进程崩溃则由下一次启动检测 |
| 提交前进程崩溃 | 事务未提交，SQLite 自动回滚；WAL 中无半成品 | 启动检查 `schema_migrations` 无 success 行 → 重跑迁移 |
| 提交后进程崩溃 | DDL 已生效，`pragma` 未恢复 | 启动钩子统一 `foreign_keys=ON`；迁移后置校验 `foreign_key_check` 为空 |
| 重建中途崩溃（`nodes_new` 已建、未改名） | 残留临时表 | 启动扫描 `nodes_new`/`*_old` → 按日志判定：未提交则 `DROP`，已提交则忽略 |
| 迁移日志 | `migration_journal(step, started_at, finished_at, result)` | 有 `step` 无 `finished_at` → 视为中断，重跑或回滚 |

**安全铁律**：迁移前必须备份；`quick_check` 不通过不迁移；`foreign_key_check` 不为空不写 `schema_migrations(success)`。

### 7.6 连接层要求（不变）

每个连接 `PRAGMA foreign_keys=ON`（SQLite 默认 OFF，这是"外键看起来没用"的头号原因）；连接池每条连接都设，不只是主连接；禁止为迁移便利长期全局关闭。

### 7.7 负向测试（FK1–FK5，沿用）

| # | 操作 | 预期 |
| --- | --- | --- |
| FK1 | 插入不存在的 `restore_token` | `FOREIGN KEY constraint failed` |
| FK2 | 删除仍被引用的授权行 | `FOREIGN KEY constraint failed`（RESTRICT） |
| FK3 | 普通节点携带格式合法但不存在的令牌 | 同 FK1 |
| FK4 | 令牌绑定 `node_id` 与插入 `id` 不同 | 触发器 ① `ABORT` |
| FK5 | 同一令牌插第二行 | `uq_nodes_restore_token` 冲突 |

---

## 8. P1-1：stable_id 冲突的六种边界

### 8.1 两路独立（沿用 v0.8）

`claim_candidate` = 历史归属（提示）；`node_assignment` = 本次应绑给谁（结论）。二者分别计算，冲突检查比较这两个不同源的量。

### 8.2 六种边界（唯一处理）

| # | 边界 | 判定依据 | 唯一处理 |
| --- | --- | --- | --- |
| B1 | 同一 `stable_id` 查到**多条**历史 claim | 同机场 live 行数 > 1；或 live + 非 live 混合 | 若同机场 live > 1 → **数据损坏**：该 id 全部 `hold`，事件 `claim_multi_live`，等待人工/迁移修复；若仅 1 live + N 非 live → 取**时间最新**的 live 为 `claim_candidate`，非 live 仅审计 |
| B2 | live claim 与配置证据冲突 | `config_ev = H1`（端点变） | 释放 live（`release_reason='reused'`）→ 新建 identity；**不得**沿用旧 identity |
| B3 | 历史 claim 已因 `reused` 释放 | `release_reason='reused'` | **禁止 readopt**；新建 identity；旧 id 不得回归（§9.2 情况 B） |
| B4 | 历史 claim 因 `absent` 释放 | `release_reason='absent'` ∧ 配置一致 | 允许 readopt：原 identity 复活或按 nodes 行是否存在分流（v0.8 §9.2） |
| B5 | 同一轮多节点竞争同一 identity | 两个不同 `stable_id` 的 `node_assignment.identity` 相同 | 保留 `occurrence_seq` 较小者绑原身份；其余按 P5 新建 + `ambiguous`；事件 `identity_multi_claim` |
| B6 | 无法确认身份 | 上述规则均不命中，或证据不足 2 轮 | **`hold`**：本轮不绑、不建、不删、不升版本；仅在 `identity_pending` 记观察；事件 `identity_ambiguous` |

**B6 的红线**：`hold` 状态下**不得**静默继承任何历史 identity。`hold` 节点的结果不参与评分、不参与发布，直到下一轮判定。

### 8.3 决策表（与 §8.2 完全同序）

| 序 | stable_id | 配置证据 | 端点 | claim | 结论 |
| --- | --- | --- | --- | --- | --- |
| 1 | 有 live（唯一） | F | 一致 | live | 延续原 identity |
| 2 | 有 live（唯一） | G1（`seen≥2 ∧ obs≥2`） | 一致 | live | 同 identity 升 `config_version` |
| 3 | 有 live（唯一） | 任意 | H1 | live | 释放 `reused` → 新建 identity（B2） |
| 4 | 无 live | 与历史一致 | 一致 | `absent` | readopt（B4） |
| 5 | 无 live | 任意 | 任意 | `reused` / `manual` | 新建（B3） |
| 6 | 无 id | — | — | — | P1–P4（指纹 → 稳定 id → 槽位） |
| 7 | 任一冲突且不可判定 | — | — | — | `hold`（B6） |

### 8.4 伪代码（无循环，与决策表同序）

```python
def assign_pull(pull):
    # 1 纯配置证据（不读 identity）
    for nd in pull.nodes:
        nd.config_ev = classify_config(nd)      # F / G1 / G2 / H1 / new
        nd.slot      = resolve_slot(nd)
    # 2 历史提示（只读）
    for nd in pull.nodes:
        nd.hint = claim_candidate(pull.airport, nd.stable_id) if nd.stable_id else None
    # 3 决策表 1–7
    for nd in pull.nodes:
        nd.assignment = resolve(nd.config_ev, nd.hint)
    # 4 整轮一致性（B1/B5）
    for sid, grp in group_by(pull.nodes, "stable_id"):
        if sid and len(grp) > 1:            mark_all(grp, "stable_id_duplicate")
        if sid and live_count(grp) > 1:     mark_all(grp, "claim_multi_live")
    for ident, grp in group_by(non_marked(pull.nodes), "assignment.identity"):
        if len(grp) > 1:                    keep_min_occ(grp); mark_rest(grp, "identity_multi_claim")
    # 5 只提交未标记者
    commit_bindings(non_marked(pull.nodes))
```

---

## 9. P0-5：多目标恢复聚合

### 9.1 v0.8 的问题

v0.8 §8.3 用 `recovery_state(node)` 概括，但恢复确认本质是**逐目标**的：G 曾故障、W 从未故障时，G 完成两次即应恢复；若用节点级单一状态，会出现"G 未确认而节点已 healthy"或"W 被无端要求两次"（P0-5.1–P0-5.5）。

### 9.2 两个层次：目标层事实，节点层投影

```sql
-- 目标层（每个 (node, target) 一行）
node_target_state(
  node_id, target,
  config_version, rule_version,
  last_result, last_pass_at, ttl,
  fail_streak,
  target_ever_fail  INTEGER NOT NULL DEFAULT 0,   -- 该目标是否曾发生有效失败
  recovery_state    TEXT CHECK(recovery_state IN ('none','observing','confirmed')),
  recovery_success_count INTEGER NOT NULL DEFAULT 0,
  first_success_at  TEXT,
  confirmed_at      TEXT
)
```

节点层不新增状态字段，由**投影**计算：

```
node_healthy(n,t) = lifecycle='active'
                  ∧ (∀ 必需目标 g：fresh(n,g,t))
                  ∧ (∀ 曾故障目标 g：recovery_state(g) = 'confirmed')
```

`nodes.state` 只是这个投影的结果缓存，不是独立的真相源。

### 9.3 逐目标规则（Q11 的唯一实现）

| 目标情形 | 要求 |
| --- | --- |
| `target_ever_fail = 0`（从未有效失败） | **不进入** `recovery_state`；只需当前 `config_version` + 当前规则下存在新鲜有效 pass |
| `target_ever_fail = 1` | 必须 `recovery_state='confirmed'`；确认条件 = **两次独立有效成功**，且 `第二次 - 第一次 ≥ 30 分钟` |
| 曾故障目标首次成功 | `observing`、`success_count=1`、`first_success_at=t1` |
| 第二次成功但间隔 < 30 分钟 | 仍 `observing`；`success_count` **不增加**（视为同一次事件的重试） |
| 第二次成功且间隔 ≥ 30 分钟 | `confirmed`、`success_count=2`、`confirmed_at=t2` |
| `observing` 期间出现**有效失败** | **重置**：`success_count=0`、`first_success_at=NULL`、`recovery_state` 回 `observing`（若失败达门槛则回 `unavailable`） |
| `confirmed` 之后再次有效失败 | 重新进入故障：`recovery_state='observing'`、`success_count=0`、`first_success_at=NULL`，`target_ever_fail` 保持 1 |
| 系统异常 / TCP-only / stale / 过期结果 | **不推进**任何计数（`fresh()` 已排除；`apply_result` 对 stale 不写状态） |

### 9.4 配置升级（P0-5.8）

| 升级前 | 升级后（`config_version+1`） |
| --- | --- |
| 目标从未故障 | 只需新版本下**一次**新鲜有效 pass（不要求两次） |
| 目标曾故障且已 `confirmed` | **恢复证据作废**：`recovery_state='observing'`、`success_count=0`、`first_success_at=NULL`；必须在**新版本**下重新完成两次（旧版本的两次成功不得混用） |
| 目标正在 `observing` | 计数清零，重新开始 |

**理由**：恢复证据是"这台机器在当前配置下能否稳定工作"的证据，配置变了就不是同一命题。而"是否曾故障"是历史事实，不随版本变化（`target_ever_fail` 保留，`ever_valid_fail` 保留）。

### 9.5 节点级聚合的执行顺序

```python
def aggregate_node(node, now):
    targets = required_targets(node)
    if not all(fresh(node, g, now) for g in targets):
        return downgrade(node)                      # 至少一个目标不新鲜 → 不进 healthy
    for g in targets:
        if target_state(node, g).target_ever_fail and \
           target_state(node, g).recovery_state != "confirmed":
            return set_state(node, "recovering")    # 任一曾故障目标未确认 → 不得 healthy
    return set_state(node, "healthy")
```

**关键点**：判定顺序是"先全员新鲜，再逐目标确认"；只要有一个曾故障目标停在 `observing`，节点只能是 `recovering`，**与其余目标多健康无关**（P0-5.5）。

### 9.6 测试（RG 组，六条必测 + 三条补充）

| # | 场景 | 预期 |
| --- | --- | --- |
| RG1 | G 曾故障、W 从未故障 | G 两次成功后 `healthy`；W 只需一次 pass，且**不出现** `recovery_state` 行 |
| RG2 | G、W 均曾故障 | 必须**分别**两次成功；只有一个确认时节点仍 `recovering` |
| RG3 | G 已确认、W 未确认 | 节点 `recovering`；G 的 `confirmed` 不被回退 |
| RG4 | 两次成功间隔 20 分钟 | `success_count` 仍 1；节点不 `healthy` |
| RG5 | 两次成功之间出现有效失败 | `success_count` 归零、`first_success_at=NULL`；需重新两次 |
| RG6 | 两次"成功"中一条为系统异常 / 一条为 TCP-only | 计数不推进（`fresh()` 拒绝）；节点不 `healthy` |
| RG7 | 配置升级前 G 已 `confirmed` | 升级后 G 回 `observing`、计数 0；旧版本两次成功不继承 |
| RG8 | 配置升级前 G 从未故障 | 升级后一次 pass 即可 |
| RG9 | 节点级 `healthy` 后 G 再次有效失败达门槛 | 节点回 `unavailable`；G `recovery_state='observing'`、计数 0 |

---

## 10. 迁移与兼容

### 10.1 变更清单（仅设计）

| 变更 | 对象 | 性质 |
| --- | --- | --- |
| `token` 升 PK、`consumed_by_node`、两唯一索引 | `restore_authorizations` | 新表 |
| `restore_token TEXT REFERENCES ... ON DELETE RESTRICT` | `nodes` | 加列带 FK |
| `uq_nodes_restore_token` | `nodes` | 唯一索引 |
| 回池三触发器 | — | 新建/重建 |
| `task_id` 主键 + `stale_reason` 扩枚举 | `detection_task_runs` | 结构 |
| `target_ever_fail` / `recovery_success_count` / `first_success_at` | `node_target_state` | 加列 |
| 零健康事件字段（`P_noresp` / `zero_denominator` / `U_unk` 分子分母） | `system_events` | 语义 |
| `migration_journal` | 新表（迁移期） | 可选 |

### 10.2 顺序（三期，见 §7.3）

```
[before-begin] 备份 + quick_check + 记录 foreign_keys 原值
[in-tx]        建授权表 → nodes 加列 → 建唯一索引 → 触发器 → detection_task_runs 扩列
               → node_target_state 加列 → foreign_key_check(只读)
[after-commit] 恢复 foreign_keys → 再查 foreign_key_check → 写 schema_migrations(success)
```

历史行默认值：`restore_token=NULL`（不触发 FK/触发器）、`target_ever_fail=0`、`recovery_success_count=0`。

### 10.3 兼容承诺

- 全部加法或语义收紧；四种格式、四 URL、UA、Token、两种 `sub_publish`、测速、评分、前端布局**未改**。
- 前端仅增量展示：`as_of`、`|A_eff|`/`rep`/`|F_ev|`/`|U_unk|` 基数、`scope_blocked` 原因码、run 的 `outcome`、逐目标恢复状态。

---

## 11. 测试矩阵

### 11.1 汇总

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务 T | 14 | T1–T7 + T8–T11（幂等）+ T12–T14（target 不匹配/并发） |
| 有效性 V | 4 | V1–V4 |
| 并发 CT | 3 | CT1–CT3 |
| 约束 FT | 23 | FT1–FT23 |
| 令牌 F/FK | 27 | F1–F22 + FK1–FK5 |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP12 |
| 零健康 Z | 30 | Z1–Z26 + Z27–Z30（零分母/无响应） |
| 恢复 RG | 9 | RG1–RG9 |
| 迁移 M | 10 | M1–M10 |

### 11.2 逐项详测

> 每条五段：**初始数据 / 步骤 / 预期数据库 / 预期业务 / 失败时必须保持不变**。

**Z27｜全局零分母（零健康）**

- 初始：机场 A、B 均 `enabled=1`、不在 `invalid_window`；两机场 `A_scope` 分别为 40、30；本轮 pull 因解析失败返回 **0 个节点**（`A_eff=∅`）。
- 步骤：执行评估。
- 预期库：事件 `zero_health_eval`，`state='zero_denominator'`、`Σ|A_eff|=0`、`cov_computed=false`（显式标记未调用 `cov`）。
- 预期业务：不判零健康；不启动 24h；active 订阅不变。
- 不变项：`empty_confirmed`、`publish_versions`、`nodes.state`。

**Z28｜单机场无响应阻断（全局分母非零）**

- 初始：机场 A 本轮返回 40 个（全失败、达门槛）；机场 B 本轮返回 0 个，但 B 在 3 小时前的 pull 中返回过 30 个（全 pass、结果仍新鲜）。
- 步骤：评估。
- 预期库：`state='scope_blocked'`、`reason='no_response:B'`；`P_noresp={B}`；未进入 `cov` 计算分支。
- 预期业务：不确认全局零健康（B 缺块）。B 的节点因结果新鲜仍可发布。
- 不变项：B 的 `node_target_state`、`publish_versions`。

**Z29｜零分母不因 `cov` 提前阻断**

- 初始：同 Z27，但机场 B 的 `cov` 若按公式计算将触发除零。
- 步骤：以断言模式执行（`cov` 被调用即抛 `AssertionError`）。
- 预期库：无异常抛出；`state='zero_denominator'`。
- 预期业务：证明 ⑤ 分支先于 ⑦ 分支。
- 不变项：一切。

**Z30｜全停用 vs 全异常**

- 初始（a）：A、B 均 `enabled=0`；初始（b）：A、B 均 `enabled=1` 且都在 `invalid_window`。
- 步骤：分别评估。
- 预期库：（a）`all_disabled`；（b）`scope_blocked(all_in_invalid_window)`；两者事件类型不同。
- 预期业务：（a）不发布；（b）维持 active，不误判停用。
- 不变项：`airports.enabled` 不被改写。

**FE1｜单次失败不构成证据**

- 初始：机场 A 池 118，`W_obs` 覆盖 107，其中 106 个 `fail_streak=3`，1 个 `fail_streak=1`（窗口内 fail）。
- 步骤：评估。
- 预期库：`F_ev=106`、`U_unk=12`（11 未观测 + 1 未达门槛）；`scope_blocked(evidence_short)`。
- 预期业务：不确认零健康。
- 不变项：该节点 `fail_streak` 仍为 1（不被评估改写）。

**FE2｜两次失败不构成证据**

- 初始：同上，但节点 `fail_streak=2`。
- 步骤：评估。
- 预期库：`U_unk` 含该节点（U5）；`scope_blocked`。
- 预期业务：同上。
- 不变项：`fail_streak=2`。

**FE3｜达到门槛构成证据**

- 初始：同上，节点 `fail_streak=3` 且最新 fail 在窗口内，其余 117 个同样。
- 步骤：连续两次评估（≥10 分钟）。
- 预期库：`U_unk=0`、`F_ev=118`、`rep=1.0`；`empty_confirmed` 一行，`confirmed_at` 只写一次。
- 预期业务：`zero_health`；24h 启动。
- 不变项：第二次评估不改 `confirmed_at`。

**FE4｜达门槛但证据过期**

- 初始：118 个均 `fail_streak=3`，但最新 fail 的 `finished_at = t-7h`（`W=6h`）。
- 步骤：评估。
- 预期库：全部落 `U_unk(U4)`；`scope_blocked(evidence_short:118)`。
- 预期业务：不确认（旧失败不能证明"现在"失效）。
- 不变项：`fail_streak` 不被清零。

**T12｜target 不匹配**

- 初始：`task_6` 的 `target='G'`；执行侧提交 `target='W'`。
- 步骤：调用 `apply_result`。
- 预期库：run 行 `stale/target`、`applied=0`；`node_target_state` 两行均不变。
- 预期业务：拒绝错位结果（防止 G 的结果写到 W）。
- 不变项：`last_pass_at`、`fail_streak`、`recovery_*`。

**T13｜重复提交（stale 两次）**

- 初始：`task_7` 首次登记 `stale(config_version)`。
- 步骤：原样提交两次。
- 预期库：run 行仍 1 条；`task_stale` 事件仍 1 条。
- 预期业务：`duplicate_ignored`，不抛异常。
- 不变项：全部健康字段。

**T14｜并发双写（`BEGIN IMMEDIATE` + UNIQUE）**

- 初始：`task_8` 未登记；两个连接同时调用 `apply_result`。
- 步骤：连接 1 先取写锁；连接 2 在 `busy_timeout` 内等待后重试。
- 预期库：run 行 1 条（`pass`、`applied=1`）；无重复事件。
- 预期业务：第二次返回 `duplicate_ignored`；若捕获 `SQLITE_BUSY` 则重试，重试命中步骤 0。
- 不变项：`success_streak` 只 +1 一次。

**RG1–RG9**（见 §9.6，同格式执行）

- 每条断言点：`node_target_state.recovery_state` / `success_count` / `first_success_at` / `confirmed_at`、`nodes.state`。
- 失败时不变项统一为：未参与目标的行、`fail_streak`、`ttl`、`ever_valid_fail`。

**M1–M10（迁移）**

- M1 加列路径全程 `foreign_keys=ON` 成功；M2 重建路径三期顺序（日志断言 `before-begin` 有 OFF、`in-tx` 无 PRAGMA、`after-commit` 有 ON）；M3 `foreign_key_check` 为空才写 success；M4 事务内异常 → 回滚且 `foreign_keys` 恢复；M5 提交后崩溃 → 启动 `foreign_keys=ON`；M6 残留 `nodes_new` 清理；M7 触发器数量核对（3+5）；M8 索引清单核对；M9 `migration_journal` 中断检测；M10 备份恢复演练。

---

## 12. v0.8 → v0.9 修订对照

| # | v0.8 | v0.9 | 章节 |
| --- | --- | --- | --- |
| P0-1 | `cov` 先算，零分母不可达；单机场 `A_eff=0` 无定义 | ⑤ 零分母前置、⑥ 单机场 `no_response` 阻断；`cov` 只在分母非零时算 | §2 |
| P0-2 | 有 fail 即证据，定义与 Z22 的 `fail_streak≥3` 不一致 | 五条件含 `fail_streak ≥ T`；系统/TCP 不入计数；U5 分类 | §3 |
| P0-3 | §4 与 §6 两套流程，顺序不同 | 唯一 `apply_result()`；幂等步骤 0；cv/rv/target 三项独立比对；SQLite 并发行为成文 | §4 |
| P0-4 | `PRAGMA foreign_keys=OFF` 写在事务内 | 三期划分；事务内禁止 PRAGMA；加列路径不关 FK；中断恢复表 | §7 |
| P0-5 | `recovery_state(node)` 概括多目标 | 目标层事实 + 节点层投影；逐目标重置规则；配置升级作废恢复证据 | §9 |
| P1-1 | 冲突边界散落 | 六种边界唯一处理 + 决策表同序 + `hold` 红线 | §8 |

---

## 13. P0/P1 关闭清单

| 来源 | 问题 | 处理 | 状态 |
| --- | --- | --- | --- |
| P0-1.1 | 单机场 vs 全局零分母未分 | §2.2 三层表 + §2.4 ⑤⑥ 分支 | 已关闭 |
| P0-1.2 | `cov` 先于零分母 | ⑤⑥ 在 ⑦ 之前；Z29 断言 `cov` 不被调用 | 已关闭 |
| P0-1.3 | 单机场无响应如何阻断 | `P_noresp` → `scope_blocked(no_response)` | 已关闭 |
| P0-1.4 | 全局无响应返回 `zero_denominator` | ⑤ 直接返回，附 `no_response_global` | 已关闭 |
| P0-1.5 | §2.3–§2.6 与 Z 测试不一致 | 状态表与分支一一对应；Z27–Z30 | 已关闭 |
| P0-2.1 | 门槛未写入定义 | `fail_streak ≥ T` 列为条件① | 已关闭 |
| P0-2.2 | 一次失败即失效 | FE1/FE2 明确不构成证据 | 已关闭 |
| P0-2.3 | 系统/TCP 可能计入 | 条件② 显式排除四类 `failure_source` 与 `tcp_only` | 已关闭 |
| P0-2.4 | 有新鲜 pass 仍记失效 | 条件④ | 已关闭 |
| P0-2.5 | 缺单次/两次/达门槛/过期测试 | FE1–FE4 | 已关闭 |
| P0-3.1 | 两套伪代码 | 全文仅 §4.2 | 已关闭 |
| P0-3.2 | 重复提交识别时机 | 步骤 0 | 已关闭 |
| P0-3.3 | 事务内重读 | 步骤 1/3 | 已关闭 |
| P0-3.4 | cv/rv/target 未分别比对 | 步骤 2 三独立分支 | 已关闭 |
| P0-3.5 | 缓存对象参与判定 | 九条规则第 2 条 | 已关闭 |
| P0-3.6 | target 只查一处 | 步骤 2 + 步骤 4 各查一次 | 已关闭 |
| P0-3.7 | outcome 闸门不统一 | 共用 `task_id` 主键 | 已关闭 |
| P0-3.8 | 重复提交重复更新 | 步骤 0 + 规则 7 | 已关闭 |
| P0-3.9 | 并发行为未说明 | §4.3 `BEGIN IMMEDIATE`/UNIQUE/BUSY/WAL | 已关闭 |
| P0-4.1 | 三期未分 | §7.3 before/in/after | 已关闭 |
| P0-4.2 | 事务内关 FK | 明令禁止 + M2 断言 | 已关闭 |
| P0-4.3 | 提交后恢复 FK | 第三期恢复 `orig_fk` 并校验 | 已关闭 |
| P0-4.4 | 把事务内 OFF 当生效 | 文档写明"事务内设置被忽略" | 已关闭 |
| P0-4.5 | 不关 FK 方案可行性 | 加列路径全程 ON | 已关闭 |
| P0-4.6 | `foreign_key_check` 要求 | 第二期与第三期各查一次，为空才 success | 已关闭 |
| P0-4.7 | 中断/回滚/重启恢复 | §7.5 五情形 + `migration_journal` | 已关闭 |
| P0-4.8 | 每连接 ON | §7.6 不变，长期关闭被禁止 | 已关闭 |
| P0-5.1 | 逐目标独立维护 | `node_target_state` 字段 | 已关闭 |
| P0-5.2 | 曾故障目标两次 30 分钟 | §9.3 | 已关闭 |
| P0-5.3 | 未故障目标不强制 | §9.3 首行 | 已关闭 |
| P0-5.4 | 节点 healthy 需全目标 | §9.2 投影 + §9.5 | 已关闭 |
| P0-5.5 | 一个未确认即不得 healthy | §9.5 `recovering` 分支 | 已关闭 |
| P0-5.6 | 中途失败是否重置 | §9.3 重置行 | 已关闭 |
| P0-5.7 | 系统/TCP/stale 不计入 | §9.3 末行 + RG6 | 已关闭 |
| P0-5.8 | 配置升级哪些重建 | §9.4 三行表 + RG7/RG8 | 已关闭 |
| P1-1 | 六种边界 | §8.2 B1–B6 + §8.3 同序表 | 已关闭 |

---

## 14. 待确认（不视为已批准）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` 表 | 是（若重建则走 §7.3 三期） | 未确认 |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口（6h / 最近 3 次） | 6h 优先 | 未确认（`W` 同时用作失败证据窗口） |
| C15 | `rep` 门槛（0.90 / 0.60） | 0.90 确认 | 未确认 |
| C16 | retired 回归是否复用原 identity | 允许（新建 config_version） | 未确认 |
| C17 | `U_unk` 是否可在连续 N 轮全量失败后降级 | 不建议 | 未确认 |

**仍需实机验证**：机场 `stable_id` 覆盖率；生产库重复配置比例；NAS `fsync`/`rename` 语义；presence log 与任务表 30 天体量；轮询周期分布（决定 C14/C15）。

---

## 15. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | `U_unk=0` 极严，轮询机场长期 `scope_blocked` | 设计意图（部分响应不得断言全池失效）；真故障由人工介入 | Z22/FE3 |
| 2 | 零分母与无响应混淆导致长期不告警 | ⑤⑥ 分支分离、原因码区分、UI 显式文案 | Z27–Z29 |
| 3 | `fail_streak` 门槛依赖 `T` 配置漂移 | `T` 只读 `settings.fail_threshold`，写入 `system_events` | FE1–FE3 |
| 4 | 迁移三期中途崩溃 | 备份 + journal + 启动钩子；`foreign_key_check` 双查 | M2–M6 |
| 5 | 逐目标恢复字段增多 | 只加 3 列，节点层由投影得出，不新增状态机 | RG1–RG9 |
| 6 | 唯一约束冲突被误当 500 | §4.3 捕获映射为 `duplicate_ignored` | T14 |

---

**v0.9 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**。C11–C17 全部待确认。文档交回最终设计审查；未获批准前不提交 P-1 实施计划、不进入任何阶段。
