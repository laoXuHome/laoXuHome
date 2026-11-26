# NodePoolME 新架构总体设计方案 v0.5

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.4
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改配置。**
**修订依据**：v0.4 第四轮审查的八项问题（R1–R8）
**文档状态**：**待第五轮设计审查**（未自行认定通过）

---

## 修订索引（v0.4 → v0.5）

| 编号 | 主题 | 涉及章节 | 性质 |
| --- | --- | --- | --- |
| R1 | stable_id 接管改为"claim 句柄"传递；配置变化先观察后确认 | §2.1–2.9 | 重写 |
| R2 | 恢复确认改为"两次独立任务 + 明确证据字段" | §3.1–3.6 | 重写 |
| R3 | 身份指针与节点指针强绑定；补 INSERT/UPDATE/DELETE 三条路径 | §4 | 重写 |
| R4 | 过滤节点历史 id 用"预留表 + 临时令牌"做库级保护 | §5 | 重写 |
| R5 | 引入"目录持久化"与"指针持久化"两级提交证明 | §6 | 重写 |
| R6 | 覆盖率改为与"本次之前"的历史集合比较；补持久化与重建 | §7 | 重写 |
| R7 | 拆分 `present_in_latest` 的三种职责 | §8 | 重写 |
| R8 | 写探针必须真实写入主库并提交；文件日志降级链 | §9 | 重写 |

未修订：Q1–Q12、30 天 missing、不改指纹、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减 AND 规则、两次独立拉取确认、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`。

---

## 0. 一句话结论

v0.4 的八项问题都指向同一个毛病：**用"看起来对的字段"替代"能证明事实的证据"**。

- 用 `identity.stable_id` 代替"当前哪条 claim 有效"→ 释放错对象（R1）；
- 用 `success_streak` 代替"两次独立任务成功"→ 同一次任务重试即可"恢复"（R2）；
- 用 `present_in_latest` 同时表示生命周期、检测资格、统计分母 → 三种语义互相污染（R7）；
- 用"目录存在"代替"已持久提交"→ 崩溃后发布未提交内容（R5）。

v0.5 的统一原则：**每个判定都必须指向一条可独立验证的证据；证据不存在就判"不可判定"，不判"通过"。**

---

## 1. 保留的既定设计（不重开）

Q1–Q12 全部保留；`missing` 30 天；不改指纹算法；每节点 30 分钟 + 抖动；业务检测 90 分钟；测速 17:00–24:00 与 50MB；骤减"≥50% 且 ≥10"双条件 + 两次独立确认；30 个可恢复版本；恢复两次有效成功且间隔 ≥30 分钟（本轮只把"两次成功"定义得更严，不改变数值）；TCP-only 永不合格；四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`；P-1 只做安全底座。

---

## 2. R1：stable_id 接管流程

### 2.1 v0.4 的四个缺陷

| 缺陷 | 位置 | 后果 |
| --- | --- | --- |
| ① 仍通过 identity 读 stable_id | §2.6 `release_claim(old.stable_id)` | 字段已删，取到 None；释放的是"某条不确定的 claim" |
| ② 接管函数用 `old=identity` 传参 | `takeover_new_identity(old=ident)` | 无法保证释放的是**当前 live claim**，可能释放历史 claim |
| ③ 指纹变 + 端点不变 + `seen_count<2` | 伪代码落到 `takeover_new_identity` | 把"一次尚未确认的配置变化"当成新机器，旧身份被误置 missing |
| ④ 首次拿到 stable_id 的确认流程缺失 | 全文 | `seen_count` 何时 +1、何时具备"轮换证据资格"没有定义 |

### 2.2 claim 是句柄，不是属性

所有涉及 stable_id 的操作**只接受 claim 对象（含 `claim.id`）**，函数签名不再接受 identity：

```python
release_claim(claim_id, reason)          # 只能释放指定 claim
claim_incr(claim)                        # seen_count += 1
claim_for(airport, stable_id) -> Claim | None   # 当前 live claim（released_at IS NULL）
```

`ctx.release_claim(old.stable_id, …)` 这类写法在 v0.5 中**不允许出现**；代码评审可直接 grep 禁止 `identity.stable_id`。

### 2.3 配置变化的三种情形（不再"一变就新建"）

记：`live` = 当前 live claim；`cur` = 该 claim 所属身份的当前版本；`fp`、`ep` = 本次节点的指纹与端点。

| 情形 | 条件 | 是否立即生效 | 处理 |
| --- | --- | --- | --- |
| F 同配置 | `fp == cur.fingerprint` | 是 | 绑定；`claim_incr` |
| G1 已确认的轮换 | `fp != cur.fp`、`ep == cur.endpoint`、`seen_count >= 2`、**且候选配置连续 2 次一致** | 是 | 升 `config_version`（同身份） |
| G2 待观察的轮换 | `fp != cur.fp`、`ep == cur.endpoint`、`seen_count < 2` **或** 候选仅出现 1 次 | **否** | 写 `identity_config_pending`（`observing`），**不绑定、不升版、不判新机器** |
| H1 已确认的迁移 | `fp != cur.fp`、`ep != cur.endpoint`、候选连续 2 次一致 | 是 | 释放 live claim → 新身份 + 新 claim；旧身份 missing |
| H2 待观察的迁移 | 端点变化但候选仅 1 次 | **否** | 同样进 `identity_config_pending`（`observing`） |

**R1.4 的落实**：未确认的配置变化一律停在 `observing`，节点不进入 `nodes` 表（因而不检测、不发布、不影响任何历史）；只有第二次 `applied` 拉取给出**完全相同**的候选（指纹 + 端点 + base 指纹）才允许 `confirmed`。

### 2.4 观察状态机（`identity_config_pending`）

```
                 ┌──────────── 候选变化，第 1 次 ────────────┐
   (无记录) ─────► observing ──第 2 次同候选──► confirmed ──► 执行 G1/H1
                     │  ▲
     第 2 次候选不同 │  │ 回退：旧配置重新出现
                     ▼  │
                 (重置计数=1)          ──7 天未再出现──► abandoned
```

规则：

1. `first_observed_at` 首次写入；`observed_count` 只在"候选完全一致"时 +1；候选变了则**整行替换**（新指纹新纪录，计数=1）。
2. `confirmed` 需要 `observed_count >= 2` **且** 两次之间间隔 ≥ 1 个 `applied` 版本（同一版本重复处理不算，幂等键 `(airport, version, fingerprint)` 去重）。
3. 观察期内旧配置重新出现（`fp == cur.fp`）→ 删除 pending、`claim_incr`、正常绑定；事件 `config_change_abandoned`。
4. 超过 7 天未确认 → `abandoned`，保留审计；旧身份若同时长期不在响应中，按 `absent`→`missing` 常规流程处理（不因 pending 而延长生命周期）。
5. 观察期内**不**写 `node_state_history`、**不**改 `nodes.state`：pending 只影响身份匹配，不影响状态。

### 2.5 首次 stable_id 的确认（R1.6）

| 时点 | 动作 |
| --- | --- |
| 第 1 次 `applied` 看到该 id（无论经 P0 还是 P1–P4 绑定） | 建 claim，`seen_count=1`，事件 `stable_id_seen` |
| 第 2 次 `applied` 该 id 仍指向同一身份、且配置未变 | `seen_count=2`，事件 `stable_id_confirmed`；**此时才具备 G1/H1 的"id 可信"资格** |
| 第 2 次指向不同身份 | 视为"脏复用"：`uq_claim_live` 阻止；旧 claim 释放、新 claim 建立、事件 `stable_id_conflict` |
| 之后每次同指向 | `seen_count += 1`（上限 100，防溢出） |

`seen_count` 只在 `applied=1` 且在**同一事务里**与 presence 更新一起写；suspect/skip 拉取不累加。

### 2.6 §2.7 完整伪代码（R1 交付物）

