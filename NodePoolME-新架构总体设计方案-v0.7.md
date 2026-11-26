# NodePoolME 新架构总体设计方案 v0.7

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.6
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**修订依据**：v0.6 第六轮审查的 P0 问题（R1–R6）与补充修订（R7–R9）
**文档状态**：**待第七轮设计审查**（未自行认定通过）

---

## 修订索引（v0.6 → v0.7）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| R1 | 全局零健康：参与集合、样本不足阻断、停用与不足分离 | §2 | 重写（P0） |
| R2 | `W_obs` 与当前发布资格统一到同一评估时点 | §3 | 重写（P0） |
| R3 | 检测任务绑定执行版本，旧结果只记 stale | §4 | 重写（P0） |
| R4 | 统一结果有效性函数 `fresh()` | §5 | 重写（P0） |
| R5 | 快照回退与时点严格对齐 | §6 | 重写（P0） |
| R6 | 回池令牌的真实授权边界（含 `nodes.restore_token`） | §7 | 重写（P0） |
| R7 | stable_id 冲突判定的独立来源与优先级 | §8 | 补充 |
| R8 | `absent`/`retired` 身份回归的生命周期闭环 | §9 | 补充 |
| R9 | `W_obs` 窗口参数边界与验证方法 | §10 | 补充 |

未修订：Q1–Q12、30 天 missing、不改指纹、30 分钟 per-node + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减 AND 规则、两次独立拉取确认、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`。**C11–C15 仍待确认，本轮不批准；新增 C16。**

---

## 0. 一句话结论

v0.6 的四类 P0 问题都是**"用局部事实代替全局事实"**：

- 用"参与机场里样本够的那几个"代替"所有参与机场"→ 样本不足被静默排除（R1）；
- 用"本次响应里的节点"代替"统计范围内的节点"→ 未返回但仍有新鲜成功的节点被忽略（R2）；
- 用"提交时的节点版本"代替"任务执行时的版本"→ 旧任务结果污染新版本（R3）；
- 用"`last_result=pass`"代替"有效且未过期、非 TCP、非系统故障"（R4）。

v0.7 的原则：**统计必须有唯一的时点、唯一的范围、唯一的有效性定义；三者任一不成立，判定结果只能是"证据不足"，不能是"确认"。**

---

## 1. 保留的既定设计（不重开）

Q1–Q12；`missing` 30 天；不改指纹；30 分钟 per-node + 抖动；业务 90 分钟；测速 17:00–24:00 与 50MB；骤减"≥50% 且 ≥10"双条件 + 两次独立确认；30 个可恢复版本；恢复两次有效成功且间隔 ≥30 分钟；TCP-only 永不合格；四格式/四 URL/UA/Token/两种 `sub_publish`；P-1 只做安全底座。

---

## 2. R1：全局零健康判定（混合机场）

### 2.1 v0.6 的错误

v0.6 §9.4 写的是：

```
全局零健康 ⇔ 所有参与机场 E1–E6 全部成立，且 Σ|A_eff| > 0
任一机场 E2/E5 不成立 → 该机场记 rolling_scope，且不纳入全局判定
```

"不纳入全局判定"等于**把样本不足机场从分母里删掉**，再对剩下的机场下结论——A、C 全挂、B 样本不足时，会得出"全局零健康"，启动 24 小时旧订阅倒计时。B 的节点可能全都活着，只是这轮没返回（R1 硬性要求明确禁止这种排除法）。

### 2.2 三类机场必须分开

| 类别 | 判定条件 | 是否参与发布 | 是否进零健康判定 | 是否阻止确认 |
| --- | --- | --- | --- | --- |
| **明确停用** | `airports.enabled=0` 或 `airport_removed=1` | 否 | **否**（不进分母） | 否（已明确退出） |
| **停用期（临时）** | 机场在 `invalid_window`（引擎/调度/DB 异常） | 否（暂停） | 否 | 是（异常未关闭） |
| **参与发布且样本充分** | `rep ≥ 0.90` | 是 | 是 | — |
| **参与发布但样本不足** | `0 < rep < 0.90` | 是 | **是（进分母与判定）** | **是（阻断全局确认）** |
| **参与发布但池为空** | `|A_scope| = 0` | 是（无节点可发） | 记为 `airport_empty` 并单列 | 否（无主体） |

**R1 的核心硬约束**：参与发布的机场中只要有 `rolling_scope` 或 `rolling_scope_low`，全局结果一律 `scope_blocked`，**不启动 24 小时计时**，无论其他机场是否全挂。

### 2.3 集合与公式（唯一口径）

```
评估时点 t：一次只读事务（BEGIN DEFERRED）快照，全表按 t 计算，事件写 as_of=t

P_pub(t)      = { a : enabled=1 ∧ airport_removed=0 ∧ 不在 invalid_window }
A_scope(a,t)  = { n : n.lifecycle='active' ∧ n.airport=a ∧ identity.last_present_at ≥ t-7d }
A_eff(a,t)    = { n ∈ A_scope : identity.last_seen_pull_id = 当前 pull }        （可测）
W_obs(a,t)    = ⋃ A_eff(a) over applied pulls in (t-W, t]                       （观测并集）
rep(a,t)      = |A_scope ∩ W_obs| / |A_scope|
E(a,t)        = { n ∈ A_scope : eligible_at(n,t) }        ← 含本次未返回的节点
F_ev(a,t)     = { n ∈ A_scope ∩ W_obs : 有失败证据 }       ← fail_streak≥1 或最新有效结果为 fail
cov(a,t)      = |{ n ∈ A_eff : 每必需目标在 60 分钟窗口内有当前版本有效结果 }| / |A_eff|
```

单机场确认（全部成立）：

```
ZH1 |A_scope| > 0
ZH2 rep ≥ 0.90
ZH3 |A_eff| > 0 且 cov ≥ 0.90
ZH4 |E| = 0                                    ← 本轮重点：本次未返回但仍有新鲜成功的节点会否掉
ZH5 |F_ev| = |A_scope ∩ W_obs|                  ← 观测到的每一个都有失败证据（不允许"未知"混入）
ZH6 无 invalid_window
```

全局确认：

```
GlobalZeroHealth(t) =
      P_pub ≠ ∅
  ∧ ∀a ∈ P_pub : ZH1–ZH6 成立
  ∧ Σ_{a∈P_pub} |A_eff(a,t)| > 0
