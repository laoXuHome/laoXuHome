# NodePoolME 新架构总体设计方案 v0.8

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.7
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**修订依据**：v0.7 第七轮审查 P0（R1–R5）与补充修订（R6–R7）
**文档状态**：**待第八轮设计审查**（本文未自行认定通过）

---

## 修订索引（v0.7 → v0.8）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| R1 | 全局零健康参与集合：`P_enabled` / `P_eval` / `P_block` / 空池规则 | §2 | 重写（P0） |
| R2 | 全池失效证据与样本代表性分离 | §3 | 重写（P0） |
| R3 | 任务应用：事务内重读全部权威数据 | §4 | 重写（P0） |
| R4 | `nodes.restore_token` 的真实外键与迁移顺序 | §5 | 重写（P0） |
| R5 | stale 与正常结果共用同一幂等闸门 | §6 | 重写（P0） |
| R6 | stable_id 冲突的统一优先级与无循环伪代码 | §7 | 补充 |
| R7 | 首次健康验证与故障恢复分离 | §8 | 补充 |

未修订：Q1–Q12、30 天 missing、不改指纹、30 分钟 per-node + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件 + 两次独立确认、30 个可恢复版本、恢复两次有效成功间隔 ≥30 分钟、TCP-only 永不合格、四格式/四 URL/UA/Token/两种 `sub_publish`、评分算法、前端布局。**C11–C16 全部继续待确认，本轮未批准任何一项。**

---

## 0. 结论先行

第七轮指出的五个 P0 有一个共同形态：**先给结论找证据，而不是先有证据再下结论**。

| 问题 | 错误形态 | v0.8 的修正方向 |
| --- | --- | --- |
| R1 | `P_pub` 已排除异常机场，却又用"异常要阻断"约束它——集合自我矛盾 | 三个集合各司其职：**谁统计、谁阻断、谁只是被记录** |
| R2 | `rep ≥ 0.90` 被当成"全池失效"的充分条件 | **代表性**与**证据充分性**拆成两个独立条件，缺一即 `scope_blocked` |
| R3 | 事务外读 task/node，事务内只写 | 事务内重读**全部**权威数据并校验，缓存对象不参与决策 |
| R4 | 文档写"外键"，DDL 只有裸 `TEXT` | 给出真实 `REFERENCES` + 迁移顺序 + 五种负向测试 |
| R5 | stale 是旁路，只有正常结果有闸门 | **一张登记表、一个唯一闸门**，stale 也走它 |

v0.8 的统一原则：**任何"确认"必须有可指认的、落在统计窗口内的证据；任何"排除"必须有可区分的原因种类；任何"写入"必须在事务内用当次读到的值判断。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；`missing` 30 天（最短 7）；不改指纹算法；per-node 30 分钟 + 抖动；业务侧 90 分钟独立；测速 17:00–24:00 与 50MB；骤减"7 天中位降 ≥50% 且绝对减 ≥10" + 两次独立拉取确认；零健康最多保留上一版 24 小时、硬上限 72 小时；30 个完整可恢复版本；恢复需两次独立有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 永不合格；四格式 / 四 URL / UA 自适应 / Token 鉴权 / 两种 `sub_publish`；机场排除；评分算法；前端布局不改（仅增量展示）。

---

## 2. R1：全局零健康的参与集合

### 2.1 v0.7 的自相矛盾

v0.7 §2.3 写：

```
P_pub(t) = { a : enabled=1 ∧ airport_removed=0 ∧ 不在 invalid_window }
...
GlobalZeroHealth ⇔ ∀a ∈ P_pub : ZH1–ZH6
```

同一节 §2.2 的表格又要求"停用期（临时）机场…是否阻止确认：**是**"。但 `P_pub` 已经把 `invalid_window` 的机场剔除了——它不在 `P_pub` 里，`∀a ∈ P_pub` 就永远看不到它，**阻断条款在公式里不可达**（R1.1）。同时：

- 全部启用机场都在 `invalid_window` 时 `P_pub = ∅`，按 v0.7 会落到 `all_disabled`——把"系统故障"误判成"用户停用"（R1.2）；
- 空池机场没有规则，一个空、一个全挂时结论不稳定（R1.3）。

### 2.2 四个集合，各司其职

| 集合 | 定义 | 作用 |
| --- | --- | --- |
| `P_disabled` | `enabled=0 ∨ airport_removed=1` | **明确停用**。不进任何分母、不阻断、事件中单列 `excluded_disabled` |
| `P_enabled` | `enabled=1 ∧ airport_removed=0` | 用户仍希望它发布。是下面两个集合的全集 |
| `P_block` | `P_enabled` 中处于 `invalid_window`（引擎/调度/DB 异常）者 | **不参与正常健康统计，但阻断全局确认** |
| `P_eval` | `P_enabled \ P_block` | 参与零健康评估 |
| `P_nonempty` | `{ a ∈ P_eval : |A_scope(a,t)| > 0 }` | 真正有主体的机场 |
| `P_empty_verified` | `{ a ∈ P_eval : |A_scope|=0 ∧ 最近 7 天内存在 applied=1 且成功完成的拉取 }` | 空池**已核实**（机场确实没有节点，不是我们拉取失败） |
| `P_empty_unverified` | `{ a ∈ P_eval : |A_scope|=0 ∧ 无上述拉取 }` | 空池**未核实** → 阻断 |

**两句话记住口径**：

1. **统计用 `P_nonempty`**（有节点才有健康可言）；空池机场分母贡献为 0，只作记录。
2. **阻断用 `P_block ∪ P_empty_unverified ∪ {样本不足的 P_nonempty}`**（异常、空池未核实、样本不足，都阻断）。

### 2.3 机场侧证据条件

```
评估时点 t：一次只读事务快照，全部集合按 t 计算，事件写 as_of=t

A_scope(a,t) = { n : lifecycle='active' ∧ airport=a ∧ last_present_at ≥ t-7d }
A_eff(a,t)   = { n ∈ A_scope : last_seen_pull_id = 当前 pull }
W_obs(a,t)   = ⋃ A_eff over applied pulls in (t-W, t]
rep(a,t)     = |A_scope ∩ W_obs| / |A_scope|
E(a,t)       = { n ∈ A_scope : eligible_at(n,t) }                  ← 可发布
F_ev(a,t)    = { n ∈ A_scope : has_fail_evidence(n,t) }             ← 落在窗口内的有效失败
U_unk(a,t)   = A_scope \ (E ∪ F_ev)                                 ← 未知/过期/无证据
cov(a,t)     = |{ n ∈ A_eff : 每必需目标在 60 分钟内均有当前版本有效结果 }| / |A_eff|
```