```python
def resolve(airport, n, pull, ctx):
    """n: 本次响应节点；pull: 本次 applied 版本（含 pull.id）"""
    live = claim_for(airport, n.stable_id) if n.stable_id else None

    # ---------- 段 1：有 live claim ----------
    if live is not None:
        ident = live.identity
        cur   = ctx.current_version(ident)          # 必有值（active 身份）

        if n.fingerprint == cur.fingerprint:
            claim_incr(live)
            ctx.clear_pending(ident)
            return bind(ident, n, reason="stable_same")

        # 配置不同：先观察，不立刻行动
        pend = ctx.upsert_pending(ident, n, pull.id)
        if pend.observed_count < 2:
            ctx.event("config_change_observed", identity=ident.id, detail=pend.summary())
            return hold(n, reason="config_change_observing")     # 不建节点、不绑定

        # 已连续 2 次一致 → 允许生效
        if n.endpoint == cur.endpoint and live.seen_count >= 2:
            claim_incr(live)
            ctx.clear_pending(ident)
            return bump_version(ident, n, reason="stable_rotated")   # G1

        if n.endpoint != cur.endpoint:
            return migrate_to_new_identity(airport, n, live)         # H1
        # 端点相同但 seen_count<2：id 尚不可信 → 继续观察，不升版
        ctx.event("rotate_blocked_unconfirmed_id", identity=ident.id)
        return hold(n, reason="stable_id_unconfirmed")

    # ---------- 段 2：有 stable_id 但无 live claim ----------
    if n.stable_id:
        hist = ctx.history_claims(airport, n.stable_id)     # released_at 非空
        if hist:
            old = hist.newest.identity
            if (old.lifecycle in ("active", "missing")
                    and n.fingerprint == ctx.current_version(old).fingerprint
                    and n.endpoint == ctx.current_version(old).endpoint):
                return readopt(old, n, claim=new_claim(airport, n.stable_id, old.id))
            return takeover(airport, n, old, reason="stable_id_reused")  # 历史 id 改嫁
        ctx.note("stable_id_new")          # 首次出现 → 允许继续 P1–P4

    # ---------- 段 3：P1–P4（组键 = 当前版本的 base_fingerprint） ----------
    group = ctx.free_identities(airport, n.base_fp)
    free  = ctx.free_nodes(n.base_fp)

    if len(group) == 1 and len(free) == 1:
        return bind(group[0], n, reason="single_candidate",
                    claim=ctx.attach_claim(airport, n.stable_id, group[0]))
    # P2 完整名 / P3 编号 / P4 槽位（同 v0.4，命中后同样 attach_claim）

    return new_identity(airport, n, seq=ctx.max_seq(airport) + 1,
                        claim=ctx.attach_claim(airport, n.stable_id, None))


def migrate_to_new_identity(airport, n, live):
    """H1：释放的是 live 这条 claim 本身"""
    with tx():
        release_claim(live.id, reason="reused")            # ← 传 claim.id，不是 identity
        new = new_identity(airport, n, seq=ctx.max_seq(airport) + 1,
                           claim=None, related=live.identity_id)
        attach_claim(airport, n.stable_id, new.id)          # 新 live claim
        ctx.clear_pending(live.identity)
        if live.identity.lifecycle == "active":
            ctx.set_lifecycle(live.identity, "missing", reason="stable_migrated")  # 触发器投影
        ctx.event("probable_migration", node=new.id, detail={"from": live.id})
    return new


def takeover(airport, n, old, reason):
    """历史 id 改嫁：释放的是"历史里那条"不需要，live 本就不存在；
       这里只保证旧身份不被新机器继承历史"""
    with tx():
        new = new_identity(airport, n, seq=ctx.max_seq(airport) + 1,
                           claim=None, related=old.id)
        attach_claim(airport, n.stable_id, new.id)
        if old.lifecycle == "active":
            ctx.set_lifecycle(old, "missing", reason=reason)
        ctx.event(reason, node=new.id, detail={"old": old.id})
    return new
```

**关键点**：`migrate_to_new_identity` 与 `takeover` 都只接受 `live`（claim）或 `old`（identity），二者语义不同，不再混用；`release_claim` 的实参永远是 `claim.id`。

### 2.7 DDL（与伪代码一致，R1.7）

```sql
CREATE TABLE identity_stable_ids (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id     INTEGER NOT NULL,
  stable_id      TEXT NOT NULL,
  identity_id    INTEGER NOT NULL REFERENCES node_identities(id),
  seen_count     INTEGER NOT NULL DEFAULT 1 CHECK(seen_count BETWEEN 1 AND 100),
  claimed_at     TEXT NOT NULL,
  released_at    TEXT,
  release_reason TEXT CHECK(release_reason IN ('reused','absent','manual'))
);
CREATE UNIQUE INDEX uq_claim_live ON identity_stable_ids(airport_id, stable_id)
  WHERE released_at IS NULL;
CREATE INDEX idx_claim_hist ON identity_stable_ids(airport_id, stable_id, released_at DESC);

-- 配置变化观察（pending 唯一写入口）
CREATE TABLE identity_config_pending (
  id                       INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_id              INTEGER NOT NULL REFERENCES node_identities(id),
  candidate_fingerprint    TEXT NOT NULL,
  candidate_base_fp        TEXT NOT NULL,
  candidate_server         TEXT NOT NULL,
  candidate_port           INTEGER NOT NULL,
  candidate_display_name   TEXT,
  observed_count           INTEGER NOT NULL DEFAULT 1,
  first_observed_at        TEXT NOT NULL,
  last_observed_at         TEXT NOT NULL,
  last_pull_version        INTEGER NOT NULL,
  state                    TEXT NOT NULL DEFAULT 'observing'
                           CHECK(state IN ('observing','confirmed','abandoned')),
  UNIQUE(identity_id, candidate_fingerprint)
);
CREATE INDEX idx_pending_state ON identity_config_pending(state, last_observed_at);
```

> `candidate_display_name` 也纳入"完全一致"的比较：名字在两次拉取之间变化，说明候选本身不稳定，不得用于确认。

### 2.8 事务顺序（R1.5）

| 操作 | 顺序（`BEGIN IMMEDIATE`） | 备注 |
| --- | --- | --- |
| 观察 | upsert pending（`observed_count` 按候选一致性 +1 或重置） → event | 不碰 nodes |
| G1 轮换 | 版本行 v(n+1) → `nodes.config_version=n+1` → `identity.current=n+1` → 旧版本 `closed_at` → `claim_incr` → 清 pending | 两指针同事务，外键 DEFERRED 到提交 |
| H1 迁移 | `release_claim(id)` → 新 identity → 新 claim → 旧 identity 置 missing（触发器投影 nodes） | 释放先于建新 |
| 首次确认 | `claim_incr` + presence 更新 + event，同一事务 | 与拉取结果同提交 |

### 2.9 测试（I 组，新增 8 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| I13 | 端点不变、指纹变、`seen_count=1` | 进 `observing`；**不**升版；**不**新建身份；旧身份仍 active |
| I14 | 同上，第 2 次相同候选 | `confirmed` → 升版；旧版本 closed；`claim.seen_count` +1 |
| I15 | 两次候选不同（同端点） | pending 重置计数=1；不确认；无版本变化 |
| I16 | 端点变 + 候选 2 次一致 | H1：live claim 释放（`released_at` 非空）→ 新身份；旧 missing；`probable_migration` |
| I17 | 端点变 + 候选仅 1 次 | 停在 `observing`；**不**新建身份 |
| I18 | 观察期内旧配置回归 | pending 清除；同身份继续；`config_change_abandoned` |
| I19 | 同一 `applied` 版本被重复处理 | 幂等：`seen_count` 不重复 +1；pending 计数不重复 +1 |
| I20 | 首次拿到 id（经 P1 绑定） | claim `seen_count=1` → 第二次 `applied` → 2；`stable_id_confirmed` |

---

## 3. R2：健康恢复确认

### 3.1 v0.4 的推断式恢复（不可靠）

v0.4 用 `success_streak >= 2` 且 `last_pass_at >= base + 30min` 间接推断"两次成功、间隔 30 分钟"。三个漏洞：

1. **同一次任务重试**：任务超时重发、结果重复入库，`success_streak` 变 2，但只发生过一次真实检测；
2. **间隔靠"最后一次 − 基准"推断**：基准是 `recovery_started_at`，不是"第一次成功"，条件可能被"第一次很早、第二次很晚"满足，也可能被"中间有失败"污染；
3. **第三次成功会破坏等式**：`last_pass_at` 前移后，`last_pass_at >= base+30min` 仍成立，但已无法说明"两次成功"是哪两次。

### 3.2 改为显式证据字段

```sql
-- node_target_state 增列（R2）
recovery_state            TEXT NOT NULL DEFAULT 'none'
                          CHECK(recovery_state IN ('none','observing','confirmed')),
recovery_first_pass_at    TEXT,
recovery_first_task_id    TEXT,
recovery_confirm_pass_at  TEXT,
recovery_confirm_task_id  TEXT,
```

`success_streak` 保留为**展示用**，明确标注"不参与任何资格或恢复判定"。

### 3.3 判定规则（硬条件，逐条可验证）

```
确认（在第二次成功写入的同一事务内完成）：
  1 两次成功来自不同检测任务：first_task_id <> confirm_task_id（任务幂等键唯一）
  2 两次都 valid=1（mihomo 真实经代理 + 当前 config_version + 当前 rule_version）
  3 confirm_pass_at - first_pass_at >= 30 分钟
  4 确认时 confirm_pass_at 即该目标"最近一次有效结果"（同一事务写入，天然成立）
  5 中间出现任何有效失败 → 立即 recovery_state='none'，四个字段清空
已确认后：
  6 recovery_state='confirmed' 即视为"恢复证据成立"，不再要求 last_pass_at 等于 confirm_pass_at；
    但一旦出现有效失败 → 回 'none'
节点级：
  7 全部必需目标 recovery_state='confirmed' 且 last_result='pass' 且各自 TTL 新鲜 → healthy
```

**R2.4 的实现说明**：第 4 条在"确认时点"校验——第二次成功与确认写入同事务，故它必然是当时最新有效结果。确认之后 `last_pass_at` 继续前进不破坏证据（否则每 30 分钟就会"证据失效"，反而制造抖动）。这条差异必须在文档里写清，避免评审误读为"放弃最新性校验"。

### 3.4 伪代码

