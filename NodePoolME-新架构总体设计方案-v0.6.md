# NodePoolME 新架构总体设计方案 v0.6

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.5
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改配置与生产数据。**
**修订依据**：v0.5 第五轮审查的九项问题（R1–R9）
**文档状态**：**待第六轮设计审查**（未自行认定通过）

---

## 修订索引（v0.5 → v0.6）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| R1 | 可信度计数与配置确认计数分离 | §2 | 重写 |
| R2 | 历史 claim 按 `release_reason` 决定能否恢复旧身份 | §3 | 重写 |
| R3 | 恢复聚合区分"故障过的目标"与"始终正常的目标" | §4 | 重写 |
| R4 | 检测任务幂等闸门（库级） | §5 | 新增 |
| R5 | 配置版本全字段不可变 | §6 | 重写 |
| R6 | 回池授权令牌改为持久表 + 可执行触发器 | §7 | 重写 |
| R7 | presence 快照时间基准与重建边界 | §8 | 重写 |
| R8 | 轮询机场零健康改按"池代表性"判定 | §9 | **重写（重点）** |
| R9 | 写探针遗留记录与 `schema_migrations` DDL | §10 | 重写 |

未修订：Q1–Q12、30 天 missing、不改指纹、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减 AND 规则、两次独立拉取确认、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`。**C11、C12 仍为待确认，本文档未批准。**

---

## 0. 一句话结论

v0.5 的九项问题有一个共同结构：**两件事被一个变量表示**。

- 一个 `seen_count` 同时表示"id 见过几次"和"配置变过几次"→ 配置一变就永远不信（R1）；
- 一个 `recovery_state='confirmed'` 既表示"恢复过"也表示"没事"→ 从没失败的目标被要求恢复（R3）；
- 一个 `A_eff` 既表示"本次能测的节点"也表示"机场全部节点"→ 子集失败被判成全池失效（R8）。

v0.6 的原则：**一个变量只表示一件事；缺少证据的判定一律降级为"样本不足"，不升级为"确认"。**

---

## 1. 保留的既定设计（不重开）

Q1–Q12；`missing` 30 天；不改指纹；30 分钟 per-node + 抖动；业务 90 分钟；测速 17:00–24:00 与 50MB；骤减"≥50% 且 ≥10"双条件 + 两次独立确认；30 个可恢复版本；恢复需两次有效成功、间隔 ≥30 分钟（本轮只把"两次"定义得更可证，数值不变）；TCP-only 永不合格；四格式/四 URL/UA/Token/两种 `sub_publish`；P-1 只做安全底座。

---

## 2. R1：可信度计数与配置确认计数

### 2.1 v0.5 的死锁

v0.5 只在"配置未变"时 `claim_incr`：

```python
if n.fingerprint == cur.fingerprint:
    claim_incr(live)          # ← 只有这里 +1
...
pend = upsert_pending(...)     # ← 配置变化时走这里，seen_count 不动
```

若某节点每次拉取的指纹都不同（机场动态下发参数），则 `seen_count` 永远停在 1，而 G1 要求 `seen_count >= 2` → **永远不能轮换，也永远不能确认 id**（R1.3）。

根因：把"id 出现次数"和"配置候选确认次数"压进了一个计数器，而两者的递增条件根本不同。

### 2.2 两个计数器，各管一件事

| 计数器 | 位置 | 统计对象 | 递增条件 | 幂等条件 | 重置条件 |
| --- | --- | --- | --- | --- | --- |
| `seen_count` | `identity_stable_ids` | "该 id 在 `applied` 拉取中出现，且指向同一身份"的次数 | 每次出现即 +1，**与配置是否变化无关** | `last_seen_pull_version < 本次 pull_version` | 只在新 claim 建立时从 1 开始；旧 claim 释放即停 |
| `observed_count` | `identity_config_pending` | "候选配置完全一致"的连续次数 | 候选完全一致时 +1（指纹 + base 指纹 + server + port + display_name） | `last_pull_version < 本次` 且候选哈希相同 | 候选任一字段变化 → 整行替换，计数=1；旧配置回归 → 删除 pending |

于是：

```
id 可信（可作轮换/迁移证据） ⇔ live.claim.seen_count >= 2
配置已确认（可执行 G1/H1）   ⇔ pending.observed_count >= 2  AND  live.claim.seen_count >= 2
```

两者都按 `applied` 拉取计，但**互不阻塞**：一个每次指纹都变的机场，`seen_count` 仍会正常涨到 2、3、4…；只是 `observed_count` 永远停在 1，因此不会轮换——这是"配置不可确认"的正确表现，而不是"id 不可信"。

### 2.3 `seen_count` 的完整规则

```
每次 applied 拉取（suspect/skip 不算）：
  对响应中每个稳定 id：
    claim = live claim(airport, id)
    if claim is None:            # 首次出现
        claim = create_claim(..., seen_count=1, last_seen_pull_version=pull)
    elif claim.identity == 本次绑定的身份:
        if claim.last_seen_pull_version < pull:      # 幂等
            claim.seen_count = min(claim.seen_count + 1, 100)
            claim.last_seen_pull_version = pull
            if claim.seen_count >= 2 and claim.confirmed_at is None:
                claim.confirmed_at = now; event("stable_id_confirmed")
    else:                        # id 指向了别的身份 → 脏复用
        release_claim(claim.id, reason="reused")
        create_claim(new identity, seen_count=1, generation=claim.generation+1)
        event("stable_id_conflict")
```

**关键**：`seen_count` 只在"同一 id → 同一身份"时累加；配置是否变化不影响它。这直接修复 R1.3。

### 2.4 DDL（R1.6）

```sql
CREATE TABLE identity_stable_ids (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id            INTEGER NOT NULL,
  stable_id             TEXT NOT NULL,
  identity_id           INTEGER NOT NULL REFERENCES node_identities(id),
  generation            INTEGER NOT NULL DEFAULT 1,   -- 同一 id 的第几手（R2 用）
  seen_count            INTEGER NOT NULL DEFAULT 1 CHECK(seen_count BETWEEN 1 AND 100),
  last_seen_pull_version INTEGER,
  claimed_at            TEXT NOT NULL,
  confirmed_at          TEXT,                          -- seen_count 首次达到 2 的时点
  released_at           TEXT,
  release_reason        TEXT CHECK(release_reason IN ('absent','reused','manual'))
);
CREATE UNIQUE INDEX uq_claim_live ON identity_stable_ids(airport_id, stable_id)
  WHERE released_at IS NULL;
CREATE INDEX idx_claim_hist ON identity_stable_ids(airport_id, stable_id, generation DESC);