机场条件（全部成立才可参与全局确认）：

| 编号 | 条件 | 不成立时的原因码 |
| --- | --- | --- |
| ZH1 | `|A_scope| > 0` | `empty`（是否阻断见 §2.2） |
| ZH2 | `rep ≥ 0.90`（代表性） | `rep_low` → 阻断 |
| ZH3 | `|A_eff| > 0 且 cov ≥ 0.90` | `cov_low` → 阻断 |
| ZH4 | `|E| = 0`（当前无可发布节点） | `has_eligible` → 不判定（正常） |
| ZH5 | `|U_unk| = 0`（**全池失效证据充分**，见 §3） | `evidence_short` → 阻断 |
| ZH6 | 不在 `invalid_window` | `invalid_window` → 阻断 |
| ZH7 | `|F_ev| = |A_scope|`（每一个都落在窗口内的失败证据） | `evidence_short` → 阻断 |

> ZH5 与 ZH7 是同一件事的两种写法（集合划分 vs 计数），实现只算一次；文档两处并列是为了让审查者能逐条核对。**ZH5/ZH7 的细节含义在 §3 定义，v0.8 明确它不是 `rep` 的推论。**

### 2.4 全局判定（优先级从高到低，短路）

```python
def evaluate_global_zero_health(t):
    # 一、全部明确停用
    if not P_enabled:                      return "all_disabled"

    # 二、全部启用机场都异常（绝不能算 all_disabled）
    if not P_eval:                         return "scope_blocked", "all_in_invalid_window"

    # 三、异常机场阻断（即便其余机场全挂）
    if P_block:                            return "scope_blocked", "invalid_window:" + list

    # 四、空池未核实阻断
    if P_empty_unverified:                 return "scope_blocked", "empty_unverified:" + list

    # 五、全部空池（且都已核实）
    if not P_nonempty:                     return "no_nodes"

    # 六、有节点但样本不足 / 证据不足
    for a in P_nonempty:
        if rep(a) < 0.90:                  return "scope_blocked", f"rep_low:{a}"
        if cov(a) < 0.90:                  return "scope_blocked", f"cov_low:{a}"
        if U_unk(a):                       return "scope_blocked", f"evidence_short:{a}:{len(U_unk)}"

    # 七、有可发布节点 → 正常（正常状态，不是零健康）
    if any(E(a) for a in P_nonempty):      return "normal"

    # 八、分母为空（无节点被本次返回）
    if sum(|A_eff(a)| for a in P_nonempty) == 0:
        return "zero_denominator"

    # 九、确认
    return "zero_health"
```

**关键差别**：`P_block` 的检查（第三）在"其余机场全挂"的判定之前——异常机场只要存在，`zero_health` 永不可达，24 小时计时永不启动。这就是 R1.1 要求的"异常阻断"在公式里真正可达。

### 2.5 状态表（含空池两种）

| 状态 | 条件 | 24h 计时 | 订阅行为 |
| --- | --- | --- | --- |
| `zero_health` | 上式第八步 | **启动** | 到期发 `minimal` |
| `scope_blocked` | 有 `P_block` / `P_empty_unverified` / `rep` 或 `cov` 不足 / `U_unk ≠ ∅` | **不启动** | 维持当前 active |
| `zero_denominator` | 有主体但本次全无节点（Σ|A_eff|=0） | 不启动 | 维持当前 active |
| `no_nodes` | `P_eval` 全为空池且已核实 | 不启动 | 视为"无节点可发"，不触发旧版保留 |
| `all_disabled` | `P_enabled = ∅` | 不启动 | 不发订阅（人工确认） |

**R1.2 落实**：`all_disabled` 只由"用户明确停用"触发；所有启用机场异常 → `scope_blocked(all_in_invalid_window)`。
**R1.3 落实**：一个空池（已核实）+ 另一个全失效 → `zero_health` 成立（空池贡献分母 0，且无主体可误判）；若空池未核实 → `scope_blocked`。

### 2.6 计时器

| 当前 | 事件 | 变化 |
| --- | --- | --- |
| 无 | `zero_health` | 写 `confirmed_at`（只写一次）、`deadline=+24h`、`hard=+72h` |
| 计时中 | `scope_blocked` | `paused` 累加，**不取消** |
| 计时中 | 任一口机场 `E ≠ ∅` | `canceled` |
| 到期 | 重验仍 `zero_health` | 发 `minimal` |
| `hard` | 未解除 | `manual_review`，停自动发布 |

---

## 3. R2：全池失效的证据充分性

### 3.1 v0.7 的跳跃

v0.7 写 `ZH5 |F_ev| = |A_scope ∩ W_obs|`，等价于"把未观测节点排除出等式，然后说全池都失败"。`rep ≥ 0.90` 只说明**观测覆盖率达标**，不说明**没观测到的那部分也失败了**（R2）。118 池、观测 107、剩 11 个既无有效成功也无有效失败时，v0.7 会得出"全池失效"——这是错误的。

### 3.2 六类节点划分（互斥完备）

```
A_scope = E ∪ F_ev ∪ U_unk            （三集互斥、并集为全集）

E     可发布：eligible_at 成立（所有必需目标新鲜有效 pass，当前版本、当前规则、非 TCP、非系统故障）
F_ev  有效失败：has_fail_evidence 成立
U_unk 证据未知，含四种子类（仅用于诊断与 UI 展示，判定上等价）：
        U1 未观测：n ∉ W_obs
        U2 结果过期：最新有效结果为 pass，但 last_pass_at + ttl ≤ t
        U3 无任何有效结果：从未有当前版本的 valid 结果
        U4 证据陈旧：最新有效结果为 fail，但 finished_at ≤ t - W
```

**`has_fail_evidence(n,t)` 的精确定义**：

```
has_fail_evidence(n,t) =
      ∃ 必需目标 g：latest_valid_result(g).last_result = 'fail'
   ∧ 该结果 config_version = n.config_version
   ∧ 该结果 rule_version   = active_rule_version(t)
   ∧ 该结果 mode = 'mihomo'
   ∧ 该结果 failure_source ∉ ('engine','scheduler','system','target_incident')
   ∧ 该结果 finished_at ∈ ( t - W , t ]                      ← 必须落在观测窗口内
   ∧ 不存在任何必需目标拥有新鲜有效 pass（否则节点属于"部分可用"）
```