```python
def apply_result(node, target, outcome):
    if not validity.is_valid(outcome, node):
        validity.record_invalid(outcome); return
    t = target_state.upsert(node, target, outcome)
    task = outcome.task_id                       # 检测任务幂等键，唯一

    if outcome.pass:
        if t.recovery_state == "none" and t.fail_streak >= 1:
            t.recovery_state = "observing"
            t.recovery_first_pass_at = db.now()
            t.recovery_first_task_id = task
        elif t.recovery_state == "observing":
            if task != t.recovery_first_task_id:                # 条件 1
                if db.now() - t.recovery_first_pass_at >= RECOVER_GAP:   # 条件 3
                    t.recovery_confirm_pass_at = db.now()
                    t.recovery_confirm_task_id = task
                    t.recovery_state = "confirmed"              # 条件 4 同事务
        # 同一任务重复 → 什么都不做（幂等）

        t.fail_streak = 0
        t.success_streak += 1            # 仅展示
        t.last_pass_at = db.now()
        t.last_result = "pass"
    else:
        t.fail_streak += 1
        t.success_streak = 0
        t.recovery_state = "none"                            # 条件 5
        t.recovery_first_pass_at = None
        t.recovery_first_task_id = None
        t.recovery_confirm_pass_at = None
        t.recovery_confirm_task_id = None
        t.last_result = "fail"
        t.last_fail_at = db.now()
        node.ever_valid_fail = 1

    new = recompute(node)
    ...


def recover_ready(t):
    return (t.recovery_state == "confirmed"
            and t.last_result == "pass"
            and t.last_pass_at + t.ttl > db.now())


def recompute(node):
    ts = required_targets(node)
    max_fail = max(t.fail_streak for t in ts)
    if max_fail >= T:      return "unavailable"
    if max_fail == T - 1:  return "unstable"
    if max_fail >= 1:      return "observe"
    if any(t.last_result == "unknown" for t in ts):  return "unknown"

    if node.episode_started_at:                       # 恢复窗口
        if all(recover_ready(t) for t in ts):
            node.episode_started_at = None
            return "healthy"
        return "recovering"

    if node.ever_valid_fail == 0:  return "healthy"   # 首次通过
    if all(t.recovery_state == "confirmed" for t in ts):  return "healthy"
    return "observe"
```

> 说明：非恢复场景（observe → healthy，行 17）也要求"该目标有过 confirmed 记录"。因为曾在 `observe` 说明发生过有效失败，`recovery_state` 会从 `none` 走到 `confirmed`；这比"累计 2 次成功"更硬。

### 3.5 迁移表增补（在 v0.4 的 20 行基础上）

| # | 前态 | 事件 | 目标层变化 | 新态 | 可发 |
| --- | --- | --- | --- | --- | --- |
| 21 | recovering | 同一任务重复提交"pass" | 无（幂等） | recovering | 否 |
| 22 | recovering | 第二次成功，间隔 29 分钟 | `observing` 保持，first 不变 | recovering | 否 |
| 23 | recovering | 第二次成功，间隔 31 分钟，不同任务 | `confirmed` | healthy（若全目标均 confirmed） | 是 |
| 24 | healthy | 任一目标有效失败 | 该目标 `none` + 清字段 | observe/unstable（按 fail_streak） | 视新鲜度 |
| 25 | observe（单次失败后成功） | 第二次成功 30 分钟后 | 该目标 `confirmed` | healthy | 是 |

### 3.6 测试（S 组新增 6 个，共 28）

| # | 场景 | 断言 |
| --- | --- | --- |
| S23 | 同一任务结果重复入库 2 次 | `recovery_state` 仍 `observing`；不确认 |
| S24 | 两次成功间隔 29 分钟 | 不确认；`first_pass_at` 不被覆盖 |
| S25 | 两次成功之间插入一次有效失败 | `state='none'`，四字段清空；后续重新从第一次算 |
| S26 | 已确认后再来成功（间隔任意） | 保持 `confirmed`；不因 `last_pass_at` 前移而失效 |
| S27 | 已确认后来失败 | 回 `none`；节点按 `fail_streak` 落到 observe/unstable |
| S28 | G confirmed、W 仅 observing | 节点仍 recovering（全目标要求） |

---

## 4. R3：数据库完整性约束

### 4.1 权威关系（R3.1）

> **`node_identities.current_config_version` 是唯一权威指针；`nodes.config_version` 是它的强制镜像，由复合外键绑定，不允许出现"两个当前版本"。**

```sql
-- 身份侧：为被引用准备唯一键
UNIQUE(id, current_config_version)          -- 允许 NULL（建身份瞬间）
-- 节点侧：直接把节点版本钉在身份指针上
FOREIGN KEY (identity_id, config_version)
  REFERENCES node_identities(id, current_config_version)
  DEFERRABLE INITIALLY DEFERRED
```

**为什么必须 DEFERRED**：切换版本时父子指针要一起动——先改 `nodes` 会先撞"节点版本不在版本表"，先改 `identity` 会撞"节点指向旧指针"。二者必须在同一事务内完成，提交时统一校验。这是 SQLite 声明式约束能表达的最紧形式。

同理，身份 → 版本用即时外键（版本行先插，随时可校验）：

```sql
FOREIGN KEY (id, current_config_version)
  REFERENCES node_config_versions(identity_id, version)
```

### 4.2 INSERT / UPDATE / DELETE 三条路径（R3.7）

| 表 | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- |
| `node_identities` | `current_config_version` 允许 NULL；`lifecycle` 默认 active；`UNIQUE(airport_id, occurrence_seq)` | 只允许改 `current_config_version`（朝已存在版本）、`lifecycle`、presence 字段、`ambiguous`；**禁止**改 `airport_id`、`occurrence_seq`（TR-I6） | **禁止**（TR-D1） |
| `node_config_versions` | `(identity_id, version)` 主键；`change_reason` 枚举 | 只允许 `last_seen_at`、`closed_at`；**禁止**改 fingerprint/params/server/port（TR-I7） | **禁止**（TR-D2） |
| `nodes` | `identity_id` 非空；`lifecycle` 必须等于身份当前值（TR-I1）；`config_version` 由 FK 钉住 | `lifecycle` 只能由触发器投影写入（TR-I2）；`config_version` 与身份指针同步（DEFERRED）；`id`/`airport_id`/`identity_id` 禁改（TR-I8） | **禁止**（TR-D3） |
| `node_target_state` | `config_version` 必须等于 `nodes.config_version`（TR-I3）；归属由复合外键 | `node_id`/`identity_id`/`config_version` 禁改（TR-I4） | **禁止**（TR-D4） |
| `node_state_history` | 归属由两个复合外键 | **禁止**（append-only，TR-I5） | **禁止**（TR-D5） |
| `identity_stable_ids` | live 部分唯一 | 只允许 `seen_count` 与 `released_at`/`release_reason` | **禁止**（TR-D6） |

### 4.3 关键 DDL（可直接执行）

```sql
PRAGMA foreign_keys = ON;        -- 每个连接初始化必须执行，禁止运行时关闭

-- T1 身份（唯一权威指针）
CREATE TABLE node_identities (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id             INTEGER NOT NULL,
  occurrence_seq         INTEGER NOT NULL,
  current_config_version INTEGER,
  lifecycle              TEXT NOT NULL DEFAULT 'active'
                         CHECK(lifecycle IN ('active','missing','retired')),
  last_seen_pull_id      INTEGER,
  absence_count          INTEGER NOT NULL DEFAULT 0,
  last_present_at        TEXT, last_absent_at TEXT,
  first_seen_at          TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  missing_since          TEXT, retired_at TEXT,
  rotation_hint          TEXT NOT NULL DEFAULT 'unknown'
                         CHECK(rotation_hint IN ('unknown','list','exit','mixed')),
  related_identity_id    INTEGER REFERENCES node_identities(id),
  ambiguous              INTEGER NOT NULL DEFAULT 0 CHECK(ambiguous IN (0,1)),
  note                   TEXT,
  UNIQUE(airport_id, occurrence_seq),      -- 槽位序号唯一（不回收见 C11）
  UNIQUE(id, airport_id),                  -- 供 nodes 机场一致性外键
  UNIQUE(id, current_config_version),      -- 供 nodes 版本一致性外键
  FOREIGN KEY (id, current_config_version)
    REFERENCES node_config_versions(identity_id, version)   -- 即时：版本行先插
);

-- T2 配置版本（永久保留；历史引用基础）
CREATE TABLE node_config_versions (
  identity_id      INTEGER NOT NULL REFERENCES node_identities(id),
  version          INTEGER NOT NULL,
  fingerprint      TEXT NOT NULL,
  base_fingerprint TEXT NOT NULL,
  params_hash      TEXT NOT NULL,
  params           TEXT NOT NULL,
  protocol         TEXT NOT NULL,
  server           TEXT NOT NULL,
  port             INTEGER NOT NULL,
  display_name     TEXT,
  sample_raw_name  TEXT,
  change_reason    TEXT NOT NULL CHECK(change_reason IN ('initial','config_rotated','readopt')),
  first_seen_at    TEXT NOT NULL, last_seen_at TEXT, closed_at TEXT,
  PRIMARY KEY (identity_id, version)
);

-- T5 节点（重建后形态：旧 UNIQUE(airport_id, fingerprint) 已移除，见 C12）
CREATE TABLE nodes__new (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id         INTEGER NOT NULL REFERENCES airports(id),
  identity_id        INTEGER NOT NULL,
  config_version     INTEGER NOT NULL,
  fingerprint        TEXT NOT NULL,
  name               TEXT, type TEXT, params TEXT, server TEXT, port INTEGER,
  lifecycle          TEXT NOT NULL DEFAULT 'active'
                     CHECK(lifecycle IN ('active','missing','retired')),
  state              TEXT NOT NULL DEFAULT 'unknown',
  state_since        TEXT, episode_started_at TEXT,
  ever_valid_fail    INTEGER NOT NULL DEFAULT 0 CHECK(ever_valid_fail IN (0,1)),
  fail_streak        INTEGER NOT NULL DEFAULT 0,
  success_streak     INTEGER NOT NULL DEFAULT 0,      -- 仅展示
  next_due_at        TEXT, last_check_at TEXT,
  last_seen_pull_id  INTEGER,
  created_at         TEXT NOT NULL, updated_at TEXT,
  UNIQUE(identity_id),
  UNIQUE(id, airport_id),
  UNIQUE(id, identity_id),                 -- 供子表归属外键
  FOREIGN KEY (identity_id, airport_id)
    REFERENCES node_identities(id, airport_id),
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_identities(id, current_config_version)
    DEFERRABLE INITIALLY DEFERRED
);

-- T3 目标层事实
CREATE TABLE node_target_state (
  node_id                 INTEGER NOT NULL,
  identity_id             INTEGER NOT NULL,
  target                  TEXT NOT NULL,
  config_version          INTEGER NOT NULL,
  rule_version            INTEGER NOT NULL,
  last_result             TEXT NOT NULL DEFAULT 'unknown'
                          CHECK(last_result IN ('pass','fail','unknown')),
  last_pass_at            TEXT, last_fail_at TEXT,
  fail_streak             INTEGER NOT NULL DEFAULT 0,
  success_streak          INTEGER NOT NULL DEFAULT 0,
  recovery_state          TEXT NOT NULL DEFAULT 'none'
                          CHECK(recovery_state IN ('none','observing','confirmed')),
  recovery_first_pass_at  TEXT,
  recovery_first_task_id  TEXT,
  recovery_confirm_pass_at TEXT,
  recovery_confirm_task_id TEXT,
  failure_source          TEXT, ttl_minutes INTEGER, updated_at TEXT NOT NULL,
  PRIMARY KEY (node_id, target, config_version),
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id),
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
);

-- T4 状态历史（append-only）
CREATE TABLE node_state_history (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id        INTEGER NOT NULL,
  identity_id    INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  from_state     TEXT NOT NULL, to_state TEXT NOT NULL,
  lifecycle      TEXT NOT NULL, reason_code TEXT NOT NULL, detail TEXT,
  rule_version   INTEGER NOT NULL, ts TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id),
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
);
CREATE INDEX idx_history_node ON node_state_history(node_id, ts);
```