CREATE TABLE identity_config_pending (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_id            INTEGER NOT NULL REFERENCES node_identities(id),
  candidate_fingerprint  TEXT NOT NULL,
  candidate_base_fp      TEXT NOT NULL,
  candidate_server       TEXT NOT NULL,
  candidate_port         INTEGER NOT NULL,
  candidate_display_name TEXT,
  observed_count         INTEGER NOT NULL DEFAULT 1,
  last_pull_version      INTEGER NOT NULL,
  first_observed_at      TEXT NOT NULL,
  last_observed_at       TEXT NOT NULL,
  UNIQUE(identity_id, candidate_fingerprint)
);
```

（`state` 字段取消：pending 只有"存在=observing"与"删除"两态，`confirmed` 由动作本身体现、`abandoned` 记事件；减少一个需要同步的状态。）

### 2.5 伪代码（R1.5）

```python
def resolve(airport, n, pull, ctx):
    live = claim_for(airport, n.stable_id) if n.stable_id else None

    if live:
        ident, cur = live.identity, ctx.current_version(live.identity)

        # 先做"可信度累积"，与配置无关
        claim_incr(live, pull)                 # 幂等，按 pull_version

        if n.fingerprint == cur.fingerprint:
            ctx.clear_pending(ident)
            return bind(ident, n, reason="stable_same")

        pend = ctx.upsert_pending(ident, n, pull)     # 比较完整候选
        if pend.observed_count < 2:
            return hold(n, reason="config_change_observing")   # 不建节点、不绑定
        if live.seen_count < 2:
            return hold(n, reason="stable_id_unconfirmed")      # id 尚不可信

        if n.endpoint == cur.endpoint:
            ctx.clear_pending(ident)
            return bump_version(ident, n, reason="stable_rotated")
        return migrate_to_new_identity(airport, n, live)
    ...
```

注意 `claim_incr` 放在最前面：无论后面走"同配置"还是"观察"，可信度都会累积。

### 2.6 事务顺序

| 操作 | 顺序 |
| --- | --- |
| 同配置 | `claim_incr` → 清 pending → 绑定（同一事务） |
| 观察 | `claim_incr` → `upsert_pending`（计数+1 或整行替换） → event |
| 轮换 | `claim_incr` → 版本行 → `nodes.cv` → `identity.current` → 旧版本 closed → 清 pending |
| 首次确认 | `claim_incr` 达 2 时写 `confirmed_at` + event，与 presence 更新同事务 |

### 2.7 测试（I 组新增 3 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| I21 | 首次拿 id 后第 2 次拉取配置就变了 | `seen_count=2`（可信达标）且 `observed_count=1`（配置未确认）→ 不轮换、不新建 |
| I22 | 配置连续变化（每次指纹不同） | `seen_count` 仍逐个 `applied` 递增至 2、3…；`observed_count` 恒 1；无版本变化 |
| I23 | 配置稳定但 id 首次出现 | 第 2 次拉取：`seen_count=2` + `observed_count=2` → 正常轮换 |

---

## 3. R2：历史 claim 复用后的身份恢复

### 3.1 v0.5 的错误

v0.5 的历史恢复只看 `fp` 与 `endpoint`：

```python
if (old.lifecycle in ("active","missing")
        and n.fingerprint == ctx.current_version(old).fingerprint
        and n.endpoint == ctx.current_version(old).endpoint):
    return readopt(old, ...)
```

机场把同一个 id 改嫁给新机器后（该 claim 已 `release_reason='reused'`），新机器若配置与原机器完全相同，就会被**自动认成原机器**，直接继承其历史、槽位与状态（R2.2）。而"配置相同"根本不能区分两台机器。

### 3.2 按释放原因决定恢复规则

| `release_reason` | 含义 | id 再次出现时的处理 |
| --- | --- | --- |
| `absent` | 身份因长期缺席（30 天）或轮询窗口结束被释放，**未观察到改嫁** | 允许 `readopt`：配置一致则复用旧身份（状态 `unknown`，不继承 Healthy）；配置不一致 → 按新机器 |
| `reused` | 系统**已观察到**该 id 被分配给另一台机器 | **禁止**自动 readopt，即使配置完全相同 → 新身份 + `generation+1` + `related_identity_id`；旧身份保持 `missing` |
| `manual` | 人工强制释放（运维/排障） | **禁止**自动恢复 → 新身份 + `ambiguous=1` + `needs_review`；事件等待人工复核 |

规则写成一句硬话：**"配置相同"不是身份证据；"未被观察到改嫁"才是。**

```python
def restore_from_history(airport, n, hist_claim):
    """history 分支的唯一入口：先看 release_reason，再看配置"""
    reason = hist_claim.release_reason
    if reason == "absent":
        if config_matches(hist_claim.identity, n):          # 允许原机器回归
            return readopt(hist_claim.identity, n,
                           claim=new_claim(airport, n.stable_id,
                                           hist_claim.identity_id,
                                           generation=hist_claim.generation))
        return new_identity(airport, n, related=hist_claim.identity_id)
    if reason == "reused":                                   # 已被观察到改嫁
        return takeover_on_reused(airport, n, hist_claim)     # 配置相同也必须新身份
    if reason == "manual":                                   # 人工释放
        new = new_identity(airport, n, related=hist_claim.identity_id, ambiguous=1)
        ctx.flag(new, "needs_review"); event("manual_release_return")
        return new
    raise AssertionError("release_reason must be one of absent/reused/manual")
```

### 3.3 接管时如何防止继承历史（R2.4）

```python
def takeover_on_reused(airport, n, hist_claim):
    """hist_claim.release_reason == 'reused'"""
    new = new_identity(airport, n, seq=max_seq+1,
                       related=hist_claim.identity_id,
                       generation=hist_claim.generation + 1,
                       ambiguous=1 if n 与旧配置完全相同 else 0)
    attach_claim(airport, n.stable_id, new.id,
                 generation=hist_claim.generation + 1)
    event("stable_id_generation_advance",
          detail={"from_generation": hist_claim.generation,
                  "old_identity": hist_claim.identity_id,
                  "config_identical": bool})
    return new
```

四道防线：

1. **永不把旧 `node_config_versions` 挂到新身份**：新身份从 `version=1` 重新开始；
2. **`related_identity_id` 只做审计关联**，任何查询（评分、历史、覆盖）都不得沿它取旧数据；
3. **`generation` 单调递增**：审计界面可直接显示"该 id 第 N 手"；
4. **`ambiguous=1`** 当新旧配置完全相同（无法自证），UI 明示"可能不是原机器"。

### 3.4 三种释放原因的写入主体

| 触发释放的场景 | `release_reason` |
| --- | --- |
| identity 因 30 天缺席转 `retired` | `absent` |
| H1 迁移（端点变化，已确认） | `reused` |
| 脏复用（同 id 指向不同身份） | `reused` |
| 人工释放 | `manual` |

### 3.5 测试（I 组新增 4 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| I24 | `reused` 后同配置回归 | **不**复用旧身份；新身份 `version=1`；`generation=2`；`ambiguous=1` |
| I25 | `absent` 后同配置回归 | 复用旧身份；状态 `unknown`；不继承 Healthy；无新 generation |
| I26 | `manual` 后回归 | 新身份 + `needs_review`；不自动检测发布 |
| I27 | `reused` 后旧身份曾被置 missing | 旧身份仍 missing；新身份 active；两者并存不冲突（`uq_claim_live` 允许，因旧 claim 已释放） |

---

## 4. R3：恢复状态机的目标聚合

### 4.1 v0.5 的问题

v0.5 的恢复条件是：

```python
if node.episode_started_at:
    if all(recover_ready(t) for t in ts): healthy
