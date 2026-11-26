# NodePoolME 新架构总体设计方案 v0.3

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v0.2
**本轮性质**：纯设计修订。未改代码、未改数据库、未建迁移文件、未执行 P-1、未改配置。
**修订依据**：v0.2 第二轮审查的九项意见（R1–R9）+ 既定设计保留清单
**文档状态**：**待第三轮设计审查**（未自行认定通过）

---

## 修订索引

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| R1 | stable_id 跨指纹匹配与复用/冲突流程 | §4.3–4.6 | 重写 |
| R2 | 槽位锚定的能力边界 | §4.7–4.9 | 重写 |
| R3 | 目标层 / 节点层两层健康模型 | §6 全节、§10.1 | **重构（最高优先级）** |
| R4 | 唯一权威、触发器、事务边界 | §11.2–11.4 | 重写 |
| R5 | 过滤节点 B 方案完整化 | §11.7、§12.6 | 新增 |
| R6 | P-1 最小底座统一 | §11.3、§12.2、§13.2、§17 | 统一 |
| R7 | 指针权威、校验清单、持久化步骤 | §10.2–10.4 | 重写 |
| R8 | 零健康确认边界与 72h 硬上限 | §7.5、§10.6 | 重写 |
| R9 | 轮询机场与身份歧义边界 | §9.6、§4.9、§14 | 新增 |

未修订章节（与 v0.2 一致）：§2、§3、§8、§15 框架、§16 既有矩阵、§17 的 P4–P6 部分。

---

## 0. 一句话结论

v0.2 的三处结构性问题是同一类错误：**把"一个事实"存成了"两个权威"**。
- 健康：目标级事实被压成节点级计数，导致重复计罚、单目标洗白；
- 配置：身份、节点行、版本表三处各存一份当前版本；
- 发布：文件与数据库两份"当前版本"。

v0.3 统一为：**事实只有一份，其余都是投影；投影只允许由一个函数/触发器写。**

---

## 1. 新旧架构对照（沿用 v0.2，修订 4 行）

| 维度 | v1.8.7 | v0.3 目标 | 相对 v0.2 |
| --- | --- | --- | --- |
| 身份匹配 | 指纹即身份 | stable_id 跨指纹查身份 → 证据分级 → 槽位兜底 | R1：候选范围不再被指纹限制 |
| 健康模型 | 单计数 + 三态 | 目标层事实 + 节点层投影 | R3：两层，`max/min` 聚合 |
| 发布权威 | 逐文件替换 | `active.json` 单指针，DB 为镜像 | R7：明确冲突裁决与校验清单 |
| P-1 | 线性 ALTER | 只建 2 张基础设施表 + copy-migrate-swap | R6：统一口径 |

---

## 2. 模块划分（沿用 v0.2，新增 1 处）

在 v0.2 基础上新增 `health/aggregate.py`：

```
health/
  target_state.py   # 目标层事实写入与 TTL
  aggregate.py      # 目标层 → 节点层投影（唯一写 nodes.state 的地方）
  state_machine.py  # 状态迁移语义与审计（调用 aggregate）
  validity.py       # 有效结果定义与归因
```

依赖规则不变。`nodes.state` 只允许 `health.aggregate.recompute(node)` 写入。

---

## 3. 模块职责（增量）

| 模块 | 职责 | 明确不做 |
| --- | --- | --- |
| `health.target_state` | 写 `(node,target)` 的 pass/fail、last_pass_at、连续计数、TTL | 不写节点状态 |
| `health.aggregate` | 用全部必需目标计算节点状态、`fail_streak`、`success_streak` | 不探测、不改目标事实 |
| `publish.pointer` | 指针解析、校验清单、启动裁决 | 不生成内容 |

---

## 4. 节点身份与配置版本【修订 R1 / R2】

### 4.1 三个概念（不变）

identity / config_version / node 行，`nodes.id` 仍是运行期句柄。

### 4.2 fingerprint 定位（不变）

只表示"配置内容"，是分组键与变化比较依据，**不证明物理身份**；算法不改（Q3）。

### 4.3 身份匹配：候选范围修正【修订 R1】

**核心修正**：`stable_id` 查询**以机场为范围，不受 `base_fingerprint` 限制**。

```
候选集 = { identity | identity.airport_id = 本次机场 且 identity.source_node_id = node.stable_id }
```

原因：若先按指纹分组，当机场"换配置但保留 id"时，新指纹会把节点分到空组，stable_id 永远匹配不上，必然误建新身份。

匹配优先级（严格顺序，命中即停）：

| 级 | 规则 | 候选范围 | 强度 | 允许改名 |
| --- | --- | --- | --- | --- |
| P0 | `stable_id` 精确匹配 | **全机场** | 强 | 是 |
| P1 | 单候选延续（组内 1 身份 + 本次 1 节点） | 同 `base_fingerprint` | 强（结构性） | 是 |
| P2 | 完整归一化名精确相等（一一映射） | 同 `base_fingerprint` | 辅助 | 否 |
| P3 | 编号配对（两侧唯一且数量相等） | 同 `base_fingerprint` | 弱（标记） | 是（编号不变） |
| P4 | 持久槽位锚定（`occurrence_seq` 升序） | 同 `base_fingerprint` | 最弱（标歧义） | 是 |
| P5 | 新建身份（`occurrence_seq=max+1`） | — | — | — |

归一化规则不变：只剥装饰（空白/全半角/emoji/国旗/限速前缀/机场后缀/大小写），**保留编号与主体**；禁止去编号哈希、禁止相似度匹配。

### 4.4 stable_id 的四种结局（完整流程）【修订 R1】

设：`S` = 匹配到的身份（0/1/多），`F_new` = 本次指纹，`F_old` = `S.current_config_version` 的指纹，`E_new/E_old` = server:port。

| 情形 | 条件 | 判定 | 动作 | 事件 |
| --- | --- | --- | --- | --- |
| A 同配置 | `S` 唯一，`F_new == F_old` | 同身份同版本 | 绑定；只更新 name/last_seen | `rename`（若名变） |
| B 参数轮换 | `S` 唯一，`F_new != F_old`，`E_new == E_old`，且 `S.stable_id_seen_count >= 2` | 同身份新配置 | 新 config_version，旧版本 `closed_at` | `config_rotated` |
| C 端点迁移 | `S` 唯一，`F_new != F_old`，`E_new != E_old` | **不改 config_version**；判为疑似复用/迁移 | 新身份；旧身份 `missing`；`related_identity_id=S` | `stable_id_reuse_suspected`（若名也完全不同）/`probable_migration` |
| D 冲突 | `S` 为空，但同机场存在同 `F_new` 的其他身份；**或** `S` 多个 | 同配置多实例（正常） / 脏数据（多个同 id） | 正常：新建独立身份，不把旧身份置 missing；脏数据：拒绝绑定，标 `identity_ambiguous` | `stable_id_conflict`（仅脏数据） |
| E 复用确认 | 情形 C 之后，下一次拉取出现 `E_old` 节点且 stable_id 仍指向新身份 | 机场把旧 id 彻底改嫁 | 旧身份保持 missing；若 `E_old` 重新出现且无 id，按 P1/P2 归位 | `stable_id_reused_confirmed` |