```

结果状态（互斥）：

| 状态 | 条件 | 24h 计时 |
| --- | --- | --- |
| `zero_health` | 上式成立 | **启动** |
| `scope_blocked` | ∃a∈P_pub 使 ZH2 不成立（样本不足） | **不启动** |
| `scope_blocked`（异常版） | ∃a∈P_pub 在 `invalid_window` 或异常未关闭 | 不启动 |
| `no_nodes` | P_pub 中所有 `|A_scope|=0` | 不启动 |
| `all_disabled` | P_pub = ∅（全明确停用） | 不启动 |
| `zero_denominator` | Σ|A_eff| = 0 但 P_pub ≠ ∅（机场在参与、本次无节点） | 不启动，记 `scope_insufficient` |

**ZH5 的意义**：只有当"观测到的节点全都确实在失败"时才允许确认——这排除了"少返回一半、那一半恰好都挂"被当成全池失效（R8.6 语义在 v0.6 已提出，v0.7 把它落到公式里）。

### 2.4 场景对照（R1 的五个必测）

| # | 场景 | 参与集合 | rep | 判定 | 24h |
| --- | --- | --- | --- | --- | --- |
| 1 | A、C 充分且全失败，B `rolling_scope` | {A,B,C} | B=0.5 | `scope_blocked` | 否 |
| 2 | A 充分全失败，B 样本不足（`rep=0.7`） | {A,B} | B=0.7 | `scope_blocked` | 否 |
| 3 | 全部机场充分且全失败 | 全部 | ≥0.9 | `zero_health` | 是（`confirmed_at` 只写一次） |
| 4 | 某机场明确停用 | 不含该机场 | — | 其余全失败 → `zero_health`；停用机场记 `excluded_disabled` | 是 |
| 5 | 某机场参与但样本不足 | 含该机场 | <0.9 | `scope_blocked`（**不**把它删掉） | 否 |

### 2.5 计时器与状态迁移

| 当前 | 新事件 | 变化 |
| --- | --- | --- |
| 无计时 | `zero_health` 成立 | 启动：`confirmed_at`（只写一次）、`deadline = confirmed+24h+paused`、`hard = confirmed+72h` |
| 计时中 | 出现 `scope_blocked` | `paused`：`paused_ms` 累加；**不取消** |
| 计时中 | `publishable ≥ 1`（含未返回节点恢复新鲜） | `canceled` |
| 计时中 | 到 `deadline` → 重验通过 | 发 `minimal` |
| 到 `hard_deadline` | 未解除 | `manual_review`，停止自动发布 |

### 2.6 事务与时点

- 一次判定 = **一个只读事务**：`P_pub`、`A_scope`、`W_obs`、`E`、`F_ev`、`cov` 全部在同一快照内计算，避免"分母是 10:00 的、分子是 10:05 的"（R2 要求）。
- 事件 `zero_health_eval` 必须写 `as_of`、各集合基数、`rep`、`excluded_disabled` 列表、`scope_blocked` 原因。

---

## 3. R2：观测集合与当前发布资格的统一点

### 3.1 v0.6 的错误

v0.6 的 `A_eff` 只含"本次响应中的节点"，`publishable` 只在 `A_eff` 上算，于是：

- 某节点在 `W_obs` 里、最近 10 分钟刚成功（`last_pass_at` 新鲜）→ 本次没返回 → 被当成"不可发布"，直接计入"零健康"；
- 某节点 3 天前失败、昨天恢复成功且仍新鲜 → 也被忽略（因为本次没返回）。

两者都会把"活着的节点"算成"死的"（R2.1、R2.2）。

### 3.2 统一评估函数 `eligible_at`

```
eligible_at(n, t) =
      n.lifecycle = 'active'
  ∧ n.state ∈ ('healthy','observe')
  ∧ ∀ 必需目标 g:
        ∃ 最新有效结果 r(g)：
            r.config_version = n.config_version
          ∧ r.rule_version   = active_rule_version(t)
          ∧ r.valid = 1 ∧ r.mode = 'mihomo'
          ∧ r.failure_source ∉ ('engine','scheduler','system','target_incident')
          ∧ r.last_pass_at + ttl(g) > t
```

**关键点**：`eligible_at` **不读取"本次是否返回"**。是否返回只影响 `A_eff`（覆盖率分母）与 `W_obs`（代表性），不影响"这个节点现在能不能发"。

### 3.3 三种节点的处理（R2 的三个"不能"）

| 节点情况 | 旧处理（v0.6） | v0.7 处理 |
| --- | --- | --- |
| 本次未返回，但 `last_pass_at` 仍新鲜 | 不计入 → 可能误判零健康 | **计入 `E`** → `ZH4` 不成立 → 不判零健康 |
| 曾失败，后来成功且新鲜 | 因"曾失败"被 `F_ev` 计数 → 误判 | `F_ev` 只统计"最近一次有效结果为 fail"或 `fail_streak≥1`；已恢复且新鲜的节点同时进 `E`，`ZH4` 否掉 |
| 本次未返回，且结果已过期 | — | 不在 `E`、不在 `F_ev`，只计入"未观测数"，由 `rep` 约束 |

**`F_ev` 的精确定义**（避免"曾失败就永久算失败"）：

```
n ∈ F_ev ⇔ (n.fail_streak ≥ 1) ∨ (该节点最近一次有效结果.last_result = 'fail')
```

即：一旦后续出现有效 pass 且 `fail_streak` 归零，该节点就**退出** `F_ev`（同时若还新鲜则进入 `E`）。

### 3.4 统计时点唯一

- 所有集合按 `t = 判定开始时刻` 的只读快照计算（同 §2.6）。
- 事件写 `as_of`，UI 展示"统计于 HH:MM:SS"。
- 禁止把"本次 pulls 的结果时间"与"上一轮判定时间"混算。

---

## 4. R3：检测任务绑定执行版本

### 4.1 v0.6 的错误

v0.6 的 `detection_task_runs` 只在结果应用时写入，写的是**提交那一刻**的 `nodes.config_version`；任务实际执行时的版本没有落库。于是：

- 任务在 v1 启动、节点升级到 v2、旧任务返回 pass → 结果按 v2 记账，污染新版本状态（R3.4）；
- `rule_version` 同理（规则升级后旧任务仍按新规则算）。

### 4.2 任务创建时固化执行上下文

```sql
CREATE TABLE detection_tasks (
  task_id        TEXT PRIMARY KEY,          -- 全局唯一
  node_id        INTEGER NOT NULL,
  identity_id    INTEGER NOT NULL,
  target         TEXT NOT NULL,
  config_version INTEGER NOT NULL,          -- ← 创建时固化
  rule_version   INTEGER NOT NULL,          -- ← 创建时固化
  created_at     TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);