```

而 `recover_ready` 要求 `recovery_state == 'confirmed'`。于是：

- G 失败 3 次导致 node `unavailable`，W 一直正常（`recovery_state='none'`）；
- G 恢复并被确认后，W 仍为 `'none'` → `all(...)` 为假 → 节点**永远卡在 recovering**。

同时 `recompute` 的非恢复分支也写了 `all(t.recovery_state=='confirmed')` → 同样卡死（R3.4）。

根因：把"恢复过"当成"健康"的必要条件，而"从未失败"被误当成"未恢复"。

### 4.2 区分两类目标

```sql
-- node_target_state 增列
faulted_in_episode INTEGER NOT NULL DEFAULT 0 CHECK(faulted_in_episode IN (0,1))
```

| 类别 | 定义 | 恢复要求 |
| --- | --- | --- |
| 故障目标（`faulted_in_episode=1`） | 本 episode 内出现过**有效失败**（或 `recovery_state != 'none'`） | 两次独立有效成功、间隔 ≥30 分钟（`recovery_state='confirmed'`） |
| 始终正常目标（`faulted_in_episode=0` 且 `recovery_state='none'`） | 本 episode 内没有有效失败 | **不要求恢复确认**，但必须：当前 config_version、有效结果 `pass`、`last_pass_at + ttl > now` |

### 4.3 聚合函数（唯一判定入口）

```python
def fresh(t):
    return t.last_result == "pass" and t.last_pass_at + t.ttl > db.now()

def target_ok(t):
    if t.faulted_in_episode or t.recovery_state != "none":
        return fresh(t) and t.recovery_state == "confirmed"
    return fresh(t)                      # 从未故障：只要有当前有效 pass 且新鲜

def recompute(node):
    ts = required_targets(node)
    max_fail = max(t.fail_streak for t in ts)
    if max_fail >= T:      return "unavailable"
    if max_fail == T - 1:  return "unstable"
    if max_fail >= 1:      return "observe"
    if any(t.last_result == "unknown" for t in ts):  return "unknown"

    if node.episode_started_at:
        if all(target_ok(t) for t in ts):
            close_episode(node)          # 清 episode_started_at + 全部 faulted_in_episode
            return "healthy"
        return "recovering"

    return "healthy" if all(target_ok(t) for t in ts) else "observe"
```

**说明**：非 episode 分支不再要求 `confirmed`；首次通过（无 episode、无故障）自然为 healthy（保留 Q11 语义：只有"从坏状态回来"才需要两次确认）。

### 4.4 目标级完整状态机（R3.5）

```
        ┌────────────── 有效失败 ──────────────┐
        │                                      ▼
   (none) ──首次失败──► (none, faulted=1) ──第1次成功──► (observing)
        ▲                        │                        │
        │                        │ 再次失败                │ 第2次成功
        │                        └──────────────┐         │ （不同任务，≥30min）
        │ 有效失败（清四字段）                    ▼         ▼
        └────────────────────────────────── (none) ◄── (confirmed)
```

| 状态 | `recovery_state` | `faulted_in_episode` | 额外证据 |
| --- | --- | --- | --- |
| 未故障 | `none` | 0 | — |
| 故障中（尚未成功） | `none` | 1 | `fail_streak >= 1` |
| 恢复观察 | `observing` | 1 | `first_pass_at`、`first_task_id` |
| 恢复确认 | `confirmed` | 1 | `first/confirm` 时间与任务 id |
| 再次失败 | `none` | 1 | 四字段清空、`fail_streak+1` |

### 4.5 测试（S 组新增 6 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| S29 | G 失败 3 次（unavailable），W 始终正常 | `G.faulted=1`、`W.faulted=0`；W 不被要求 confirmed |
| S30 | 同上，G 首次恢复成功 | 节点仍 recovering（G 未 confirmed）；W 的 `target_ok` 为真 |
| S31 | 同上，G 第二次成功（35 分钟后） | G confirmed → 节点 healthy；W 未参与恢复确认 |
| S32 | W 在此期间 TTL 到期 | 节点**不** healthy（W `fresh=false`）→ 停在 recovering，UI 标 W stale |
| S33 | healthy 后 W 首次有效失败 | 新 episode；仅 W `faulted=1`；G 不需要重新确认 |
| S34 | episode 结束 | `episode_started_at` 与所有 `faulted_in_episode` 清零 |

---

## 5. R4：检测任务幂等

### 5.1 v0.5 的漏洞

v0.5 只在恢复字段上做幂等（`task != first_task` 才推进），但 `last_pass_at`、`success_streak`、`fail_streak` 仍会被重复提交刷新：

- 任务超时重发、结果被写入两次 → `last_pass_at` 前移，TTL 被"续命"；
- 同一 `task_id` 落到两个目标 → 两个目标都被算作"两次独立成功"；
- 同一任务在版本切换后被重新应用 → 新版本目标行被旧任务"预填"。

根因：幂等在**应用层**判断，而数据库没有任何"这条结果已经处理过"的事实。

### 5.2 库级闸门：任务结果登记表

```sql
CREATE TABLE detection_task_runs (
  task_id        TEXT PRIMARY KEY,                 -- 全局唯一 uuid（唯一范围：单次检测任务）
  node_id        INTEGER NOT NULL,
  identity_id    INTEGER NOT NULL,
  target         TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  rule_version   INTEGER NOT NULL,
  outcome        TEXT NOT NULL CHECK(outcome IN ('pass','fail','invalid')),
  finished_at    TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);
CREATE INDEX idx_task_tuple ON detection_task_runs(node_id, target, config_version, finished_at);
```

主键 `task_id` 就是闸门：**同一任务只能登记一次**。登记与状态更新在**同一事务**内完成，因此"登记成功但状态未更新"不可能出现（回滚会一起撤销）。

### 5.3 应用流程

```python
def apply_result(node, target, outcome):
    # ① 有效性先判（无效结果也要登记，防止重复噪音）
    valid = validity.is_valid(outcome, node)

    # ② 幂等闸门
    try:
        db.execute("""INSERT INTO detection_task_runs
                      (task_id,node_id,identity_id,target,config_version,rule_version,outcome,finished_at)
                      VALUES (?,?,?,?,?,?,?,?)""",
                   outcome.task_id, node.id, node.identity_id, target,
                   node.config_version, outcome.rule_version,
                   "pass" if valid and outcome.pass else ("fail" if valid else "invalid"),
                   db.now())
    except UniqueViolation:
        row = db.one("detection_task_runs", task_id=outcome.task_id)
        if (row.node_id, row.target, row.config_version, row.rule_version) != \
           (node.id, target, node.config_version, outcome.rule_version):
            event("task_id_misuse", detail={"stored": row.tuple(), "incoming": (...)})
        return                    # 完全重复或错误复用 → 一律不改状态

    # ③ 以下全部在同一事务内
    if not valid:
        validity.record_invalid(outcome); return
    t = target_state.upsert(node, target, outcome)
    ...（更新 last_pass_at / fail_streak / recovery 证据）
    new_state = recompute(node); ...