**为什么情形 C 不升版本**：stable_id 可能被机场复用；端点整体变化时，"同 id"不足以证明"同一台机器换了地址"。把历史挂过去风险高于收益。若未来要支持，需要独立的"连续性判定"，见待确认 C1。

**`stable_id_seen_count` 的维护**：只在 `applied=1` 的拉取中，该 `stable_id` 仍指向同一身份时 +1；冲突或缺失时归零。它只用于 B 情形的证据门槛（≥2），不参与 D。

**同一机场两个相同指纹、不同 stable_id**：两条 P0 各命中各自身份，均绑定、均 active、均参与检测与发布；**不得**把任一置 missing（这是 v0.2 的错误，本轮修正）。

### 4.5 匹配伪代码【修订 R1】

```
def resolve(airport, node, ctx):
    # P0：全机场范围
    if node.stable_id:
        cands = ctx.identities(airport).where(source_node_id == node.stable_id
                                              and lifecycle != 'retired')
        if len(cands) == 1:
            s = cands[0]
            if node.fp == s.current_fp:
                return bind(s, node, reason="stable_same")
            if node.server_port == s.current_endpoint and s.stable_id_seen_count >= 2:
                return bump_version(s, node, reason="stable_rotated")
            return new_identity(node, related=s, reason="stable_endpoint_change")
        if len(cands) > 1:
            return ambiguous(node, reason="duplicate_stable_id")

    # P1：单候选延续（同指纹组）
    group = ctx.free_identities(airport, node.base_fp)
    free_nodes = ctx.free_nodes(node.base_fp)
    if len(group) == 1 and len(free_nodes) == 1:
        return bind(group[0], node, reason="single_candidate")

    # P2：完整名精确（一一映射）
    ...  # 仅 unbound × unbound，且名字唯一

    # P3：编号配对（弱）
    ...  # 标记 weak_binding

    # P4：槽位锚定
    ...  # 标记 identity_ambiguous

    # P5：新建
    return new_identity(node, occurrence_seq=max+1)
```

收尾：本次未绑定身份 → `missing`；`missing` 身份命中则恢复 active、状态回 `unknown`。

### 4.6 旧配置结果隔离（不变）

`validity` 要求 `result.config_version == node.config_version`；B 情形旧版本 `closed_at` 后不再产生新结果；D 情形新身份是新的 `node_id`，旧结果不可能命中。

### 4.7 槽位锚定：能力边界【修订 R2】

必须写死三句话：

1. **槽位稳定 ≠ 物理身份稳定**。`occurrence_seq` 只保证"系统内部不来回改绑"。
2. 多个同配置节点**同时改名**且无 stable_id 时，**不声称**能恢复物理身份；只保证槽位连续、历史不串。
3. 任何基于排序的分配都不作为身份证据，必须标 `identity_ambiguous=1` 并记录事件。

### 4.8 可延续 vs 必须标歧义【修订 R2】

| 情形 | 可延续原槽位？ | 标记 |
| --- | --- | --- |
| 组内 1 身份 1 节点，改名 | 是（P1） | 无 |
| 多节点，仅名称不变者 | 是（P2 精确名） | 无 |
| 多节点，1 个改名、其余不变 | 是（P2 绑其余，P3/P4 给改名者） | 改名者 `weak_binding` |
| 多节点，全部改名，数量不变 | 是（P4 槽位） | 全部 `identity_ambiguous` |
| 多节点，数量变化且无强键 | 是（槽位补齐/截断） | 全部 `identity_ambiguous` |
| 名称集合互换（A 拿到 B 旧名） | **不交换绑定**，按既有锚定 | `name_swap_suspected`，不合并历史 |
| 无任何未绑定身份，新增节点 | 否（P5 新建） | 无 |

**禁止**：因"本次排序结果"把某身份的历史转给另一身份。持久化绑定优先于任何推断。

### 4.9 身份歧义节点的参与边界【修订 R9】

| 维度 | 是否参与 | 说明 |
| --- | --- | --- |
| 基础检测 | 是 | 每槽位独立检测，互不影响 |
| 业务检测 | 是 | 同上 |
| 评分 | 是，但打标 | 按 identity 槽位聚合，不跨槽合并；排名展示标注"身份存疑" |
| 发布 | 是（满足资格即可） | 歧义不阻断发布，但订阅名不加任何"存疑"字样 |
| 历史统计 | 是 | 只在本槽位内累计；导出时带 `ambiguous=1` |
| 轮换判定 | **否** | 歧义节点不得作为"列表轮换/出口轮换"的唯一证据 |

### 4.10 身份测试（12 个）【修订 R1/R2】

| # | 场景 | 断言（加严） |
| --- | --- | --- |
| I1 | 单节点改名 | 同 identity/同版本；`rename` 事件；旧名不再作为 key |
| I2 | 两重复节点换序、名称不变 | 两绑定不变；无歧义；两次拉取 id 集合完全一致 |
| I3 | 两重复节点换序 + 1 个改名 | 未改名者绑定不变、其 `state/fail_streak` 不被触碰；改名者只落到剩余槽位；`weak_binding=1`；**不得**出现两名字对调 |
| I4 | 两重复节点全部改名 | 两节点 `identity_ambiguous=1`；槽位 seq 不变；第二次拉取（同样新名）不重排；每槽历史连续 |
| I5 | stable_id + 改名 + 同端点 + 指纹变 | 同 identity；`config_version+1`；旧版本 closed；旧结果不参与新判定 |
| I6 | stable_id + 指纹变 + 端点变 | **不升版本**；新 identity；旧 missing；`probable_migration` |
| I7 | 同机场两个同指纹、不同 stable_id | 两 identity 同时存在且均 active；无 missing；各自检测 |
| I8 | stable_id 被复用（旧 id 给不同端点节点） | 新身份 + 旧 missing + `stable_id_reuse_suspected`；下轮确认 `stable_id_reused_confirmed` |
| I9 | 消失 20 天后同配置返回 | 恢复原 identity/版本；状态 unknown；不继承 Healthy |
| I10 | 消失 20 天后不同配置返回 | 旧仍 missing；新 identity v1；`related_identity_id` 仅关联 |
| I11 | 重复组新增 1 个 | 新 seq；既有槽位不重排 |
| I12 | 过滤节点准入回池（B 方案） | 恢复原 `nodes.id` 与 identity；不新建、不串历史 |

---

## 5. 生命周期（沿用 v0.2，补 2 条）

1. `missing` 只由 `applied=1` 的拉取触发；suspect/失败不触发。
2. `retired` 只改 lifecycle，不删 `nodes` 行。
3. **`missing` 是身份级状态**，与"本次响应中没有"不同：轮询机场的"本次未返回"先记 `absent`，不立即 missing（§9.6）。
4. 机场 `enabled=0` 不改 lifecycle，只冻结检测与发布。

---

## 6. 健康状态：目标层与节点层【修订 R3，最高优先级】

### 6.1 两层模型与唯一事实

```
目标层（事实，每个必需目标一行）
  node_target_state(node_id, target, config_version)
    last_result        pass | fail | unknown
    last_pass_at       最近一次有效通过时间
    last_fail_at       最近一次有效失败时间
    fail_streak        该目标连续有效失败
    success_streak     该目标连续有效成功
    recovery_started_at 该目标"不可用后首次通过"的时间
    failure_source / rule_version / ttl_minutes

节点层（投影，nodes.state + 两个聚合计数）
  fail_streak    = max(各必需目标 fail_streak)
  success_streak = min(各必需目标 success_streak)
  state          = aggregate(targets, prev_state)
```