CREATE TABLE detection_task_runs (
  task_id        TEXT PRIMARY KEY,
  outcome        TEXT NOT NULL CHECK(outcome IN ('pass','fail','invalid','stale')),
  exec_config_version INTEGER NOT NULL,     -- ← 执行时版本（冗余固化，防篡改）
  exec_rule_version   INTEGER NOT NULL,
  finished_at    TEXT NOT NULL,
  applied        INTEGER NOT NULL DEFAULT 0 CHECK(applied IN (0,1)),
  stale_reason   TEXT CHECK(stale_reason IN ('config_version','rule_version','identity','lifecycle')),
  FOREIGN KEY (task_id) REFERENCES detection_tasks(task_id)
);
```

**R3.5 的落实**：两个表都记录 `config_version` / `rule_version`，且都是**任务创建时**的值；结果只带 `exec_*`，用于与任务行交叉校验（不一致 → 数据损坏，拒绝）。

### 4.3 应用前版本校验（同事务）

```python
def apply_result(node, target, outcome):
    task = db.one("detection_tasks", task_id=outcome.task_id)
    if task is None:
        event("unknown_task", level="critical"); return

    # ① 执行版本与任务固化版本必须一致（防篡改）
    if (outcome.exec_config_version, outcome.exec_rule_version) != \
       (task.config_version, task.rule_version):
        event("task_version_mismatch", level="critical"); return

    # ② 与当前节点/规则比较：不一致 → 只记 stale
    with tx():
        if task.config_version != node.config_version:
            record_stale(task, "config_version"); return
        if task.rule_version != active_rule_version():
            record_stale(task, "rule_version"); return
        if task.identity_id != node.identity_id:
            record_stale(task, "identity"); return
        if node.lifecycle != "active":
            record_stale(task, "lifecycle"); return

        # ③ 幂等闸门（v0.6 保留）
        try:
            db.execute("INSERT INTO detection_task_runs(task_id, outcome, exec_config_version,"
                       " exec_rule_version, finished_at, applied) VALUES(?,?,?,?,?,1)",
                       outcome.task_id, outcome.verdict, outcome.exec_config_version,
                       outcome.exec_rule_version, db.now())
        except UniqueViolation:
            return                                   # 已处理过，零状态变化

        # ④ 目标状态更新（与以上同一事务）
        ...
```

`record_stale` 只写 `detection_task_runs(outcome='stale', applied=0)`，**不触碰** `last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`ttl`、`state`。

### 4.4 测试（T 组新增 2 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| T6 | 任务在 cv=1 启动，节点升到 cv=2，旧任务返回 pass | `runs.outcome='stale'`、`applied=0`；cv2 的目标行保持 `unknown`；`last_pass_at` 不变 |
| T7 | 规则版本升级后旧任务返回 | `stale_reason='rule_version'`；健康状态不变 |

---

## 5. R4：统一结果有效性函数

### 5.1 v0.6 的错误

v0.6 §4.3：

```python
def fresh(t):
    return t.last_result == "pass" and t.last_pass_at + t.ttl > db.now()
```

而 §4.2 的表格声称"要求当前 config_version、有效结果"。函数只检查了 `pass` 与时间——旧版本 pass、TCP-only、系统故障期间的 pass 都能通过 `fresh()`（R4）。

### 5.2 唯一有效性定义

```python
SYSTEM_SOURCES = {"engine", "scheduler", "system", "target_incident"}

def result_valid(n, g, t, now):
    """判定一条目标结果是否可作为当前健康证据"""
    if t.last_result != "pass":                    return False   # ①
    if t.config_version != n.config_version:       return False   # ② 版本一致
    if t.rule_version != active_rule_version(now): return False   # ③ 规则有效
    if t.mode != "mihomo":                         return False   # ④ 非 TCP-only
    if t.failure_source in SYSTEM_SOURCES:         return False   # ⑤ 非系统/引擎/目标事故
    if t.valid != 1:                               return False   # ⑥ 显式有效
    if t.last_pass_at + t.ttl <= now:              return False   # ⑦ TTL 未过期
    return True

def fresh(n, g, now):
    return result_valid(n, g, target_state(n, g), now)
```

三条使用点全部复用 `fresh()`：

| 使用点 | 位置 |
| --- | --- |
| 目标健康判定 `target_ok` | §5.3 |
| 恢复确认后的节点聚合 | §5.3 |
| 发布资格 `eligible_at` | §3.2 / §5.4 |

### 5.3 状态机（与 v0.6 结构一致，仅把 `fresh` 换成三参版本）

```python
def target_ok(n, g, now):
    t = target_state(n, g)
    if t.faulted_in_episode or t.recovery_state != "none":
        return fresh(n, g, now) and t.recovery_state == "confirmed"
    return fresh(n, g, now)
```

### 5.4 发布资格（唯一表达式）

```
eligible_at(n,t) = n.lifecycle='active'
                 ∧ n.state ∈ ('healthy','observe')
                 ∧ ∀g: fresh(n, g, t)
```

`fresh` 已包含版本、规则、TCP、系统故障、TTL 五项，不再另写一套条件（避免两套定义漂移）。

### 5.5 负向测试（V 组，4 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| V1 | 旧 config_version 的 pass | `fresh=false`；不改状态 |
| V2 | 规则版本已失效的 pass | `fresh=false` |
| V3 | TCP-only "pass" | `fresh=false`；不写目标层 |
| V4 | 引擎异常期间的 pass | `fresh=false`；`failure_source` 保留 |

---

## 6. R5：快照回退窗口对齐

### 6.1 v0.6 的错误

v0.6 §8.2 写 `U7_prev = 快照 U7(D-7d)`（缺 log 时回退），但没规定"任意时刻 t"能否用"某日 00:00 快照"替代。若 `t=15:00` 时拿 `D 00:00` 的并集当 `(t-7d, t-7d]` 窗口，窗口差 15 小时，`simU`/`growthU` 全错（R5）。

### 6.2 严格对齐规则

```
快照 W_snap(D) = ( D-7d 00:00 , D 00:00 ]         ← 精确到秒，记为 snapshot_as_of

若请求窗口 W_req = ( a , b ]：
    可直接使用快照 ⇔ a == D-7d 00:00 且 b == D 00:00
    否则 → 必须用 presence_log 聚合；log 不足 → baseline_insufficient
```