```

**幂等的范围**：`last_pass_at`、`fail_streak`、`success_streak`、`recovery_*`、`state`、`state_history` 全部不因重复提交而改变（因为第二次连闸门都进不去）。

### 5.4 三类错误复用的处理

| 情形 | 检测方式 | 处理 |
| --- | --- | --- |
| 同一任务、同一 (node,target,version,rule) 重复提交 | 主键冲突 + 四元组相同 | 静默丢弃（等价于"已处理"） |
| 同一 `task_id` 被用于另一目标/节点 | 主键冲突 + 四元组不同 | 丢弃 + `task_id_misuse`（critical） |
| 同一 `task_id` 跨 config_version | 四元组不同 | 丢弃 + 事件；不写任何目标行 |
| `invalid` 结果重复 | 同上 | 只登记一次，不产生多条 invalid |

### 5.5 测试（T 组，5 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| T1 | 同一任务结果提交两次 | 第二次无任何写入；`last_pass_at` 不变；`success_streak` 不变 |
| T2 | 同一任务先 pass 再 fail | 第二次丢弃；状态仍为 pass |
| T3 | 同一 task_id 用于 G 与 W | W 被丢弃 + `task_id_misuse` |
| T4 | 版本切换后旧任务被重放 | 丢弃；新版本目标行保持 unknown |
| T5 | `invalid` 结果重复 | 只登记一条；无 invalid 计数加倍 |

---

## 6. R5：配置版本不可变

### 6.1 字段分类

| 字段 | 类别 | 允许变更？ |
| --- | --- | --- |
| `identity_id`、`version` | 主键 | 否 |
| `fingerprint`、`base_fingerprint` | 配置内容 | 否 |
| `params_hash`、`params` | 配置内容 | 否 |
| `protocol`、`server`、`port` | 配置内容 | 否 |
| `display_name`、`sample_raw_name` | 配置内容（含展示名） | 否 |
| `change_reason` | 建立原因 | 否 |
| `first_seen_at` | 建立时间 | 否 |
| `last_seen_at` | 生命周期元数据 | **是**（每次见到该配置可刷新） |
| `closed_at` | 生命周期元数据 | **是**（版本退役时写一次） |

### 6.2 触发器（覆盖全部不可变字段，R5.4）

```sql
CREATE TRIGGER trg_version_immutable
BEFORE UPDATE OF identity_id, version, fingerprint, base_fingerprint,
                 params_hash, params, protocol, server, port,
                 display_name, sample_raw_name, change_reason, first_seen_at
ON node_config_versions
WHEN NEW.identity_id       <> OLD.identity_id
  OR NEW.version           <> OLD.version
  OR NEW.fingerprint       <> OLD.fingerprint
  OR NEW.base_fingerprint  <> OLD.base_fingerprint
  OR NEW.params_hash       <> OLD.params_hash
  OR NEW.params            <> OLD.params
  OR NEW.protocol          <> OLD.protocol
  OR NEW.server            <> OLD.server
  OR NEW.port              <> OLD.port
  OR COALESCE(NEW.display_name,'')   <> COALESCE(OLD.display_name,'')
  OR COALESCE(NEW.sample_raw_name,'')<> COALESCE(OLD.sample_raw_name,'')
  OR NEW.change_reason     <> OLD.change_reason
  OR NEW.first_seen_at     <> OLD.first_seen_at
BEGIN SELECT RAISE(ABORT,'config version fields are immutable'); END;

-- 生命周期元数据只允许"向前"写
CREATE TRIGGER trg_version_closed_once
BEFORE UPDATE OF closed_at ON node_config_versions
WHEN OLD.closed_at IS NOT NULL AND NEW.closed_at IS NOT OLD.closed_at
BEGIN SELECT RAISE(ABORT,'closed_at can be written only once'); END;
```

（`display_name` / `sample_raw_name` 用 `COALESCE(...,'')` 比较，避免 NULL 参与比较时恒为 NULL 导致触发条件失效。）

### 6.3 逐字段负向测试（FT 组新增 8 个）

| # | 操作 | 期望 |
| --- | --- | --- |
| FT15 | UPDATE fingerprint | abort |
| FT16 | UPDATE base_fingerprint | abort |
| FT17 | UPDATE params / params_hash | abort |
| FT18 | UPDATE protocol / server / port | abort |
| FT19 | UPDATE display_name（→ NULL） | abort |
| FT20 | UPDATE sample_raw_name | abort |
| FT21 | UPDATE change_reason / first_seen_at | abort |
| FT22 | UPDATE last_seen_at（允许） | 成功 |
| FT23 | 第二次 UPDATE closed_at | abort |

---

## 7. R6：过滤节点回池的授权令牌

### 7.1 v0.5 的不可用设计

v0.5 的触发器直接引用 `temp.restore_ctx`：

```sql
AND NOT EXISTS (SELECT 1 FROM temp.restore_ctx c WHERE c.node_id = NEW.id)
```

两个问题（R6.1、R6.2）：

1. **主库持久触发器不能可靠引用 TEMP 对象**：TEMP 表按连接创建，触发器在另一个连接里执行时会解析失败（`no such table`），行为变成"报错而非允许/拒绝"，语义失控；
2. **令牌不真实**：TEMP 表只是"连接内一块内存"，任何能执行 SQL 的代码都能自己 `INSERT INTO temp.restore_ctx`，无法证明授权来自回池流程（R6.9 明确禁止只把 TEMP 改成普通表而不解决真实性问题）。

### 7.2 改为持久表 + 三元组校验 + 一次性消费

```sql
-- 历史 id 预留（保留 v0.5）
CREATE TABLE node_id_reservations (
  node_id            INTEGER PRIMARY KEY,
  filtered_id        INTEGER NOT NULL,
  origin_identity_id INTEGER REFERENCES node_identities(id),
  origin_fingerprint TEXT NOT NULL,
  state              TEXT NOT NULL DEFAULT 'held' CHECK(state IN ('held','restored')),
  created_at         TEXT NOT NULL, released_at TEXT
);

-- 回池授权令牌（持久、一次性、限时、绑定四元组）
CREATE TABLE restore_authorizations (
  token        TEXT PRIMARY KEY,                 -- uuid4
  node_id      INTEGER NOT NULL,
  filtered_id  INTEGER NOT NULL,
  identity_id  INTEGER NOT NULL,
  fingerprint  TEXT NOT NULL,
  tx_marker    TEXT NOT NULL,                    -- 回池事务标记（审计用）
  issued_at    TEXT NOT NULL,
  expires_at   TEXT NOT NULL,                    -- issued_at + 120s
  consumed_at  TEXT,
  FOREIGN KEY (node_id) REFERENCES node_id_reservations(node_id)
);
CREATE UNIQUE INDEX uq_auth_live ON restore_authorizations(node_id)
  WHERE consumed_at IS NULL;                     -- 同一 id 同时只有一张有效令牌