四条聚合不变量（直接对应用户指出的矛盾）：

| 矛盾 | 解决 |
| --- | --- |
| 一个目标成功清除另一个目标的失败 | 节点 `fail_streak = max(...)`；另一目标未清零则 max 不减 |
| G、W 独立失败重复加节点计数 | 节点计数是**派生**的 max，不是递增累加；同周期两目标各失败 1 次 → 节点仍为 1，不是 2 |
| unknown 仅一个目标成功就 healthy | `healthy` 要求**全部必需目标**都有当前版本的有效结果且为 pass |
| recovering 未要求全部目标 | `recovering` 要求全部目标 `success_streak>=1`；`healthy` 要求全部 `>=2` 且各自间隔 ≥30 分钟 |

### 6.2 目标层状态判定

| 目标状态 | 条件 |
| --- | --- |
| `unknown` | 无当前 `config_version` 的有效结果 |
| `pass` | 最近一次有效结果通过 |
| `fail` | 最近一次有效结果失败 |
| `stale` | `last_pass_at + ttl <= now`（与 pass/fail 并存，不覆盖 last_result） |
| 合格（供发布用） | `last_pass_at + ttl > now` 且 `config_version`、`rule_version` 匹配 且 `fail_streak < T-1` |

> 关键：发布看的是**最近一次成功是否还在有效期内**，不是"最近一次结果必须是 pass"。这解决了"observe 可发但 §10.1 要求 pass"的矛盾。

### 6.3 节点层状态定义（派生）

| 状态 | 判定（按顺序，先命中先返回） | 可发 |
| --- | --- | --- |
| `unknown` | 任一必需目标 `unknown`（无当前版本有效结果） | 否 |
| `unavailable` | `max(fail_streak) >= T` | 否 |
| `unstable` | `max(fail_streak) == T-1` | 否 |
| `observe` | `max(fail_streak) >= 1`（且未达上一档） | 是（逐目标合格时） |
| `recovering` | `max(fail_streak)==0` 且 `min(success_streak)>=1` 且（`min(success_streak)<2` 或 间隔<30min）且 `prev_state ∈ {unavailable, recovering}` | 否 |
| `healthy` | `max(fail_streak)==0` 且 全部目标 `success_streak>=2`（首次进入时为全部 pass） 且 每目标两次成功间隔 ≥30 分钟 | 是 |

补充：
- 首次通过（unknown → healthy）：不要求 2 次，因为从未有过失败，不属于"恢复"（Q11 只约束从 unavailable 恢复）。
- `observe` 允许发布的前提是**每个必需目标**都还有有效期内的成功记录（§6.2 合格）。
- `unstable` 不可发布：连续 2 次失败先停发，符合"一次失败不摘、两次停发、三次不可用"。
- `T=2` 时无 observe；`T=1` 时首次失败即 unavailable。

### 6.4 状态迁移表（按事件重算，不再维护独立计数器）

| # | 前态 | 事件 | 目标层变化 | 新节点态 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 1 | unknown | G pass，W unknown | G: pass | unknown | 不因单目标成功变 healthy |
| 2 | unknown | G、W 均首次 pass | 两目标 pass | healthy | 首次通过 |
| 3 | unknown | 任一 fail | 该目标 fail=1 | observe | 不直接 unavailable |
| 4 | healthy | G fail，W pass | G fail=1 | observe | 另一目标成功不清零 |
| 5 | healthy | G、W 均 fail | 两目标各 1 | observe（节点=1） | **不重复计为 2** |
| 6 | observe | 同一目标再 fail | 该目标 2 | unstable | 停发 |
| 7 | observe | 另一目标 fail（原先 0） | max=1 | observe | 仍不停发 |
| 8 | unstable | 任一目标再 fail 至 3 | max=3 | unavailable | 停发 |
| 9 | unstable | 失败目标 pass | 该目标 0 | healthy 或 observe | 视其他目标 |
| 10 | unavailable | 全部目标首次 pass（同一轮） | 各 success=1 | recovering | 需确认 |
| 11 | unavailable | 仅 G pass，W 仍 fail | G success=1，W fail≥3 | unavailable | **不得**进入 recovering |
| 12 | recovering | 下一轮全部 pass，间隔 ≥30min | 各 success=2 | healthy | 恢复完成 |
| 13 | recovering | 下一轮全部 pass，间隔 <30min | 各 success≥2 但间隔不足 | recovering | 不推进 |
| 14 | recovering | 任一目标 fail | 该目标 fail=1 | unavailable | 恢复作废 |
| 15 | 任意 | 引擎/系统/目标事故 | 无（valid=0） | 不变 | 只记事件 |
| 16 | 任意 | 目标 TTL 到期 | 无 | 不变 + stale | 停发 |
| 17 | 任意 | 新 config_version | 目标行重建 | unknown | 旧结果隔离 |
| 18 | 任意 | lifecycle=missing/absent | 冻结 | 不变 | 不发 |

### 6.5 聚合与迁移伪代码【修订 R3】

```python
def recompute(node, prev_state):
    ts = target_states(node)                     # 必需目标 G、W
    if any(t.state == "unknown" for t in ts):
        return "unknown"
    max_fail = max(t.fail_streak for t in ts)
    min_ok   = min(t.success_streak for t in ts)

    if max_fail >= T:            return "unavailable"
    if max_fail == T - 1:        return "unstable"
    if max_fail >= 1:            return "observe"

    # max_fail == 0，全部目标当前有效结果为 pass
    if prev_state in ("unavailable", "recovering"):
        gaps_ok = all(t.last_pass_at - t.recovery_started_at >= 30 * 60 for t in ts)
        if min_ok >= 2 and gaps_ok:  return "healthy"
        return "recovering"
    return "healthy"

def apply_result(node, target, outcome):
    if not validity.is_valid(outcome, node):      # §6.7
        validity.record_invalid(outcome); return
    t = target_state.upsert(node, target, outcome)
    if outcome.pass:
        t.success_streak += 1
        t.last_pass_at = now
        if t.fail_streak >= T and t.recovery_started_at is None:
            t.recovery_started_at = now          # 不可用后的第 1 次成功
        t.fail_streak = 0
        t.last_result = "pass"
    else:
        t.fail_streak += 1
        t.success_streak = 0
        t.recovery_started_at = None
        t.last_result = "fail"
        t.last_fail_at = now
    new_state = recompute(node, node.state)
    state_history.write(node, node.state, new_state, reason=outcome.reason)
    node.state = new_state
```

### 6.6 发布资格表达式（与状态机完全一致）【修订 R3】

```
eligible(node) =
      node.lifecycle == 'active'
  AND node.state IN ('healthy','observe')
  AND ∀ t IN required_targets:
        EXISTS ts(node,t) with ts.config_version == node.config_version
                          AND ts.rule_version   == current_rule
                          AND ts.last_pass_at + ttl(t) > now
                          AND ts.fail_streak < T-1
```

三条一致性的自检（评审可逐项对表）：