- `U_before(t)`：窗口 `(t-7d, t)`，**永远**用 log；t 为任意时刻时不接受快照替代。
- `U7_prev(t)`：窗口 `(t-14d, t-7d)`；仅当 `t` 恰好是某日 `00:00:00` 且 log 不足时才允许用 `W_snap(D-7d)`。
- `median7`：按日定义（`U7(D-6)…U7(D)`），**只允许**使用快照；缺行 → log 重放；仍不足 → `baseline_insufficient`。

### 6.3 降级与不可用

| 情形 | 状态 | 行为 |
| --- | --- | --- |
| t=15:00，log 缺 14 天窗口，想用日快照 | **禁止** | `baseline_insufficient`；不判骤减、不判 rolling |
| 快照 `snapshot_as_of` 与 `day` 不一致 | `snapshot_mismatch` | 以 `snapshot_as_of` 为准修正/重写 |
| 快照延迟 > 30 分钟 | `snapshot_lagging` | log 重建补写，不阻塞 |
| 时区漂移（服务器非 UTC+8） | `tz_mismatch` | 拒绝使用快照；统一 `db.now()` 与 `Asia/Shanghai` |

### 6.4 边界包含关系

- 窗口一律左开右闭 `( , ]`；`t` 时刻到达的 presence（`ts = t`）**计入**。
- 快照 `as_of` 为 `00:00:00`；`00:00:00` 整点事件计入**当日**快照（右闭）。
- presence log 的 `ts` 精确到秒；跨午夜由 `ts` 决定归属，不按"拉取批次开始时间"。

### 6.5 测试（补充 RP12）

| # | 场景 | 断言 |
| --- | --- | --- |
| RP12 | t=15:00，log 不足，存在 `D 00:00` 快照 | `baseline_insufficient`；**不**用快照；不判骤减/rolling |

---

## 7. R6：回池令牌的真实授权边界

### 7.1 v0.6 的残留漏洞

v0.6 的触发器只校验"存在一张未消费、未过期、四元组匹配的令牌"：

```sql
AND NOT EXISTS (SELECT 1 FROM restore_authorizations a
                WHERE a.node_id = NEW.id AND a.identity_id = NEW.identity_id
                  AND a.fingerprint = NEW.fingerprint
                  AND a.consumed_at IS NULL AND a.expires_at > now)
```

三个问题（R6.1–R6.4）：

1. **令牌与插入行没有硬链接**：任何插入只要四元组猜对，就能用掉别人的合法令牌；
2. **令牌可以"预置等待"**：签发后 120 秒内，任意普通插入路径可抢用；
3. **无法证明"消费发生在同一个回池事务里"**：`consumed_at` 由应用写，触发器不校验先后。

### 7.2 修正：令牌成为节点行的外键引用

```sql
ALTER TABLE nodes ADD COLUMN restore_token TEXT;         -- 仅回池行非空
CREATE UNIQUE INDEX uq_nodes_restore_token ON nodes(restore_token)
  WHERE restore_token IS NOT NULL;                        -- 一张令牌只能用一次

ALTER TABLE restore_authorizations ADD COLUMN consumed_by_node INTEGER;
CREATE UNIQUE INDEX uq_auth_consumed_by ON restore_authorizations(consumed_by_node)
  WHERE consumed_by_node IS NOT NULL;
```

触发器改为**自证式**：

```sql
-- ① 历史 id 插入：必须携带令牌，且令牌与本次插入四元组完全一致
CREATE TRIGGER trg_nodes_reserved_token BEFORE INSERT ON nodes
WHEN EXISTS (SELECT 1 FROM node_id_reservations r
             WHERE r.node_id = NEW.id AND r.state = 'held')
 AND (NEW.restore_token IS NULL
      OR NOT EXISTS (SELECT 1 FROM restore_authorizations a
                     WHERE a.token = NEW.restore_token
                       AND a.node_id = NEW.id
                       AND a.identity_id = NEW.identity_id
                       AND a.fingerprint = NEW.fingerprint
                       AND a.consumed_at IS NULL
                       AND a.expires_at > strftime('%Y-%m-%dT%H:%M:%S','now','localtime')))
BEGIN SELECT RAISE(ABORT,'historic node id requires its own valid restore token'); END;

-- ② 令牌只能被"引用它的那一行"消费：插入后由触发器标记 consumed
CREATE TRIGGER trg_nodes_reserved_consume AFTER INSERT ON nodes
WHEN NEW.restore_token IS NOT NULL
BEGIN
  UPDATE restore_authorizations
     SET consumed_at = strftime('%Y-%m-%dT%H:%M:%S','now','localtime'),
         consumed_by_node = NEW.id
   WHERE token = NEW.restore_token AND consumed_at IS NULL;
END;

-- ③ 非预留 id 不得携带令牌（防止"用令牌插普通节点"绕过审计）
CREATE TRIGGER trg_nodes_token_only_reserved BEFORE INSERT ON nodes
WHEN NEW.restore_token IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM node_id_reservations r
                 WHERE r.node_id = NEW.id AND r.state = 'held')
BEGIN SELECT RAISE(ABORT,'restore token is only valid for reserved ids'); END;
```

**这套机制能做到什么**：

| 保证 | 实现 |
| --- | --- |
| 令牌与插入行一一对应 | `nodes.restore_token` 唯一索引 + `consumed_by_node` 唯一索引 |
| 一张令牌只能用一次 | `uq_nodes_restore_token` + `consumed_at` |
| 令牌不能用于别的 id | 触发器 ① 要求 `a.node_id = NEW.id`，③ 禁止非预留 id 带令牌 |
| 令牌不能"预置等待"普通插入 | 触发器 ③ + 令牌必须由 `readmit()` 在同一事务内签发（见下） |
| 事务回滚则令牌不残留 | 签发、插入、消费在同一 `BEGIN IMMEDIATE` 事务内，回滚全部撤销 |
| 并发 | `BEGIN IMMEDIATE` 串行 + `uq_auth_live` |

### 7.3 能力边界（必须保留的声明，不许夸大）

> **SQLite 无法证明"调用者身份"**。上述约束能证明的是：**令牌与数据的绑定关系成立、一次性、限时、只用于预留 id**；不能证明"这条 INSERT 来自 `readmit()` 而不是某个知道全部字段的代码路径"。
>
> 因此本设计的授权边界是**"数据层一致性 + 应用层唯一入口 + 审计"三层**，而不是"数据库级调用者鉴权"。文档与管理界面不得宣称后者。运行期唯一合法入口仍是 `readmit()`（评审 grep：`restore_authorizations` 的写入只允许出现在该函数内），并对每次签发/消费写 `system_events`。

### 7.4 生命周期