### 4.4 触发器（只补声明式表达不了的规则）

```sql
-- TR-I1：节点插入时 lifecycle 必须与身份一致（R3.3）
CREATE TRIGGER trg_nodes_ins_lifecycle BEFORE INSERT ON nodes
WHEN NEW.lifecycle <> (SELECT lifecycle FROM node_identities WHERE id = NEW.identity_id)
BEGIN SELECT RAISE(ABORT,'nodes.lifecycle mismatch on insert'); END;

-- TR-I2：节点 lifecycle 只能由身份投影改写（R3.3）
CREATE TRIGGER trg_nodes_lifecycle_direct BEFORE UPDATE OF lifecycle ON nodes
WHEN NEW.lifecycle <> (SELECT lifecycle FROM node_identities WHERE id = NEW.identity_id)
BEGIN SELECT RAISE(ABORT,'nodes.lifecycle must follow node_identities'); END;

-- TR-I3：目标事实只允许写"当前节点版本"（R3.4）
CREATE TRIGGER trg_tstate_current_ins BEFORE INSERT ON node_target_state
WHEN NEW.config_version <> (SELECT config_version FROM nodes WHERE id = NEW.node_id)
BEGIN SELECT RAISE(ABORT,'target state must be current config_version'); END;

CREATE TRIGGER trg_tstate_current_upd BEFORE UPDATE OF config_version ON node_target_state
WHEN NEW.config_version <> (SELECT config_version FROM nodes WHERE id = NEW.node_id)
BEGIN SELECT RAISE(ABORT,'target state update must be current config_version'); END;

-- TR-I4：目标事实的归属字段不可改（R3.4，UPDATE 路径）
CREATE TRIGGER trg_tstate_immutable BEFORE UPDATE OF node_id, identity_id ON node_target_state
WHEN NEW.node_id <> OLD.node_id OR NEW.identity_id <> OLD.identity_id
BEGIN SELECT RAISE(ABORT,'target state ownership is immutable'); END;

-- TR-I5：状态历史 append-only
CREATE TRIGGER trg_history_append_only BEFORE UPDATE ON node_state_history
BEGIN SELECT RAISE(ABORT,'node_state_history is append-only'); END;

-- TR-I6：身份不可改机场与槽位
CREATE TRIGGER trg_identity_immutable BEFORE UPDATE OF airport_id, occurrence_seq ON node_identities
WHEN NEW.airport_id <> OLD.airport_id OR NEW.occurrence_seq <> OLD.occurrence_seq
BEGIN SELECT RAISE(ABORT,'identity airport/seq immutable'); END;

-- TR-I7：配置版本的配置内容不可改
CREATE TRIGGER trg_version_immutable BEFORE UPDATE OF fingerprint, params_hash, server, port, params ON node_config_versions
WHEN NEW.fingerprint <> OLD.fingerprint OR NEW.params_hash <> OLD.params_hash
  OR NEW.server <> OLD.server OR NEW.port <> OLD.port OR NEW.params <> OLD.params
BEGIN SELECT RAISE(ABORT,'config version content immutable'); END;

-- TR-I8：节点身份归属不可改
CREATE TRIGGER trg_nodes_identity_immutable BEFORE UPDATE OF id, airport_id, identity_id ON nodes
WHEN NEW.id <> OLD.id OR NEW.airport_id <> OLD.airport_id OR NEW.identity_id <> OLD.identity_id
BEGIN SELECT RAISE(ABORT,'node identity immutable'); END;

-- TR-I9：身份生命周期 → 节点（唯一合法写路径）
CREATE TRIGGER trg_identity_lifecycle_project AFTER UPDATE OF lifecycle ON node_identities
BEGIN
  UPDATE nodes
     SET lifecycle = NEW.lifecycle,
         missing_since = CASE WHEN NEW.lifecycle='missing'
                              THEN COALESCE(NEW.missing_since, NEW.last_seen_at) END
   WHERE identity_id = NEW.id;
END;

-- TR-D1..D6：删除保护（R3.7 / R4.5）
CREATE TRIGGER trg_del_identity   BEFORE DELETE ON node_identities       BEGIN SELECT RAISE(ABORT,'node_identities is immutable'); END;
CREATE TRIGGER trg_del_version    BEFORE DELETE ON node_config_versions  BEGIN SELECT RAISE(ABORT,'node_config_versions is immutable'); END;
CREATE TRIGGER trg_del_node       BEFORE DELETE ON nodes                 BEGIN SELECT RAISE(ABORT,'nodes rows are never deleted'); END;
CREATE TRIGGER trg_del_tstate     BEFORE DELETE ON node_target_state     BEGIN SELECT RAISE(ABORT,'target facts are immutable'); END;
CREATE TRIGGER trg_del_history    BEFORE DELETE ON node_state_history    BEGIN SELECT RAISE(ABORT,'history is append-only'); END;
CREATE TRIGGER trg_del_claim      BEFORE DELETE ON identity_stable_ids   BEGIN SELECT RAISE(ABORT,'release claim via UPDATE'); END;
```

**删除保护的正当例外**：离线维护（重建表 `nodes__new`）时必须临时 `DROP TABLE`，那属于 schema 操作而非行删除；文档要求维护脚本显式 `PRAGMA foreign_keys=OFF` **仅限离线维护会话**，且事后跑完整性检查（这一点与 R3.9"不允许通过关闭外键解决问题"不冲突：运行期禁止，离线维护必须显式声明并校验）。

### 4.5 写入顺序（一旦顺序错，DEFERRED 会在提交时报错）

| 操作 | 顺序 | 校验点 |
| --- | --- | --- |
| 建身份 | identity(NULL) → 版本 v1 → identity.current=1 → insert nodes | 提交时两处外键 |
| 轮换 | 版本 v(n+1) → nodes.config_version=n+1 → identity.current=n+1 → 旧版本 closed_at | 提交时 DEFERRED |
| 写结果 | tstate upsert → recompute → nodes.state/counts | TR-I3 |
| 生命周期 | identity.lifecycle → TR-I9 投影 nodes | TR-I2 |
| 回池 | reservation=held → temp 令牌 → insert nodes(explicit id) → reservation=restored | TR-R1/TR-R2（§5） |

### 4.6 负向测试（FT 组，14 个）

| # | 操作 | 期望 |
| --- | --- | --- |
| FT1 | 插入 nodes，lifecycle=active，身份为 missing | TR-I1 abort |
| FT2 | 直接 UPDATE nodes.lifecycle | TR-I2 abort |
| FT3 | 改身份 lifecycle | TR-I9 投影成功；无 abort |
| FT4 | 插 tstate 指向旧版本 | TR-I3 abort |
| FT5 | UPDATE tstate 的 `node_id` | TR-I4 abort |
| FT6 | UPDATE history 任一行 | TR-I5 abort |
| FT7 | UPDATE identity.airport_id | TR-I6 abort |
| FT8 | UPDATE 版本行的 fingerprint | TR-I7 abort |
| FT9 | UPDATE nodes.identity_id | TR-I8 abort |
| FT10 | DELETE nodes / identity / version / tstate / history / claim | 各自 TR-D abort |
| FT11 | identity.current=2 而 nodes.config_version=1，提交 | DEFERRED 在 COMMIT 失败 |
| FT12 | nodes.config_version=9（不存在版本） | FK 失败 |
| FT13 | nodes.airport_id 与身份不符 | 复合 FK 失败 |
| FT14 | 同机场两节点同指纹、不同身份 | **必须成功**（旧唯一约束已移除） |