| 状态 | 表达式是否可能成立 | 原因 |
| --- | --- | --- |
| healthy | 是 | 全部 pass 且新鲜 |
| observe | 是 | 某目标 fail=1，但它的 `last_pass_at` 仍在 TTL 内 |
| unstable | 否 | `fail_streak=T-1` 被 `< T-1` 拦下 |
| unavailable / unknown / recovering | 否 | 状态不在集合内 |
| stale（目标级） | 否 | 该目标 `last_pass_at` 过期 |

> 若某目标 `fail_streak=1` 且 `last_pass_at` 已过期 → 状态仍是 observe，但表达式为假 → 不下发。状态与资格不再互相矛盾，因为资格额外要求"成功证据新鲜"。

### 6.7 有效结果与故障边界（不变，补一条）

- 有效：mihomo 真实经代理 + 当前 config_version + 当前 rule_version + 完成复核 + 非 engine/scheduler/system + 不在目标事故窗口。
- TCP-only：`valid=0`，不写目标层，不参与任何聚合。
- 目标事故：该目标本批结果 `valid=0`，`node_target_state` **不更新**（不是写 fail=0），冷却后探针复检。
- 新增：同一轮检测中，G、W 结果分别入库，**不得**在同一事件里合并成"节点失败一次"；节点计数纯派生。

### 6.8 状态机测试（14 个）

| # | 场景 | 断言 |
| --- | --- | --- |
| S1 | unknown + G pass + W unknown | 仍 unknown，不可发 |
| S2 | unknown + 双目标首次 pass | healthy，可发 |
| S3 | healthy + G fail | observe，仍可发（W 新鲜） |
| S4 | healthy + G、W 同轮均 fail | 节点 `fail_streak=1`，不是 2 |
| S5 | observe + 同一目标第 2 次 fail | unstable，停发 |
| S6 | observe + 另一目标首次 fail | 仍 observe（max=1） |
| S7 | unstable + 任一目标到 3 | unavailable |
| S8 | unavailable + 仅 G 恢复 | 仍 unavailable，不 recovering |
| S9 | unavailable + 双目标同轮 pass | recovering，停发 |
| S10 | recovering + 双目标 pass 间隔 10min | 仍 recovering |
| S11 | recovering + 双目标 pass 间隔 35min | healthy |
| S12 | recovering + 任一目标 fail | 回 unavailable |
| S13 | observe + G 的 last_pass_at 过期 | 状态 observe，但**不可发** |
| S14 | 引擎异常 3 次 | 状态/计数不变，事件 3 条 |

---

## 7. 调度与覆盖统计【修订 R8 边界】

### 7.1–7.4 不变

每节点 30 分钟 + 抖动、业务 90 分钟独立、测速 17:00–24:00（仅迁移旧默认）、50MB。

### 7.5 覆盖与零健康：分母为 0 的规则【修订 R8】

| 概念 | 定义 |
| --- | --- |
| 活跃节点 `A` | `nodes.lifecycle='active'` 且其 `identity.present_in_latest=1`（轮询机场见 §9.6） |
| 目标覆盖 `cov(t)` | `A` 中"当前 config/rule + valid=1 结果在 60 分钟窗口内"的数量 / `|A|` |
| `|A| = 0` | `cov` 无定义，**不参与零健康判定**；不发布空订阅；不启动 24h |
| 机场异常剔除后分母为 0 | 同上，记 `insufficient_scope`，保持 active 版本 |
| 全部机场停用 | 同 `|A|=0`；UI 显示"全部机场已停用"，不判定零健康 |
| 全部机场 suspect | 同上；事件为 `scope_suspect` |
| 真实节点全部不可用 | `|A|>0`、`cov≥90%`、`publishable=0` → 进入确认流程 |

**零健康确认的完整前置条件**：
1. `|A| > 0`；
2. 每个必需目标 `cov(t) ≥ 90%`；
3. 无 `invalid_window`（引擎/调度/DB 异常）；
4. 无未关闭的机场异常（剔除后仍需满足 1、2）；
5. `publishable = 0`；
6. 连续两次评估（≥10 分钟）均满足。

任一不满足 → 记 `zero_health_deferred` 与原因，不创建 `empty_confirmed` 事件。

---

## 8. 并发、队列、超时、恢复（不变）

配额、幂等键、超时层级、重启恢复步骤沿用 v0.2 §8。补一条：`detect` 任务在恢复时若 `node.lifecycle != active` 或 `config_version` 变化 → 直接丢弃（幂等键已含版本）。

---

## 9. 机场保护与轮换【修订 R9】

### 9.1–9.4 不变

五类分类；主规则（7 天中位数、≥50% **且** ≥10、两次独立确认）；小样本 3 次/人工；0 节点人工。

### 9.5 三种"数量变化"必须分开【修订 R9】

| 概念 | 含义 | 用途 |
| --- | --- | --- |
| 响应子集 | 本次 HTTP 响应返回的节点集合 | 只决定"本次能测什么" |
| 长期身份集合 | 该机场 7 天内出现过的身份并集 | 决定 missing/轮换判定、suspect 基线 |
| 出口观测 | 抽样测到的出口 IP/ASN | 只做 `rotation_hint`，不改身份/健康/版本 |

**禁止**：把"本次响应少了一半"直接解释为"物理节点删除"。这是 v0.2 的隐含错误。

### 9.6 轮询机场（rolling_pool）规则【新增】

判定为 `rolling_pool` 的条件（满足任一，且需连续 3 个 `applied` 版本验证）：
- 连续 3 次响应的身份集合互不包含，但 7 天并集稳定（并集波动 <10%）；
- 单次数量波动 ≥30% 且无稳定 ID 变化。

规则：
1. **absent 计数**：身份在本次响应中缺失 → `absence_count+1`、`last_absent_at=now`，lifecycle **保持 active**，`present_in_latest=0`；
2. `present_in_latest=0` 时：不检测、不发布、不计入 `|A|`（分母按"当前可测节点"算），但保留身份与历史；
3. 转 `missing` 的条件：`absence_count >= 3` **且** 距 `last_present_at >= 7 天`（两个都满足，防抖动）；
4. 重新出现 → `present_in_latest=1`、`absence_count=0`；若配置一致，状态按"结果是否新鲜"决定（不直接 Healthy）；
5. suspect 基线用**长期身份集合**的 7 天中位数，不用单次响应数量；因此"轮询少一半"不会触发 `count_drop`；
6. 一致性的集合比较也按并集口径：`Jaccard(本次, 并集) ≥ 0.9` 才算一致。

### 9.7 轮换判定与歧义【修订 R9】

- `rotation_hint` 只用**非歧义身份**（`ambiguous=0`）计算；歧义节点超 30% 时强制 `unknown`。
- 出口轮换需要 ≥2 次、间隔 ≥12 小时的出口观测样本；样本不足 → `unknown`。
- 轮换事件只记录，不触发节点增删（增删仍由 `applied` 拉取决定）。

---

## 10. 订阅发布：指针权威与恢复【修订 R7 / R8】

### 10.1 资格（见 §6.6，不重复）

### 10.2 权威关系（一句话）

> **`data/sub/active.json` 是运行时唯一权威。`publish_versions` 是目录镜像与审计，不是第二发布源。`data/sub/sub_all.*` 取消作为发布源。**