```python
def readmit(f, node):
    r = db.one("node_id_reservations", filtered_id=f.id, state="held")
    with tx():                                    # BEGIN IMMEDIATE
        token = uuid4()
        db.execute("INSERT INTO restore_authorizations(token,node_id,filtered_id,identity_id,"
                   "fingerprint,tx_marker,issued_at,expires_at) VALUES(?,?,?,?,?,?,?,?)",
                   token, r.node_id, f.id, r.origin_identity_id, r.origin_fingerprint,
                   uuid4(), now, now + 120)
        row = db.insert("nodes", id=r.node_id, restore_token=token,
                        identity_id=r.origin_identity_id, ...)     # 触发器 ① ② 校验并消费
        db.update("node_id_reservations", node_id=r.node_id, state="restored", released_at=now)
        db.update("airport_filtered_nodes", id=f.id, origin_state="restored")
    return row
```

| 场景 | 结果 |
| --- | --- |
| 正常提交 | 令牌 `consumed_by_node` 已写；节点行带 `restore_token`；预留 `restored` |
| 事务回滚 | 令牌、节点、状态更新一起回滚；无残留 |
| 进程崩溃（提交前） | 回滚；下次可重试 |
| 进程崩溃（提交后） | 幂等返回既有行（`reservation.state='restored'`） |
| 并发两连接 | 先拿到 `BEGIN IMMEDIATE` 者成功；后者 `uq_auth_live`/`uq_nodes_restore_token` 冲突 |
| 令牌过期 | 触发器 ① 拒绝；可从 `held` 状态重新签发 |

### 7.5 测试（F 组新增 4 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| F17 | 普通创建路径携带别人的合法令牌 | 触发器 ①（四元组不符）或 ③ abort |
| F18 | 同一令牌插两行 | `uq_nodes_restore_token` 冲突 |
| F19 | 用令牌插非预留 id | 触发器 ③ abort |
| F20 | 令牌签发后事务回滚 | 令牌不存在；可重新签发 |

---

## 8. R7：stable_id 冲突判定的独立来源

### 8.1 v0.6 的循环论证

v0.6 §2.5：

```python
if live:
    ident, cur = live.identity, ...      # ← 先用 live 的 identity 当"本次绑定身份"
    ...
    else:                                 # ← 再用它判断"是否指向别的身份"
```

冲突判定本该是"本次响应里这个 id 应该绑给谁"，但代码先假设答案等于 `live.identity`，再拿它与自己比较，冲突永远检测不出来（R7.1）。

### 8.2 两个独立输入：`claim_candidate` 与 `node_assignment`

| 来源 | 含义 | 由谁产生 |
| --- | --- | --- |
| `claim_candidate` | 该 `stable_id` 的历史归属（"这个 id 上次属于谁"） | `claim_for(airport, id)` |
| `node_assignment` | 本次响应中，这个节点应当绑定到哪个身份（"这次该给谁"） | 由配置证据 + 槽位规则决定（P0–P5） |

两者**必须分别计算**，再在"整轮赋值（pull-level assignment）"里做一致性检查：

```
1  对本次响应每个节点独立算出 node_assignment（只看配置证据与槽位，不看 claim 结论）
2  对每个 stable_id 取 claim_candidate（可能为空）
3  整轮一致性检查：
     C1 同一 stable_id 在本轮出现 ≥2 次          → stable_id_duplicate
     C2 两个不同 stable_id 指向同一 identity     → identity_multi_claim
     C3 node_assignment 与 claim_candidate 不同且 claim 为 live → stable_id_conflict
4  只有通过 C1–C3 的节点才进入最终 bind
```

### 8.3 优先级（谁说了算）

| 优先级 | 证据 | 说明 |
| --- | --- | --- |
| 1 | `live claim` 的 identity + 配置一致（F） | 最强：id 与配置同时一致 |
| 2 | `live claim` + 配置变化已确认（G1，需 `seen_count≥2` 且 `observed_count≥2`） | 同身份升版本 |
| 3 | `live claim` + 端点变化已确认（H1） | 同 id 不同机器 → 新身份（release live claim） |
| 4 | 无 live claim + 历史 `absent` 释放 + 配置一致 | 原机器回归（readopt） |
| 5 | 无 live claim + 历史 `reused`/`manual` | **不得** readopt（§9 规则） |
| 6 | 无 id / 首次出现 | P1–P4 指纹与槽位 |
| 7 | 以上都冲突 | `identity_ambiguous`，本轮不绑、不建、不删 |

### 8.4 冲突处理（R7.3）

| 冲突 | 处理 |
| --- | --- |
| C1 同 id 出现两次（重复条目） | 两条均 `identity_ambiguous`；不绑定；事件 `stable_id_duplicate`；需下一轮观察 |
| C2 两 id 指同一身份 | 保留 `occurrence_seq` 较小者绑原身份；另一条按 P5 新建 + `ambiguous`；事件 `identity_multi_claim` |
| C3 赋值与 claim 不一致 | **不**改绑；该节点本轮 `hold`；事件 `stable_id_conflict`；下一轮按 §2.3 的 pending 观察流程重新判定 |
| live claim 指向已 `retired` 的身份 | 按 §9.3 的 retired 回归规则处理 |

---

## 9. R8：`absent` / `retired` 回归的生命周期闭环

### 9.1 触发条件

| 场景 | 前置 |
| --- | --- |
| `absent` 回归 | claim `release_reason='absent'`；旧 identity 仍 `active` 或 `missing` |
| `retired` 回归 | 旧 identity `lifecycle='retired'`（30 天 + 人工/自动退役） |

### 9.2 回归处理（按 nodes 行是否存在分流）

| 情况 | nodes 行 | identity | config_version | node_id | 健康 |
| --- | --- | --- | --- | --- | --- |
| A | 存在 | `retired → active`（同 identity，保留历史） | **必须新建** `version = max+1`，`change_reason='readopt'`；旧版本保持 `closed_at` 不变 | 沿用原 `node_id`（同一行） | `unknown`，重新验证 |
| B | 不存在（离线维护/历史遗留） | **新建** identity，`related_identity_id=旧`，`generation+1` | 新 identity 从 `version=1` 起 | **新 id**（除非 §7 有预留 + 令牌） | `unknown` |
| C | 存在但身份已 `retired` 且 claim `reused` | 不复活旧 identity；新建 | 新从 1 起 | 新 id（旧行保留但不再使用） | `unknown` |

**为什么必须新建 config_version**：`node_config_versions` 的字段不可变（§6/v0.6 R5），旧版本已 `closed_at`；直接"复用 v3"会让历史结果与新结果混在同一版本键上。新版本号让 `results` 按 `config_version` 天然隔离。