---

## 5. R4：过滤节点 ID 恢复保护

### 5.1 结构与字段（R4.1）

```sql
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_node_id      INTEGER;   -- 历史标识，无外键
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_identity_id INTEGER REFERENCES node_identities(id);
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_fingerprint  TEXT;
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_state        TEXT NOT NULL DEFAULT 'none'
  CHECK(origin_state IN ('none','held','restored','conflicted'));
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_status      TEXT NOT NULL DEFAULT 'unmapped'
  CHECK(mapping_status IN ('mapped','ambiguous','unmapped'));
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_note        TEXT;
ALTER TABLE airport_filtered_nodes ADD COLUMN mapped_at           TEXT;

-- 历史 id 预留表（库级保护，R4.4）
CREATE TABLE node_id_reservations (
  node_id            INTEGER PRIMARY KEY,          -- 被预留的历史 nodes.id
  filtered_id        INTEGER NOT NULL,
  origin_identity_id INTEGER REFERENCES node_identities(id),
  origin_fingerprint TEXT NOT NULL,
  state              TEXT NOT NULL DEFAULT 'held'
                     CHECK(state IN ('held','restored')),
  created_at         TEXT NOT NULL, released_at TEXT
);
CREATE UNIQUE INDEX uq_resv_filtered ON node_id_reservations(filtered_id) WHERE state='held';
```

**`origin_identity_id` 的来源**：回填时读 `nodes.identity_id`（该行当时存在）；`mapping_status='unmapped'`（原行已被旧逻辑硬删）→ 置 NULL，并在 `mapping_note` 记录"identity 不可考"。约束上它只是可空外键——身份行永不删除，所以只要写得进去就一直有效。

### 5.2 普通创建路径禁止使用历史 id（R4.2 / R4.3）

SQLite 无法在 SQL 层区分"显式 id"与"自动 id"，因此用**预留表 + 临时令牌**做库级拦截：

```sql
-- 连接初始化：CREATE TEMP TABLE IF NOT EXISTS restore_ctx(node_id INTEGER PRIMARY KEY);

-- TR-R1：历史 id 被持有时，普通插入直接拒绝
CREATE TRIGGER trg_nodes_reserved_id BEFORE INSERT ON nodes
WHEN EXISTS (SELECT 1 FROM node_id_reservations r
             WHERE r.node_id = NEW.id AND r.state = 'held')
 AND NOT EXISTS (SELECT 1 FROM temp.restore_ctx c WHERE c.node_id = NEW.id)
BEGIN SELECT RAISE(ABORT,'historic node id is reserved; use readmit'); END;

-- TR-R2：即使拿到令牌，指纹必须与预留快照一致
CREATE TRIGGER trg_nodes_reserved_fp BEFORE INSERT ON nodes
WHEN EXISTS (SELECT 1 FROM node_id_reservations r
             WHERE r.node_id = NEW.id AND r.state = 'held')
 AND EXISTS (SELECT 1 FROM temp.restore_ctx c WHERE c.node_id = NEW.id)
 AND NEW.fingerprint <> (SELECT origin_fingerprint FROM node_id_reservations WHERE node_id = NEW.id)
BEGIN SELECT RAISE(ABORT,'readmit fingerprint mismatch'); END;
```

`restore_ctx` 是**连接级临时表**，只能由 `readmit()` 在回池事务内写入，事务结束即 `DELETE`。普通插入路径（`INSERT INTO nodes(...)` 不带 id，AUTOINCREMENT 生成新 id）永远不会命中预留，因此天然不受影响。

### 5.3 回池流程（R4.3 / R4.4）

```python
def readmit(f, node):
    r = db.one("node_id_reservations", filtered_id=f.id, state="held")

    # 断言 1：指纹必须与预留快照一致
    if r and r.origin_fingerprint != node.fingerprint:
        return new_node(node, reason="fingerprint_changed")

    # 断言 2：身份必须一致（origin_identity_id 为空则不允许恢复 id）
    if r and r.origin_identity_id is None:
        return new_node(node, reason="origin_identity_unknown")

    # 断言 3：目标 id 若已被占用
    if r and db.exists("nodes", id=r.node_id):
        owner = db.one("nodes", id=r.node_id)
        if owner.identity_id != r.origin_identity_id:
            db.update("airport_filtered_nodes", id=f.id, origin_state="conflicted")
            return new_node(node, reason="id_occupied_by_other")
        return owner                       # 幂等

    # 合法回池：令牌 → 插入 → 释放
    with tx():
        db.execute("INSERT OR REPLACE INTO temp.restore_ctx(node_id) VALUES(?)", r.node_id)
        row = db.insert("nodes", id=r.node_id, identity_id=r.origin_identity_id,
                        config_version=..., ...)
        db.execute("DELETE FROM temp.restore_ctx WHERE node_id=?", r.node_id)
        db.update("node_id_reservations", node_id=r.node_id, state="restored", released_at=now)
        db.update("airport_filtered_nodes", id=f.id, origin_state="restored")
    return row
```

### 5.4 再次过滤（R4.6）

`origin_state='restored'` 的节点**再次被过滤**时：

1. 该节点行仍存在（不过滤不删行）→ `mapping_status='mapped'`、`origin_state='held'`；
2. 预留表：同 `filtered_id` 的旧行已是 `restored`，新建一条 `held`（`uq_resv_filtered` 只管 held 部分，不冲突）；`node_id` 主键已被旧行占用 → 复用同一 `node_id`，把旧行 `state` 由 `restored` 改回 `held` 并更新 `filtered_id`；
3. 回池时按 §5.3 走；若 `origin_identity_id` 已变（例如期间身份被接管）→ `conflicted` + 新 id。

### 5.5 删除保护与串号（R4.5）

- `trg_del_node` 让运行期**没有任何**删除 nodes 行的路径；硬删只能发生在离线维护（重建表）。
- 孤儿结果行（原行被旧逻辑删除后遗留）不参与任何聚合：查询层一律 `JOIN nodes`，`nodes` 不在即不命中。
- 回池前三条断言（指纹 / 身份 / 占用）保证"历史 id 只回到它自己身份"。

### 5.6 迁移清单（P0）

```
1 备份 + quick_check
2 加 6 个列（origin_* / mapping_*）
3 回填：nodes(airport_id, fingerprint) 唯一 → mapped + identity_id + fingerprint 快照
         多候选 → ambiguous（不猜）
         无候选 → unmapped（identity_id NULL）
4 建 node_id_reservations（只为 mapped 建 held 行）
5 建 TR-R1 / TR-R2
6 F 组负向测试在临时库跑通
```

### 5.7 测试（F 组，10 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| F1 | 唯一映射，原行已删，合法回池 | 恢复原 id；reservation=`restored`；无新身份 |
| F2 | 多候选 | `ambiguous`；回池新 id |
| F3 | 普通插入撞上预留 id | TR-R1 abort（**库级**，非应用层） |
| F4 | 拿到令牌但指纹不符 | TR-R2 abort |
| F5 | `origin_identity_id` 为空仍尝试恢复 | 拒绝；新 id；事件 |
| F6 | id 被其他身份占用 | `conflicted`；新 id |
| F7 | `restored` 后再次过滤 | 复用同一 reservation 行；状态回 `held`；回池幂等 |
| F8 | 孤儿结果行 | 聚合不命中 |
| F9 | 运行期 DELETE nodes | TR-D3 abort |
| F10 | 回填时两条映射同一 id | 第二条强制 `ambiguous`（`uq_resv` 冲突被显式处理） |

---

## 6. R5：发布提交点与崩溃恢复

### 6.1 两级持久化（R5.1 / R5.2）

| 级别 | 完成标志 | 保证 |
| --- | --- | --- |
| 目录持久化 | `rename <v>.tmp → <v>` **且** `fsync versions/` **且** `fsync data/sub/` | 版本目录在断电后仍存在 |
| 指针持久化 | `rename active.json.tmp → active.json` **且** `fsync data/sub/` | 指针在断电后仍指向该版本 |

**R5.2 的落实**：`rename` 只改目录项（可能还在页缓存），**父目录 fsync 之后才算持久**。因此"指针可靠提交"的完整判定是：

```
durable_commit(v) = active.json 内容指向 v
                 AND active.json 自身已 fsync（文件）
                 AND data/sub 目录已 fsync（目录项持久）
                 AND v 目录已持久（rename + versions/ fsync + data/sub fsync）
                 AND v 的 checksums 6 项校验通过
                 AND commit_token 与 DB 的 committing/active 记录一致
```

任何一条缺失 → 只能算"疑似提交"，走恢复矩阵，不得直接对外提供服务。

### 6.2 事务边界（R5.4）

| 步骤 | 动作 | 提交边界 |
| --- | --- | --- |
| 1 | 渲染 + 校验（内存） | 无 IO |
| 2 | `INSERT publish_versions(state='generated')` | **独立事务提交**（先记账） |
| 3–4 | 写 `<v>.tmp` 四格式 + manifest + meta + checksums；逐文件 fsync | 文件级 |
| 5 | `rename → <v>`；`fsync versions/`；`fsync data/sub` | **目录持久化完成** |
| 6 | `UPDATE state='verified'` | 独立事务 |
| 7 | 写 `pending.json`（含 version + token + checksums_sha）；fsync 文件 + `fsync data/sub` | **意图持久化**（不是提交） |
| 8 | `UPDATE state='committing', commit_token=…` | 独立事务 |
| 9 | 写 `active.json.tmp`；fsync 文件 | — |
| 10 | `rename active.json.tmp → active.json` | 提交点（页缓存） |
| 11 | `fsync data/sub` | **指针持久化完成** |
| 12 | `UPDATE state='active', durable_at=now`；prev → `superseded` | 独立事务 |
| 13 | 删 `pending.json`；`fsync data/sub`；share_history | — |