三点必须同时成立：**是失败**、**是本版本的失败**、**是本窗口内的失败**。缺一条即落入 `U_unk`（U2/U4）。第四个附加条件（"没有任何新鲜 pass"）用于防止"一个目标挂着、另一个目标还新鲜"的节点被记成已失效——这种节点落在 `U_unk`，会阻断确认，这是保守且正确的方向。

### 3.3 代表性 ≠ 证据充分（两个独立条件）

| 条件 | 度量 | 回答的问题 | 不成立时 |
| --- | --- | --- | --- |
| **代表性** `rep ≥ 0.90` | 观测覆盖比例 | "我们看到的够不够多" | `scope_blocked(rep_low)` |
| **证据充分性** `U_unk = 0` | 全池逐节点证据 | "没看到的那些是否也已确认失效" | `scope_blocked(evidence_short)` |

两个条件**同时**成立才允许 `zero_health`。只用 `rep` 是必要条件，不是充分条件——这正是 R2 的核心。

### 3.4 118 / 107 / 11 的答案

> 118 个长期节点，本轮与近期窗口观测到 107 个，107 个全部失败，剩 11 个**既无有效成功也无有效失败证据**。
>
> **不能确认整个机场零健康。** 结果必须是 `scope_blocked(evidence_short: unobserved=11)`。
>
> 理由：那 11 个的"无证据"可能来自（a）机场轮换没返回它们、（b）它们其实健康但没被检测、（c）结果过期。三种都与"失效"不相容。`rep = 107/118 = 0.907 ≥ 0.90` 只说明覆盖率过了门槛，**不构成这 11 个已失效的证据**。

**何时可以确认**：同一机场在窗口内被观测到全部 118 个且都有窗口内失败证据（多轮覆盖场景），`rep = 1.0`、`U_unk = 0` → `zero_health`。若轮换周期长于 `W`，则长期只能停留在 `scope_blocked`——这是**正确**的行为：轮询机场的部分响应永远不足以断言全池失效，因此**永远不会**由部分响应触发 24 小时旧订阅保留。

### 3.5 与发布资格的联动

- `E ≠ ∅` → `normal`（不存在"零健康"），无需看证据；
- `E = ∅` 且 `U_unk ≠ ∅` → `scope_blocked`；
- `E = ∅` 且 `U_unk = ∅` 且 ZH1–ZH7 全成立 → `zero_health`。

---

## 4. R3：任务应用在事务内重读全部权威数据

### 4.1 v0.7 的竞争窗口

v0.7 §4.3：

```python
task = db.one("detection_tasks", task_id=...)   # ← 事务外
...
with tx():
    if task.config_version != node.config_version:   # ← node 也是事务外的旧对象
```

读与写之间隔着任意时长：读时 cv=1，写时节点已升到 cv=2，`node` 仍是旧对象 → 用旧值比较、按旧值写状态（R3）。规则版本同理；`lifecycle` 在两者之间进入 `missing`/`retired` 也检测不到。

### 4.2 唯一正确的执行顺序

```python
def apply_result(task_id, exec_cv, exec_rv, target, verdict, finished_at):
    with tx():                                  # BEGIN IMMEDIATE，唯一的读+写边界
        # ① 事务内重读任务
        task = q("SELECT * FROM detection_tasks WHERE task_id=?", task_id)
        if task is None:
            insert_run(task_id, None, "invalid", "unknown_task"); return
        # ② 执行版本与任务固化版本必须一致（防篡改）
        if (exec_cv, exec_rv) != (task.config_version, task.rule_version):
            insert_run(task_id, task.node_id, "invalid", "exec_version_mismatch"); return
        # ③ 幂等闸门（唯一键，见 §6）
        if exists("detection_task_runs", task_id):
            return                              # 已登记，零变化、零事件
        # ④ 事务内重读节点与规则
        node = q("SELECT * FROM nodes WHERE id=?", task.node_id)
        rule = q("SELECT version FROM detection_rules WHERE active=1")
        # ⑤ 六项校验，全部用事务内读到的值
        if node is None or node.identity_id != task.identity_id:
            insert_run(task_id, task.node_id, "stale", "identity"); return
        if node.lifecycle != "active":
            insert_run(task_id, task.node_id, "stale", "lifecycle"); return
        if task.target not in required_targets(node):
            insert_run(task_id, task.node_id, "stale", "target"); return
        if task.config_version != node.config_version:
            insert_run(task_id, task.node_id, "stale", "config_version"); return
        if task.rule_version != rule.version:
            insert_run(task_id, task.node_id, "stale", "rule_version"); return
        # ⑥ 正常登记 + ⑦ 目标状态更新（同一事务）
        insert_run(task_id, task.node_id, verdict, None, applied=1)
        update_target_state(node, target, verdict, finished_at)
```

**五条不可让渡的规则**：

1. 事务外**只允许**持有 `task_id` 与"执行侧数据"（`exec_cv`/`exec_rv`/`target`/`verdict`/`finished_at`）。
2. `node` 对象必须在事务内 `SELECT`，且校验与写入使用同一个对象实例。
3. `rule_version` 必须在事务内读，不得用进程内缓存（缓存可能比 DB 旧）。
4. 任何校验失败 → 只写 `stale`/`invalid` 登记，**不碰** `last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`state`、`node_state_history`。
5. `insert_run` 与 `update_target_state` 必须在同一 `BEGIN IMMEDIATE` 内；任一失败整体回滚。

### 4.3 并发测试（详测见 §10）

| # | 交错 | 断言 |
| --- | --- | --- |
| CT1 | 读到 cv=1 后，另一连接把节点升到 cv=2，再提交旧结果 | `stale/config_version`，cv2 状态不变 |
| CT2 | 读到 rule=3 后规则升到 4，再提交 | `stale/rule_version` |
| CT3 | 读到 `active` 后节点转 `missing`/`retired`，再提交 | `stale/lifecycle`，无状态变化 |

---

## 5. R4：`restore_token` 的真实外键

### 5.1 v0.7 的问题

v0.7 正文写"令牌成为节点行的外键引用"，DDL 却是：

```sql
ALTER TABLE nodes ADD COLUMN restore_token TEXT;   -- 裸 TEXT，没有 REFERENCES
```

名不副实（R4.1）。SQLite 不允许事后 `ADD CONSTRAINT`，必须选择**加列带 FK**或**重建表**，并明确顺序。

### 5.2 方案：加列带真实 `REFERENCES`（P-1 一次完成）

`ALTER TABLE ... ADD COLUMN` 允许列定义里带 `REFERENCES`，前提是默认值为 `NULL` 且父键有唯一索引。因此先把授权表的 `token` 升为**主键**（新表，无迁移负担），再生效 `nodes` 的引用列：

```sql
-- ① 授权表：token 作为主键（父键必须有 PK 或 UNIQUE）
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