### 9.3 具体步骤（情况 A）

```
1  claim：新建 claim（generation=旧+1），seen_count=1
2  identity：lifecycle 'retired' → 'active'；retired_at 保留审计（不清空）
3  config：INSERT node_config_versions(identity, max+1, 'readopt')
4  nodes：UPDATE config_version=max+1（DEFERRED 外键，同事务）；state='unknown'；
          state_since=now；fail_streak=0；success_streak=0；
          episode_started_at=NULL；ever_valid_fail=0
5  target_state：为新版本建 unknown 行（旧版本行保留、不再写入）
6  事件：identity_revived（含旧/新版本号）
```

### 9.4 历史隔离规则

| 数据 | 是否关联 | 规则 |
| --- | --- | --- |
| 旧 `results`（旧 config_version） | **不参与**新健康 | `fresh()` 要求 `config_version == 当前` |
| `node_state_history` | 可关联 | 按 `config_version` 分段，UI 显示"v3 期间 / v4 起" |
| 评分历史 | 可关联但分段 | 只统计当前版本的窗口；跨版本不合并均值 |
| 发布历史 | **不关联 identity** | 发布按版本目录与 `publish_versions`，与节点身份无关 |
| `related_identity_id` | 只作审计 | 任何聚合/评分/覆盖查询禁止沿它取旧数据 |

### 9.5 测试（I 组新增 3 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| I28 | retired 回归，nodes 行存在 | identity 复用 → active；新 `config_version+1`；`node_id` 不变；`state='unknown'`；旧版本行不写入 |
| I29 | retired 回归，nodes 行不存在 | 新 identity（`related` 指向旧、`generation+1`）；新 node id；无历史继承 |
| I30 | 回归后第一次检测 pass | 不直接 healthy（需按 §5 的 `fresh` 与恢复规则判定；`ever_valid_fail=0` 时可首次通过） |

---

## 10. R9：`W_obs` 参数边界（C14 保持待确认）

### 10.1 参数不被批准

`W = 6 小时，不足 2 次拉取则取最近 3 次` 属于 **C14（待确认）**。v0.7 只把它写成"实现时可选默认值"，**不作为已批准设计**。

### 10.2 降级策略（与参数无关的硬规则）

| 情形 | 状态 | 行为 |
| --- | --- | --- |
| 窗口内 `applied` 拉取 < 2 | `W_obs_window_thin` | 扩到最近 3 次拉取；仍 <2 → `rep` 不计算，按 `rolling_scope` |
| 最近 3 次拉取跨度 > 24 小时 | `W_obs_window_stale` | 视为窗口不代表当前暴露 → 全局 `scope_blocked` |
| 机场轮询周期 > 窗口 | `W_obs_window_short` | 同上；并在 UI 明示"该机场轮询周期 8h，超出采样窗口" |
| 窗口内包含 suspect/失败拉取 | — | 只统计 `applied=1` 的拉取 |

### 10.3 如何用真实数据验证（后续实测清单）

1. 取某轮询机场近 30 天 presence log；
2. 统计其"完整覆盖周期"分布（每个身份两次出现之间的间隔中位数）；
3. 分别用 `6h / 12h / 最近 3 次 / 最近 5 次` 计算 `rep`，比较四种窗口下 `rep` 的稳定性（标准差）与"误判为零健康"的次数；
4. 选 `rep` 波动最小且不误判的窗口作为 C14 批准依据。

**在该验证完成前**，实现必须保留 `W` 为可配置项，且默认值取保守方向（宁可 `rolling_scope`，不可误判 `zero_health`）。

---

## 11. 迁移与兼容

### 11.1 增量（仅设计，不执行）

| 变更 | 表 | 性质 |
| --- | --- | --- |
| 加 `config_version`/`rule_version`/`created_at` | `detection_tasks`（新表） | 结构 |
| 加 `exec_*`/`applied`/`stale_reason` | `detection_task_runs` | 加法 |
| 加 `restore_token` + 唯一索引 | `nodes` | 结构 |
| 加 `consumed_by_node` + 唯一索引 | `restore_authorizations` | 结构 |
| 触发器 ① ② ③（回池） | — | 结构 |
| `zero_health_eval` 事件字段扩展 | `system_events` | 语义 |

### 11.2 顺序（P0/P1）

```
1 备份 + quick_check + 探针（S1 才继续）
2 建 detection_tasks / 扩 detection_task_runs
3 nodes 加 restore_token（历史行 NULL）；建唯一索引
4 restore_authorizations 加 consumed_by_node
5 替换回池触发器（① ② ③）
6 负向测试 F17–F20 / T6–T7 / V1–V4 临时库跑通
7 写 schema_migrations(success)
```

### 11.3 兼容承诺