`pending.json` 只证明"打算提交"；`active.json` + 目录 fsync 才证明"已持久提交"。**禁止仅凭 pending.json、目录存在或最大版本号推断已发布。**

### 6.3 崩溃恢复矩阵（R5.6，含新增场景）

| # | 崩溃点 | 断电后磁盘真实状态 | 恢复判定 | 动作 |
| --- | --- | --- | --- | --- |
| 1 | 写 tmp 中 | `<v>.tmp` 残留 | 目录未持久化 | 删 tmp；`aborted`；旧 active 服务 |
| 2 | rename 完成、`fsync versions/` 前 | `<v>` 可能存在也可能消失 | 目录持久化未完成 | 视为未生成：清理残留；`aborted` |
| 3 | `fsync versions/` 后、`fsync data/sub` 前 | `<v>` 可能丢失 | 同上（父目录未持久） | 清理；`aborted` |
| 4 | 步骤 6（verified）后、pending 前 | `<v>` 已持久 | 已校验、未提交 | 保留 `verified`；旧 active |
| 5 | pending 写入后、DB committing 前 | `pending.json` 存在 | 意图存在、无提交 | 删 pending；`verified`；旧 active |
| 6 | DB committing 后、active.tmp 写入前 | pending + DB committing | 同上 | 删 pending；回 `verified` |
| 7 | **rename 完成、`fsync data/sub` 前断电（R5.5 新增）** | 两种可能：<br>A `active.json` 回退到旧内容<br>B `active.json` 已是新内容 | A：未提交 → 旧 active 继续<br>B：内容已校验 + token 匹配 → **补 fsync(data/sub) 完成持久化**，再置 DB active | A：`verified`<br>B：补做持久化后 `active` |
| 8 | `fsync data/sub` 后、DB 置 active 前 | 指针已持久 | 已提交 | 认指针 → 补 DB `active`（`durable_at`=补写时刻） |
| 9 | DB active 后、删 pending 前 | pending 残留 | 已提交 | 删 pending；无需其他动作 |
| 10 | active.json 损坏（截断/0 字节） | DB 有 `active` 且目录完整 | 指针不可用，DB 可证明 | 重建指针（写 tmp → fsync → rename → fsync 目录）→ 再 `fsync`；事件 `pointer_repaired` |
| 11 | 目录被删（磁盘故障） | DB 有 `active` + `manifest_gz` | 内容可重建 | 重渲染 4 格式 → 与 `checksums_sha` 比对一致 → 落盘 → 重建指针 |
| 12 | 指针与 DB 均无法证明 | — | 不可判定 | **fail-closed 503** + `pointer_critical` |

**场景 7 的判定依据**（R5.2）：不能因为"文件里看到新内容"就认为已提交——内容可能来自未落盘的页缓存。恢复时先 `fsync(data/sub)`，再重新读取 `active.json` 确认内容未被回滚；两者都成立才算提交成功。这是唯一允许"补做持久化"的例外，因为内容本身已通过 6 项校验且 token 与 DB 的 `committing` 记录一致。

**场景 9 的正当性**：DB 已是 `active` 说明步骤 12 完成，而步骤 12 在 `fsync` 之后，因此指针必然持久。

### 6.4 `active.json` 结构（含提交证明）

```json
{
  "version": 128,
  "commit_token": "0f6c…",
  "checksums_sha256": "…",
  "switched_at": "2026-11-26T10:12:03+08:00",
  "prev_version": 127,
  "prev_token": "…"
}
```

`commit_token` 是唯一能把"指针"与"DB 记录"绑起来的证据；`prev_token` 用于回退链审计。

### 6.5 测试（P 组，14 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| P1 | 正常发布 | 6 项校验通过；`state=active`；`durable_at` 非空 |
| P2 | 内容未变 | `skipped`，不建版本 |
| P3 | 渲染失败 | 不落盘；旧 active |
| P4 | 场景 2（rename 后未 fsync） | 重启后该版本 `aborted`；**不**发布 |
| P5 | 场景 3（缺父目录 fsync） | 同上 |
| P6 | 场景 7A（指针回退） | 旧 active 继续；新版本 `verified` |
| P7 | 场景 7B（指针为新） | 补 fsync → `active`；服务新内容 |
| P8 | 场景 8（指针持久、DB 未更新） | 认指针；DB 补 `active` |
| P9 | 场景 10（指针损坏） | 重建指针；`pointer_repaired` |
| P10 | 场景 11（目录被删） | 由 manifest 重建；哈希一致 |
| P11 | 场景 12（双不可证） | 503；不返回任何订阅 |
| P12 | pending 存在但 DB `verified` | 不发布 |
| P13 | 高编号未提交版本 + 指针损坏 | 不选高编号；按 DB active 恢复 |
| P14 | 30 个版本轮转 | 只删非 active 且超 30 的最老 |

---

## 7. R6：rolling_pool 统计公式

### 7.1 v0.4 的致命错误

v0.4 用 `cover_i = |S_i ∩ U7| / |S_i|`，但 `U7` 在**本次响应写入之后**才重算——此时 `S_i` 已并入 `U7`，于是 `S_i ∩ U7 = S_i`，`cover ≡ 1`。公式恒真等于没有判据（R6.1）。

### 7.2 顺序修正：先比较，后写入

```
每次 applied 拉取的处理顺序（不可颠倒）：
  1 读出 U_before = 本次写入之前的历史并集（7 天窗口，来自 presence log）
  2 用 S_i 与 U_before 计算 cover / fresh / overlap（只读）
  3 判定 rolling / 骤减 / 一致性
  4 写入 presence（present → last_present_at / last_seen_pull_id；absent → absence_count+1）
  5 重算并缓存 U_after（供 UI 与下次比较）
```

### 7.3 定义（全部可复算）

| 记号 | 定义 | 来源 |
| --- | --- | --- |
| `S_i` | 第 i 次 `applied` 响应中的身份集合 | 拉取结果 |
| `U_before` | 截至第 i 次**之前**的 7 天并集 `{id : last_present_at >= t-7d}` | presence log |
| `U7(d)` | 第 d 天 00:00 的 7 天并集 | 每日快照表 |
| `U7_prev` | `t-7d` 时点的并集 | 快照表（缺则用 presence log 重建） |

指标：

```
cover_i  = |S_i ∩ U_before| / |S_i|            （分母是本次响应；U_before 不含本次）
fresh_i  = 1 - cover_i
overlap  = |S_i ∩ S_{i-1}| / min(|S_i|, |S_{i-1}|)
swing    = max(N_i,N_{i-1},N_{i-2}) / min(N_i,N_{i-1},N_{i-2})
simU     = |U_after ∩ U7_prev| / |U_after ∪ U7_prev|
growthU  = |U_after| / |U7_prev| - 1
```

### 7.4 数据来源与持久化（R6.4 / R6.5 / R6.6）

```sql
-- 事件级：可重建任意时点的 7 天并集（保留 30 天）
CREATE TABLE identity_presence_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id  INTEGER NOT NULL,
  identity_id INTEGER NOT NULL REFERENCES node_identities(id),
  pull_version INTEGER NOT NULL,          -- airport_fetch_versions 的版本号
  present     INTEGER NOT NULL CHECK(present IN (0,1)),
  ts          TEXT NOT NULL,
  UNIQUE(airport_id, identity_id, pull_version)
);
CREATE INDEX idx_presence_win ON identity_presence_log(airport_id, ts);

-- 日级：7 天并集快照（每机场每天一行 + 成员行）
CREATE TABLE airport_identity_daily (
  airport_id   INTEGER NOT NULL,
  day          TEXT NOT NULL,             -- YYYY-MM-DD（本地日期）
  union_count  INTEGER NOT NULL,
  pull_count   INTEGER NOT NULL,
  PRIMARY KEY (airport_id, day)
);
CREATE TABLE airport_union_snapshot (
  airport_id  INTEGER NOT NULL,
  day         TEXT NOT NULL,
  identity_id INTEGER NOT NULL,
  PRIMARY KEY (airport_id, day, identity_id)
);
```

- 快照生成：每天 `00:05` 由调度任务写入（幂等 upsert），内容 = 该机场 7 天窗口内出现过的身份。
- 保留：`airport_union_snapshot` 保留 35 天（覆盖"7 天 + 前一个 7 天"），`airport_identity_daily` 保留 90 天。
- **重建**：快照丢失/损坏 → 从 `identity_presence_log` 按 `ts >= day-7d` 聚合重放；presence log 也在保留期内，故 `U7(d)` 与 7 天中位数**都有真实、可重建的数据来源**。
- 7 天中位数：`median(union_count)` 取最近 7 个 `day` 行；不足 3 行 → 走 v0.2 的"小样本策略"（不启用骤减判定）。

### 7.5 rolling_pool 判定（三条件，连续 3 个 applied）

```
A 子集性：  cover_i >= 0.80
B 并集稳定：simU >= 0.90 且 |growthU| <= 0.10
C 摆动：    swing >= 1.30 或 overlap < 0.90
```