```

**触发器（主库对象，不含任何 TEMP 引用）**：

```sql
-- 令牌签发合法性：必须与预留、过滤记录、身份、指纹全部一致
CREATE TRIGGER trg_auth_issue_valid BEFORE INSERT ON restore_authorizations
WHEN NOT EXISTS (
  SELECT 1 FROM node_id_reservations r
    JOIN airport_filtered_nodes f ON f.id = NEW.filtered_id
   WHERE r.node_id = NEW.node_id
     AND r.state = 'held'
     AND r.filtered_id = NEW.filtered_id
     AND r.origin_identity_id = NEW.identity_id
     AND r.origin_fingerprint = NEW.fingerprint
     AND f.origin_node_id = NEW.node_id
     AND f.mapping_status = 'mapped'
     AND f.origin_state = 'held')
BEGIN SELECT RAISE(ABORT,'restore authorization does not match reservation'); END;

-- 历史 id 插入：必须有有效、未消费、未过期、四元组一致的令牌
CREATE TRIGGER trg_nodes_reserved_id BEFORE INSERT ON nodes
WHEN EXISTS (SELECT 1 FROM node_id_reservations r
             WHERE r.node_id = NEW.id AND r.state = 'held')
 AND NOT EXISTS (SELECT 1 FROM restore_authorizations a
                 WHERE a.node_id = NEW.id
                   AND a.identity_id = NEW.identity_id
                   AND a.fingerprint = NEW.fingerprint
                   AND a.consumed_at IS NULL
                   AND a.expires_at > strftime('%Y-%m-%dT%H:%M:%S','now','localtime'))
BEGIN SELECT RAISE(ABORT,'historic node id requires a valid restore authorization'); END;

-- 令牌一次性：消费后不可复用
CREATE TRIGGER trg_auth_consume_once BEFORE UPDATE OF consumed_at ON restore_authorizations
WHEN OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS NOT OLD.consumed_at
BEGIN SELECT RAISE(ABORT,'authorization already consumed'); END;
```

### 7.3 令牌生命周期（R6.3 / R6.5 / R6.6）

```python
def readmit(f, node):
    r = db.one("node_id_reservations", filtered_id=f.id, state="held")

    with tx():                                       # BEGIN IMMEDIATE：单写者
        token = uuid4(); txm = uuid4()
        # ① 签发（触发器校验四元组）
        db.execute("""INSERT INTO restore_authorizations
                      (token,node_id,filtered_id,identity_id,fingerprint,tx_marker,issued_at,expires_at)
                      VALUES (?,?,?,?,?,?,?,?)""",
                   token, r.node_id, f.id, r.origin_identity_id, r.origin_fingerprint,
                   txm, now, now + 120s)
        # ② 插入（触发器校验令牌）
        row = db.insert("nodes", id=r.node_id, identity_id=r.origin_identity_id, ...)
        # ③ 消费
        db.execute("UPDATE restore_authorizations SET consumed_at=? WHERE token=?", now, token)
        # ④ 释放预留
        db.update("node_id_reservations", node_id=r.node_id, state="restored", released_at=now)
        db.update("airport_filtered_nodes", id=f.id, origin_state="restored")
    return row
