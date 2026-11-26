# NodePoolME 新架构总体设计方案 v0.4

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.3
**本轮性质**：纯设计修订。未改代码、未改数据库、未建迁移文件、未执行 P-1、未改配置。
**修订依据**：v0.3 第三轮审查的八项阻断问题（R1–R8）
**文档状态**：**待第四轮设计审查**（未自行认定通过）

---

## 修订索引

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| R1 | stable_id 当前映射/历史映射分离，索引不再阻断接管 | §2 | 重写 |
| R2 | 状态优先级、recovering 时间基准、unstable 收口 | §3 | 重写 |
| R3 | 关联完整性交给复合外键，触发器只补结构表达不了的规则 | §4 | 重写 |
| R4 | 过滤节点 id 保留机制（去掉矛盾外键） | §5 | 重写 |
| R5 | 提交证明（generated/verified/committed/active）+ 崩溃矩阵 | §6 | 重写 |
| R6 | rolling_pool 集合比较公式 + 数值验证 | §7 | 重写 |
| R7 | 零健康统计集合单一化 | §8 | 重写 |
| R8 | P-1 三种 DB 状态与文件降级日志 | §9 | 重写 |

未修订：Q1–Q12、30 天 missing、指纹算法、30 分钟 per-node / 90 分钟业务、17:00–24:00 测速、50MB、骤减 AND 规则、两次独立确认、30 个版本、四格式/四 URL/UA/Token/两种 `sub_publish`、P-1 不做业务迁移。

---

## 0. 一句话结论

v0.3 的八项问题有三个共同根因：

1. **把"当前映射"和"历史映射"挤进同一条唯一约束**（R1、R4）；
2. **把"状态判定"和"证据是否存在"混在一条优先级链里**（R2）；
3. **把"文件写完了"当成"已经发布"**（R5）。

v0.4 的修法统一为一句话：**能证明的才认，不能证明的一律 fail-closed；约束交给数据库，语义交给单一函数。**

---

## 1. 保留的既定设计（不重开）

Q1–Q12 全部保留；`missing` 30 天；不改指纹；per-node 30 分钟 + 抖动；业务 90 分钟；测速 17:00–24:00 与 50MB；骤减"≥50% 且 ≥10"双条件 + 两次独立确认；30 个可恢复版本；恢复两次有效成功且间隔 ≥30 分钟；TCP-only 永不合格；四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`；P-1 只做安全底座。

---

## 2. R1：stable_id 的当前映射与历史映射

### 2.1 问题复述（为什么 v0.3 会撞索引）

v0.3 把 `source_node_id` 存在 `node_identities` 上，并建：

```sql
CREATE UNIQUE INDEX uq_identity_stable ON node_identities(airport_id, source_node_id)
  WHERE source_node_id IS NOT NULL;
```

机场把某个 `stable_id` 从旧节点改嫁到新节点时，旧 identity 仍持有该 `stable_id`（历史需要保留），新 identity 要接管 → **唯一索引直接拒绝**。v0.3 只能靠"不清旧值"绕过，结果是新身份永远建不出来。

### 2.2 结构修正：stable_id 从身份表剥离为"占用记录"

`stable_id` 不是身份的属性，而是**机场发给某个槽位的、可被回收的标签**。因此独立成表，一行 = 一次占用（claim）：

```sql
CREATE TABLE identity_stable_ids (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id    INTEGER NOT NULL,
  stable_id     TEXT    NOT NULL,
  identity_id   INTEGER NOT NULL REFERENCES node_identities(id),
  seen_count    INTEGER NOT NULL DEFAULT 0,
  claimed_at    TEXT    NOT NULL,
  released_at   TEXT,                       -- NULL = 当前有效
  release_reason TEXT CHECK(release_reason IN ('reused','absent','manual')),
  UNIQUE(id)                                -- 便于审计引用
);
-- 同一机场同一 stable_id 只允许一条"当前有效"记录
CREATE UNIQUE INDEX uq_claim_live ON identity_stable_ids(airport_id, stable_id)
  WHERE released_at IS NULL;
-- 历史记录可以无限多，互不冲突
CREATE INDEX idx_claim_hist ON identity_stable_ids(airport_id, stable_id, released_at DESC);
CREATE INDEX idx_claim_ident ON identity_stable_ids(identity_id, released_at);
```

同时：

- `node_identities` **删除** `source_node_id`、`stable_id_seen_count`；
- `node_identities` **删除** `base_fingerprint`、`occurrence_key`。

**为什么也删指纹组键**：v0.3 的 `uq_identity(airport_id, base_fingerprint, occurrence_key)` 在"身份 B 参数轮换进 A 所在的指纹组"时会撞唯一键（两个 seq=1 同组）。指纹组是**派生集合**，不该持久化成唯一键。组键改由 `node_config_versions.base_fingerprint`（当前版本的 base 指纹）计算：

```sql
-- 某机场某指纹组内的身份（派生）
SELECT i.* FROM node_identities i
  JOIN node_config_versions v
    ON v.identity_id = i.id AND v.version = i.current_config_version
 WHERE i.airport_id = ? AND v.base_fingerprint = ? AND v.closed_at IS NULL;
```

身份唯一性只剩：`PRIMARY KEY(id)` + 机场内 `occurrence_seq` 单调递增（`UNIQUE(airport_id, occurrence_seq)`，用于槽位排序与展示，不再承担指纹分组语义）。

### 2.3 五种接线（当前/历史/回归/接管/新增）

记 `C_live = live claim(airport, stable_id)`、`C_hist = 该 (airport, stable_id) 的已释放 claim 列表`。

| 情形 | 条件 | 语义 | 动作 |
| --- | --- | --- | --- |
| **F 同配置** | `C_live` 存在，`fp == current_fp` | 同身份同版本 | 绑定；`seen_count+1`；更新 name/last_seen |
| **G 参数轮换** | `C_live` 存在，`fp != current_fp`，`endpoint` 相同，`seen_count >= 2` | 同身份新配置 | 新 `config_version`；旧版本 `closed_at`；`seen_count+1` |
| **H 端点迁移** | `C_live` 存在，`fp != current_fp`，`endpoint` 不同 | 同 id 不代表同机器 | `C_live` 释放（`reused`）；建新 identity + 新 claim；旧身份置 `missing`；`related_identity_id` 指向旧身份；事件 `probable_migration` |
| **I 回归** | `C_live` 不存在，`C_hist` 最新一条的 identity 仍 `active/missing`，且 `fp`、`endpoint` 与**该 identity 当前版本**一致 | 机场把 id 还给原机器 | 旧 identity 复用；新建 claim（`seen_count=历史值+1`）；状态按"结果是否新鲜"重算，不继承 Healthy |
| **J 接管** | `C_live` 不存在，`C_hist` 存在，但配置不匹配（或旧身份已 `retired`） | 机场把旧 id 给了另一台机器 | 旧 identity 保持 `missing`（若原为 active 则先置 missing + 事件）；建新 identity + 新 claim；`related_identity_id` = 旧；事件 `stable_id_reused` |
| **K 首次出现** | `C_live` 不存在，`C_hist` 为空 | 该机场此前从未发过这个 id | **允许继续走 P1–P4 指纹匹配**（见 §2.5）；匹配成功则把 claim 挂到已有身份（`stable_id_gained`） |

**"当前映射"与"历史映射"的关系**：同一 `(airport, stable_id)` 在任意时刻**至多一条 live claim**，历史 claim 全部保留且 `released_at` 非空。因此"旧 identity 保留历史"和"新 identity 接管"不再互斥。

### 2.4 释放与生效的时序

```
接管（J）：
  1 事务开始（BEGIN IMMEDIATE）
  2 UPDATE identity_stable_ids SET released_at=now, release_reason='reused'
      WHERE airport_id=? AND stable_id=? AND released_at IS NULL
  3 INSERT identity（occurrence_seq = max+1）
  4 INSERT node_config_versions(identity, 1, ...)
  5 UPDATE identity SET current_config_version=1
  6 INSERT identity_stable_ids(airport, stable_id, new_identity, claimed_at=now)
  7 旧 identity：lifecycle='missing'（若原 active）；related_identity_id 双向记录
  8 提交（deferred 外键在此刻校验）