理由：切换必须是单文件原子操作；DB 事务无法与目录 rename 原子绑定。

### 10.3 版本目录与校验清单【修订 R7】

```
data/sub/
  active.json            # {"version":N,"sha256":"<checksums.txt 的 sha256>","switched_at":...}
  versions/000123/
    clash.yaml
    singbox.json
    base64.txt
    loon.txt
    manifest.json.gz     # 完整节点配置快照（可重建 4 格式）
    meta.json            # 统计/原因/health_version/airport_versions/rule_version/content_hash
    checksums.txt        # 下列 6 项的 sha256（自身不列入）
```

校验范围（发布前全过、读取时逐项）：

| 文件 | 校验 |
| --- | --- |
| clash.yaml | YAML 可解析 + 必要键（proxies/proxy-groups/rules）+ 节点数 = manifest |
| singbox.json | JSON 可解析 + outbounds 数 = manifest |
| base64.txt | 可解码 + 每行可解析为分享链接 + 数 = manifest |
| loon.txt | 行数与代理段完整 + 数 = manifest |
| manifest.json.gz | gzip 可解 + JSON 可解析 + 每节点含 protocol/server/port/params/display_name |
| meta.json | 必填字段齐全 + content_hash 与目录名一致 |
| checksums.txt | 6 项齐全（4 格式 + manifest + meta）且与文件实际哈希一致 |

`active.json.sha256` = `checksums.txt` 的 sha256；用于"指针指向的目录是否被篡改"的快速判定。

### 10.4 发布与持久化步骤【修订 R7】

```
1  content_hash 计算；与 active 相同 → skipped
2  渲染 4 格式到内存；4 个全部 validate（任一失败即中止）
3  写 versions/<v>.tmp/：4 文件 + manifest + meta + checksums
4  fsync 每个文件
5  fsync versions/<v>.tmp 目录
6  rename <v>.tmp → <v>            # 目录级原子（同文件系统）
7  fsync versions/ 父目录
8  写 active.json.tmp → fsync 文件
9  rename active.json.tmp → active.json   # ★唯一提交点
10 fsync data/sub 目录
11 DB：INSERT publish_versions → UPDATE active 标记（可重试）
12 share_history + 清理非 active 旧版本（保留 30）
```

### 10.5 冲突裁决与恢复优先级【修订 R7】

启动或每次读取时：

```
P1 读 active.json → 版本目录存在 & checksums 全过 → 采用；顺手修复 DB（缺则重建，标记 recovered=1）
P2 active.json 损坏/缺失 → 在 versions/ 中找"目录完整 + checksums 全过"的最大版本 → 重建 active.json；记 pointer_repaired
P3 目录都不完整，但 DB 有 active=1 且其 manifest/校验通过 → 用 DB 重建目录（从 manifest 重渲染）与指针；记 pointer_rebuilt_from_db
P4 DB 与目录均不可用 → 503 + system_events(pointer_critical)，拒绝返回"猜测内容"
```

DB 与指针冲突的裁决：**指针优先**；仅当指针指向的版本校验失败时，才允许用 DB 的 active（且必须能通过 manifest 重建校验）。任何"两边都改"的操作必须走 P3，不允许部分合并。

### 10.6 零健康 24 小时与 72 小时硬上限【修订 R8，正式写入】

事件：`system_events(scope='system', kind='empty_confirmed', immutable=1)`

| 字段 | 规则 |
| --- | --- |
| `confirmed_at` | 首次满足 §7.5 全部条件的时间，**只写一次** |
| `state` | `counting` / `paused` / `expired` / `canceled` / `manual_review` |
| `paused_ms` | 累计暂停（引擎/调度/DB/机场异常），只在 paused→counting 时累加 |
| `deadline` | `confirmed_at + 24h + paused_ms` |
| `hard_deadline` | `confirmed_at + 72h`（**不随暂停顺延**） |

规则：
1. 部分恢复（`publishable ≥1`）→ `canceled`，正常发布。
2. 系统/机场异常 → `paused`；恢复后 `counting`，`paused_ms` 累加。
3. 重复评估 **不得** 改 `confirmed_at`；只允许更新 `paused_ms` 与 `last_eval_at`。
4. 到 `deadline`：先重验（§7.5 条件 1–5）→ 通过则发布 `minimal`；不通过顺延 30 分钟（不发布）。
5. 到 `hard_deadline`（72h）仍未解除 → 转 `manual_review`，**停止自动发布**，前端要求人工选择"发布最小订阅 / 继续保留 / 关闭机场"，并记录操作者。不得无限期自动暂停或自动发布。
6. `manual_review` 状态不自动转回；人工处理后写新事件。

---

## 11. 数据库：唯一权威、DDL、关系【修订 R4 / R5 / R6】

### 11.1 权威表（逐项，不留"代码约定"）

| 数据 | 唯一权威 | 投影/镜像 | 维护方式 |
| --- | --- | --- | --- |
| 身份是否存在/生命周期 | `node_identities.lifecycle` | `nodes.lifecycle` | **触发器**同步 |
| 当前配置版本 | `node_config_versions`（行存在性） | `node_identities.current_config_version`、`nodes.config_version` | 单函数按固定顺序写 + **校验触发器**兜底 |
| 目标级检测事实 | `node_target_state` | 无 | 直接写 |
| 节点健康状态 | **派生**（`health.aggregate`） | `nodes.state`、`fail_streak`、`success_streak` | 单函数写 + `state_since` |
| 发布内容 | `active.json` | `publish_versions` | 提交点 + 启动修复 |
| 机场当前版本 | `airport_fetch_versions` 中最大 `applied=1` | `airports.last_version` | 同事务更新 |
| 任务状态 | `task_jobs.state` | 无 | 直接写 |

### 11.2 一致性由触发器保证（不是约定）

```sql
-- 1) nodes.config_version 必须存在于 node_config_versions
CREATE TRIGGER trg_nodes_cfg_ins BEFORE INSERT ON nodes
WHEN NEW.identity_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM node_config_versions v
  WHERE v.identity_id=NEW.identity_id AND v.version=NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes.config_version not in node_config_versions'); END;

CREATE TRIGGER trg_nodes_cfg_upd BEFORE UPDATE OF config_version, identity_id ON nodes
WHEN NEW.identity_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM node_config_versions v
  WHERE v.identity_id=NEW.identity_id AND v.version=NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes.config_version not in node_config_versions'); END;

-- 2) 身份当前版本只能指向已存在版本（写入顺序：版本行 → 节点行 → 身份指针）
CREATE TRIGGER trg_identity_cfg_upd BEFORE UPDATE OF current_config_version ON node_identities
WHEN NOT EXISTS (SELECT 1 FROM node_config_versions v
                 WHERE v.identity_id=NEW.id AND v.version=NEW.current_config_version)
BEGIN SELECT RAISE(ABORT,'identity config version missing'); END;

-- 3) 生命周期：身份 → 节点（单向投影）
CREATE TRIGGER trg_identity_life AFTER UPDATE OF lifecycle ON node_identities
BEGIN
  UPDATE nodes SET lifecycle = NEW.lifecycle,
                  missing_since = CASE WHEN NEW.lifecycle='missing' THEN COALESCE(NEW.missing_since, datetime('now','localtime')) ELSE NULL END
  WHERE identity_id = NEW.id;
END;

-- 4) 目标状态必须属于当前节点的当前版本
CREATE TRIGGER trg_tstate_ver BEFORE INSERT ON node_target_state
WHEN NOT EXISTS (SELECT 1 FROM nodes n
                 WHERE n.id=NEW.node_id AND n.config_version=NEW.config_version)
BEGIN SELECT RAISE(ABORT,'target state config_version mismatch'); END;

-- 5) 状态历史的历史版本必须存在
CREATE TRIGGER trg_state_ver BEFORE INSERT ON node_state_history
WHEN NOT EXISTS (SELECT 1 FROM node_config_versions v
                 WHERE v.identity_id=NEW.identity_id AND v.version=NEW.config_version)
BEGIN SELECT RAISE(ABORT,'state history config_version missing'); END;
```