-- ② 节点列：真实外键，ON DELETE RESTRICT（删除被引用的授权直接报错）
ALTER TABLE nodes ADD COLUMN restore_token TEXT
  REFERENCES restore_authorizations(token) ON DELETE RESTRICT ON UPDATE RESTRICT;
-- SQLite 允许 ADD COLUMN 带 REFERENCES，条件是：默认值为 NULL 且父键已有唯一索引/PK；
-- 且加列时若 foreign_keys=ON，必须保持默认 NULL（本设计满足）。

-- ③ 一张令牌只能出现在一行 node 上
CREATE UNIQUE INDEX uq_nodes_restore_token ON nodes(restore_token)
  WHERE restore_token IS NOT NULL;

PRAGMA foreign_key_check;      -- 迁移后必须为空
PRAGMA foreign_keys = ON;      -- 每个连接都必须开（见 §5.4）
```

### 5.3 顺序与依赖（若 P0 需要重建 `nodes`）

| 步 | 操作 | 前置 |
| --- | --- | --- |
| 1 | 备份 + `quick_check` + 探针 | — |
| 2 | 建 `restore_authorizations` + 两个唯一索引 | — |
| 3 | `ALTER nodes ADD COLUMN restore_token ... REFERENCES` | 步 2 的 PK |
| 4 | 建 `uq_nodes_restore_token` | 步 3 |
| 5 | 建回池三触发器（①校验 ②消费 ③限预留） | 步 3/4 |
| 6 | `foreign_key_check` + 负向测试 FK1–FK5 | 步 5 |
| 7 | 写 `schema_migrations(success)` | 全部 |

若因 C12 需要重建 `nodes`：**顺序必须是**（a）`PRAGMA foreign_keys=OFF` 仅限迁移事务内、`foreign_keys` 原值记录；（b）建 `nodes_new`（列定义内联 `REFERENCES`）；（c）`INSERT ... SELECT`；（d）`DROP nodes`；（e）`ALTER nodes_new RENAME TO nodes`；（f）重建**全部**索引与**全部**触发器（含 v0.5/v0.6 的 5 支 + 回池 3 支）；（g）`foreign_key_check`；（h）恢复 `PRAGMA foreign_keys` 原值。**重建后必须核对触发器数量与名称清单**，遗漏一个等于静默失去约束。

### 5.4 连接层要求

- 每个连接 `PRAGMA foreign_keys=ON`（SQLite 默认 **OFF**，这是最常见的"外键看起来没用"的成因）。
- 连接池初始化钩子统一设置；`foreign_keys` 是**连接级**的，池里每条连接都要设，不能只在建立主连接时设一次。
- 迁移脚本关闭检查必须**限定在迁移事务内且成对恢复**，禁止全局关闭。

### 5.5 负向测试（FK1–FK5）

| # | 操作 | 预期 |
| --- | --- | --- |
| FK1 | 插入 `restore_token='nonexistent'` 的节点 | `FOREIGN KEY constraint failed` |
| FK2 | 删除仍被节点引用的授权行 | `FOREIGN KEY constraint failed`（RESTRICT） |
| FK3 | 普通节点携带无效令牌（格式合法但不存在） | FK1 同 |
| FK4 | 令牌绑定的 `node_id` 与插入 `id` 不同 | 触发器 ① `ABORT` |
| FK5 | 同一令牌插第二行 | `uq_nodes_restore_token` 冲突 |

---

## 6. R5：stale 与正常结果共用同一幂等闸门

### 6.1 v0.7 的漏洞

v0.7 只有在"版本校验通过"之后才 `INSERT INTO detection_task_runs`；`record_stale()` 是另一条路径，**没有唯一约束保护**。于是：同一 stale 任务重投两次 → 两个 run 行、两条事件；先 stale 后 pass → pass 会把状态改掉（R5.1–R5.3）。

### 6.2 一张表、一个闸门

```sql
CREATE TABLE detection_task_runs (
  task_id            TEXT PRIMARY KEY,          -- 唯一闸门：无论 outcome 是什么
  node_id            INTEGER,                   -- unknown_task 时可为 NULL
  outcome            TEXT NOT NULL CHECK(outcome IN ('pass','fail','invalid','stale')),
  stale_reason       TEXT CHECK(stale_reason IN
                       ('config_version','rule_version','identity','lifecycle','target',
                        'exec_version_mismatch','unknown_task')),
  exec_config_version INTEGER,
  exec_rule_version   INTEGER,
  finished_at         TEXT NOT NULL,
  applied             INTEGER NOT NULL DEFAULT 0 CHECK(applied IN (0,1)),
  recorded_at         TEXT NOT NULL
);
```

**规则**：`apply_result` 的**第一件事**就是尝试登记（`INSERT OR IGNORE` 语义），无论后面结论是 pass/fail/stale/invalid：

```python
with tx():
    task = q("detection_tasks", task_id)                 # 事务内
    run  = q("detection_task_runs", task_id)
    if run is not None:                                  # 任何 outcome 都已登记 → 直接返回
        return "duplicate_ignored"
    # 并发兜底：两个连接同时看到"无行"时，靠 task_id 主键的 UniqueViolation 捕获，
    # 同样返回 duplicate_ignored（BEGIN IMMEDIATE 已串行化，此分支仅作防御）
    outcome, reason = decide(task, node=..., rule=...)    # 事务内读
    insert_run(task_id, outcome, reason, applied=(outcome in ('pass','fail')))
    if outcome in ('pass','fail'):
        update_target_state(...)