```

顺序不能反：**先释放，再插入**。反了会撞 `uq_claim_live`。这也是 v0.3 撞索引的直观复现点。

### 2.5 stable_id 有值但匹配不到历史时，是否允许进 P1–P4

分两种，不能一刀切：

- **K 首次出现（历史为空）**：允许进入 P1–P4。理由：节点可能"先有指纹身份、后拿到 id"，若不允许，就会给同一台机器再建一个身份，历史断裂。匹配成功后补 claim（事件 `stable_id_gained`），并要求后续两次 `applied` 拉取该 id 仍指向同一身份才把 `seen_count` 提到 2。
- **J 接管（历史非空）**：**禁止**进入 P1–P4。理由：P1 的条件是"组内 1 个未绑定身份 + 1 个未绑定节点"，恰恰会在"旧身份还在 missing、新机器配置相同"时把旧身份绑给新机器——这正是"靠 fingerprint 相同合并不同 stable_id"的入口。接管必须走"新身份"，历史只做关联不做继承。

### 2.6 完整身份匹配伪代码（R1 交付物）

```python
def resolve(airport, n, ctx):
    """n: 本次响应中的一个节点；返回绑定结果（含 identity 与 config_version）"""
    fp, ep = n.fingerprint, (n.server, n.port)
    live = ctx.live_claim(airport, n.stable_id) if n.stable_id else None

    # ---------- P0：stable_id 当前映射 ----------
    if live:
        ident = live.identity
        if fp == ctx.current_fp(ident):
            claim_incr(ctx, live)
            return bind(ident, n, reason="stable_same")

        if ep == ctx.current_endpoint(ident) and live.seen_count >= 2:
            claim_incr(ctx, live)
            return bump_version(ident, n, reason="stable_rotated")

        # H 端点迁移：同 id 不足以为证
        return takeover_new_identity(airport, n, old=ident,
                                     reason="stable_endpoint_change")

    # ---------- P0'：stable_id 有值但无 live claim ----------
    if n.stable_id:
        hist = ctx.history_claims(airport, n.stable_id)      # released_at 非空
        if hist:
            last = hist.newest
            old = last.identity
            if (old.lifecycle in ("active", "missing")
                    and fp == ctx.current_fp(old)
                    and ep == ctx.current_endpoint(old)):
                return readopt(old, n, claim=last)           # I 回归
            return takeover_new_identity(airport, n, old=old,
                                         reason="stable_id_reused")   # J 接管
        ctx.note("stable_id_new")                            # K 首次出现 → 继续

    # ---------- P1：单候选延续（组键 = 当前版本的 base_fingerprint） ----------
    group = ctx.free_identities(airport, n.base_fp)          # 未绑定本次的
    free  = ctx.free_nodes(n.base_fp)
    if len(group) == 1 and len(free) == 1:
        return bind(group[0], n, reason="single_candidate", claim=n.stable_id)

    # ---------- P2：完整归一化名精确（一一映射） ----------
    cands = [i for i in group if i.current_display_name == n.display_name]
    if len(cands) == 1 and ctx.name_unique_in_group(n.display_name):
        return bind(cands[0], n, reason="exact_name", claim=n.stable_id)

    # ---------- P3：编号配对（弱） ----------
    pair = ctx.number_pair(group, free)
    if pair.unique:
        return bind(pair.identity, n, reason="index_pair",
                    weak=True, claim=n.stable_id)

    # ---------- P4：持久槽位锚定（最弱） ----------
    slot = ctx.next_slot(airport, n.base_fp)                 # occurrence_seq 升序
    if slot:
        return bind(slot, n, reason="slot_anchor",
                    ambiguous=True, claim=n.stable_id)

    # ---------- P5：新建 ----------
    return new_identity(airport, n, seq=ctx.max_seq(airport) + 1,
                        claim=n.stable_id)


def takeover_new_identity(airport, n, old, reason):
    """J/H：释放旧 claim → 建新身份 → 新 claim（同一事务）"""
    ctx.release_claim(old.stable_id, reason="reused")
    new = new_identity(airport, n, seq=ctx.max_seq(airport) + 1,
                       claim=n.stable_id, related=old.id)
    if old.lifecycle == "active":
        ctx.set_lifecycle(old, "missing", reason=reason)
    ctx.event(kind=reason, scope="node", identity=new.id, detail={"old": old.id})
    return new
```

收尾规则（与 v0.3 相同）：本次未绑定任何身份 → 该身份 `present_in_latest=0`、`absence_count+1`（轮询机场见 §7）；命中则恢复 `active`、状态按新鲜度重算。

### 2.7 索引与唯一约束的最终形态（R1 交付物）

| 表 | 约束 | 作用 | 失败测试 |
| --- | --- | --- | --- |
| `identity_stable_ids` | `uq_claim_live(airport_id, stable_id) WHERE released_at IS NULL` | 当前映射唯一 | FT-S1 |
| `identity_stable_ids` | 无全表唯一 | 历史可多条 | FT-S2 |
| `node_identities` | `UNIQUE(airport_id, occurrence_seq)` | 槽位序号唯一（排序/展示） | FT-S3 |
| `node_identities` | `UNIQUE(id, airport_id)` | 供 nodes 复合外键引用 | — |
| `node_config_versions` | `PRIMARY KEY(identity_id, version)` | 供外键引用 + 版本唯一 | FT-S4 |
| `nodes` | `UNIQUE(identity_id)`（**替换** 旧 `UNIQUE(airport_id, fingerprint)`） | 一个身份只对应一行节点 | FT-S5 |

> **必须删除旧唯一约束** `nodes(airport_id, fingerprint)`：两个同指纹不同 `stable_id` 的节点在新模型下是两个身份、两行 nodes，旧约束会直接拒绝第二行。SQLite 里这是表内 UNIQUE，不能 `DROP INDEX`，须走 §10 的 copy-migrate-swap 重建表。

### 2.8 测试（I 组，新增 4 个，共 16）

| # | 场景 | 断言 |
| --- | --- | --- |
| I7a | 同机场两个同指纹、不同 `stable_id` | 两条 live claim、两个 identity、两行 nodes；**无** missing；均参与检测 |
| I8a | stable_id 复用（旧 id 给新端点节点） | 旧 claim `released_at` 非空；新 claim live；旧 identity missing；`related_identity_id` 正确；`uq_claim_live` 不报错 |
| I8b | 复用后旧节点带原 id 回归（配置一致） | I 回归：复用旧 identity（不新建），claim 重建，`seen_count` 累加 |
| I8c | 新 stable_id 首次出现且指纹组内有 1 个未绑定身份 | 走 P1 绑定成功 + `stable_id_gained`；不新建身份 |
| I8d | 接管场景下指纹相同（诱导 P1 合并） | **禁止**进 P1；新 identity；旧 identity 保持 missing；历史不迁移 |

---

## 3. R2：健康状态机的优先级与恢复

### 3.1 §6.3 与 §6.4 的矛盾点

v0.3 §6.3 把 `unknown` 放在第一优先级（"任一必需目标 unknown → unknown"），而迁移表第 3 行写"unknown + 任一 fail → observe"。同一输入两个结论。

根因：把两类东西混在一条链里——

- **失败证据**（`fail_streak >= 1`）：一旦存在，节点必须有明确结论（observe/unstable/unavailable）；
- **证据缺失**（某目标无当前版本结果）：只在**没有失败证据**时才决定"无法判定"。

### 3.2 新优先级（唯一顺序，先命中先返回）

```
1 max_fail >= T                     → unavailable
2 max_fail == T-1                   → unstable
3 max_fail >= 1                     → observe
4 存在必需目标无当前版本有效结果     → unknown
5 恢复窗口开启                      → recovering（满足全部恢复条件则 healthy）
6 min(success_streak) >= 2          → healthy
7 ever_valid_fail == 0              → healthy（首次通过）
8 其余（曾有失败、现只有 1 次成功）  → observe
```

`unknown + G fail + W unknown` → 命中第 3 条 → `observe`（与迁移表一致）。`unknown + G pass + W unknown` → 第 1–3 不命中，第 4 命中 → `unknown`。

### 3.3 recovering 的时间基准（禁止对 NULL 直接运算）

**问题**：v0.3 的 `t.last_pass_at - t.recovery_started_at >= 30min` 在 `recovery_started_at IS NULL` 时得到 NULL，`all()` 语义随实现漂移（Python 里 NULL 会变 False，SQL 里会变 NULL → 三值逻辑）。

**修正**：引入节点级恢复窗口起点 `nodes.episode_started_at`（进入 `unstable` 或 `unavailable` 的时刻），并定义：

```
episode_started_at  : 节点首次进入 unstable/unavailable 时写入；进入 healthy 时清空
recovery_started_at : 目标级，该目标"出现过失败后第一次 pass"时写入；该目标再次失败时清空
base(t)             : max( coalesce(t.recovery_started_at, episode.episode_started_at),
                           episode.episode_started_at )
recover_ready(t)    : t.last_result == 'pass'
                  AND t.success_streak >= 2
                  AND t.last_pass_at >= base(t) + 30min
                  AND t.last_pass_at + t.ttl > now