> 注：触发器里用 `datetime('now','localtime')` 是允许的（显式本地时区），但业务 SQL 仍统一走 `db.now()`。

### 11.3 P-1 的建表范围（统一口径）【修订 R6】

| 表 | P-1 建？ | 理由 |
| --- | --- | --- |
| `schema_migrations` | **是** | schema 版本审计，基础设施 |
| `system_events` | **是**（仅此一张事件表） | 迁移失败/自检需要落事件，属基础设施；业务事件后续复用，不另建 `airport_events` |
| `node_identities` / `node_config_versions` | 否（P0） | 业务表 |
| `node_target_state` / `node_state_history` / `detection_rules` | 否（P1） | 业务表 |
| `airport_fetch_versions` | 否（P0） | 业务表 |
| `publish_versions` | 否（P3） | 业务表 |
| `task_jobs` | 否（P2） | 业务表 |
| `node_exit_observations` | 否（按 C7） | 可选模块 |

**迁移失败的记录路径**（三选一，按可用性降级）：
1. DB 可打开 → `system_events(kind='migration_failed', level='critical')` + `schema_migrations(result='failed')`；
2. DB 不可打开 → 只写 `schema_migrations` 失败行（若可写）；
3. 全不可写 → `data/migration_failed.json`（含时间、步骤、错误、备份路径）+ 进程日志；degraded 启动。

P-1 **不建**任何业务表、不做任何业务回填、不做完整自检。

### 11.4 表结构（修订版）

```sql
-- 身份
CREATE TABLE node_identities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  base_fingerprint TEXT NOT NULL,
  occurrence_key TEXT NOT NULL DEFAULT '',
  occurrence_seq INTEGER NOT NULL DEFAULT 0,
  source_node_id TEXT,
  stable_id_seen_count INTEGER NOT NULL DEFAULT 0,
  current_config_version INTEGER NOT NULL DEFAULT 1,
  lifecycle TEXT NOT NULL DEFAULT 'active'
    CHECK(lifecycle IN ('active','missing','retired')),
  present_in_latest INTEGER NOT NULL DEFAULT 1,
  absence_count INTEGER NOT NULL DEFAULT 0,
  last_present_at TEXT, last_absent_at TEXT,
  first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  missing_since TEXT, retired_at TEXT,
  rotation_hint TEXT NOT NULL DEFAULT 'unknown'
    CHECK(rotation_hint IN ('unknown','list','exit','mixed')),
  related_identity_id INTEGER REFERENCES node_identities(id),
  ambiguous INTEGER NOT NULL DEFAULT 0, note TEXT
);
CREATE UNIQUE INDEX uq_identity ON node_identities(airport_id, base_fingerprint, occurrence_key);
CREATE UNIQUE INDEX uq_identity_stable ON node_identities(airport_id, source_node_id)
  WHERE source_node_id IS NOT NULL;
CREATE INDEX idx_identity_life ON node_identities(airport_id, lifecycle, present_in_latest);

-- 配置版本
CREATE TABLE node_config_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_id INTEGER NOT NULL REFERENCES node_identities(id),
  version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL, params_hash TEXT NOT NULL,
  params TEXT NOT NULL, protocol TEXT NOT NULL, server TEXT NOT NULL, port INTEGER NOT NULL,
  sample_raw_name TEXT,
  change_reason TEXT NOT NULL CHECK(change_reason IN
    ('initial','config_rotated','readopt')),
  first_seen_at TEXT NOT NULL, last_seen_at TEXT, closed_at TEXT,
  UNIQUE(identity_id, version)
);

-- 目标层事实
CREATE TABLE node_target_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  target TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  rule_version INTEGER NOT NULL,
  last_result TEXT NOT NULL DEFAULT 'unknown'
    CHECK(last_result IN ('pass','fail','unknown')),
  last_pass_at TEXT, last_fail_at TEXT, recovery_started_at TEXT,
  fail_streak INTEGER NOT NULL DEFAULT 0,
  success_streak INTEGER NOT NULL DEFAULT 0,
  failure_source TEXT, ttl_minutes INTEGER,
  updated_at TEXT NOT NULL,
  UNIQUE(node_id, target, config_version)
);
CREATE INDEX idx_tstate_fresh ON node_target_state(target, last_pass_at);

-- 状态历史（复合外键）
CREATE TABLE node_state_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  identity_id INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  from_state TEXT NOT NULL, to_state TEXT NOT NULL,
  lifecycle TEXT NOT NULL, reason_code TEXT NOT NULL, detail TEXT,
  rule_version INTEGER NOT NULL, ts TEXT NOT NULL,
  FOREIGN KEY(identity_id, config_version)
    REFERENCES node_config_versions(identity_id, version)
);
```

> `node_state_history` 的复合外键依赖 `node_config_versions(identity_id, version)` 的唯一约束（DDL 中已建）。SQLite 需 `PRAGMA foreign_keys=ON` 才生效，连接初始化里强制打开。

其余表（`airport_fetch_versions`、`publish_versions`、`detection_rules`、`task_jobs`、`system_events`、`schema_migrations`）沿用 v0.2 DDL，改动两处：

1. `system_events` 增加 `immutable INTEGER DEFAULT 0`、`scope` 增加 `target`/`node`（v0.2 已有），并作为唯一事件表；
2. `airport_fetch_versions` 增加 `suspect_mode`、`consistency_count`、`identity_union_hash`（轮询并集口径）。

### 11.5 删除策略

- **禁止**删除 `nodes`、`node_identities`、`node_config_versions`、`node_state_history`、`node_target_state`（只改 lifecycle / 归档）。
- `airport` 删除：只置 `airport_removed=1` + 身份 `retired`，保留全部历史。
- 历史清理只清 `results/latency_results/speed_*` 的过期行，且不触碰 `node_id` 仍存在或近 7 天的数据。
- 版本目录清理只删非 active 且超出 30 个的版本。

### 11.6 时间策略（沿用 v0.2 结论）

本地时间（UTC+8）+ 统一 `db.now()`；禁止 `datetime('now')`（触发器内显式 `localtime` 例外）。

### 11.7 过滤节点 B 方案（C2 未定前的 P0 兜底）【修订 R5】

**结构**：`airport_filtered_nodes` 增加
```sql
ALTER TABLE airport_filtered_nodes ADD COLUMN origin_node_id INTEGER REFERENCES nodes(id);
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_status TEXT NOT NULL DEFAULT 'unmapped'
  CHECK(mapping_status IN ('mapped','ambiguous','unmapped'));
ALTER TABLE airport_filtered_nodes ADD COLUMN mapping_note TEXT;
```