```

要点：

- **先占位，再判定**：`task_id` 主键在事务开始时即被占住（同一事务内 `INSERT` 后判定，判定失败则回滚整事务；若判定为 stale，占位行即最终行）。
- **同一 `task_id` 只能有一个 outcome**：第一次登记为 pass / fail / invalid / stale，后续任何提交（包括换 outcome）一律 `duplicate_ignored`，零事件、零状态变化。
- **stale 不产生重复事件**：事件只在**首次登记**成功时写一次。
- **stale 永不写状态**：`applied=0` 即声明"本行不构成任何健康证据"；`update_target_state` 只对 `applied=1` 调用。

### 6.3 四种交错

| 交错 | 结果 |
| --- | --- |
| stale → stale（同 task） | 第二次 `duplicate_ignored`；run 行只有一条；事件一条 |
| stale → pass（同 task） | 第二次被忽略；**仍为 stale**；节点状态保持"无证据" |
| pass → stale（同 task） | 第二次被忽略；保持 pass 已应用的状态；不写 stale 事件 |
| 不同 task 分别 stale | 各自独立登记（`task_id` 不同），互不覆盖 |

> 注意 "stale → pass 仍为 stale" 是**有意**的：任务一旦在某个版本上被判 stale，其结果就永久不可用于该节点；要拿到新证据只能**新建任务**。这避免了"重投一次就洗白"的路径。

---

## 7. R6：stable_id 冲突的统一优先级

### 7.1 为什么必须两路独立

`claim_candidate` 回答"这个 `stable_id` 历史上属于谁"；`node_assignment` 回答"本次响应里这台机器应该绑到谁"。**前者是提示，不是结论**。若先取 claim 的 identity 当结论，再用它与自己比较，冲突永远为假（v0.7 §8.1 已指出，R6 要求补全决策表与无循环伪代码）。

- `node_assignment` **独立计算的目的**：让"配置证据"与"历史归属"成为两个可分辨的输入，从而能区分**真实冲突**（同 id 换了机器）与**正常延续**（同 id 同一机器、配置微调）。若只有一路，二者不可分辨。

### 7.2 决策表（唯一优先级）

| 序 | stable_id | 配置证据 | 端点 | claim 状态 | 结论 |
| --- | --- | --- | --- | --- | --- |
| 1 | 有 live claim | 一致（F） | 一致 | live | **延续原 identity**，`seen_count+1` |
| 2 | 有 live claim | 变化已确认（G1：`seen_count≥2 ∧ observed_count≥2`） | 一致 | live | **同 identity 升 config_version** |
| 3 | 有 live claim | 任意 | 变化已确认（H1） | live | **同 id 不同机器**：释放 live claim（`reused`）→ 新建 identity |
| 4 | 无 live claim | 与历史一致 | 一致 | 历史 `absent` 释放 | **readopt**（§9.2 情况 A/B） |
| 5 | 无 live claim | 任意 | 任意 | 历史 `reused` / `manual` | **不得 readopt**（新 identity） |
| 6 | 无 id | — | — | — | 按 P1–P4：指纹 → 稳定 id → 槽位 |
| 7 | 冲突不可判定 | — | — | — | `identity_ambiguous`，本轮 `hold` |

### 7.3 无循环伪代码

```python
def assign_pull(pull):
    nodes = pull.nodes
    # 阶段 1：纯配置证据，完全不看 claim
    for nd in nodes:
        nd.config_ev  = classify_config(nd)       # F / G1 / G2 / H1 / new
        nd.slot       = resolve_slot(nd)          # 机场内槽位（P5）
    # 阶段 2：取历史提示（只读，不作结论）
    for nd in nodes:
        nd.hint = claim_candidate(pull.airport, nd.stable_id) if nd.stable_id else None
    # 阶段 3：按决策表求 assignment（结果是"应当绑谁"，不是"claim 说绑谁"）
    for nd in nodes:
        nd.assignment = resolve(nd.config_ev, nd.hint)     # 表 1–6
    # 阶段 4：整轮一致性（此时才有资格谈冲突）
    for sid, group in group_by(nodes, "stable_id"):
        if sid and len(group) > 1:  mark_all(group, "stable_id_duplicate")     # C1
    for ident, group in group_by([n for n in nodes if n.assignment.identity], "assignment.identity"):
        if len(group) > 1:  keep_min_occurrence(group), mark_rest(group, "identity_multi_claim")  # C2
    for nd in nodes:
        if nd.hint and nd.hint.live and nd.assignment.identity != nd.hint.identity:
            mark(nd, "stable_id_conflict")                                       # C3
    # 阶段 5：只对未被 mark 的节点提交绑定
    commit_bindings([n for n in nodes if not n.marked])
```

**无循环的三条结构保证**：

1. 阶段 1 只读 `params_hash` / `server` / `port` / `display_name`，不读 `identity`；
2. 阶段 3 的 `resolve()` 只接受"配置证据 + hint"，返回 `assignment`，不读 `nd.identity`；
3. 阶段 4 的比较对象是 `assignment` 与 `hint`，两者不同源，因此比较有意义。

### 7.4 冲突与延续的判别（R6 关键）

| 现象 | 是冲突还是延续 | 判据 |
| --- | --- | --- |
| 同 id、同端点、仅 `display_name` 变 | **延续** | F 级（名称不参与指纹） |
| 同 id、同端点、`server/port` 变且连续 2 轮一致 | **延续 + 升版本** | G1 |
| 同 id、端点变（`server` 或出口变化） | **冲突（换机器）** | H1 |
| 同 id 但配置与历史完全不符且只出现 1 轮 | **pending 观察** | `seen_count<2`，不绑不升 |
| 两个不同 id 指向同一 identity | **冲突（重复条目）** | C2 |

---

## 8. R7：首次健康验证与故障恢复分离

### 8.1 两种"通过"不能同一标准

v0.7 `I30` 只写"回归后第一次检测 pass，不直接 healthy"——但没区分：

- **从未故障**的 `unknown` 节点（新节点、配置升级后、retired 复活后）：第一次全目标通过就该 `healthy`；
- **曾经故障**的节点（`unavailable` 之后）：必须 Q11 两次独立有效成功、间隔 ≥30 分钟。

若把两者都要求两次成功，会让新节点白等一个周期；若都不要求，则故障节点一次成功就洗白（R7）。

### 8.2 故障史的唯一载体

```sql
-- nodes 上（身份级，不随 config_version 清零）
ever_valid_fail    INTEGER NOT NULL DEFAULT 0   -- 是否发生过"有效失败"
fault_episode_id   TEXT                         -- 当前故障事件的标识
episode_started_at TEXT
```

`ever_valid_fail` **不因配置升级、恢复成功而清零**（只在人工重建身份时随新 identity 归零）。

### 8.3 判定规则

```python
def evaluate_node(node, now):
    if not all(fresh(node, g, now) for g in required_targets(node)):
        return unchanged(node)

    if node.ever_valid_fail == 0 and node.state == "unknown":
        # 首次健康：一次全目标有效通过即可
        return set_state(node, "healthy", reason="first_health")

    if node.state in ("unavailable", "recovering") or node.ever_valid_fail == 1:
        # 故障恢复：两次独立有效成功，间隔 ≥ 30 分钟
        if recovery_state(node).confirmed_count < 2 or \
           now - recovery_state(node).first_success_at < 30 * MINUTE:
            return set_state(node, "recovering")
        return set_state(node, "healthy", reason="recovered")