```

三条都取 `max(...)`，所以**任何情况下 base 都不是 NULL**（只要节点进过坏状态，episode 必非空；未进过坏状态则不走恢复分支）。

### 3.4 恢复是否要求"每个必需目标分别两次成功、间隔 ≥30 分钟"

**是**，但对"从未失败过的目标"用 `episode_started_at` 作为基准：

- 目标 G 失败导致 unavailable（W 一直正常）：W 的 `recovery_started_at` 为 NULL，`base(W) = episode_started_at`；W 在 30 分钟节奏下天然会累积 `success_streak >= 2`，且 `last_pass_at` 必然晚于 `episode + 30min` → 满足。**不会因为"W 没有 recovery_started_at"卡死恢复**，也不会给 W 免检。
- 目标 A、B 不同时间开始恢复：各自的 `base` 独立，节点必须**两个都** `recover_ready` 才 healthy。
- 恢复过程中一个目标再次失败：该目标 `fail_streak=1` → 第 3 条优先 → 直接回 `observe`（不是留在 recovering）。若该目标已到 `T-1` → `unstable`。`episode_started_at` **不重置**（同一事件还没结束）。

### 3.5 unstable 是否也要恢复观察

**要**。v0.3 的伪代码里 `unstable` →（目标 pass）→ `max_fail=0` → 落入"`return healthy`"分支，等于"连续 2 次失败后 1 次成功立刻满血"，与 §6.3 的 `healthy 要求 success_streak>=2` 自相矛盾。

修正：`episode` 在进入 `unstable` 时即开启，因此 `unstable →（全目标 pass）→ recovering → healthy`。代价是约 30–60 分钟不可发，收益是"2 次失败"没有被 1 次成功抹平。

### 3.6 一次目标成功不能清除另一个目标的失败

聚合仍是投影，不做增量：

```
nodes.fail_streak    = max(t.fail_streak for t in required)
nodes.success_streak = min(t.success_streak for t in required)
```

G 成功只把 `G.fail_streak` 置 0；`max` 仍由 W 的 `fail_streak` 决定。**没有任何路径对节点计数执行 `+=` 或 `=0`。**

### 3.7 完整状态迁移表（20 行）

`T=3`；"全 pass"指所有必需目标当前版本有效 pass。

| # | 前态 | 事件 | 目标层变化 | 聚合中间值 | 新态 | 可发 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | unknown | G pass，W 无结果 | G ok=1/fail=0 | max_fail=0，有 unknown | unknown | 否 |
| 2 | unknown | 全目标首次 pass | ok=1 | max_fail=0，ever_fail=0 | healthy | 是 |
| 3 | unknown | G fail，W 无结果 | G fail=1 | max_fail=1 | observe | 是（若 G 有过期成功则否） |
| 4 | healthy | G fail，W pass | G fail=1 | max_fail=1 | observe | 是 |
| 5 | healthy | G、W 同轮 fail | 各 fail=1 | max_fail=1 | observe | 可能（两目标各自 `last_pass_at` 仍在 TTL 内时才可发；`fail_streak<T-1` 仍成立） |
| 6 | observe | 同一目标再 fail | 该目标 2 | max_fail=2 | unstable | 否 |
| 7 | observe | 另一目标首次 fail | max=1 | max_fail=1 | observe | 否 |
| 8 | unstable | 任一目标到 3 | max=3 | max_fail=3 | unavailable | 否 |
| 9 | unstable | 失败目标 pass | 该目标 ok=1 | max_fail=0，episode 开启 | recovering | 否 |
| 10 | unavailable | 全目标同轮 pass | 各 ok=1 | max_fail=0 | recovering | 否 |
| 11 | unavailable | 仅 G pass，W 仍 fail | G ok=1，W fail=3 | max_fail=3 | unavailable | 否 |
| 12 | recovering | 全 pass，各 ok=2，间隔 ≥30min | ok=2 | 全部 ready | healthy（episode 关闭） | 是 |
| 13 | recovering | 全 pass，间隔 10min | ok=2 | ready=false（时间不足） | recovering | 否 |
| 14 | recovering | 某目标 fail | 该目标 fail=1 | max_fail=1 | observe | 否（该目标无新鲜成功） |
| 15 | observe | 全 pass（单次） | ok=1 | max=0，ever_fail=1 | observe | 是（新鲜时） |
| 16 | 任意 | 引擎/系统/目标事故 | valid=0，不写目标层 | 不变 | 不变 | 不变 |
| 17 | 任意 | 目标 TTL 到期 | 不写（派生判定） | 不变 | 不变（UI 标 stale） | 否 |
| 18 | 任意 | 新 config_version | 目标行重建 | all unknown | unknown | 否 |
| 19 | 任意 | lifecycle missing/absent | 冻结 | 不变 | 不变 | 否 |
| 20 | healthy | TTL 到期（全目标） | 不变 | 不变 | healthy（但不可发） | 否 |

> 第 15 行说明：单次失败后 1 次成功回到 `observe` 而不是 `healthy`（`success_streak=1 < 2`）。这是"一次失败不摘"，同时不把 1 次成功当 2 次。

### 3.8 伪代码（唯一写 `nodes.state` 的地方）

```python
T = settings.fail_threshold          # 默认 3
RECOVER_GAP = 30 * 60

def recompute(node, prev):
    ts = required_targets(node)      # 当前 config_version 下的必需目标（G、W）
    if not ts:
        return "unknown"
    max_fail = max(t.fail_streak for t in ts)

    if max_fail >= T:      return "unavailable"
    if max_fail == T - 1:  return "unstable"
    if max_fail >= 1:      return "observe"
    if any(t.last_result == "unknown" for t in ts):
        return "unknown"

    if node.episode_started_at is not None:            # 恢复窗口开启
        if all(recover_ready(t, node.episode_started_at) for t in ts):
            close_episode(node)                        # 清空 episode_started_at
            return "healthy"
        return "recovering"

    if min(t.success_streak for t in ts) >= 2:
        return "healthy"
    if node.ever_valid_fail == 0:
        return "healthy"                               # 首次通过（Q11 只约束"恢复"）
    return "observe"


def recover_ready(t, ep):
    base = max(t.recovery_started_at or ep, ep)        # 永不为 NULL
    return (t.last_result == "pass"
            and t.success_streak >= 2
            and t.last_pass_at >= base + RECOVER_GAP
            and t.last_pass_at + t.ttl > db.now())


def apply_result(node, target, outcome):
    if not validity.is_valid(outcome, node):
        validity.record_invalid(outcome); return          # 不写目标层
    t = target_state.upsert(node, target, outcome)

    if outcome.pass:
        t.fail_before = t.fail_streak
        if t.fail_before >= 1 and t.recovery_started_at is None:
            t.recovery_started_at = db.now()
        t.fail_streak = 0
        t.success_streak += 1
        t.last_pass_at = db.now()
        t.last_result = "pass"
    else:
        t.fail_streak += 1
        t.success_streak = 0
        t.recovery_started_at = None
        t.last_result = "fail"
        t.last_fail_at = db.now()
        node.ever_valid_fail = 1

    new = recompute(node, node.state)
    if new in ("unstable", "unavailable") and node.episode_started_at is None:
        node.episode_started_at = db.now()
    if new == "healthy":
        node.episode_started_at = None
    if new != node.state:
        state_history.write(node, node.state, new, reason=outcome.reason)
        node.state_since = db.now()
    node.state = new
```

### 3.9 发布资格（与状态机一致的唯一表达式）

```
eligible(node) =
      node.lifecycle == 'active'
  AND node.state IN ('healthy','observe')
  AND ∀ t: exists ts(node,t) with ts.config_version == node.config_version
                              AND ts.rule_version == current_rule
                              AND ts.last_pass_at + ts.ttl > now
                              AND ts.fail_streak < T-1
```

一致性自检（评审可逐行对表）：`healthy` 必然成立（全 pass + 新鲜）；`observe` 仅在"失败目标的成功仍新鲜"时成立；`unstable` 被 `fail_streak < T-1` 拦下；`recovering/unknown/unavailable` 被状态集合拦下。

### 3.10 状态机测试（S 组，22 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| S1 | unknown + G pass + W unknown | unknown，不可发 |
| S2 | unknown + G fail + W unknown | **observe**（§3.2 第 3 条）；不可发（G 无有效成功） |
| S3 | unknown + 双目标首次 pass | healthy |
| S4 | healthy + G fail | observe，可发（W 新鲜） |
| S5 | healthy + G、W 同轮 fail | 节点 `fail_streak=1`，不是 2 |
| S6 | observe + 同目标第 2 次 fail | unstable，停发 |
| S7 | observe + 另一目标首次 fail | 仍 observe |
| S8 | unstable + 任一目标到 3 | unavailable |
| S9 | unavailable（仅 G 引起，W 一直正常）+ G 恢复 | G `recovery_started_at` 写入；W 为 NULL；**仍 recovering**，不因 W 为 NULL 报错 |
| S10 | unavailable + 全目标同轮 pass | recovering |
| S11 | G、W 不同时间开始恢复 | 先恢复者就绪后仍 recovering；两者都 ready 才 healthy |
| S12 | recovering 中 W 再次 fail | observe（max_fail=1），episode 不重置 |
| S13 | recovering + 全 pass 间隔 10min | 仍 recovering |
| S14 | recovering + 全 pass 间隔 35min | healthy，episode 关闭 |
| S15 | unstable + 全 pass（单次） | recovering（**不是** healthy） |
| S16 | observe + 全 pass（单次） | observe（`success_streak=1`），可发 |
| S17 | observe + 再一轮 pass | healthy（`success_streak=2`） |
| S18 | recovering + 目标 TTL 到期 | 仍 recovering；`recover_ready=false`；不可发 |
| S19 | healthy + TTL 到期 | 状态不变；状态历史无新行；资格为假 |
| S20 | 引擎异常 3 次 | 状态与计数不变；仅事件 |
| S21 | 目标事故（G 全部 valid=0） | G 行不更新；W 正常；节点不因 G 变 fail |
| S22 | `recovery_started_at IS NULL` 参与聚合 | 不产生 NULL 传播；以 episode 为 base |

---

## 4. R3：数据库关联约束（复合外键优先，触发器补位）

### 4.1 原则

能用**声明式约束**表达的，绝不用触发器；触发器只做"声明式表达不了"的跨表规则。SQLite 支持 `DEFERRABLE INITIALLY DEFERRED` 外键（需 `PRAGMA foreign_keys=ON`），用于打破"身份 ↔ 版本"的循环依赖。

### 4.2 逐条对应审查意见

| 意见 | 解决方式 | 类型 |
| --- | --- | --- |
| 1. `current_config_version` 的 INSERT 完整性 | `(id, current_config_version)` → `node_config_versions(identity_id, version)`，**DEFERRED**；身份先以 NULL 建，事务内补齐，提交时校验 | 外键 |
| 2. `nodes.airport_id` 与 identity 一致 | `(identity_id, airport_id)` → `node_identities(id, airport_id)` 复合外键 | 外键 |
| 3. `nodes.lifecycle` 不能被直接改 | `BEFORE UPDATE OF lifecycle ON nodes` 比对 identity 当前值；唯一合法写路径是 identity 的投影触发器 | 触发器 |
| 4. `node_target_state` INSERT/UPDATE 版本一致 | 复合外键 `(identity_id, config_version)` → 版本表；触发器限制"只能写当前版本" | 外键 + 触发器 |
| 5. target_state 与 identity/config_version 的关联 | 目标表**加 `identity_id`**，与 `config_version` 组成复合外键；`node_id` 只作快照 | 结构 |
| 6. `node_state_history.node_id` 必须属于该 identity | `BEFORE INSERT` 触发器比对 `nodes.identity_id` | 触发器 |
| 7. 历史版本 vs 当前版本必须区分 | 历史表引用**版本表**（永久保留）；当前版本只由 `nodes.config_version` 表达；触发器禁止把旧版本写成"当前事实" | 语义 + 触发器 |
| 8. 写入顺序与事务边界 | §4.5 固定顺序；所有多行写入 `BEGIN IMMEDIATE` | 约定（文档化） |

### 4.3 关键 DDL（可直接执行片段）

```sql
PRAGMA foreign_keys = ON;   -- 每个连接初始化必须执行