**回填算法**（迁移时执行，只读旧表）：

```
for each filtered row f:
    cands = nodes where airport_id=f.airport_id and fingerprint=f.fingerprint
    if len(cands) == 1:
        f.origin_node_id = cands[0].id; f.mapping_status='mapped'
    elif len(cands) > 1:
        # 重复配置：不猜
        f.mapping_status='ambiguous'; f.mapping_note='multiple candidates: ids=...'
    else:
        # 已被旧逻辑删除，无法找回
        f.mapping_status='unmapped'
```

**准入回池**（新增/恢复）：

1. `mapping_status='mapped'` 且 `origin` 行仍存在、`fingerprint/params` 一致 → 直接 `UPDATE` 原行（`filtered=0` 或移动语义按 C2 结果），**id 不变**；
2. `origin` 不存在但 `origin_node_id` 未被占用 → `INSERT` 显式指定 `id = origin_node_id`（SQLite 允许），恢复原 id；
3. `ambiguous/unmapped` → **新建 id**，`identity_ambiguous=1`，事件 `filtered_identity_unmapped`；**不复制**任何旧历史；
4. 准入前校验 `origin.identity_id` 与 `f` 的关系：若 f 无身份或身份不匹配 → 不继承，按新节点处理。

**防止历史串号**：任何恢复 id 的操作前，断言 `nodes.id` 不存在或属于同一 fingerprint；插入时显式 id 冲突 → 放弃并新建，记事件。

**迁移前后对照表**（示例结构，P0 输出真实清单）：

| filtered.id | fingerprint | 候选 nodes | origin_node_id | status | 处理 |
| --- | --- | --- | --- | --- | --- |
| 11 | fpA | 1 个（id=7） | 7 | mapped | 准入恢复 id=7 |
| 12 | fpB | 2 个（id=8,9） | NULL | ambiguous | 新建 id + 标记 |
| 13 | fpC | 0 个 | NULL | unmapped | 新建 id |

**测试**：映射唯一、映射多候选、原行已删、准入后 id 相同、history 不串、显式 id 冲突。

---

## 12. 迁移与兼容【修订 R4/R5/R6】

### 12.1 原则（不变）

加法、备份、副本迁移、原子替换、幂等、不伪造历史。

### 12.2 阶段化迁移（统一口径）【修订 R6】

| 步骤 | 内容 | 阶段 | 建表 |
| --- | --- | --- | --- |
| M0 | 备份 + `user_version` + `schema_migrations` + `system_events` | P-1 | 2 张 |
| M1 | 身份/版本/节点 12 列 + 触发器 + 回填身份 | P0 | T1/T2/T5 |
| M2 | 过滤节点 `origin_node_id` 回填 | P0 | — |
| M3 | 目标状态 + 状态历史 + 规则版本 + 结果加列 | P1 | T3/T4/T7 |
| M4 | 历史结果 `valid=0/rule_version=0` + 状态回填（最高 observe） | P1 | — |
| M5 | 发布版本 + 基线 manifest + 指针 | P3 | T6 |
| M6 | 任务表 + 队列迁移 | P2 | T8 |

### 12.3 状态回填（沿用 v0.2 修正版，补"目标级"）

| 证据 | 目标层 | 节点层 |
| --- | --- | --- |
| 最近结果 TTL 内、非 engine、pass | 该目标 `pass`，`last_pass_at=ts` | 全目标 pass → healthy |
| 最近结果 TTL 内、非 engine、fail | 该目标 `fail`，`fail_streak=1` | 任一 fail → observe（**最高**） |
| 超 TTL 或仅 engine 错误 | `unknown` | unknown |
| 无结果 | `unknown` | unknown |
| 旧 `fail_count` | 不写入 | 仅进迁移报告 |

### 12.4 `valid=0` 与 `rule_version=0`（不变）

历史可查不可发；升级后 60 分钟 `migration_recovery` 期只读 active，不触发零健康。

### 12.5 WAL 与替换（沿用 v0.2 十三步）

补一条：P-1 只做 schema 层的 copy-migrate-swap；业务表在其阶段随版本发布执行同一流程。

### 12.6 三种回退（不变）

Schema 回退 / 代码回退 / 数据回退，分别定义。

---

## 13. 备份、恢复与升级（P-1 边界统一）【修订 R6】

### 13.1 备份（不变）

四类备份、轮转、manifest + `quick_check` + 行数 + 抽样校验。

### 13.2 P-1 只做安全底座

1. `schema_migrations` + `system_events`（仅这两张）；
2. 迁移前快照 + 校验；
3. copy-migrate-swap（schema 层）；
4. 恢复完整性校验（`integrity_check` + 表/列 + schema 版本）；
5. 失败保护（原库不动、degraded 启动、失败事件三路降级）；
6. 备份轮转与失败事件。

**不做**：业务表、业务回填、完整自检、`/healthz` 分级、启动自检门禁（P6）。

### 13.3 升级流程（不变）

---

## 14. 前端（增量）

1. 节点详情：G/W **分目标**显示 `最近成功时间 / 最近结果 / TTL 剩余 / 连续失败`；任一目标过期单独标红。
2. 解释文案："暂不下发：W 目标最近成功已过期 47 分钟"（逐目标）。
3. 身份歧义：显示"同配置 ×N，槽位 #k，物理身份不可判定"；不显示"已恢复原节点"这类断言。
4. 轮询机场：显示"本次响应 62 / 长期集合 118"，避免用户误解为删节点。
5. 发布：显示 active 版本来源（指针/DB 重建/修复），`pointer_repaired` 事件可见。
6. 零健康：显示"计时中 / 已暂停（引擎故障）/ 72h 人工复核"三种态。

---

## 15. 保留清单（不变）

四格式、四 URL 变体、UA 自适应、Token 鉴权、两种 `sub_publish`、测速面板与 50MB、机场排除、Mihomo 检测、TCP 诊断、评分、过滤、前端布局——全部不动。

---

## 16. 测试矩阵（合并版，按阶段交付）

| 组 | 场景 | 数量 | 阶段 |
| --- | --- | --- | --- |
| 身份 | I1–I12（§4.10） | 12 | P0 |
| 状态机 | S1–S14（§6.8） | 14 | P1 |
| 发布原子 | v0.2 P1–P8 + 指针冲突/DB重建 | 10 | P3 |
| 覆盖/零健康 | 分母为 0、全部停用、全 suspect、真实全挂、重复评估、恢复取消、72h 复核 | 9 | P2/P3 |
| 轮询 | 子集响应、并集基线、absent→missing 双条件、复现 | 5 | P0 |
| 小样本骤减 | 新机场、2 天历史、baseline=6→2、0 节点、3 次不一致 | 5 | P0 |
| 迁移/回退 | 迁移中断、失败事件三路、代码回退、DB 恢复、WAL 残留 | 6 | P-1/P5 |
| 过滤 B 方案 | 唯一映射、多候选、原行已删、id 冲突、历史不串 | 5 | P0 |

---

## 17. 阶段边界（统一版）【修订 R6】