```

| 场景 | 结果 |
| --- | --- |
| 事务正常提交 | 令牌 `consumed_at` 已写，行保留作审计（90 天后清理） |
| 事务回滚（插入失败/中途异常） | 令牌、nodes 行、状态更新**一起回滚**，令牌不存在，预留仍 `held` |
| 进程崩溃（提交前） | SQLite 回滚 → 同上；无残留令牌 |
| 进程崩溃（提交后） | 已消费令牌 + `restored` 预留；重跑回池走"幂等返回既有行" |
| 连接复用/连接池 | 令牌在**主库表**中，与连接无关；不依赖任何 TEMP 对象 |
| 并发回池（两连接） | `BEGIN IMMEDIATE` 串行 + `uq_auth_live` → 第二个拿不到 live 令牌 → abort |

### 7.4 如何防止普通创建路径伪造令牌（R6.7）

| 防线 | 作用 |
| --- | --- |
| 签发触发器 | 令牌必须与 `reservations` + `filtered` 的 node_id / filtered_id / identity / fingerprint 全部一致；伪造者必须先有一组合法的映射关系（那就是合法回池条件本身） |
| 一次性 + 限时 120s | 令牌不可预置复用到未来；过期即失效 |
| `uq_auth_live(node_id)` | 同一 id 不能堆叠多张令牌（并发/预置都被拒） |
| 预留状态 | 插入成功后立即置 `restored`，此后该 id 不再受保护（后续删除禁止 + AUTOINCREMENT 保证不复用） |
| 审计 | `tx_marker` 落 `system_events`，异常签发可追溯 |

> **诚实边界**：库层能保证"令牌与真实映射一致、一次性、限时"，**不能证明调用者身份**。运行期唯一合法入口是 `readmit()`（评审 grep：`restore_authorizations` 只允许在该函数内出现），其余写入路径由代码评审与权限控制约束。这一点写清，不用"看起来更严"的假机制掩盖。

### 7.5 测试（F 组新增 6 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| F11 | 正常回池 | 令牌签发→消费→预留 restored；nodes 行 id 正确 |
| F12 | 事务中途抛异常 | 全部回滚；预留仍 held；无令牌残留 |
| F13 | 两连接并发回池同一 id | 一个成功、一个 abort（`uq_auth_live`） |
| F14 | 伪造令牌（四元组不符） | 签发触发器 abort |
| F15 | 令牌过期后插入 | 插入触发器 abort |
| F16 | 进程 kill -9（提交前） | 重启后预留仍 held；可正常回池 |

---

## 8. R7：presence 快照的时间基准

### 8.1 精确定义（R7.1 / R7.2 / R7.3）

| 概念 | 定义 |
| --- | --- |
| 日界线 `D` | 本地日期（`Asia/Shanghai`），`D 00:00:00` 为切点 |
| 快照 `U7(D)` | **截至 `D 00:00:00`** 的 7 天身份并集 = `{id : last_present_at ∈ (D-7d 00:00, D 00:00]}` |
| 快照生成时刻 | `D 00:05`（生成的是"截至 00:00"的快照；00:00–00:05 之间的事件**不计入**） |
| `snapshot_as_of` | 快照行显式存 `D 00:00:00`，用于自证时点，不依赖文件名或生成时间 |
| 当前比较窗口 `U_before(t)` | `(t-7d, t)`，直接从 `identity_presence_log` 聚合（不依赖快照） |

**为什么不用"生成时刻"当基准**：若 00:05 生成却按"截至 00:05"统计，跨午夜拉取会被计入两天，导致 `union_count` 虚高、`growthU` 抖动（R7.1 的问题）。固定 `as_of` 后，同一事件只属于一个日界线。

### 8.2 公式（R7.6）

```
U_before(t)  = { id : exists presence(id, present=1, ts ∈ (t-7d, t)) }
U_after(t)   = U_before(t) ∪ S_t
U7(D)        = 快照行（as_of = D 00:00）
U7_prev(t)   = { id : exists presence(id, present=1, ts ∈ (t-14d, t-7d) }   ← 优先用 log
                缺失时回退：快照 U7(D-7d)
simU         = |U_after(t) ∩ U7_prev(t)| / |U_after(t) ∪ U7_prev(t)|
growthU      = |U_after(t)| / |U7_prev(t)| - 1
median7      = median{ U7(D-6) … U7(D) 的 union_count }        ← 快照表
```

### 8.3 重建边界（R7.4）

| 数据 | 权威 | 重建方式 |
| --- | --- | --- |
| `U_before` / `U7_prev` | `identity_presence_log`（保留 30 天） | 直接窗口聚合 |
| `U7(D)`、`median7` | `airport_identity_daily` / `airport_union_snapshot` | 从 log 按 `as_of` 边界重放；重放结果必须与快照逐项一致，否则以 log 为准并重写快照 |

**边界规则**：`presence_log` 保留 30 天 > 计算所需 14 天；因此只要 log 完整，快照**永远可重建**。快照只是"减少扫描量的缓存"，不是事实源。

### 8.4 降级策略（R7.5）

| 情形 | 判定 | 动作 |
| --- | --- | --- |
| 快照未生成（> 00:30 仍无 `D` 行） | `snapshot_lagging` | 用 log 重建并补写；不阻塞拉取 |
| 快照存在但 `union_count` 与 log 重放不一致 | `snapshot_mismatch` | 以 log 为准，重写快照，事件 |
| log 不足 14 天（新库/清理过度） | `baseline_insufficient` | **暂停**骤减判定与 rolling 判定；不暂停检测与发布；UI 明示 |
| log 与快照均无（首日） | `baseline_empty` | 只累计，不判定 |

### 8.5 测试（RP 组新增 3 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| RP9 | 跨午夜（23:58 与 00:02 两次拉取） | 只计入各自日界线；`union_count` 不重复计数 |
| RP10 | 快照延迟 40 分钟 | `snapshot_lagging`；log 重建结果与补写后快照一致 |
| RP11 | 历史窗口缺失（log 仅 5 天） | `baseline_insufficient`；不判骤减、不判 rolling |

---

## 9. R8：轮询机场的零健康误判（重点）

### 9.1 v0.5 的错误链条

v0.5 的零健康是：

```
cov = 有效节点 / A_eff        （A_eff = 本次响应中的节点）
|A_eff| > 0 且 cov ≥ 90% 且 publishable = 0  → 零健康 → 24h 倒计时
```

轮询机场 118 个长期节点、本次只返回 62 个：这 62 个全挂 → `cov=100%`、`publishable=0` → **直接判定"整个机场零健康"并启动 24 小时旧订阅保留倒计时**。但另外 56 个根本没被观测，它们的死活未知（R8.1–R8.3、R8.7）。

根因：`A_eff` 只描述"本次能看到什么"，却被当成"机场全部节点"。

### 9.2 五个集合，各司其职（R8.9）

| 集合 | 定义 | 用途 | 是否落库 |
| --- | --- | --- | --- |
| `A_raw` | `nodes.lifecycle='active'` 且身份存在 | 展示"原始活跃节点数" | 派生 |
| `A_pool` | 机场长期身份池 = 7 天内出现过的身份（presence log） | 骤减基线、代表性判定 | 派生 |
| `A_detect` | 本次 `applied` 响应中出现的 active 节点（`last_seen_pull_id = pull`） | "本次可检测" | 派生 |
| `A_eff` | `A_detect` 剔除 disabled/suspect/invalid_window 机场 | **覆盖率与 publishable 的分母** | 派生（同一快照） |
| `W_obs` | 最近 6 小时内所有 `applied` 拉取的 `A_detect` 并集（不足 2 次拉取则取最近 3 次） | **样本代表性** | 派生 |

> 三者不再混用：`A_pool` 决定"机场一共有多少节点"，`W_obs` 决定"我们这轮到底看到了多少"，`A_eff` 决定"这一轮能测多少"。

### 9.3 代表性判定（R8.4）

```
rep_ratio(airport) = |A_pool ∩ W_obs| / |A_pool|
```

| `rep_ratio` | 判定 | 含义 |
| --- | --- | --- |
| `≥ 0.90` | 样本充分 | 可进入零健康确认 |
| `0.60 – 0.90` | `rolling_scope` | 覆盖不足：**不判定零健康**、不启动 24h |
| `< 0.60` | `rolling_scope_low` | 强不足：同上，且 UI 提示"机场仅暴露部分节点" |

### 9.4 零健康判定（单一口径，所有机场通用）

```
对每个机场：
  E1  |A_eff| > 0
  E2  rep_ratio ≥ 0.90
  E3  ∀t: cov(t) ≥ 0.90            （cov 只在 A_eff 上算）
  E4  publishable(A_eff) = 0
  E5  所有 n ∈ A_eff 的 fail_streak ≥ 1      ← 有"确实失败"的证据，而非"没被返回"
  E6  无 invalid_window；无未关闭的机场异常

全局零健康 ⇔ 所有参与机场 E1–E6 全部成立，且 Σ|A_eff| > 0
任一机场 E2/E5 不成立 → 该机场记 rolling_scope，且**不纳入**全局判定；
所有机场都不成立 → 全局 rolling_scope（不启动 24h）
```

`E5` 是 R8.6 的核心：**必须证明"统计范围内的节点确实失效"**，而不是"没有被本次返回"。未返回的节点既不进 `A_eff`、也不产生失败证据，因此不会把"缺席"当成"失败"。

### 9.5 数值场景（R8.8）

| # | 场景 | `|A_pool|` | `|W_obs|` | `rep_ratio` | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | 长期 118，本次 62，62 个全失败 | 118 | 62 | 0.525 | `rolling_scope`；**不**启动 24h |
| 2 | 多轮交替，3 轮覆盖 118，全部失败 | 118 | 118 | 1.000 | 各机场 E1–E6 成立 → `zero_health` |
| 3 | 118 全部返回且全失败 | 118 | 118 | 1.000 | `zero_health` |
| 4 | 正常轮询，本次仅 5 个 | 118 | 5 | 0.042 | `rolling_scope_low`；不启动 24h |
| 5 | 62 返回：40 失败、22 正常 | 118 | 62 | 0.525 | `rolling_scope`（且 `publishable>0`） |
| 6 | 非轮询机场，全部返回全失败 | 40 | 40 | 1.000 | `zero_health` |

**场景 2 的细节**：三轮分别返回 40/42/36 个，并集 118，`W_obs=118`，且每个节点在某一轮中都有有效失败（`fail_streak≥1`）→ 满足 E5。这证明"全池确实失效"，与"部分响应"有本质区别。

### 9.6 24 小时倒计时与旧订阅

| 条件 | 行为 |
| --- | --- |
| `zero_health` 成立 | 启动 24h 计时（`confirmed_at` 只写一次），沿用 v0.5 规则（暂停顺延 + 72h 人工） |
| `rolling_scope` / `rolling_scope_low` | **不启动**计时；保持当前 active 版本；记事件 `scope_insufficient` |
| 计时中情况转为 `rolling_scope` | 事件 `scope_degraded`，计时**暂停**（计入 `paused_ms`），不取消 |
| 部分恢复（`publishable ≥ 1`） | 取消计时（`canceled`） |

### 9.7 测试（Z 组新增 5 个，共 15）

| # | 场景 | 断言 |
| --- | --- | --- |
| Z11 | 118/62，62 全失败 | `rolling_scope`；无 24h；active 版本不变 |
| Z12 | 多轮覆盖 118 且全失败 | `zero_health`；24h 启动；`confirmed_at` 只写一次 |
| Z13 | 118 全返回全失败 | `zero_health` |
| Z14 | 正常轮询、本次极少（5 个） | `rolling_scope_low` |
| Z15 | 62 返回中 22 正常 | 不判零健康（`publishable>0`） |

原有 Z1–Z10（库空、全停用、全 suspect、cov 不足、重复评估、72h 等）保持不变。

---

## 10. R9：写探针与 `schema_migrations`

### 10.1 v0.5 的遗留问题

v0.5 用 `schema_migrations` 做探针，写入 `version=-1, result='probe'`：

- 若上次探针崩溃留下 `version=-1` 行，下次插入撞唯一键 → 探针误判为"写失败"，进而把健康库判成 S2/S3；
- 探针行与正式迁移行混在一张表里，任何"取最大版本"的查询都可能读到 `-1` 或 `probe`（R9.4）。

### 10.2 完整 DDL（R9.3）

```sql
CREATE TABLE schema_migrations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  version    INTEGER NOT NULL CHECK(version >= 0
                                    OR (result = 'probe' AND version = 0)),
  applied_at TEXT NOT NULL,
  result     TEXT NOT NULL CHECK(result IN ('success','failed','probe','aborted')),
  probe_token TEXT,                       -- 仅 result='probe' 时非空（uuid）
  note       TEXT
);
-- 正式记录按版本唯一；探针不受此约束，永不影响"最大已应用版本"
CREATE UNIQUE INDEX uq_migration_version ON schema_migrations(version)
  WHERE result IN ('success','failed');