```

**补充约束**：

| 规则 | 说明 |
| --- | --- |
| 首次健康证据只能是 `fresh()` 通过的结果 | TCP-only、系统异常、stale 一律不算（`fresh()` 已排除） |
| `ever_valid_fail=0` 的 `healthy` 节点，短暂失败后回到 pass | 走 `healthy → observe → healthy`，**不**进入 `recovering`（未发生有效失败不算故障） |
| 从未故障的**目标**不得进入 `recovery_state` | `recovery_state` 只在 `ever_valid_fail=1` 且该目标曾有效失败时创建 |
| 配置升级后（`cv+1`） | `state` 重置为 `unknown`，但 `ever_valid_fail` 保留：曾故障 → 仍需两次；未曾故障 → 一次通过即可 |
| retired 复活（§9.2） | 情况 A 复用 identity → 沿用 `ever_valid_fail`；情况 B 新 identity → 归零（新身份无故障史，但需一次全通过） |

### 8.4 三个独立测试（VH1–VH3）

| # | 场景 | 预期 |
| --- | --- | --- |
| VH1 | 新节点，全目标首次 pass | 一次转 `healthy`；`recovery_state='none'` |
| VH2 | 故障节点（`ever_valid_fail=1`），一次 pass | 转 `recovering`，第 2 次 pass（≥30 分钟）后 `healthy` |
| VH3 | 配置升级后 `unknown`，升级前未曾故障，一次 pass | 一次转 `healthy`；若升级前曾故障 → 仍需两次 |

---

## 9. 迁移与兼容

### 9.1 变更清单（仅设计）

| 变更 | 对象 | 性质 |
| --- | --- | --- |
| `token` 升主键、`consumed_by_node`、两个唯一索引 | `restore_authorizations` | 新表定义 |
| `restore_token TEXT REFERENCES ... ON DELETE RESTRICT` | `nodes` | 加列带 FK |
| `uq_nodes_restore_token` | `nodes` | 唯一索引 |
| `detection_task_runs` 扩列 + `task_id` 主键 | 已有表 | 结构 |
| `nodes.ever_valid_fail` / `fault_episode_id` | `nodes` | 加列（默认 0/NULL） |
| 回池三触发器 | — | 重建 |
| 零健康事件字段（`P_block` / `P_empty_*` / `U_unk` 基数） | `system_events` | 语义 |

### 9.2 顺序

```
备份 → quick_check → 探针(S1 才继续)
→ 建/改 restore_authorizations（token PK + 两索引）
→ nodes 加 restore_token（带 FK）
→ 建 uq_nodes_restore_token
→ 重建回池三触发器
→ detection_task_runs 扩列
→ nodes 加 ever_valid_fail/fault_episode_id（历史行 0）
→ foreign_key_check 必须为空
→ FK1–FK5 / CT1–CT3 / VH1–VH3 临时库跑通
→ schema_migrations(success)
```

### 9.3 兼容承诺

- 全部加法；历史节点 `restore_token=NULL`，不触发任何 FK/触发器。
- 四种格式、四 URL、UA、Token、两种 `sub_publish`、测速、评分、前端布局**未改**。
- 前端仅增量展示：`as_of`、`E`/`F_ev`/`U_unk` 基数、`P_block` 列表、`scope_blocked` 原因码、run 的 `outcome`。

---

## 10. 测试矩阵

### 10.1 汇总

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务幂等 T | 11 | T1–T7 + T8–T11（stale 幂等四项） |
| 有效性 V | 4 | V1–V4 |
| 并发 CT | 3 | CT1–CT3 |
| 约束 FT | 23 | FT1–FT23 |
| 过滤/令牌 F | 27 | F1–F22 + FK1–FK5 |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP12 |
| 零健康 Z | 26 | Z1–Z21 + Z22–Z26 |
| 首次健康 VH | 3 | VH1–VH3 |
| 迁移 M | 10 | M1–M10 |

### 10.2 逐项详测

> 每条五段：**初始数据 / 操作步骤 / 预期数据库 / 预期业务 / 失败时必须保持不变**。

**Z22｜118 / 107 / 11：代表性达标但证据不足**

- 初始：机场 A 长期池 `A_scope=118`；`W_obs` 覆盖 107（`rep=0.907`）；107 个节点 `fail_streak≥3`、最新有效结果为 fail 且 `finished_at ∈ (t-W,t]`；剩 11 个：5 个 `U1 未观测`、4 个 `U2 结果过期（pass 但 ttl 已过）`、2 个 `U3 无当前版本结果`。
- 步骤：执行一次零健康评估（只读事务，`t`）。
- 预期数据库：`system_events` 一条 `zero_health_eval`，`as_of=t`，`rep=0.907`、`|E|=0`、`|F_ev|=107`、`|U_unk|=11`、`scope_blocked_reason='evidence_short'`；无 `empty_confirmed`；`publish_versions` 无新行。
- 预期业务：全局 `scope_blocked`；**不启动 24h**；active 订阅继续。
- 不变项：`publish_versions` 指针、`empty_confirmed` 任何行、订阅产物。

**Z23｜118 全观测全失败（对照组）**

- 初始：同上，但 `W_obs` 覆盖全部 118，118 个都有窗口内失败证据（多轮累积）。
- 步骤：连续两次评估，间隔 ≥10 分钟。
- 预期数据库：一条 `empty_confirmed(state='counting', confirmed_at=首次, immutable=1)`；第二次评估 `confirmed_at` 不变；`U_unk=0`、`rep=1.0`。
- 预期业务：`zero_health`；24h 计时启动；到期发 `minimal`。
- 不变项：第二次评估不得改写 `confirmed_at` / `deadline`。

**Z24｜全部启用机场都在 invalid_window**

- 初始：机场 A、B 均 `enabled=1`、`airport_removed=0`、均处于 `invalid_window`（引擎异常）；两机场池内节点上次结果均 fail。
- 步骤：评估。
- 预期数据库：`system_events` 记 `scope_blocked(all_in_invalid_window)`；`P_eval=∅`、`P_block={A,B}`；**无** `all_disabled` 事件。
- 预期业务：不判 `all_disabled`（不得理解为用户停用）；不启动 24h；不发任何订阅变更。
- 不变项：`airports.enabled` 不被改写；`publish_versions` 不变。

**Z25｜一个机场空池（已核实）+ 另一个机场全失效**

- 初始：机场 A `A_scope=0`，但 6 小时内有 `applied=1` 的成功拉取；机场 B 池 40 全失败且窗口内证据齐全、`rep=1.0`。
- 步骤：评估。
- 预期数据库：`P_empty_verified={A}`、`P_nonempty={B}`；分母只算 B；事件 `airport_empty_excluded=['A']`；结果 `zero_health`。
- 预期业务：确认零健康（A 无节点可发，不影响结论）；24h 启动。
- 不变项：A 不得被标为 `disabled` 或删除。

**Z26｜一个机场空池（未核实）+ 另一个机场全失效**

- 初始：机场 A `A_scope=0` 且 7 天内无成功 applied 拉取（拉取持续失败）；机场 B 全失败且证据齐全。
- 步骤：评估。
- 预期数据库：`scope_blocked(empty_unverified: A)`；`P_empty_unverified={A}`。
- 预期业务：不确认零健康；不启动 24h——因为 A 的"空"可能只是我们拉不到。
- 不变项：`publish_versions`、`empty_confirmed`。

**T8｜同一 stale 任务提交两次**

- 初始：`task_1` 在 cv=1 创建；节点已升 cv=2；`task_1` 首次提交 → 登记 `stale(config_version)`。
- 步骤：原样再提交一次。
- 预期数据库：`detection_task_runs` 仍 **1 行**（`task_id` 主键），`outcome='stale'`、`applied=0`；`system_events` 中 `task_stale` 仍 1 条。
- 预期业务：第二次返回 `duplicate_ignored`，不抛异常、不重复告警。
- 不变项：`last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`nodes.state`。