-- T1 身份
CREATE TABLE node_identities (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id            INTEGER NOT NULL,
  occurrence_seq        INTEGER NOT NULL,
  current_config_version INTEGER,                       -- 允许 NULL，事务内补齐
  lifecycle             TEXT NOT NULL DEFAULT 'active'
                        CHECK(lifecycle IN ('active','missing','retired')),
  present_in_latest     INTEGER NOT NULL DEFAULT 1 CHECK(present_in_latest IN (0,1)),
  absence_count         INTEGER NOT NULL DEFAULT 0,
  last_present_at       TEXT, last_absent_at TEXT,
  first_seen_at         TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  missing_since         TEXT, retired_at TEXT,
  rotation_hint         TEXT NOT NULL DEFAULT 'unknown'
                        CHECK(rotation_hint IN ('unknown','list','exit','mixed')),
  related_identity_id   INTEGER REFERENCES node_identities(id),
  ambiguous             INTEGER NOT NULL DEFAULT 0 CHECK(ambiguous IN (0,1)),
  note                  TEXT,
  UNIQUE(airport_id, occurrence_seq),
  UNIQUE(id, airport_id),
  FOREIGN KEY (id, current_config_version)
    REFERENCES node_config_versions(identity_id, version)
    DEFERRABLE INITIALLY DEFERRED
);

-- T1b stable_id 占用（当前/历史分离）
CREATE TABLE identity_stable_ids (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id     INTEGER NOT NULL,
  stable_id      TEXT NOT NULL,
  identity_id    INTEGER NOT NULL REFERENCES node_identities(id),
  seen_count     INTEGER NOT NULL DEFAULT 0,
  claimed_at     TEXT NOT NULL,
  released_at    TEXT,
  release_reason TEXT CHECK(release_reason IN ('reused','absent','manual'))
);
CREATE UNIQUE INDEX uq_claim_live ON identity_stable_ids(airport_id, stable_id)
  WHERE released_at IS NULL;
CREATE INDEX idx_claim_hist ON identity_stable_ids(airport_id, stable_id, released_at DESC);

-- T2 配置版本（永久保留，供历史引用）
CREATE TABLE node_config_versions (
  identity_id    INTEGER NOT NULL REFERENCES node_identities(id),
  version        INTEGER NOT NULL,
  fingerprint    TEXT NOT NULL,
  base_fingerprint TEXT NOT NULL,
  params_hash    TEXT NOT NULL,
  params         TEXT NOT NULL,
  protocol       TEXT NOT NULL,
  server         TEXT NOT NULL,
  port           INTEGER NOT NULL,
  display_name   TEXT,
  sample_raw_name TEXT,
  change_reason  TEXT NOT NULL CHECK(change_reason IN
                 ('initial','config_rotated','readopt')),
  first_seen_at  TEXT NOT NULL, last_seen_at TEXT, closed_at TEXT,
  PRIMARY KEY (identity_id, version)
);

-- T5 nodes（重建表：去旧 UNIQUE(airport_id,fingerprint)，加复合外键）
CREATE TABLE nodes__new (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id    INTEGER NOT NULL REFERENCES airports(id),
  identity_id   INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  fingerprint   TEXT NOT NULL,
  name          TEXT, type TEXT, params TEXT,
  server        TEXT, port INTEGER,
  lifecycle     TEXT NOT NULL DEFAULT 'active',
  state         TEXT NOT NULL DEFAULT 'unknown',
  state_since   TEXT,
  episode_started_at TEXT,
  ever_valid_fail INTEGER NOT NULL DEFAULT 0 CHECK(ever_valid_fail IN (0,1)),
  fail_streak   INTEGER NOT NULL DEFAULT 0,
  success_streak INTEGER NOT NULL DEFAULT 0,
  next_due_at   TEXT, last_check_at TEXT,
  missing_since TEXT, created_at TEXT NOT NULL, updated_at TEXT,
  UNIQUE(identity_id),
  FOREIGN KEY (identity_id, airport_id)
    REFERENCES node_identities(id, airport_id),
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
);
CREATE INDEX idx_nodes_due ON nodes(next_due_at, lifecycle, state);

-- T3 目标层事实
CREATE TABLE node_target_state (
  node_id        INTEGER NOT NULL REFERENCES nodes(id),
  identity_id    INTEGER NOT NULL,
  target         TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  rule_version   INTEGER NOT NULL,
  last_result    TEXT NOT NULL DEFAULT 'unknown'
                 CHECK(last_result IN ('pass','fail','unknown')),
  last_pass_at   TEXT, last_fail_at TEXT, recovery_started_at TEXT,
  fail_streak    INTEGER NOT NULL DEFAULT 0,
  success_streak INTEGER NOT NULL DEFAULT 0,
  failure_source TEXT, ttl_minutes INTEGER, updated_at TEXT NOT NULL,
  PRIMARY KEY (node_id, target, config_version),
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
    DEFERRABLE INITIALLY DEFERRED
);