### 7.6 数值验证（118 / 62 / 70，含 R6.1 对照）

`U_before = 118`（前一次拉取后的 7 天并集，与本次无关）。

| 指标 | 拉取 1 | 拉取 2 | 判定 |
| --- | --- | --- | --- |
| `|S|` | 62 | 70 | — |
| `S ∩ U_before` | 62（全为已知） | 58（12 个新面孔） | — |
| `cover` | 62/62 = **1.000** | 58/70 = **0.829** | A 两次均过 |
| `fresh` | 0 | 0.171 | — |
| `overlap` | — | 48/62 = 0.774 | C 过（成员在换） |
| `swing` | — | 70/62 = 1.13 | 规模稳定 |
| `simU` | 0.96 | ≥0.90 | B 过 |
| `growthU` | +2% | ≤10% | B 过 |
| 旧公式（写入后算） | 62/62=1.0 | 70/70=1.0 | **恒真，失效**（复现 R6.1） |

结论：三条件成立 → `rolling_pool`；`N` 摆动 1.13 不进入骤减公式，故不触发骤减。

### 7.7 空集合与零节点响应（R6.7）

| 情形 | 处理 |
| --- | --- |
| `|S_i| = 0`（响应 0 个节点） | `cover` 无定义；标记 `empty_response`；**不写 presence**（否则全员 absence+1，会造成误删）；连续 2 次空 → 机场转 `suspect` |
| `U_before = ∅`（新机场/新窗口） | `cover` 无定义（除零）；首次拉取直接建身份，不判 rolling |
| `U_before ≠ ∅` 但 `|S_i| = 1` | `cover` 只有 0/1，样本不足 → 不判 rolling（小样本策略） |
| 7 天中位数样本 < 3 | 不启用骤减判定（v0.2 小样本策略） |

### 7.8 测试（RP 组，8 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| RP1 | 118/62/70 交替 | 判 rolling；cover=1.0 / 0.829；无骤减、无 missing |
| RP2 | 旧公式（写入后比较） | 复现 cover 恒 1（仅作反例，不进生产） |
| RP3 | 池真缩 118→55 | 触发骤减（ratio 0.534、abs 63）；两次确认 |
| RP4 | 池 118→100 | 不触发（ratio 0.153） |
| RP5 | 单节点 3 次缺席但 7 天内出现过 | 不转 missing |
| RP6 | 响应 0 节点 | `empty_response`；不写 presence；连续 2 次转 suspect |
| RP7 | 快照丢失，presence log 重建 | `U7(d)` 与中位数可复算且一致 |
| RP8 | 无 stable_id + 大幅摆动 | `rolling_pool_unverifiable`；不删节点 |

---

## 8. R7：零健康统计口径

### 8.1 拆掉"一字段三职责"（R7.2）

v0.4 的 `present_in_latest` 同时被当：① 生命周期（absent→missing 的依据）、② 检测资格（是否要测）、③ 统计分母（`A_eff`）。三者时点与范围都不同，必然互相污染。v0.5 **删除该字段**，改为三条独立表达：

| 职责 | 表达 | 时点 |
| --- | --- | --- |
| 生命周期 | `absence_count` + `last_present_at`（双条件转 missing，§7.6） | 跨拉取累积 |
| 检测资格 | `last_seen_pull_id == 当前 pull_version`（渲染时派生，不落库） | 单次拉取 |
| 长期统计 | `identity_presence_log` 的 7 天窗口 | 窗口聚合 |

### 8.2 四个集合（R7.1 / R7.3）

| 集合 | 定义 | 用途 |
| --- | --- | --- |
| `A_raw` | `nodes.lifecycle='active'` 且身份存在 | UI 展示"原始活跃节点" |
| `A_detect` | `A_raw` 中 `identity.last_seen_pull_id = 当前 pull` 的节点 | "本次可检测" |
| `A_eff` | `A_detect` 剔除：机场 `enabled=0` / `suspect` / `invalid_window` | **覆盖率与可发布数的唯一分母** |
| `A_pool` | 7 天内出现过的身份（presence log 聚合） | 骤减、轮换、长期统计 |

**R7.3 的落实**：轮询机场本次没返回的节点，`absence_count+1` 但仍在 `A_pool` 里，不属于"长期池消失"，因此不进入 `A_eff`，也**不**影响骤减基线（基线取自 `A_pool`）。

### 8.3 零健康判定

```
cov(t) = |{ n ∈ A_eff : 目标 t 在 60 分钟窗口内有当前版本有效结果 }| / |A_eff|
publishable = |{ n ∈ A_eff : eligible(n) }|          ← 与 cov 同集合

零健康必要（全部满足）：
  |A_eff| > 0
  ∀t: cov(t) >= 0.90
  publishable = 0
  无 invalid_window；无未关闭的机场异常
  连续两次评估（≥10 分钟）
```

### 8.4 五种"都是 0"（更新）

| 情形 | `A_raw` | `A_detect` | `A_eff` | 判定 |
| --- | --- | --- | --- | --- |
| 库空 | 0 | 0 | 0 | `no_nodes` |
| 全部机场停用 | >0 | >0 | 0 | `all_disabled` |
| 全部 suspect | >0 | >0 | 0 | `all_suspect` |
| 轮询本次返回空/极少 | >0 | 0 或 1 | 0 | `rolling_scope` |
| 真实全挂 | >0 | >0 | >0 | `zero_health`（进 24h） |

`|A_eff| = 0` 一律不启动 24h、不创建 `empty_confirmed`。24h/72h 规则不变（`confirmed_at` 只写一次，72h 转人工）。

### 8.5 测试（Z 组，10 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| Z1 | 库空 | `no_nodes`；无 24h |
| Z2 | 全机场停用 | `all_disabled`；无 24h |
| Z3 | 全 suspect | `all_suspect`；无 24h |
| Z4 | 真实全挂（cov≥90%） | 进 24h |
| Z5 | cov=60% | 不判零健康；`cov_insufficient` |
| Z6 | 轮询本次 0 节点 | `rolling_scope`；无 24h |
| Z7 | 轮询缺席节点 | 不进 `A_eff`；不进 `A_pool` 消失；不转 missing |
| Z8 | 重复评估 | `confirmed_at` 不变 |
| Z9 | 72h 到点 | `manual_review`；不自动发布 |
| Z10 | cov 与 publishable 集合一致性 | 用同一 `A_eff` 快照计算（快照期间加锁） |

---

## 9. R8：写探针与降级日志

### 9.1 探针必须真实写主库（R8.1 / R8.2 / R8.3 / R8.4）

`CREATE TEMP TABLE` 只写 `temp` 库（内存或临时文件），**不能证明主库可写**。`BEGIN IMMEDIATE` 只证明能拿到写锁，**不能证明提交能落盘**（WAL 下锁与 fsync 是两件事）。因此探针必须：

```
probe_main_db():
  1  BEGIN IMMEDIATE                                  # 拿写锁
  2  INSERT INTO schema_migrations(version, applied_at, result)
       VALUES(-1, now, 'probe')                       # 真实写主库页
  3  COMMIT                                           # 真实持久化（synchronous=FULL 下含 fsync）
  4  记录 probe_ok_at
  5  BEGIN IMMEDIATE; DELETE FROM schema_migrations WHERE result='probe'; COMMIT   # 清理
  6  失败分支见下表
```

用 `schema_migrations` 自身做探针目标，**P-1 仍只建 2 张表**（不需要新增 `write_probe`）。

### 9.2 三态判定（更新）

| 状态 | 现象 | 判定依据 | 能否写 `schema_migrations` |
| --- | --- | --- | --- |
| S1 可读可写 | 步骤 3 成功 | 主库真实提交成功 | 能 |
| S2 可读、写失败 | 步骤 1 或 2 或 3 报 `SQLITE_READONLY` / `SQLITE_FULL` / `SQLITE_BUSY` / `disk I/O error` | 真实写入失败 | **不能**（也不假装成功） |
| S3 完全不可用 | `open()` 抛错 / `quick_check` 失败 / 文件不存在 | 连读都不成立 | **不能** |

补充：`COMMIT` 成功但随后 `fsync` 报错（`SQLITE_IOERR_FSYNC`）→ 按 S2 处理，并在事件里区分 `ioerr_fsync`，因为"报成功但没落盘"比"报失败"更危险。

### 9.3 文件日志是"尽力"，不是保证（R8.5 / R8.6）

降级链（每一级失败就进下一级）：

```
L1  data/events/migration_failed-<ts>.json      （正常路径）
L2  data/events/fallback-<ts>.json              （目录不可写时换子目录）
L3  <cwd>/MIGRATION_FAILED-<ts>.json            （数据盘整体不可写）
L4  /tmp/nodepool-migration-failed-<ts>.json    （临时盘）
L5  stderr 单行 JSON + 进程退出码 3（fail loudly；不再声称"已记录"）
```

- 每级都 `fsync` 文件与目录；成功即停。
- 格式固定（`schema: nodepool.migration_failure/1`，含 `db_state`、`step`、`error.type/msg`、`backup.path/sha256`、`degraded`、`next_action`）。
- **明确声明**：磁盘满时任何一级都可能失败；走到 L5 时系统**没有**持久记录，只能靠 stderr 与退出码暴露问题，文档与管理界面必须按"可能无记录"处理，不得假设日志一定成功。

### 9.4 P-1 与 P6 界线（不变）