**T9｜同一 task_id 先 stale 后 pass**

- 初始：同上，`task_1` 已登记 `stale`。
- 步骤：以同一 `task_id` 提交 `pass`（携带 cv=1 的执行版本）。
- 预期数据库：run 行**不变**（仍 stale、`applied=0`）；无新事件；cv2 目标行仍 `unknown`。
- 预期业务：旧任务无法通过重投洗白；返回 `duplicate_ignored`。
- 不变项：状态全部不变（尤其 `last_pass_at` 必须仍为 NULL）。

**T10｜同一 task_id 先 pass 后 stale**

- 初始：`task_2` 在 cv=2 正常执行并登记 `pass`、`applied=1`。
- 步骤：随后节点升到 cv=3，用同一 `task_2` 再提交（会被判 stale）。
- 预期数据库：run 行仍为 `pass`/`applied=1`；**不**新增 stale 行；无 stale 事件。
- 预期业务：先到者胜；已应用的健康证据保留（它当时确实有效）。
- 不变项：`stale_reason` 保持 NULL；`fail_streak` 等不变。

**T11｜不同任务分别 stale**

- 初始：`task_a`、`task_b` 分别在 cv=1 创建，节点已升 cv=2。
- 步骤：分别提交。
- 预期数据库：两行 run，各自 `stale`、`applied=0`；两条事件（各一次）。
- 预期业务：互不覆盖；两条都不可用于 cv2。
- 不变项：两行的 `task_id` 不变、`node_id` 正确。

**CT1｜读后版本变化（cv）**

- 初始：节点 N cv=1，`task_3` 在 cv=1 创建。
- 步骤：连接 1 调用 `apply_result`；在 `BEGIN IMMEDIATE` 之后、判定之前，由连接 2 提交 `cv→2`（或模拟为事务内读到已提交的 cv=2）。
- 预期数据库：run 行 `stale/config_version`、`applied=0`；`node_config_versions` 有 v2；cv2 目标行 `unknown`。
- 预期业务：旧结果不污染 v2。
- 不变项：cv2 的 `last_pass_at`、`fail_streak`、`state`。

**CT2｜读后规则版本变化**

- 初始：`task_4` 在 rule=3 创建。
- 步骤：事务内读到 rule=4 后再判定。
- 预期数据库：`stale/rule_version`、`applied=0`。
- 预期业务：旧规则结果不可用。
- 不变项：目标行全部字段。

**CT3｜读后生命周期变化**

- 初始：节点 N `lifecycle='active'`，`task_5` 在 active 时创建。
- 步骤：判定前 N 转 `missing`（或 `retired`）。
- 预期数据库：`stale/lifecycle`、`applied=0`；`nodes.lifecycle` 保持新值（不被回写 active）。
- 预期业务：退役/失踪节点不接受结果。
- 不变项：`nodes.state`、目标行。

**FK1–FK5**（Git 侧结构测试，见 §5.5）

- 初始：`restore_authorizations` 有 1 条有效令牌 `tk`（`node_id=7`、未消费）；`nodes` 有历史行 id=7（`state='unavailable'`），`node_id_reservations(id=7, state='held')`。
- 步骤：分别执行 5 种非法插入/删除。
- 预期数据库：每次均报错回滚；表行数不变（`nodes` 无新增、授权表无删除、`consumed_at` 仍 NULL）。
- 预期业务：历史 id 无法被抢占。
- 不变项：`restore_authorizations` 全部字段、`nodes` 行数、预留状态。

**VH1｜首次健康（一次通过）**

- 初始：新节点 N `state='unknown'`、`ever_valid_fail=0`、`config_version=1`；两目标均无结果。
- 步骤：两目标各来一条当前版本、当前规则、`mihomo` 的 pass。
- 预期数据库：`nodes.state='healthy'`、`state_since=now`；`node_target_state` 两行 `last_result='pass'`、`success_streak=1`；`recovery_state='none'`；无 `recovery_*` 行。
- 预期业务：新节点即时可用（不白等一个周期）。
- 不变项：`ever_valid_fail` 仍 0；不得创建 `recovery_state`。

**VH2｜故障后恢复（两次 + 间隔）**

- 初始：N `state='unavailable'`、`ever_valid_fail=1`、`fail_streak=3`。
- 步骤：目标 G 第 1 次 pass（t0）→ 第 2 次 pass（t0+10min）→ 第 3 次 pass（t0+40min）。
- 预期数据库：t0 后 `state='recovering'`、`recovery_state='observing'`、`first_success_at=t0`、`confirmed_count=1`；t0+10 仍 `recovering`（间隔不足）；t0+40 `state='healthy'`、`recovery_state='confirmed'`、`confirmed_count=2`、`confirmed_at=t0+40`。
- 预期业务：满足 Q11 才恢复发布。
- 不变项：`ever_valid_fail` 仍 1；`episode_started_at` 不清空。