CREATE INDEX idx_migration_result ON schema_migrations(result, applied_at);

-- 探针必须带 token，且同 token 只能一行
CREATE UNIQUE INDEX uq_probe_token ON schema_migrations(probe_token)
  WHERE probe_token IS NOT NULL;
```

正式版本查询一律用：

```sql
SELECT MAX(version) FROM schema_migrations WHERE result = 'success';
```

探针行（`result='probe'`）**永远不参与**该查询。

### 10.3 探针流程（含遗留清理，R9.1 / R9.2 / R9.5）

```python
def probe_main_db():
    # ① 启动时先清理上次遗留（可能是崩溃/清理失败留下的）
    db.execute("DELETE FROM schema_migrations WHERE result='probe'")
    db.commit()

    token = uuid4()
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute("""INSERT INTO schema_migrations(version, applied_at, result, probe_token)
                      VALUES(0, ?, 'probe', ?)""", now, token)
        db.commit()                                     # 真实落盘（synchronous=FULL）
    except (SQLITE_READONLY, SQLITE_FULL, SQLITE_BUSY, IOERR_FSYNC) as e:
        db.rollback(); return S2(ioerr=type(e))

    # ② 清理（失败不影响判定，只留记录）
    try:
        db.execute("DELETE FROM schema_migrations WHERE probe_token=?", token)
        db.commit()
    except Exception:
        event("probe_cleanup_failed", level="warning")
        # 令牌行保留 → 下次启动第①步会清掉；不影响 S1 判定
    return S1(probe_token=token)
```

| 情况 | 系统状态 | 后果 |
| --- | --- | --- |
| 插入 + 提交成功、清理成功 | S1 | 干净 |
| 插入 + 提交成功、**清理失败** | S1（记 warning） | 残留一行 `probe`；下次启动清掉；不影响版本查询 |
| 插入失败 / 提交失败 | S2 | 不写正式失败行；走文件日志 |
| 插入成功但 `fsync` 报错 | S2（`ioerr_fsync`） | 同上（"报成功但没落盘"更危险） |
| 进程在插入后、提交前崩溃 | 回滚 → 无残留 | 下次启动正常 |
| 进程在提交后、清理前崩溃 | 残留一行 `probe` | 下次启动第①步清理；**不撞唯一键**（`version` 唯一索引只覆盖正式行） |

### 10.4 三种失败状态（沿用 v0.5 口径，补一条）

| 状态 | 判定 | 能否写 `schema_migrations` | 记录 |
| --- | --- | --- | --- |
| S1 | 探针插入 + 提交成功 | 能 | 事件 + 正式行 |
| S2 | 探针失败（RO/FULL/BUSY/IOERR） | 不能 | 文件日志降级链（L1→L5，尽力） |
| S3 | `open()` 失败 / `quick_check` 失败 | 不能 | 文件日志；不尝试任何 DB 写 |

文件日志五级降级、`stderr + exit 3` 末级沿用 v0.5 §9.3，并再次声明：**磁盘满时日志也可能写不进去，系统可能没有任何持久记录，不得假设"已记录"。**

### 10.5 测试（M 组新增 4 个，共 10）

| # | 场景 | 断言 |
| --- | --- | --- |
| M7 | 探针提交后崩溃（残留 `probe` 行） | 重启后清理成功；`MAX(version)` 不受影响；判 S1 |
| M8 | 连续两次探针 | 无唯一键冲突；两次 token 不同 |
| M9 | 正式迁移行与探针共存 | `MAX(version WHERE result='success')` 正确 |
| M10 | 清理失败 | 判 S1 + `probe_cleanup_failed`；不误判 S2 |

---

## 11. 迁移与兼容

### 11.1 对库的增量（仅设计，不执行）

| 变更 | 表 | 性质 |
| --- | --- | --- |
| 加 `generation`、`last_seen_pull_version`、`confirmed_at`；`release_reason` 改为三值 | `identity_stable_ids` | 结构 |
| 去 `state`，统一 `last_pull_version` | `identity_config_pending` | 结构 |
| 加 `faulted_in_episode` | `node_target_state` | 加法 |
| 新表 `detection_task_runs` | — | 结构 |
| 新表 `restore_authorizations`；`node_id_reservations` 保留 | — | 结构 |
| 扩触发器：版本全字段不可变、令牌签发/消费 | — | 结构 |
| 重建 `schema_migrations`（加 `id`/`probe_token`/部分唯一索引） | — | 结构 |
| 快照表加 `snapshot_as_of` 语义（`day` 保持日期键） | `airport_identity_daily` | 语义 |

### 11.2 迁移顺序（P0）

```
1 备份 + quick_check + 探针（S1 才继续）
2 重建身份相关表（copy → 行数校验 → rename）
3 建 detection_task_runs / restore_authorizations
4 加 node_target_state.faulted_in_episode（默认 0）
5 重建 schema_migrations（保留 success/failed 行，清 probe）
6 创建/替换触发器（顺序见 §6.2、§7.2）
7 负向测试 FT1–FT23、F1–F16、T1–T5、M1–M10 在临时库跑通
8 写 schema_migrations(success)
```

### 11.3 兼容承诺

- 全部为语义收紧 + 加法；旧代码不写新列时，`faulted_in_episode=0` 与 `recovery_state='none'` 会让"从未故障"的目标按 `fresh()` 判定，不会误判健康。
- 四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`、测速与评分算法**未改动**。
- 前端只增量展示：id 第几手（generation）、待确认配置、样本代表性（`rep_ratio`）、`rolling_scope` 三种态。