-- T4 状态历史（复合外键 + node 归属触发器）
CREATE TABLE node_state_history (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id        INTEGER NOT NULL REFERENCES nodes(id),
  identity_id    INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  from_state     TEXT NOT NULL, to_state TEXT NOT NULL,
  lifecycle      TEXT NOT NULL, reason_code TEXT NOT NULL, detail TEXT,
  rule_version   INTEGER NOT NULL, ts TEXT NOT NULL,
  FOREIGN KEY (identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
);
CREATE INDEX idx_history_node ON node_state_history(node_id, ts);
```

### 4.4 触发器（只做声明式表达不了的 5 条）

```sql
-- TR1：节点生命周期只能经身份投影写入
CREATE TRIGGER trg_nodes_lifecycle_direct BEFORE UPDATE OF lifecycle ON nodes
WHEN NEW.lifecycle <> (SELECT lifecycle FROM node_identities WHERE id = NEW.identity_id)
BEGIN SELECT RAISE(ABORT,'nodes.lifecycle must follow node_identities'); END;

-- TR2：身份生命周期 → 节点（唯一合法写路径）
CREATE TRIGGER trg_identity_lifecycle_project AFTER UPDATE OF lifecycle ON node_identities
BEGIN
  UPDATE nodes
     SET lifecycle = NEW.lifecycle,
         missing_since = CASE WHEN NEW.lifecycle='missing'
                              THEN COALESCE(NEW.missing_since, NEW.last_seen_at) END
   WHERE identity_id = NEW.id;
END;

-- TR3：目标事实只能写当前版本
CREATE TRIGGER trg_tstate_current_ins BEFORE INSERT ON node_target_state
WHEN NEW.config_version <> (SELECT config_version FROM nodes WHERE id = NEW.node_id)
BEGIN SELECT RAISE(ABORT,'target state must be current config_version'); END;

CREATE TRIGGER trg_tstate_current_upd BEFORE UPDATE OF config_version, node_id ON node_target_state
WHEN NEW.config_version <> (SELECT config_version FROM nodes WHERE id = NEW.node_id)
BEGIN SELECT RAISE(ABORT,'target state update must be current config_version'); END;

-- TR4：目标事实的 node 必须属于该 identity
CREATE TRIGGER trg_tstate_identity BEFORE INSERT ON node_target_state
WHEN NOT EXISTS (SELECT 1 FROM nodes n
                 WHERE n.id = NEW.node_id AND n.identity_id = NEW.identity_id)
BEGIN SELECT RAISE(ABORT,'target state node/identity mismatch'); END;

-- TR5：状态历史的 node 必须属于该 identity
CREATE TRIGGER trg_history_identity BEFORE INSERT ON node_state_history
WHEN NOT EXISTS (SELECT 1 FROM nodes n
                 WHERE n.id = NEW.node_id AND n.identity_id = NEW.identity_id)
BEGIN SELECT RAISE(ABORT,'history node/identity mismatch'); END;
```

> `trg_identity_lifecycle_project` 内的 `UPDATE nodes` 会再触发 TR1；因为身份值已先更新，TR1 比较通过，不会自锁。`recursive_triggers` 默认关闭，TR1 不修改身份表，无递归风险。

### 4.5 事务边界与写入顺序（固定，不允许各模块自定）

| 操作 | 顺序（同一 `BEGIN IMMEDIATE` 事务） | 提交时校验 |
| --- | --- | --- |
| 建身份 | identity(NULL) → 版本 v1 → identity.current=1 → nodes 行 | DEFERRED 外键 |
| 参数轮换 | 版本 v(n+1) → nodes.config_version=n+1 → identity.current=n+1 → 旧版本 closed_at | 同上 |
| 写结果 | target_state upsert → recompute → nodes.state + 计数（同事务） | TR3/TR4 |
| 生命周期 | identity.lifecycle → 触发器投影 nodes | TR1/TR2 |
| 删除/归档 | 禁止删除身份与版本行；只改 lifecycle | — |

**为什么"版本行先于节点行"**：TR3/复合外键都要求"节点指向的版本已存在"。反序必定 abort，这也是 v0.3 风险表 D10 的落地。

### 4.6 约束失败测试（每条约束一个负向用例）

| # | 操作 | 期望 |
| --- | --- | --- |
| FT1 | 插入 `nodes` 且 `identity_id=NULL` | 复合外键 / NOT NULL 报错 |
| FT2 | 插入 `nodes` 且 `airport_id` 与身份不一致 | 复合外键报错 |
| FT3 | 直接 `UPDATE nodes SET lifecycle='missing'`（身份仍 active） | TR1 abort |
| FT4 | 改身份 lifecycle | TR2 同步 nodes；无 TR1 abort |
| FT5 | 插入 target_state 指向旧版本 | TR3 abort |
| FT6 | 插入 target_state，`identity_id` 与 node 不符 | TR4 abort |
| FT7 | 插入 state_history，node 属于另一身份 | TR5 abort |
| FT8 | 身份 `current_config_version` 指向不存在的版本并提交 | DEFERRED 外键在 COMMIT 时失败 |
| FT9 | 同一机场同一 stable_id 插两条 live claim | `uq_claim_live` 报错 |
| FT10 | 两个节点同一 identity | `UNIQUE(identity_id)` 报错 |
| FT11 | 同一机场两节点同指纹不同身份 | **必须成功**（旧 `UNIQUE(airport_id,fingerprint)` 已移除） |

---

## 5. R4：过滤节点的 id 保留机制

### 5.1 矛盾复述

v0.3 同时要求：(a) `origin_node_id REFERENCES nodes(id)`；(b) 原 nodes 行已删时仍保留 `origin_node_id`；(c) 回池时重新 `INSERT` 原 `nodes.id`。(a) 与 (b) 直接冲突——没有父行就没有合法外键值；(c) 若先插父行再回池，等于"回池前先把节点复活"，与过滤语义冲突。

### 5.2 结论：`origin_node_id` 是**历史标识**，不是外键

关键事实：`nodes.id` 是 `INTEGER PRIMARY KEY AUTOINCREMENT`，**id 永不复用**（sqlite_sequence 单调）。因此"保存一个已删节点的 id"不会与未来的新 id 撞车，也不需要父行存在。

```sql
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_node_id INTEGER;      -- 无 FK
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_fingerprint TEXT;     -- 快照，防串号
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_state TEXT NOT NULL DEFAULT 'none'
  CHECK(origin_state IN ('none','held','restored','conflicted'));
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_status TEXT NOT NULL DEFAULT 'unmapped'
  CHECK(mapping_status IN ('mapped','ambiguous','unmapped'));
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_note TEXT;
ALTER TABLE airport_filtered_nodes ADD COLUMN mapped_at TEXT;

-- 一个历史 id 最多被一条过滤记录"持有"
CREATE UNIQUE INDEX uq_filtered_origin ON airport_filtered_nodes(origin_node_id)
  WHERE origin_node_id IS NOT NULL AND origin_state <> 'conflicted';
```

**为什么用 `origin_state` 而不是靠 `nodes` 是否存在来判断**：`nodes` 存在只说明"id 被占用"，不能说明"这次占用是否就是它自己的回池"。用状态机表达：

```
none --回填映射成功--> held --回池成功--> restored
                     \--id 被他人占用--> conflicted
```

### 5.3 回填（迁移时，只读旧表 + 写新列）

```
for f in filtered:
    cands = nodes where airport_id=f.airport_id and fingerprint=f.fingerprint
    if len(cands) == 1:
        f.origin_node_id = cands[0].id
        f.origin_fingerprint = cands[0].fingerprint
        f.mapping_status = 'mapped'
        f.origin_state = 'held'
    elif len(cands) > 1:
        f.mapping_status = 'ambiguous'         # 不猜
        f.origin_state = 'none'
        f.mapping_note = 'multiple: ' + ids
    else:
        f.mapping_status = 'unmapped'          # 旧逻辑已硬删，无从找回
        f.origin_state = 'none'
```

重复配置不猜的理由：同一 `(airport, fingerprint)` 多行时，旧表没有任何字段能区分是哪一行，任何选择都是把历史赌在一个随机 id 上。

### 5.4 回池（三种情况，全部带前置断言）

```python
def readmit(f, node):
    # 断言 1：指纹一致，否则不继承任何东西
    if f.origin_fingerprint and f.origin_fingerprint != node.fingerprint:
        return insert_new(node, reason="fingerprint_changed")   # 新 id + 事件

    # 断言 2：目标 id 未被他人占用
    if f.origin_node_id and db.exists("nodes", id=f.origin_node_id):
        owner = db.one("nodes", id=f.origin_node_id)
        if owner.identity_id != f.origin_identity_id or owner.fingerprint != node.fingerprint:
            f.origin_state = 'conflicted'
            return insert_new(node, reason="id_occupied_by_other")
        # 同一身份 → 视为重复准入，幂等返回
        return owner

    # 情况 A：mapped，原行不存在，id 空闲 → 显式恢复原 id
    if f.mapping_status == 'mapped' and f.origin_state == 'held':
        with tx():
            f.origin_state = 'restored'                 # 先释放"持有"
            row = db.insert("nodes", id=f.origin_node_id, identity_id=..., ...)
        return row

    # 情况 B：ambiguous / unmapped → 新建 id，标歧义，不继承历史
    f.origin_state = 'none'
    return insert_new(node, reason="origin_unmapped", ambiguous=True)
```

**原 ID 已被占用**：分两种——占用者是同一身份（幂等，返回既有行）；占用者是别的身份（`conflicted` + 新 id + 事件 `origin_id_conflict`）。绝不覆盖、绝不改绑。

### 5.5 防止历史检测数据串号

风险来源：原节点行被硬删后，`results / latency_results / speed_samples` 里仍留着 `node_id=old` 的孤儿行；若一个新节点复用该 id，孤儿行会被当成本节点历史。

三条防线：

1. **id 空间只减不增地用**：`AUTOINCREMENT` + §11.5"禁止删除 nodes"，使"复用"只会发生在回池这一条显式路径上；
2. **回池前做身份断言**：`origin_identity_id` 必须与将要写入的身份一致（上表断言 2）；不一致直接 `conflicted`；
3. **孤儿行不参与评分**：孤儿行没有对应 `node_identities` 行时，查询层用 `JOIN nodes` 过滤；`nodes` 不在 → 统计不命中。评分只读"当前 identity + 当前 config_version"的结果（v0.3 §6.2 已要求 `config_version` 匹配），旧行天然被排除。

**不做**：不给孤儿行补 `identity_id`（无法可靠推断），不删除孤儿行（保留审计）。补一行 `invalid_reason='orphan_node'` 仅用于展示，不进入任何聚合。

### 5.6 迁移前后 ID 对照（P0 输出真实清单，此处为结构示例）

| filtered.id | fingerprint | 候选 nodes | origin_node_id | mapping_status | origin_state | 回池结果 |
| --- | --- | --- | --- | --- | --- | --- |
| 11 | fpA | 1（id=7） | 7 | mapped | held | 恢复 id=7 |
| 12 | fpB | 2（id=8,9） | NULL | ambiguous | none | 新 id，标歧义 |
| 13 | fpC | 0 | NULL | unmapped | none | 新 id |
| 14 | fpD | 1（id=7，但指纹已变） | 7 | mapped | held | 指纹不符 → 新 id |
| 15 | fpE | 1（id=20），回池时 id=20 已被身份 B 占用 | 20 | mapped | conflicted | 新 id + 事件 |

### 5.7 测试（F 组，8 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| F1 | 唯一映射，原行已删，回池 | 恢复原 id；`origin_state=restored`；无新 identity |
| F2 | 多候选 | `ambiguous`；回池新建 id；不继承任何历史 |
| F3 | 原行仍存在 | 幂等返回同一行；不重复插入 |
| F4 | 指纹已变 | 不复用 id；新 id；事件 `fingerprint_changed` |
| F5 | id 被其他身份占用 | `conflicted`；新 id；`origin_id_conflict` 事件 |
| F6 | 孤儿结果行存在 | 评分/覆盖统计不命中；UI 标 orphan |
| F7 | 迁移回填 | `uq_filtered_origin` 不冲突（两条映射到同一 id 时必须标 ambiguous） |
| F8 | 同一过滤记录重复回池 | 第二次幂等，不产生第二行 |

---

## 6. R5：发布提交证明与崩溃恢复

### 6.1 四种状态必须分开（v0.3 的根错误）

| 状态 | 定义 | 证据 | 是否可作为"当前发布" |
| --- | --- | --- | --- |
| `generated` | 目录已写入，未经校验 | 目录存在 | 否 |
| `verified` | 7 项校验全过 | `checksums.txt` + 重算哈希一致 | **否**（还不能证明提交） |
| `committed` | 指针已切换（`active.json` 指向它） | `active.json` 内容 + `commit_token` | 是 |
| `active` | DB 已记录且与指针一致 | DB `state='active'` 且指针匹配 | 是 |

**"版本目录完整 ≠ 已发布"**：v0.3 的 P2 恢复规则是"找最大编号且校验通过的版本 → 重建 active"，这在"生成完但崩溃在替换指针前"的情况下会**发布一个从未提交的版本**。v0.4 必须用 `commit_token` 证明提交。

### 6.2 提交协议（write-intent → swap → confirm）

```
0  version = max(versions)+1；content_hash 计算；与 active 相同 → skipped
1  render 4 格式（内存）+ 全部校验（任一失败 → 中止，不落盘）
2  INSERT publish_versions(version, state='generated', content_hash, manifest_gz=...)
3  写 versions/<v>.tmp/：4 文件 + manifest.json.gz + meta.json + checksums.txt
4  fsync 每个文件；fsync versions/<v>.tmp
5  rename <v>.tmp → <v>；fsync versions/
6  UPDATE publish_versions SET state='verified'
7  写 data/sub/pending.json {version, commit_token, checksums_sha, created_at}；fsync 文件 + 目录
8  UPDATE publish_versions SET state='committing', commit_token=<uuid>   ← 提交意图落库
9  写 active.json.tmp {version, sha256: checksums_sha, commit_token, prev_version, prev_sha}
   fsync 文件
10 rename active.json.tmp → active.json                                  ← ★唯一提交点
11 fsync data/sub
12 UPDATE publish_versions SET state='active', activated_at=now；prev 置 'superseded'
13 DELETE pending.json + fsync 目录；share_history 追加
```

### 6.3 恢复优先级（只认能证明的）

```
R1  active.json 可解析 且 commit_token 与 DB 的 committing/active 行匹配 且 目录校验通过
      → 采用该版本；DB 若落后则补写 state='active'（recovered=1）

R2  active.json 可解析 且 目录校验通过，但 DB 无对应行
      → 采用（指针优先）；补写 DB 行 state='active'，事件 pointer_db_desync（recovered）

R3  active.json 缺失/损坏
      → 只在 DB 中找 state='active' 的**唯一**一行，且其目录校验通过
        → 重建 active.json（沿用原 commit_token 与 checksums_sha），事件 pointer_repaired
      → 若 DB 有多行 active（脏数据）→ 取 activated_at 最新且通过校验者，其余置 superseded，事件 pointer_multi_active
      → 若无 active 行，或校验不通过 → 进 R4

R4  active.json 不可用 且 DB 无可用 active
      → 若存在 pending.json 且其中 version 的目录校验通过 **但从未有 active 证据**
        → **不发布**（这是"生成/校验完但没提交"）；将 pending 标记 aborted（state='verified'）
      → 回退到 DB 中最后一个 state='superseded' 且 activated_at 最新的可校验版本？
        → **仅当** 其目录校验通过 且 无更高编号的 committed 版本，才允许作为"安全回退"
      → 否则 fail-closed：503 + system_events(pointer_critical)，不返回任何订阅内容
```

**关键判定（R5.4 / R5.6）**：

| 场景 | 判定 | 动作 |
| --- | --- | --- |
| 目录生成后、指针替换前崩溃 | 未提交 | 保留 `verified`，**绝不**自动 active；下次发布重新生成同编号或跳到新编号 |
| 指针替换后、DB 更新前崩溃 | 已提交（指针是证据） | R2/R1：补 DB；`pending.json` 留作旁证，清理 |
| active.json 损坏，且存在更高编号未提交版本 | 不能选大编号 | R3/R4：按 DB `active` 恢复；大编号保持非 active |
| DB active 与指针不一致 | 指针优先 | 仅当指针校验失败才用 DB（R3） |
| 两边都无法证明最后提交 | 不猜 | **fail-closed 503**（R4），人工介入 |

`pending.json` 的作用是"意图旁证"，**不是提交证据**：它只能证明"打算切换"，不能证明"切换成功"。唯一提交证据是 `active.json` 的 `commit_token`。

### 6.4 崩溃恢复矩阵（R5 交付物）

| # | 崩溃点 | 磁盘状态 | DB 状态 | 恢复动作 | 最终可发版本 |
| --- | --- | --- | --- | --- | --- |
| 1 | 步骤 3–4（写 tmp） | `<v>.tmp` 残留 | `generated` | 删 tmp；标记 `aborted` | 旧 active |
| 2 | 步骤 5–6（rename 后） | `<v>` 完整 | `verified` | 保留；等待下次发布 | 旧 active |
| 3 | 步骤 7–8（pending 写入后） | `<v>` + `pending.json` | `committing` | 删除 pending（未提交）；置 `verified` | 旧 active |
| 4 | 步骤 9（active.tmp 写完） | 同 #3 | `committing` | 同 #3（tmp 会被覆盖） | 旧 active |
| 5 | 步骤 10 后、11 前 | `active.json` 已指向 v | `committing` | R1：认指针；补 DB `active` | 新 v |
| 6 | 步骤 11 后、12 前 | 同上 | `committing` | 同上 | 新 v |
| 7 | 步骤 12 后、13 前 | 同上 + `pending.json` 残留 | `active` | 删 pending | 新 v |
| 8 | active.json 被截断/损坏 | 指针不可解析 | `active` | R3：用 DB 重建指针（校验目录） | DB active |
| 9 | 目录被删（磁盘故障） | 无 `<v>` | `active` | R4：用 `manifest_gz`（DB）重渲染 → 校验 → 重建目录 | DB active |
| 10 | 指针与 DB 都无可信记录 | — | — | fail-closed 503 + 事件 | 无（人工） |

> 支撑 #9：`publish_versions.manifest_gz BLOB` 保存完整节点配置快照，重渲染 4 格式后必须与 `content_hash` 一致才算恢复成功；不一致即认为 manifest 不可信 → 进 #10。

### 6.5 `publish_versions` 增量 DDL

```sql
ALTER TABLE publish_versions ADD COLUMN state TEXT NOT NULL DEFAULT 'generated'
  CHECK(state IN ('generated','verified','committing','active','superseded','aborted'));
ALTER TABLE publish_versions ADD COLUMN commit_token TEXT;
ALTER TABLE publish_versions ADD COLUMN checksums_sha TEXT;
ALTER TABLE publish_versions ADD COLUMN manifest_gz BLOB;      -- 目录丢失时的重建依据
ALTER TABLE publish_versions ADD COLUMN activated_at TEXT;
ALTER TABLE publish_versions ADD COLUMN superseded_at TEXT;
CREATE UNIQUE INDEX uq_publish_active ON publish_versions(state) WHERE state='active';
CREATE UNIQUE INDEX uq_publish_token ON publish_versions(commit_token) WHERE commit_token IS NOT NULL;
```

`uq_publish_active` 让"DB 里同时两个 active"变成不可能；若历史脏数据已存在，迁移时须先修正（保留 `activated_at` 最新者）。

### 6.6 校验清单（7 项，与 v0.3 一致，明确"何时做"）

| 文件 | 校验 | 生成后 | 恢复时 |
| --- | --- | --- | --- |
| clash.yaml | 可解析 + 必要键 + 节点数 = manifest | 是 | 是 |
| singbox.json | 可解析 + outbounds 数 = manifest | 是 | 是 |
| base64.txt | 可解码 + 每行可解析 + 数 = manifest | 是 | 是 |
| loon.txt | 代理段完整 + 数 = manifest | 是 | 是 |
| manifest.json.gz | 可解压 + 含 protocol/server/port/params/display_name | 是 | 是 |
| meta.json | 必填字段 + content_hash 与目录一致 | 是 | 是 |
| checksums.txt | 6 项（4 格式 + manifest + meta）哈希一致 | 是 | 是 |

`active.json.sha256` = `checksums.txt` 的 sha256，用于"指针指向的目录是否被篡改"的快速判定。

### 6.7 测试（P 组，12 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| P1 | 正常发布 | 四格式一致；`state='active'`；指针 token 匹配 |
| P2 | 内容未变 | `skipped`，不建新版本 |
| P3 | 渲染失败（某格式非法） | 不落盘；旧 active 不变 |
| P4 | 崩溃点 #3（pending 存在，指针未换） | 重启后**不**发布 v；v 保持 `verified` |
| P5 | 崩溃点 #5（指针已换，DB committing） | 重启后认 v；DB 补 `active` |
| P6 | active.json 损坏 + DB active 可用 | 重建指针；`pointer_repaired` |
| P7 | active.json 损坏 + DB 无 active + 高编号未提交 | fail-closed；**不**选高编号 |
| P8 | 目录被删 + manifest 可重建 | 重渲染 → 哈希一致 → 恢复 |
| P9 | 目录被删 + manifest 哈希不一致 | 不恢复；503 |
| P10 | DB 两个 active 行 | 迁移修正 + `pointer_multi_active` 事件 |
| P11 | 回退到 superseded 版本 | 仅当无更高 committed 且校验通过 |
| P12 | 30 个版本轮转 | 只删非 active 且超 30 的最老版本 |

---

## 7. R6：rolling_pool 的集合比较

### 7.1 为什么 Jaccard 不适用

`Jaccard(S_i, U7) = |S_i ∩ U7| / |U7|` 的分母是**长期并集**。轮询机场的 `S_i` 天生是子集（62 / 118），Jaccard 上限就是 `62/118 ≈ 0.53`，永远达不到 0.9 → 会被判成"不一致"，进而误触发骤减与身份删除。**用集合相似度衡量"子集是否正常"是量纲错误。**

### 7.2 四个集合与三个指标

| 记号 | 定义 |
| --- | --- |
| `S_i` | 第 i 次 `applied` 响应中的身份集合（按 stable_id，无 id 时按"当前 base 指纹 + 槽位"占位身份） |
| `U7(t)` | 截至 t 的 7 天身份并集 = `{id : last_present_at >= t - 7d}` |
| `U7_prev` | 上一个观察窗口的并集（`t - 7d` 时点的 `U7`） |
| `N_i` | `|S_i|` |

指标：

```
覆盖率（本次响应有多少是已知身份）
  cover_i   = |S_i ∩ U7| / |S_i|                        （分母是本次响应，不是并集）
新面孔率
  fresh_i   = |S_i \ U7| / |S_i| = 1 - cover_i
并集稳定性（长期盘子的变化速度）
  simU      = |U7 ∩ U7_prev| / |U7 ∪ U7_prev|
  growthU   = |U7| / |U7_prev| - 1
单次摆动（响应规模是否在抖）
  swing     = max(N_i, N_{i-1}, N_{i-2}) / min(N_i, N_{i-1}, N_{i-2})
  overlap   = |S_i ∩ S_{i-1}| / min(N_i, N_{i-1})        （相邻两次的重叠比例）
```

### 7.3 rolling_pool 判定（三条件同时成立，连续 3 次）

```
A 子集性：  cover_i >= 0.80        # 至少 80% 的响应节点是 7 天内见过的
B 并集稳定：simU >= 0.90  且  |growthU| <= 0.10
C 摆动：    swing >= 1.30  或  overlap < 0.90
```

三条同时满足 → 判为 `rolling_pool`（需连续 3 个 `applied` 版本）。

- 只有 C 成立（摆动大）而 A、B 不成立 → 是"真增删"，走骤减主规则；
- 只有 A 成立而 B 崩（并集本身在缩）→ 视为"池子在缩"，按 §7.5 处理，不判 rolling。

### 7.4 数值验证（R6 必测示例）

已知：`|U7| = 118`，`S1 = 62`，`S2 = 70`，`|S1 ∩ S2| = 48`（交替节点 14 + 22），`U7` 在 7 天内基本不变（`simU = 0.96`，`growthU = +2%`）。

| 指标 | 计算 | 结果 | 判定 |
| --- | --- | --- | --- |
| `cover_1` | 62 / 62（假设全在 U7 内） | 1.00 | A 通过 |
| `cover_2` | 70 / 70 | 1.00 | A 通过 |
| `simU` | 0.96 | ≥0.90 | B 通过 |
| `growthU` | +2% | ≤10% | B 通过 |
| `swing` | 70 / 62 = 1.13 | <1.30 | C 不通过（规模稳定） |
| `overlap` | 48 / 62 = 0.774 | <0.90 | **C 通过**（成员在换） |
| 旧 `Jaccard(S1,U7)` | 62 / 118 = 0.525 | 远低于 0.9 | **旧公式误判**（说明必须替换） |

结论：A、B、C 全通过 → 判 `rolling_pool`；且因 `N_i` 摆动仅 1.13，骤减主规则（7 天中位数降 ≥50% 且绝对减 ≥10）不会被触发。

### 7.5 骤减基线必须用并集，不用单次数量

```
baseline(t)      = median( |U7(d)| for d in 最近 7 天 )
drop_ratio       = 1 - |U7(t)| / baseline(t)
drop_abs         = baseline(t) - |U7(t)|
触发（两条件必须同时）:
  drop_ratio >= 0.50  AND  drop_abs >= 10
```

- 池子 118 → 100（`drop_abs=18`，`ratio=0.153`）→ 不触发（ratio 不足）；
- 池子 118 → 55（`ratio=0.534`，`abs=63`）→ 触发，再走两次独立拉取确认；
- 响应数量 62 / 70 的波动**根本不进入该公式**，因此轮询抖动不会误触发。

### 7.6 absent 与 missing（双条件，AND）

```
每次 applied 拉取后：
  对每个 U7 中的身份 id：
     if id 不在本次 S：
         absence_count += 1；last_absent_at = now；present_in_latest = 0
     else:
         absence_count = 0；last_present_at = now；present_in_latest = 1

转 missing 的条件：
  absence_count >= 3  AND  now - last_present_at >= 7 天
```

为什么必须 AND：轮询池中单节点出现率约 `N/|U7| ≈ 0.52`，连续 3 次缺席的概率约 `0.48³ ≈ 11%`，单靠 `absence_count` 会周期性误判。加上"7 天未出现"后，正常轮换节点的误判概率趋近 0（7 天内约 300 次拉取，全缺席概率 `0.48^300`）。

对照（真删除）：池子 118 → 100，某节点在 7 天内一次未出现且 `absence_count >= 3` → 转 `missing` → 30 天后 `retired`（Q2 不变）。

### 7.7 身份的"占位"问题（无 stable_id 的轮询机场）

轮询机场若不给 stable_id，`S_i` 的集合元素只能用"当前指纹 + 槽位"占位身份表达，此时 `U7` 的并集口径本身不可靠。规则：

- 若某机场 `stable_id` 覆盖率为 0 且 `swing >= 1.30` → 标 `rolling_pool_unverifiable`，**不启用** absent→missing，全部按"响应子集"处理（只冻结检测，不动生命周期），并在 UI 明示"身份不可观测"。
- 该状态需人工确认后才能改判（避免用不可靠并集自动删节点）。

### 7.8 测试（RP 组，6 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| RP1 | 118/62/70 交替（§7.4） | 判 rolling；无骤减；无 missing |
| RP2 | 旧 Jaccard 公式 | 复现 0.525 误判（作为回归对照，不用于生产） |
| RP3 | 池子真缩 118→55 | 触发骤减；两次确认后进入保护 |
| RP4 | 池子 118→100 | 不触发（ratio 不足） |
| RP5 | 单节点 3 次缺席但 7 天内出现过 | 不转 missing |
| RP6 | 无 stable_id + 大幅摆动 | `rolling_pool_unverifiable`；不删节点 |

---

## 8. R7：零健康统计集合单一化

### 8.1 集合定义（唯一口径，cov 与 publishable 共用）

| 集合 | 定义 | 用途 |
| --- | --- | --- |
| `A_raw` | `nodes.lifecycle='active'` 且 identity 存在 | 仅展示"原始活跃节点数" |
| `A_eff` | `A_raw` 剔除：① 机场 `enabled=0`；② 机场 `suspect`；③ 机场在 `invalid_window`（引擎/调度/DB 异常期）；④ `present_in_latest=0`（轮询 absent） | **覆盖率与可发布数的唯一分母** |
| `P` | `A_eff` 中满足 §3.9 `eligible` 的节点 | `publishable = |P|` |

```
cov(t) = |{ n ∈ A_eff : 目标 t 有当前版本有效结果且 last_pass_at + ttl > now }| / |A_eff|
零健康必要：  |A_eff| > 0  且  ∀t: cov(t) >= 0.90  且  |P| = 0
```

### 8.2 五种"看起来都是 0"的情形（必须区分）

| 情形 | `|A_raw|` | `|A_eff|` | cov | 判定 | 动作 |
| --- | --- | --- | --- | --- | --- |
| 无节点（库空） | 0 | 0 | 未定义 | `no_nodes` | 不判零健康；不发布空订阅；UI 提示"无节点" |
| 全部机场停用 | >0 | 0 | 未定义 | `all_disabled` | 同上；保持 active 版本；不发事件 `empty_confirmed` |
| 全部机场 suspect | >0 | 0 | 未定义 | `all_suspect` | `insufficient_scope`；保持 active；72h 计时**不启动** |
| 真实全挂 | >0 | >0 | ≥90% | `zero_health` | 进入 24h 确认流程 |
| 轮询 absent 导致分母塌缩 | >0 | 0 或极小 | 未定义/样本不足 | `rolling_scope` | 按"可测节点"计算；不判零健康；记 `insufficient_scope` |

**关键规则**：`|A_eff| = 0` 时，**既不启动 24h 计时，也不创建 `empty_confirmed`**。因为"没有可判定对象"与"有对象但全不可用"是两种完全不同的事实，混淆会导致"机场全停用 24 小时后自动发一个空订阅"。

### 8.3 24h / 72h（保留 v0.3，不重开）

| 字段 | 规则 |
| --- | --- |
| `confirmed_at` | 首次满足 §8.1 全部条件的时间，**只写一次**，重复评估不得改写 |
| `deadline` | `confirmed_at + 24h + paused_ms` |
| `hard_deadline` | `confirmed_at + 72h`（不随暂停顺延） |
| 到 `deadline` | 重验条件 → 通过则发 `minimal`；不通过顺延 30 分钟 |
| 到 `hard_deadline` | 转 `manual_review`，停止自动发布，要求人工三选一 |

### 8.4 测试（Z 组，9 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| Z1 | 空节点池 | `no_nodes`；无 24h；不发布 |
| Z2 | 全部机场停用 | `all_disabled`；无 24h；active 不变 |
| Z3 | 全部 suspect | `all_suspect`；无 24h |
| Z4 | 真实全挂（`A_eff>0`，cov≥90%） | 进 24h 流程 |
| Z5 | 真实全挂但 cov=60% | 不判零健康（证据不足），记 `cov_insufficient` |
| Z6 | 重复评估 | `confirmed_at` 不变；`paused_ms` 可增 |
| Z7 | 暂停 8 小时后恢复 | `deadline` 顺延 8h；`hard_deadline` 不变 |
| Z8 | 累计 72h 仍全挂 | `manual_review`；不自动发布 |
| Z9 | 轮询 absent 使分母为 0 | `rolling_scope`；不判零健康 |

---

## 9. R8：P-1 阶段边界与迁移失败记录

### 9.1 P-1 与 P6 的界线（一张表说清）

| 项 | P-1（安全底座） | P6（完整启动自检） |
| --- | --- | --- |
| schema 版本表 | 建 `schema_migrations` | 读并在 UI 展示 |
| 事件表 | 建 `system_events` | 消费/聚合/告警 |
| DB 完整性 | `quick_check` + 表/列存在性 | 全库 `integrity_check` + 跨表一致性巡检 |
| 备份 | 迁移前快照 + 校验和 + 行数 | 定时备份、轮转、异地 |
| 恢复验证 | 快照可打开 + 关键表可读 | 恢复演练、RTO 测量 |
| 失败处理 | 原库不动 + degraded 启动 + 落事件 | 自动回滚、告警、门禁 |
| 业务表 | **不建** | — |
| 身份迁移 | **不做** | — |

### 9.2 DB 三种失败状态（R8 必须区分）

| 状态 | 判定 | 能否写 `schema_migrations` | 记录方式 |
| --- | --- | --- | --- |
| S1 可读可写 | `open()` 成功 + `BEGIN IMMEDIATE` 成功 | **能** | `system_events(kind='migration_failed')` + `schema_migrations(result='failed')` |
| S2 只读/写失败（磁盘满、权限、WAL 锁） | `open()` 成功但写探针失败（`CREATE TEMP TABLE` 或 `BEGIN IMMEDIATE` 失败） | **不能** | 只写文件（§9.3）；不尝试 DB 写，不假装成功 |
| S3 完全不可用（文件损坏/路径不存在/句柄失败） | `open()` 抛出 / `quick_check` 失败 | **不能** | 只写文件；原库保持原样；degraded 启动 |

**明确禁止**：在 S3 状态下声称"已记录 `schema_migrations` 失败行"。v0.3 的"若可写则写失败行"在 S3 下是空操作，却读起来像已记录——这是 R8 指出的措辞性错误。

### 9.3 文件降级日志（路径、格式、恢复方式）

路径：`data/events/migration_failed-<YYYYMMDDTHHMMSS>.json`（一次迁移失败一个文件；同日多文件不覆盖）

```json
{
  "schema": "nodepool.migration_failure/1",
  "ts": "2026-11-26T11:20:31+08:00",
  "step": "M1.add_columns",
  "db_state": "S2",
  "error": {"type": "OperationalError", "msg": "database or disk is full"},
  "db_path": "/data/nodepool.db",
  "backup": {"path": "/data/backups/pre-M1-20261126T111500.db", "sha256": "…", "rows": {"nodes": 137}},
  "degraded": true,
  "next_action": "restore_backup_and_retry | manual_review"
}
```

- **恢复方式**：S1/S2 → 修因（空间/权限/锁）后按 `schema_migrations` 最后成功版本续跑；S3 → 用 `backup.path` 覆盖原库后重跑；无法恢复 → 保留文件与备份，人工介入。
- **轮转**：按天保留 90 天，或累计 200 个文件后删最老（与 `logs` 同策略）。
- **审计**：`/healthz` 读该目录数量，`degraded` 时返回 `degraded`（分级在 P6 完成）。

### 9.4 P-1 建表范围（与 v0.3 一致，重申）

| 表 | P-1 | 阶段 |
| --- | --- | --- |
| `schema_migrations` | 是 | P-1 |
| `system_events` | 是（**唯一**事件表） | P-1 |
| `node_identities` / `node_config_versions` / `airport_fetch_versions` | 否 | P0 |
| `node_target_state` / `node_state_history` / `detection_rules` | 否 | P1 |
| `task_jobs` | 否 | P2 |
| `publish_versions` | 否 | P3 |
| `node_exit_observations` | 否 | 按 C7 |

P-1 不做：业务表、业务回填、身份迁移、完整自检。

---

## 10. 迁移与兼容

### 10.1 v0.3 → v0.4 对库的增量影响（仅设计，不执行）

| 变更 | 表 | 性质 | 风险 |
| --- | --- | --- | --- |
| 删 `source_node_id` / `stable_id_seen_count` / `base_fingerprint` / `occurrence_key` | `node_identities` | 结构性 | 需重建表 |
| 新表 `identity_stable_ids` | 新 | 结构性 | 回填已有 stable_id |
| 删 `UNIQUE(airport_id, fingerprint)`，加 `UNIQUE(identity_id)` + 两个复合外键 | `nodes` | 重建表 | 迁移必须一次成功，否则唯一约束仍拦 |
| 加 `occurrence_seq` 唯一 + `UNIQUE(id, airport_id)` | `node_identities` | 结构性 | — |
| 加 `identity_id` / `episode_started_at` / `ever_valid_fail` / `state_since` | `nodes` | 加法 | — |
| 加 `identity_id` + 复合外键 | `node_target_state` | 结构性 | — |
| 加 `state` / `commit_token` / `checksums_sha` / `manifest_gz` / `activated_at` / `superseded_at` | `publish_versions` | 加法 | 需修正历史多 active |
| 加 `origin_node_id`（无外键）/ `origin_fingerprint` / `origin_state` / `mapping_*` | `airport_filtered_nodes` | 加法 | — |

### 10.2 迁移顺序（P0）

```
1 备份（含 sha256 + 行数）
2 quick_check
3 建 identity_stable_ids + 回填（按 airport + 现有 source_node_id）
4 重建 nodes（copy → 校验行数 → rename；同时补 identity_id）
5 建索引与触发器（TR1–TR5）
6 负向测试（FT1–FT11）在临时库跑一遍，任一失败即中止
7 写 schema_migrations(success)
```

### 10.3 兼容承诺

- 全部语义收紧 + 加法；旧代码读新库时不写新列，`episode_started_at` 等为 NULL 不影响旧逻辑；
- P-1/P0/P1 允许"只回代码、不回库"；
- 四种格式、四个 URL、UA 自适应、Token 鉴权、两种 `sub_publish`、测速与评分算法**均未改动**；
- 前端只增加展示字段，不改布局。

---

## 11. 测试矩阵（合并，按阶段）

| 组 | 场景数 | 编号 | 阶段 |
| --- | --- | --- | --- |
| 身份 | 16 | I1–I12 + I7a/I8a/I8b/I8c/I8d | P0 |
| 状态机 | 22 | S1–S22 | P1 |
| 数据库约束 | 11 | FT1–FT11 | P0/P1 |
| 过滤节点 | 8 | F1–F8 | P0 |
| 发布/崩溃 | 12 | P1–P12 | P3 |
| 轮询 | 6 | RP1–RP6 | P0 |
| 零健康 | 9 | Z1–Z9 | P2/P3 |
| 小样本骤减 | 5 | v0.2 原表 | P0 |
| 迁移/回退 | 6 | 中断、三态失败、代码回退、恢复、WAL | P-1/P5 |

新增必测（本轮明确点名）：I8a–I8d、S2/S9/S11/S12/S15/S18、FT1–FT11、P4–P7、RP1–RP6、Z1–Z9。

---

# B. v0.3 → v0.4 修订对照表

| # | v0.3 问题 | v0.4 修订 | 章节 | 是否完全解决 |
| --- | --- | --- | --- | --- |
| R1 | `source_node_id` 唯一索引阻止接管；指纹组唯一键在轮换时撞键 | stable_id 拆为 claim 表（live 部分唯一 + 历史无限）；身份表去指纹组键，改由版本表派生 | §2 | 是 |
| R2 | unknown/observe 优先级冲突；recovering 对 NULL 运算；unstable 一跳 healthy | 新优先级链（失败证据优先）；`episode_started_at` 兜底 base；unstable 也走 recovering | §3 | 是 |
| R3 | 关联靠触发器与代码约定 | 复合外键 + DEFERRED 打破循环 + 5 个触发器补规则；11 个负向测试 | §4 | 是 |
| R4 | `origin_node_id` 外键与"父行已删"矛盾 | 去掉外键（id 永不复用）+ `origin_state` 状态机 + 三条防串号 | §5 | 是 |
| R5 | 目录完整即视为已发布 | `commit_token` + pending 意图 + R1–R4 优先级 + 10 行崩溃矩阵 + fail-closed | §6 | 是 |
| R6 | `Jaccard(S,U7)` 分母错误 | cover/fresh/simU/growth/swing/overlap 六指标 + 数值验证（0.525 误判复现） | §7 | 是 |
| R7 | cov 与 publishable 集合不一 | `A_raw`/`A_eff`/`P` 单一口径；五种"都是 0"分表 | §8 | 是 |
| R8 | S3 下仍声称可写 `schema_migrations` | 三态判定 + 文件日志格式/路径/恢复 + P-1 vs P6 对照 | §9 | 是 |

---

# C. 待确认事项

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C1 | stable_id + 指纹变 + 端点变是否自动升版本 | 不自动（情形 H） | 沿用 |
| C2 | 过滤节点是否并入 `nodes` | 方案 A；B 兜底已完整 | 沿用 |
| C3 | 遗留 `tasks` 表何时清理 | 保留一个 release | 沿用 |
| C4 | 时间本地 vs UTC | 本地 + `db.now()` | 沿用 |
| C5 | 业务目标是否写 `node_target_state` | 写，仅展示 | 沿用 |
| C6 | 零健康暂停是否计入 24h | 顺延 + 72h 硬上限 | 沿用 |
| C7 | 出口观测是否启用 | 默认关闭 | 沿用 |
| C8 | 指针 vs DB 权威 | 指针（v0.4 §6.3 已给完整裁决） | 沿用 |
| C9 | `rolling_pool` absent 阈值 | 3 次 **且** 7 天（§7.6） | 沿用 |
| C10 | 72h 到点默认动作 | 转人工，不自动发布 | 沿用 |
| **C11** | `occurrence_seq` 是否需要按机场永久单调（跨 30 天 missing 也不回收） | 是（避免槽位语义漂移） | 新增 |
| **C12** | `nodes` 表重建（去 `UNIQUE(airport_id,fingerprint)`）是否允许在 P0 一次完成 | 是；若不允许，需先加"影子唯一键"过渡 | 新增 |

**仍需实机验证**（不假设）：机场 stable_id 真实覆盖率；生产库重复配置比例；NAS 目录 `rename` 原子性；`cdn-cgi/trace` 可用性；`publish_versions.manifest_gz` 的体积对备份时长的影响。

---

# D. 风险与兼容

| # | 风险 | 触发 | 缓解 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | claim 表回填错误导致身份错配 | 旧库 stable_id 重复 | 回填时同 id 多身份 → 全部标 `ambiguous`，不自动绑定 | FT-S1/S2 |
| 2 | `nodes` 重建失败 | 迁移中断 | copy → 校验 → rename；失败保留原表 | 迁移组 |
| 3 | 复合外键在旧数据上校验失败 | 历史脏数据（identity_id NULL） | 回填后再建约束；FT 在临时库先跑 | FT1–FT11 |
| 4 | DEFERRED 外键被误认为"无需理会" | 事务未提交即返回成功 | 写入函数必须 `with tx()`；提交后校验 | 写入用例 |
| 5 | recovering 过久影响可用性 | unstable 也走恢复 | 恢复只需 2 次成功（30 分钟节奏下约 30–60 分钟） | S13/S14 |
| 6 | 误发未提交版本 | active.json 丢失 + 高编号目录 | `commit_token` 证明 + fail-closed | P4/P7 |
| 7 | 轮询机场误删节点 | absent 计数抖动 | 双条件 AND + 并集基线 | RP5/RP6 |
| 8 | 零健康与"全停用"混淆 | 分母为 0 | `A_eff` 单一口径 + 五情形分表 | Z1–Z3 |
| 9 | 过滤 id 恢复串号 | 孤儿结果行 | 身份断言 + 查询层 JOIN 过滤 | F5/F6 |
| 10 | 文件日志丢失 | 磁盘满 | 与 `logs` 同轮转；`/healthz` 可见 | Z/迁移组 |
| 11 | 触发器顺序导致自锁 | TR1/TR2 互相触发 | 先更身份再投影；`recursive_triggers=OFF` | FT3/FT4 |
| 12 | 多 active 行 | 历史脏数据 | `uq_publish_active` + 迁移修正 | P10 |

**兼容承诺**：v0.4 不改变任何已确认决策与算法；所有改动都是"把不可证明的东西变成可证明的"，或"把代码约定变成数据库约束"。

---

**v0.4 到此结束。** 未改代码、未改数据库、未建迁移文件、未执行 P-1、未改配置。请交回第四轮设计审查；在获得明确批准前，不提交实施计划、不进入任何阶段。