**VH3｜配置升级后首次通过**

- 初始：N 升级到 cv=2（`state='unknown'`）；`ever_valid_fail=0`。
- 步骤：两目标各一条 cv=2 的 pass。
- 预期数据库：`state='healthy'`；`recovery_state='none'`；旧 cv=1 结果不被读取。
- 预期业务：未曾故障 → 一次通过即可。
- 不变项：旧版本行不被改写；`fail_streak=0`。

---

## 11. v0.7 → v0.8 修订对照

| # | v0.7 | v0.8 | 章节 |
| --- | --- | --- | --- |
| R1 | `P_pub` 排除异常机场，又要求异常阻断——公式不可达；全异常误判 `all_disabled`；空池无规则 | 四集分离（`P_disabled`/`P_enabled`/`P_block`/`P_eval`）+ 空池两态；阻断检查前置于判定 | §2 |
| R2 | `rep ≥ 0.90` 被当全池失效充分条件；`F_ev` 集合等式排除未观测 | `rep`（代表性）与 `U_unk=0`（证据）独立；六类节点划分；118/107/11 明确不可确认 | §3 |
| R3 | 事务外读 task/node，事务内只写 | 全程事务内重读 + 六项校验 + 五条规则 | §4 |
| R4 | 文档称外键，DDL 裸 `TEXT` | `token` 升 PK；`ADD COLUMN ... REFERENCES ... ON DELETE RESTRICT`；真迁移顺序；连接级 `foreign_keys=ON` | §5 |
| R5 | stale 旁路无闸门 | 单一 `task_id` 主键闸门，先占位后判定，stale 也走它 | §6 |
| R6 | 决策分散、伪代码有循环风险 | 统一决策表 + 五阶段无循环伪代码 + 冲突/延续判别 | §7 |
| R7 | 首次健康与恢复混用 | `ever_valid_fail` 分流；首次一次通过、故障两次 30 分钟 | §8 |

---

## 12. P0/P1 问题关闭清单

| 来源 | 问题 | 处理 | 状态 |
| --- | --- | --- | --- |
| 七轮 R1-1 | `P_pub` 与阻断条款矛盾 | 四集分离，阻断检查前置（§2.4 第三步） | 已关闭 |
| 七轮 R1-2 | 全异常误判 `all_disabled` | `all_disabled` 仅由 `P_enabled=∅` 触发 | 已关闭 |
| 七轮 R1-3 | 空池机场规则缺失 | 已核实不阻断 / 未核实阻断 | 已关闭 |
| 七轮 R2-1 | `rep` 冒充全池失效证据 | `U_unk=0` 独立条件 + 六类划分 | 已关闭 |
| 七轮 R2-2 | 未观测节点被集合等式排除 | `U_unk` 必须为空；118/107/11 → blocked | 已关闭 |
| 七轮 R2-3 | 证据窗口未定义 | `finished_at ∈ (t-W,t]` | 已关闭 |
| 七轮 R3-1 | 事务外读 task/node | 事务内重读 | 已关闭 |
| 七轮 R3-2 | 规则版本用缓存 | 事务内 `SELECT`，无缓存 | 已关闭 |
| 七轮 R3-3 | 生命周期变化检测不到 | 事务内校验 `lifecycle` | 已关闭 |
| 七轮 R4-1 | 外键名不副实 | 真 `REFERENCES` + RESTRICT | 已关闭 |
| 七轮 R4-2 | 迁移顺序缺失 | §5.3 七步 / 重建八步 | 已关闭 |
| 七轮 R5-1 | stale 无幂等 | 同一 `task_id` 闸门 | 已关闭 |
| 七轮 R5-2 | stale→pass 可洗白 | 先到者胜，永久 stale | 已关闭 |
| 七轮 R6-1 | 优先级分散 | 决策表 1–7 | 已关闭 |
| 七轮 R7-1 | 首次健康 vs 恢复混用 | `ever_valid_fail` 分流 | 已关闭 |

---

## 13. 待确认（不得视为已批准）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C1–C10 | 沿用 | 不变 | 沿用 |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` 表 | 是（若走重建，§5.3 八步） | 未确认 |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口（6h / 最近 3 次） | 6h 优先，不足取 3 次 | 未确认（v0.8 已把 `W` 同时用作"失败证据窗口"，参数取值仍属本项） |
| C15 | `rep` 门槛（0.90 / 0.60） | 0.90 确认、0.60 强不足 | 未确认 |
| C16 | retired 回归是否复用原 identity | 允许（新建 config_version） | 未确认 |
| **C17** | `U_unk` 是否允许在"机场已连续 N 轮全量返回且全失败"时降级为可接受 | 不建议降级（宁 blocked） | **新增，未确认** |

---

## 14. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | `U_unk=0` 过严，轮询机场永不确认零健康 | 这是**设计意图**（部分响应不得断言全池失效）；真故障由机场级连续失败 + 人工介入处理 | Z22/Z23 |
| 2 | 全异常被误读为停用 | 状态码分开（`all_disabled` vs `scope_blocked`），UI 显式文案 | Z24 |
| 3 | 空池"已核实"被拉取失败伪造 | 判据要求 `applied=1` 且成功完成；未核实一律阻断 | Z25/Z26 |
| 4 | 事务内重读增加锁竞争 | `BEGIN IMMEDIATE` 短事务（毫秒级）；结果写入串行化 | CT1–CT3 压测 |
| 5 | `nodes` 重建丢失触发器 | 迁移后核对触发器名称清单（5+3 支） | M 组 |
| 6 | 外键未开导致"看起来没约束" | 连接池钩子统一 `foreign_keys=ON`；FK1–FK5 强制验证 | FK 组 |
| 7 | stale 永久化导致重试无门 | 新任务重建即可；文档明确"stale 不洗白，只重建" | T8–T11 |
| 8 | `ever_valid_fail` 永不清零导致误伤 | 只在人工重建身份时归零；正常恢复保留故障史（符合 Q11） | VH2/VH3 |

---

**v0.8 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**。C11–C17 全部待确认。文档交回第八轮设计审查；未获批准前不提交实施计划、不进入任何阶段。