| 阶段 | 交付 | 建表 | 不做 |
| --- | --- | --- | --- |
| P-1 | 备份、schema 版本、快照、恢复验证、迁移失败保护、最小门禁、测试夹具 | `schema_migrations`、`system_events` | 业务表、回填、自检 |
| P0 | 身份匹配（R1/R2）、配置版本、missing/absent、过滤 B 方案、机场版本表、小样本保护 | T1/T2/T5 | 状态机、发布门槛 |
| P1 | 目标层/节点层状态（R3）、有效结果、目标事故、TCP 边界、结果回填 | T3/T4/T7 | 调度、订阅格式 |
| P2 | per-node 调度、任务持久化、配额、覆盖统计 | T8 | 判定、发布 |
| P3 | 版本目录、指针、四格式原子、去重、回滚、零健康 72h | T6 | 渲染内容 |
| P4 | 业务 90 分钟、测速窗口、源屏蔽 | — | 算法与评分 |
| P5 | 归档清理、孤儿策略、规则版本历史 | — | 阈值 |
| P6 | 完整自检、healthz 分级、启动门禁、回退演练 | — | 业务表结构 |

已确认决策核对（Q1–Q12）：与 v0.2 §17.2 表一致，逐条已落点，未改动。

---

# B. v0.2 → v0.3 修订对照表

| # | v0.2 问题 | v0.3 修订 | 章节 | 是否完全解决 |
| --- | --- | --- | --- | --- |
| R1 | stable_id 候选被 `base_fingerprint` 限制；同指纹不同 id 会误置 missing | 候选改为全机场；四种结局 A–E；同配置多实例共存；复用/冲突流程与 3 个测试 | §4.3–4.5、I5–I8 | 是 |
| R2 | 未说清槽位稳定≠物理身份 | 能力边界三条写死；可延续/必须标歧义表；I3/I4 断言加严 | §4.7–4.8、I3/I4 | 是（边界声明，非算法可解） |
| R3 | 状态与资格矛盾、重复计罚、单目标洗白、recovering 不全 | 目标层事实 + 节点层 `max/min` 派生；`last_pass_at` 判资格；14 个状态测试 | §6 全节、§10.1 | 是 |
| R4 | 多处"当前版本"无唯一权威 | 权威表 + 5 个触发器 + 复合外键 + 事务边界 | §11.1–11.4 | 是 |
| R5 | B 方案只有一句话 | `origin_node_id` + 回填算法 + 准入恢复 + 防串号 + 对照表 + 5 测试 | §11.7、§12 | 是 |
| R6 | P-1 建表口径三处不一致 | 统一为"仅 2 张基础设施表"；失败记录三路降级；业务表按阶段 | §11.3、§12.2、§13.2、§17 | 是 |
| R7 | 指针/DB 权威与冲突裁决不明 | 指针权威；P1–P4 恢复优先级；校验清单；12 步持久化 | §10.2–10.5 | 是 |
| R8 | 分母为 0、72h、重复刷新未定义 | `|A|=0` 四类区分；确认 6 条件；72h 转人工；`confirmed_at` 只写一次 | §7.5、§10.6 | 是 |
| R9 | 响应子集被当物理增删 | 三概念分离；rolling_pool 并集规则；absent 双条件；歧义节点参与边界 | §9.5–9.7、§4.9 | 是 |

---

# C. 其余待确认事项（仅列真正未决）

> 已确认的 Q1–Q12 不再列出。C1、C2、C4、C7、C8 沿用 v0.2，状态更新如下。

| 编号 | 事项 | 推荐 | 现状 |
| --- | --- | --- | --- |
| C1 | stable_id + 指纹变 + 端点变，是否允许自动升 config_version | 不自动（情形 C） | **本轮因 R1 收紧，仍待确认** |
| C2 | 过滤节点是否并入 `nodes`（方案 A） | A；未定前用 B 兜底（本轮已完整化） | 待确认 |
| C3 | 遗留 `tasks` 表何时清理 | 保留一个 release | 待确认 |
| C4 | 时间本地 vs UTC | 本地 + 统一 helper | 待确认 |
| C5 | 业务目标是否写 `node_target_state` | 写，仅展示 | 待确认 |
| C6 | 零健康暂停是否计入 24h | 暂停顺延 + 72h 硬上限（本轮已写入 §10.6） | **本轮升级为规则，仅需确认 72h 数值** |
| C7 | 出口观测是否启用 | 默认关闭 | 待确认 |
| C8 | 指针 vs DB 权威 | 指针（本轮已定并给裁决流程） | 仅需确认 |
| **C9** | `rolling_pool` 的 absent 阈值（3 次 + 7 天） | 3 次 + 7 天 | 新增待确认 |
| **C10** | 72 小时硬上限到点后默认动作 | 转人工，不自动发布 | 新增待确认 |

**尚未解决、需实机验证**（不假设）：

1. 真实机场是否提供 stable_id，覆盖率未知（需真实订阅样本）。
2. 生产库规模与重复配置比例未知（P-1 只读普查）。
3. NAS 文件系统上目录 `rename` 是否原子（NFS/overlay 需实测）。
4. `cdn-cgi/trace` 在目标网络下的可用性。

---

# D. 风险与兼容性说明

| # | 风险 | 触发 | 缓解 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 同配置多节点物理身份不可知 | 无 stable_id 且同时改名 | 槽位 + 歧义标记 + 不合并历史 | I4 |
| 2 | stable_id 被复用 | 机场把旧 id 给新端点 | 情形 C/D 流程 + 双次确认 | I8 |
| 3 | 目标层聚合误判 | G/W 结果不同步 | `max/min` 派生 + 逐目标资格 + 14 测试 | S1–S14 |
| 4 | 指针与 DB 双写不一致 | 磁盘满、kill -9 | 校验清单 + P1–P4 裁决 + 启动修复 | 发布组 |
| 5 | 零健康误判 | 分母为 0、机场 suspect | 六条件 + `insufficient_scope` + 72h 人工 | 覆盖组 |
| 6 | 轮询被当删除 | 机场滚动池 | absent 双条件 + 并集基线 | 轮询组 |
| 7 | 迁移失败 | 断电/磁盘满 | copy-migrate-swap + 三路失败记录 | 迁移组 |
| 8 | 代码回退 | 新列/触发器影响旧代码 | 加法 schema；旧代码不写新列 | 回退用例 |
| 9 | 升级瞬间清空订阅 | 历史结果 valid=0 | 60 分钟 `migration_recovery` | §12.4 |
| 10 | 触发器误伤写入 | 版本顺序错 | 先写版本行再写节点；事务内顺序固定 | 迁移/写入用例 |
| 11 | 时区混用 | 混用 `datetime('now')` | 统一 helper + lint 禁止 | 清理边界用例 |
| 12 | 身份歧义影响评分 | 槽位被当独立节点 | 评分按槽位 + 标注 + 不作为轮换证据 | §4.9 |

**兼容承诺**：v0.3 全部为加法与语义收紧；P-1/P0/P1 允许"只回代码、不回库"；四种格式、四个 URL、鉴权、两种发布模式、测速与评分算法均未改动。

---

**v0.3 到此结束。** 未改代码、未改数据库、未建迁移文件、未执行 P-1、未改配置。请将本文档交回第三轮设计审查；在获得明确批准前，不提交任何实施计划、不进入任何阶段。