| 项 | P-1 | P6 |
| --- | --- | --- |
| 建表 | `schema_migrations`、`system_events` | — |
| 探针 | 主库真实写探针（§9.1） | 周期性健康探针 |
| 完整性 | `quick_check` + 表/列存在 | 全库 `integrity_check` + 跨表巡检 |
| 恢复 | 快照校验 + degraded 启动 | 自动回滚、告警、门禁 |
| 业务 | **不做** | — |

### 9.5 测试（M 组，6 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| M1 | 正常库 | S1；探针行已清理 |
| M2 | 只读挂载 | S2；不写 `schema_migrations` 失败行；文件日志 L1 成功 |
| M3 | 磁盘满（写失败） | S2；`ioerr` 类型正确；L1 失败 → L2 成功 |
| M4 | 库文件损坏 | S3；不尝试任何 DB 写；L1/L2/L3 依序降级 |
| M5 | 全部路径不可写 | 到达 L5；退出码 3；stderr 含 schema 字段 |
| M6 | TEMP 表可建但主库只读 | 判 S2（**不**因 temp 成功判 S1） |

---

## 10. 迁移与兼容

### 10.1 对库的增量（仅设计）

| 变更 | 表 | 性质 |
| --- | --- | --- |
| 删 `present_in_latest`，加 `last_seen_pull_id` | `node_identities`、`nodes` | 结构 |
| 加 `UNIQUE(id, current_config_version)`、`UNIQUE(id, identity_id)` | `node_identities`、`nodes` | 结构 |
| 加恢复证据 5 列（含 `recovery_state`） | `node_target_state` | 加法 |
| 新表 `identity_config_pending` | — | 结构 |
| 新表 `identity_presence_log` / `airport_identity_daily` / `airport_union_snapshot` | — | 结构 |
| 新表 `node_id_reservations`；加 6 列 | `airport_filtered_nodes` | 结构 |
| 加 `durable_at` | `publish_versions` | 加法 |
| 重命名/新增触发器 15 条 | — | 结构 |

### 10.2 迁移顺序（P0/P1）

```
1 备份 + quick_check + 写探针（S1 才继续）
2 identity_config_pending / presence_log / daily / snapshot 建表
3 nodes 重建（去 UNIQUE(airport_id,fingerprint)，加 UNIQUE(identity_id)、UNIQUE(id,identity_id)）
4 node_identities 重建（加 UNIQUE(id,current_config_version)、last_seen_pull_id）
5 node_target_state 加列（默认 none/NULL）
6 触发器按 §4.4 顺序创建
7 负向测试 FT1–FT14 临时库跑通
8 写 schema_migrations(success)
```

### 10.3 兼容承诺

- 语义收紧 + 加法；旧代码不写新列时，`recovery_state='none'` 不会让节点误判为 healthy（healthy 需 confirmed）。
- 四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`、测速与评分算法**未改动**。
- 前端只增量展示（分目标恢复状态、指针来源、长期池 vs 本次响应）。

---

## 11. 测试矩阵（合并）

| 组 | 数量 | 范围 | 阶段 |
| --- | --- | --- | --- |
| 身份 I | 20 | I1–I12 + I13–I20 | P0 |
| 状态机 S | 28 | S1–S28 | P1 |
| 约束 FT | 14 | FT1–FT14 | P0/P1 |
| 过滤 F | 10 | F1–F10 | P0 |
| 发布 P | 14 | P1–P14 | P3 |
| 轮询 RP | 8 | RP1–RP8 | P0 |
| 零健康 Z | 10 | Z1–Z10 | P2/P3 |
| 迁移 M | 6 | M1–M6 | P-1 |
| 小样本骤减 | 5 | v0.2 原表 | P0 |

---

# B. v0.4 → v0.5 修订前后对照

| # | v0.4 | v0.5 | 章节 | 解决度 |
| --- | --- | --- | --- | --- |
| R1 | 通过 `identity.stable_id` 释放；未确认配置变化即新建身份；首次 id 确认无流程 | claim 句柄化（只传 `claim.id`）；`identity_config_pending` 观察态；`seen_count` 确认流程 | §2 | 完整 |
| R2 | `success_streak + 时间差`推断两次成功 | `recovery_state` + 首/确认时间 + 任务 id；失败清零；确认时点校验最新性 | §3 | 完整 |
| R3 | 身份指针与节点指针各自独立；只补 INSERT 触发器 | 复合外键把 `nodes.config_version` 钉在身份指针上（DEFERRED 同事务移动）；补 UPDATE/DELETE 与不可变触发器 | §4 | 完整 |
| R4 | `origin_node_id` 无外键、仅靠文档禁止删除 | `origin_identity_id` + `node_id_reservations` + 临时令牌触发器；运行期删除全禁 | §5 | 完整 |
| R5 | rename 即视为提交 | 目录持久化 / 指针持久化两级；场景 7（rename 后未 fsync）单列；补 fsync 后才置 active | §6 | 完整 |
| R6 | cover 在写入后计算 → 恒 1 | 先比较后写入；presence log + 日快照 + 重建路径；0 节点响应不写 presence | §7 | 完整 |
| R7 | `present_in_latest` 三职责混用 | 拆成 absence 累积 / `last_seen_pull_id` 派生 / presence log；`A_raw/A_detect/A_eff/A_pool` 四集合 | §8 | 完整 |
| R8 | `CREATE TEMP TABLE` 当写探针；失败行"可能写成功" | 主库真实 INSERT+COMMIT 探针；三态判定；文件日志五级降级且声明"尽力" | §9 | 完整 |

---

# C. 待确认决策（不得视为已批准）

| 编号 | 事项 | 推荐 | 必要性 |
| --- | --- | --- | --- |
| C1 | stable_id + 指纹变 + 端点变是否允许自动升版本 | 不自动（走 H1 确认） | 沿用 |
| C2 | 过滤节点是否并入 `nodes` | 方案 A；B 方案已完整 | 沿用 |
| C3 | 遗留 `tasks` 表清理时点 | 保留一个 release | 沿用 |
| C4 | 时间本地 vs UTC | 本地 + `db.now()` | 沿用 |
| C5 | 业务目标是否写 `node_target_state` | 写，仅展示 | 沿用 |
| C6 | 零健康暂停是否计入 24h | 顺延 + 72h 硬上限 | 沿用 |
| C7 | 出口观测是否启用 | 默认关闭 | 沿用 |
| C8 | 指针 vs DB 权威 | 指针（§6.3） | 沿用 |
| C9 | rolling absent 阈值 | 3 次且 7 天 | 沿用 |
| C10 | 72h 到点默认动作 | 转人工，不自动发布 | 沿用 |
| **C11** | `occurrence_seq` 是否按机场永久单调，跨 `missing`、`retired` 均不复用 | **是**（否则"槽位 k"含义漂移；代价是序号只增不减） | 本轮新增，未确认 |
| **C12** | 是否允许 P0 一次完成 `nodes` 表重建，移除旧 `UNIQUE(airport_id, fingerprint)` | **是**（不重建则两同指纹不同身份无法共存）；若不允许，需先加"影子唯一键"过渡并延期 P1 | 本轮新增，未确认 |

**仍需实机验证**：机场 stable_id 真实覆盖率；生产库重复配置比例；NAS 目录 `rename` 与 `fsync` 的实际语义（部分 NAS 的 fsync 可能不保证）；presence log 30 天保留量级对库体积的影响。

---

# D. 风险与兼容

| # | 风险 | 触发 | 缓解 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 观察态积压导致新配置迟迟不生效 | 机场每次给不同指纹 | 7 天 `abandoned` + 事件；UI 显示"待确认配置" | I13–I15 |
| 2 | `seen_count<2` 长期阻塞轮换 | 机场 id 不稳定 | 先走 P1 绑定升级；必要时人工确认 | I20 |
| 3 | 恢复证据过严导致上线更慢 | 每次部署重建库 | `recovery_state` 持久化，重启不丢 | S23–S28 |
| 4 | DEFERRED 外键被误用 | 事务外分段写 | 写入必须 `with tx()`；FT11 | FT11 |
| 5 | 删除保护妨碍维护 | 需要重建表 | 仅离线维护显式声明 + 完整性检查 | 迁移组 |
| 6 | 临时令牌被滥用 | 代码直接写 `restore_ctx` | 只允许 readmit 内创建；评审 grep | F3/F4 |
| 7 | fsync 语义在 NAS 上不保证 | 网络文件系统 | 启动时自检（写小文件 + 断电不可测→文档标注局限） | 待实测 |
| 8 | 场景 7B 误判 | 页缓存内容被当作已提交 | 恢复时先 fsync 再读回校验 + token 匹配 | P7 |
| 9 | presence log 膨胀 | 高频拉取 | 30 天保留 + 按机场/日归档 | 容量普查 |
| 10 | 零健康分母抖动 | 轮询响应波动 | `A_eff` 只取本次可检测；`A_pool` 独立 | Z6/Z7 |
| 11 | 触发器数量增加写入开销 | 每次结果写入 3–4 个触发器 | 只保留结构必需；基准测试（待实测） | 性能测试 |
| 12 | 旧代码写入被新触发器拒绝 | 回退时代码仍写旧列 | 全部为"新列默认值合法"；FT 覆盖回退场景 | 回退用例 |

**兼容承诺**：v0.5 不改变任何已确认的业务规则；所有修订都是"把不可验证的推断替换为可验证证据"，或"把应用层约定升级为库级约束"。

---

**v0.5 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置**。文档交回第五轮设计审查；在获得明确批准前，不提交实施计划、不进入任何阶段。