---

## 12. 测试矩阵（合并）

| 组 | 数量 | 范围 | 阶段 |
| --- | --- | --- | --- |
| 身份 I | 27 | I1–I12（v0.4）+ I13–I23（v0.5）+ I24–I27（v0.6） | P0 |
| 状态机 S | 34 | S1–S28 + S29–S34 | P1 |
| 任务幂等 T | 5 | T1–T5 | P1 |
| 约束 FT | 23 | FT1–FT14 + FT15–FT23 | P0/P1 |
| 过滤 F | 16 | F1–F10 + F11–F16 | P0 |
| 发布 P | 14 | P1–P14 | P3 |
| 轮询 RP | 11 | RP1–RP8 + RP9–RP11 | P0 |
| 零健康 Z | 15 | Z1–Z10 + Z11–Z15 | P2/P3 |
| 迁移 M | 10 | M1–M6 + M7–M10 | P-1 |
| 小样本骤减 | 5 | v0.2 原表 | P0 |

---

# B. v0.5 → v0.6 修订前后对照

| # | v0.5 | v0.6 | 章节 | 解决度 |
| --- | --- | --- | --- | --- |
| R1 | `seen_count` 只在同配置路径 +1；配置变化即断流 | 两个计数器分离：可信度只看"出现"，确认只看"候选一致"；`claim_incr` 前置 | §2 | 完整 |
| R2 | 历史恢复只比 fp + endpoint | 按 `release_reason` 分流：`absent` 可回归，`reused`/`manual` 一律新身份；`generation` + `ambiguous` 防继承 | §3 | 完整 |
| R3 | 恢复与健康都要求全部目标 `confirmed` | `faulted_in_episode` 区分两类目标；未故障目标只要"当前版本有效 pass + TTL" | §4 | 完整 |
| R4 | 幂等只在应用层、只覆盖恢复字段 | `detection_task_runs` 主键闸门；四元组校验；重复提交零状态变化 | §5 | 完整 |
| R5 | 不可变只覆盖 5 个字段 | 覆盖全部 11 个不可变字段 + `closed_at` 只写一次；9 个负向测试 | §6 | 完整 |
| R6 | 触发器引用 `temp.restore_ctx` | 持久表 `restore_authorizations`（一次性、120s、四元组绑定）+ 签发与消费触发器 | §7 | 完整（附能力边界声明） |
| R7 | 快照基准含糊（生成时刻 vs 统计时点） | 明确定义 `as_of = D 00:00`；`U_before`/`U7_prev` 以 log 为准；四级降级 | §8 | 完整 |
| R8 | `A_eff` 子集失败即判全机场零健康 | 五集合分离 + `rep_ratio` 代表性 + `E5` 失败证据；`rolling_scope` 不启动 24h | §9 | 完整 |
| R9 | 探针用 `version=-1` 与正式行混表 | 新表结构 + `probe_token` + 部分唯一索引 + 启动清理；三种结果明确 | §10 | 完整 |

---

# C. 待确认决策（不得视为已批准）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C1–C10 | 沿用 v0.2–v0.5 | 不变 | 沿用 |
| **C11** | `occurrence_seq` 是否按机场永久单调（跨 missing/retired 不复用） | 是 | **未确认** |
| **C12** | 是否允许 P0 一次完成 `nodes` 表重建（移除旧 `UNIQUE(airport_id,fingerprint)`） | 是 | **未确认** |
| **C13** | `detection_task_runs` 的保留期（长期保留会持续增长；清理后丢失幂等证明） | 保留 30 天 + 任务键不重用 | 新增，未确认 |
| **C14** | `W_obs` 的采样窗口（6 小时 / 最近 3 次取大者）是否合适 | 6 小时优先，不足取 3 次 | 新增，未确认 |
| **C15** | `rep_ratio` 门槛 0.90 / 0.60 两级是否合适 | 0.90 确认、0.60 强不足 | 新增，未确认 |

**仍需实机验证**：机场 stable_id 真实覆盖率；生产库重复配置比例；NAS 上 `fsync` 与目录 `rename` 的实际语义；presence log 与 `detection_task_runs` 的 30 天数据量级；轮询机场真实轮换周期（决定 `W_obs` 窗口）。

---

# D. 风险与兼容

| # | 风险 | 触发 | 缓解 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | `rep_ratio` 过严导致真故障不告警 | 轮询周期长于 6 小时 | 允许 `W_obs` 扩到最近 3 次；门槛待 C15 确认 | Z11/Z12 |
| 2 | 令牌仍依赖应用层唯一入口 | 直接写 `restore_authorizations` | 签发触发器强约束四元组 + 审计 + 评审 grep | F14 |
| 3 | `detection_task_runs` 无限增长 | 高频检测 | 30 天清理 + 任务键不重用（C13） | 容量普查 |
| 4 | 两个计数器语义混淆 | 代码误用 `observed_count` 判 id 可信 | 字段命名区分（`seen` vs `observed`）+ 单函数写入 | I21/I22 |
| 5 | 任务幂等闸门与状态更新未同事务 | 分开提交 | 明确要求同一 `BEGIN IMMEDIATE` | T1/T5 |
| 6 | 快照 `as_of` 与事件时区不一致 | 服务器时区漂移 | 统一 `db.now()`；快照写 `snapshot_as_of` 自证 | RP9 |
| 7 | 零健康分母抖动 | 轮询响应波动 | `A_eff` 单次快照 + `rep_ratio` 门槛 | Z11–Z15 |
| 8 | `schema_migrations` 重建丢历史 | 迁移中断 | copy → 校验行数 → rename | M9 |
| 9 | 触发器增多导致写入延迟 | 每结果 4–5 个触发器 | 只保留结构必需；基准测试（待实测） | 性能测试 |
| 10 | 旧代码写入被新触发器拒绝 | 回退 | 新列均有默认值；FT/T/F 覆盖回退场景 | 回退用例 |

**兼容承诺**：v0.6 不改任何已确认业务规则；所有修订都是"把一个变量拆成两件事"，或"把应用层假设换成可验证证据"。

---

**v0.6 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**。C11–C15 均为待确认事项，未在本文档中批准。文档交回第六轮设计审查；在获得明确批准前，不提交实施计划、不进入任何阶段。