- 全部加法或语义收紧；历史节点 `restore_token=NULL` 不影响任何触发器（触发器只在预留 id 上生效）。
- 四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`、测速与评分算法**未改动**。
- 前端增量展示：统计时点 `as_of`、`E`/`F_ev`/`rep` 基数、`scope_blocked` 原因、任务 `stale` 计数、身份第几手。

---

## 12. 测试矩阵

### 12.1 汇总

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I27 + I28–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务幂等 T | 7 | T1–T7 |
| 有效性 V | 4 | V1–V4 |
| 约束 FT | 23 | FT1–FT23 |
| 过滤/令牌 F | 22 | F1–F22（F17–F22 为回池令牌专测） |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP11 + RP12 |
| 零健康 Z | 21 | Z1–Z15 + Z16–Z21（含 6 条详测） |
| 迁移 M | 10 | M1–M10 |

### 12.2 逐项详测（每条含初始数据 / 步骤 / 预期库状态 / 预期业务结果）

**Z16｜多机场混合：A、C 充分全失败，B 样本不足**

- 初始：机场 A（池 40，本次返回 40，全 `fail_streak=3`）；机场 C（池 30，本次返回 30，全失败）；机场 B（池 118，本次返回 45，`rep=0.38`）。
- 步骤：执行一次零健康评估（只读快照 `t`）。
- 预期库：`system_events` 新增 `zero_health_eval`，`as_of=t`，`excluded_disabled=[]`，`scope_blocked_reason='rep<0.9: B'`；**无** `empty_confirmed` 行；`publish_versions` 无新版本。
- 预期业务：全局状态 `scope_blocked`；不启动 24h；订阅继续用当前 active 版本。

**Z17｜样本不足机场阻止全局确认（两机场）**

- 初始：机场 A 池 20 全失败；机场 B 池 50、本次返回 25（`rep=0.5`，其返回节点全 pass）。
- 步骤：同上。
- 预期库：`scope_blocked`；`E` 中 B 的返回节点非空（`|E|>0` 已由 ZH4 直接否掉，事件需同时记录 `rep` 与 `|E|`）。
- 预期业务：不判零健康；B 的 pass 节点继续发布。

**Z18｜全部机场充分且全失败**

- 初始：A（40/40 全失败）、B（45/45 全失败，`rep=1.0`）。
- 步骤：连续两次评估（间隔 ≥10 分钟）。
- 预期库：一条 `empty_confirmed(state='counting', confirmed_at=首次, immutable=1)`；第二次评估**不**改 `confirmed_at`。
- 预期业务：`zero_health`；24h 计时启动；到期发 `minimal`。

**Z19｜明确停用机场不参与发布统计**

- 初始：机场 D `enabled=0`（池 60，全部有新鲜 pass）；机场 A 池 40 全失败。
- 步骤：评估。
- 预期库：事件含 `excluded_disabled=['D']`；分母不含 D 的 60；`|A_eff|` 只算 A。
- 预期业务：`zero_health` 成立（D 已退出发布）；D 的节点不出现在订阅。

**Z20｜`W_obs` 内仍有新鲜成功的节点，但本次未返回**

- 初始：机场 B 池 118；本次返回 60（全失败）；另有 1 个节点 `X` 在 3 小时前的拉取中出现且 `last_pass_at = t-20min`（当前版本、规则匹配、TTL 未过期）。
- 步骤：评估。
- 预期库：`|E| ≥ 1`（含 X，尽管 `X ∉ A_eff`）；`rep` 计算含 X。
- 预期业务：**不**判零健康（`ZH4` 不成立）；X 仍可发布。

**Z21｜曾失败节点后续成功且仍新鲜**

- 初始：机场 B 池 118，本次返回 60 全失败；节点 `Y` 昨天 `fail_streak=3`，今天 `last_result='pass'`、`fail_streak=0`、`last_pass_at=t-30min`。
- 步骤：评估。
- 预期库：`Y ∉ F_ev`；`Y ∈ E`；`fail_streak` 已归零（非 3）。
- 预期业务：不判零健康；Y 可发布。

**T6（详测）｜config_version 变化后旧任务返回**

- 初始：节点 N `config_version=1`；任务 `task_1` 在 cv=1 创建并入队；随后 N 升到 `cv=2`（`node_config_versions` 有 v2、v1 已 `closed_at`）。
- 步骤：`task_1` 返回 `pass`，走 `apply_result`。
- 预期库：`detection_task_runs(task_1)` 行 `outcome='stale'`、`applied=0`、`stale_reason='config_version'`；cv=2 的 `node_target_state` 行仍 `last_result='unknown'`、`last_pass_at=NULL`、`fail_streak=0`；`nodes.state` 不变。
- 预期业务：旧结果不产生任何健康证据；v2 需新任务验证。

**T7（详测）｜rule_version 变化后旧任务返回**

- 初始：任务 `task_2` 在 `rule_version=3` 创建；规则升到 4。
- 步骤：返回 `pass`。
- 预期库：`stale_reason='rule_version'`、`applied=0`；目标行不变。
- 预期业务：规则变更后旧结果不可用。

**V3（详测）｜TCP-only 结果**

- 初始：节点 N 目标 G 现有 `pass`（10 分钟前，cv 一致）。
- 步骤：新结果 `mode='tcp_only'`、`result=pass`。
- 预期库：`node_target_state` **不更新**（`updated_at` 不变）；`results` 行 `valid=0`；无 `state_history` 新行。
- 预期业务：TCP-only 不构成健康证据；节点仍按旧 pass 判（若 TTL 内则可发）。

**V4（详测）｜引擎异常结果**

- 初始：同上。
- 步骤：新结果 `failure_source='engine'`、`result=fail`。
- 预期库：目标行不变（`fail_streak` 不 +1）；`system_events` 记 `engine_incident`。
- 预期业务：系统故障不降级节点。

**RP12（详测）｜非午夜时刻（t=15:00）快照回退**

- 初始：presence log 只有 5 天；`D 00:00` 快照存在（`union_count=118`）。
- 步骤：在 `t=15:00` 计算 `U7_prev`，log 不足触发回退。
- 预期库：事件 `baseline_insufficient(window=(t-14d,t-7d], reason=log_short)`；**未**读取快照参与 `simU`。
- 预期业务：不判骤减、不判 rolling；检测与发布不受影响。

**F21｜普通创建路径尝试利用已有令牌**

- 初始：回池事务已签发令牌 `tk`（未消费），预留 id=7。
- 步骤：普通路径执行 `INSERT INTO nodes(id=7, identity_id=?, fingerprint=?, restore_token='tk')`，其中 `fingerprint` 与预留快照不同。
- 预期库：触发器 ① abort，事务回滚；`restore_authorizations` 无 `consumed_at`。
- 预期业务：历史 id 无法被抢用；回池流程可重新签发。

**F22｜两回池事务并发**

- 初始：预留 id=7 `state='held'`；两个连接同时 `readmit`。
- 步骤：连接 1 先 `BEGIN IMMEDIATE` 并签发；连接 2 随后尝试签发同 `node_id`。
- 预期库：连接 1 提交（令牌已消费、nodes 行存在、预留 `restored`）；连接 2 因 `uq_auth_live` 冲突 abort，无任何行写入。
- 预期业务：单次回池成功，无重复节点。

**I28（详测）｜retired 回归且原 nodes 行存在**

- 初始：identity I 已 `retired`，`config_version=3`（`closed_at` 已写），对应 nodes 行 id=12 存在、`state='unavailable'`。
- 步骤：机场返回同配置节点，stable_id 与历史 `absent` claim 匹配。
- 预期库：I `lifecycle='active'`（`retired_at` 保留）；`node_config_versions` 新增 v4（`change_reason='readopt'`），v3 仍 `closed_at`；`nodes(12)` `config_version=4`、`state='unknown'`、`fail_streak=0`、`episode_started_at=NULL`；新目标行 `unknown`。
- 预期业务：回归节点不继承 Healthy；需重新检测。

**I29（详测）｜retired 回归且原 nodes 行不存在**

- 初始：identity I `retired`；其 nodes 行在离线维护中被移除（无 `node_id_reservations`）。
- 步骤：同上。
- 预期库：**新** identity（`related_identity_id=I`、`generation=I+1`），`config_version=1`；新 nodes 行 id 由 AUTOINCREMENT 分配（**不**复用旧 id）；旧 identity 仍 retired。
- 预期业务：历史完全隔离；新节点需重新检测与评分。

---

# B. v0.6 → v0.7 修订对照

| # | v0.6 | v0.7 | 章节 | 关闭情况 |
| --- | --- | --- | --- | --- |
| R1 | 样本不足机场"不纳入全局判定" | 参与集合固定；样本不足**阻断**全局确认；停用/不足/空池三类分开 | §2 | 关闭 |
| R2 | 只用本次响应算可发布 | `eligible_at` 不读"是否返回"；`E`/`F_ev` 定义明确；统一时点 | §3 | 关闭 |
| R3 | 任务结果按提交时版本记账 | `detection_tasks` 固化执行版本；不一致只记 `stale` | §4 | 关闭 |
| R4 | `fresh()` 只查 pass + 时间 | 七条校验（版本/规则/TCP/系统故障/valid/TTL/pass），三处复用 | §5 | 关闭 |
| R5 | 任意时刻可回退日快照 | 窗口必须精确对齐；不对齐 → `baseline_insufficient` | §6 | 关闭 |
| R6 | 触发器只查"存在合法令牌" | 令牌成为 `nodes.restore_token` 外键引用 + 唯一索引 + 三触发器；明确能力边界 | §7 | 关闭（边界如实声明） |
| R7 | 用 `live.identity` 自证冲突 | `claim_candidate` 与 `node_assignment` 分离 + 整轮一致性检查 | §8 | 关闭 |
| R8 | retired 回归未定义 | 按 nodes 行存在与否分流；新 config_version；历史分段隔离 | §9 | 关闭 |
| R9 | `W` 参数写法像已定 | 明确归入 C14；补四种降级状态与验证方法 | §10 | 关闭（参数待确认） |

---

## 13. P0/P1 问题逐项关闭清单

| 来源 | 问题 | v0.7 处理 | 状态 |
| --- | --- | --- | --- |
| 六轮 R1-1（混合机场） | 排除样本不足机场后判定 | §2.3 `scope_blocked` 硬阻断 | 已关闭 |
| 六轮 R1-2（停用 vs 不足） | 两类混同 | §2.2 五类表 + `excluded_disabled` | 已关闭 |
| 六轮 R1-3（零分母） | 未定义 | §2.3 `zero_denominator` | 已关闭 |
| 六轮 R2-1（未返回的有效成功） | 被忽略 | §3.2 `eligible_at` 不读返回状态 | 已关闭 |
| 六轮 R2-2（曾失败后成功） | 仍被当失败 | §3.3 `F_ev` 退出规则 | 已关闭 |
| 六轮 R2-3（时点混用） | 各集合时点不同 | §2.6/§3.4 单一只读快照 + `as_of` | 已关闭 |
| 六轮 R3-1（执行版本） | 未固化 | §4.2 两表固化 | 已关闭 |
| 六轮 R3-2（旧结果污染） | 直接记账 | §4.3 `stale` 分支 | 已关闭 |
| 六轮 R4-1（`fresh` 不全） | 只查 pass/时间 | §5.2 七条校验 | 已关闭 |
| 六轮 R5-1（快照时点） | 可任意回退 | §6.2 窗口精确对齐 | 已关闭 |
| 六轮 R6-1（令牌可抢用） | 无行级绑定 | §7.2 `restore_token` + 唯一索引 | 已关闭 |
| 六轮 R6-2（调用者鉴权） | 表述夸大 | §7.3 能力边界声明 | 已关闭（如实降级表述） |
| 六轮 R7-1（冲突自证） | 循环论证 | §8.2 双来源 + 整轮检查 | 已关闭 |
| 六轮 R8-1（retired 回归） | 无流程 | §9.2 三分流表 | 已关闭 |
| 六轮 R9-1（窗口参数） | 似已批准 | §10.1 归入 C14 | 已关闭（待确认） |

---

# C. 待确认决策（不得视为已批准）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C1–C10 | 沿用 | 不变 | 沿用 |
| **C11** | `occurrence_seq` 是否按机场永久单调 | 是 | 未确认 |
| **C12** | 是否允许 P0 一次重建 `nodes` 表 | 是 | 未确认 |
| **C13** | `detection_task_runs` 保留期 | 30 天 + 任务键不重用 | 未确认 |
| **C14** | `W_obs` 采样窗口（6h / 最近 3 次） | 6h 优先，不足取 3 次；以实测为准 | 未确认 |
| **C15** | `rep` 门槛（0.90 / 0.60） | 0.90 确认、0.60 强不足 | 未确认 |
| **C16** | retired 身份回归是否允许复用原 identity（nodes 行存在时） | 允许（新建 config_version） | **新增，未确认** |

**仍需实机验证**：机场 stable_id 覆盖率；生产库重复配置比例；NAS `fsync`/`rename` 语义；presence log 与任务表 30 天体量；轮询周期分布（决定 C14/C15）。

---

# D. 风险与兼容

| # | 风险 | 触发 | 缓解 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 样本门槛过严导致真故障不告警 | 轮询周期长 | C14/C15 实测校准；保守方向（宁 scope_blocked 不误判） | Z16–Z18 |
| 2 | `E` 含未返回节点导致长期无法确认零健康 | 节点长期不返回但结果新鲜 | 结果 TTL 90 分钟自然过期；UI 展示 `|E|` 明细 | Z20 |
| 3 | 令牌仍可能被"知情代码"使用 | 直接构造四元组 | 行级绑定 + 唯一索引 + 审计 + 评审 grep；边界已声明 | F21/F22 |
| 4 | 任务表与 runs 表双写不一致 | 事务中断 | 同在 `BEGIN IMMEDIATE`；FK 保证 runs 必有 task | T8/T9 |
| 5 | retired 复活导致历史混读 | 查询未按 config_version 过滤 | `fresh()` 强校验版本；评分按版本分段 | I31/I32 |
| 6 | 快照时区漂移 | 服务器非 UTC+8 | `tz_mismatch` 拒用快照 | RP13 |
| 7 | 触发器增加写入开销 | 每结果 4–5 个触发器 | 只保留结构必需；基准测试（待实测） | 性能测试 |
| 8 | 旧代码写入被拒 | 回退 | 新列均有默认值；负向测试覆盖回退场景 | 回退用例 |

**兼容承诺**：v0.7 不改变任何已确认业务规则；所有修订都是"收紧统计口径、把推断替换为证据"。

---

**v0.7 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**。C11–C16 均待确认。文档交回第七轮设计审查；在获得明确批准前，不提交实施计划、不进入任何阶段。
