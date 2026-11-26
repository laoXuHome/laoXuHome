# NodePoolME 新架构总体设计方案 v0.2（修订版）

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**前置文档**：《现有架构审查报告（阶段 0）》、《新架构总体设计方案 v0.1》
**本轮性质**：纯设计修订。未改代码、数据库、配置、迁移文件，未进入 P-1/P0。
**修订依据**：九项必须修订内容 + Q1–Q12 已确认决策（不推翻）

---

## 修订索引（先看这张表）

| 编号 | 修订主题 | 涉及章节 | 性质 |
| --- | --- | --- | --- |
| R1 | 节点身份匹配算法重写 | §4.3、§4.4、§4.7 | 重写 |
| R2 | fingerprint / identity / config_version 边界 | §4.2、§4.5、§4.6 | 重写（收紧） |
| R3 | 健康状态机 + 逐目标有效期 | §5.3、§6 全节、§10.1 | 重写 |
| R4 | 旧库迁移规则 | §12.2–12.5 | 重写（原方案错误） |
| R5 | 四格式整体原子发布 | §10.2–10.6 | 重写 |
| R6 | 小机场骤减保护 | §9.2、§9.3 | 新增 |
| R7 | per-node 调度下的覆盖与零健康确认 | §7.5、§10.5 | 新增 |
| R8 | 数据库结构、关系与迁移范围 | §11 全节、§12.1、§12.6 | 重写 |
| R9 | 阶段边界与决策引用 | §17 全节 | 修正 |

未修订章节（内容与 v0.1 一致，仅按修订结果做必要措辞同步）：§1、§2、§3、§8、§13、§14、§15、§16 的框架部分。

---

## 0. 设计摘要（修订后）

原则不变：**保留检测主干，为它加身份、时间、版本。** 本轮收紧三处最危险的推断：

1. **身份不再靠名称推断**。名称只作"延续已建立绑定"的辅助证据；同指纹多节点必须靠稳定 ID 或持久化槽位锚定，推断不成立就标 `identity_ambiguous`，不静默改写历史。
2. **配置版本不再随指纹自动递增**。没有可信稳定 ID 时，指纹变化=新身份，旧身份进 missing，只记"疑似关联"。
3. **有效期从"节点一个 last_valid_at"改为"每个检测目标各自一份"**。Google 新鲜不能替 YouTube 背书。

发布改为**"文件指针是唯一运行时权威"**：四种格式、manifest、校验和全部写进版本目录，切换只改 `active.json`；`publish_versions` 是镜像与审计，不是第二发布源。

---

## 1. 新旧架构对照

与 v0.1 相同的部分不再重复，仅列受本轮修订影响的 8 行（其余行保留 v0.1 §1）。

| 维度 | v1.8.7 现状 | v0.2 目标 | 相对 v0.1 的修订 |
| --- | --- | --- | --- |
| 身份匹配 | 指纹即身份；重复节点按返回顺序加后缀（`fetcher.py:146-163`） | 稳定 ID → 单候选延续 → 完整名精确匹配 → 持久槽位锚定 → 新建；全程可解释 | R1：取消"去编号哈希"，名称只作辅助 |
| 配置版本 | 无 | 仅在有稳定 ID 且连续两次一致时递增；否则新身份 | R2：不再"同端点同名即新版本" |
| 有效期 | 无 | 每个目标独立 `last_valid_at + ttl` | R3：取消节点级单一有效期 |
| 发布原子性 | 逐格式 `os.replace` + `meta.json` | 版本目录一次落盘 + 单指针切换，读者只认指针 | R5：取消 `sub_all.*` 作为发布源 |
| 零健康节点 | 无限期保留 | 覆盖率确认 + 不可变事件 + 24h（可暂停） | R7：确认条件与计时绑定重定义 |
| 小机场保护 | 无 | 独立小样本策略，禁止静默接受骤减 | R6：新增 |
| 迁移 | 线性 ALTER，无版本 | 备份 → 副本迁移 → 校验 → 原子替换；业务迁移按阶段拆分 | R4/R8/R9 |
| 阶段边界 | P-1 含自检骨架与全部业务迁移 | P-1 只做安全底座，业务表迁移下沉到 P0/P1/P3/P5 | R9 |

---

## 2. 总体模块划分（未修订，补 2 个模块）

在 v0.1 分层基础上新增：

```
backend/health/target_state.py     # 逐目标有效期与结果（R3）
backend/publish/pointer.py         # active.json 读写、启动一致性修复（R5）
```

依赖规则不变：`api → core/scheduler → domain → infra`；状态唯一写入口是 `health.state_machine`；身份唯一解析入口是 `lifecycle.identity.resolve_snapshot`；所有订阅读取必须经 `publish.pointer.resolve()`。

---

## 3. 模块职责（未修订，新增两行）

| 模块 | 职责 | 明确不做 |
| --- | --- | --- |
| `health/target_state` | 维护每个 (node, target) 的有效结果、时间、config/rule 版本、TTL、失败来源 | 不做节点级汇总判定 |
| `publish/pointer` | 解析 `active.json`、校验版本目录 checksums、启动修复、禁止直读 `sub_all.*` | 不生成内容 |

其余模块职责与 v0.1 §3 一致。

---

## 4. 节点身份与配置版本模型【修订 R1 / R2】

### 4.1 三个概念（未修订）

identity 回答"是不是同一节点"，config_version 回答"用的是哪版配置"，node 行回答"当前运行时快照"。`nodes.id` 仍是运行期句柄，不改主键。

### 4.2 fingerprint 的定位【修订 R2】

`fingerprint(protocol, server, port, params 子集)`（`parsers/subscription.py:94`）**只表示"配置内容"**，不再等价于"节点身份"。它的唯一用途是：

1. 作为同机场内"候选同配置组"的分组键（`base_fingerprint`）；
2. 作为"配置是否变化"的比较依据（同身份前后对比）。

**它不能单独证明两个节点是同一物理节点。** 本次不改算法（Q3）。

### 4.3 身份匹配：完整优先级【修订 R1】

参与匹配的输入只有五类：`base_fingerprint`、`airport`、`stable_id`（若机场提供）、完整归一化名、已持久化的绑定。

**优先级（严格顺序，命中即停；不允许跳级推断）**

| 级 | 规则 | 强度 | 名称变化允许 | 备注 |
| --- | --- | --- | --- | --- |
| P0 | `stable_id` 精确匹配同一已存在身份 | 强 | 是 | 要求该身份此前至少 **2 次连续 applied 拉取**中 `stable_id` 稳定（防机场 id 复用） |
| P1 | **单候选延续**：组内恰有 1 个未绑定身份 + 本次恰有 1 个未绑定节点 | 强（结构性） | 是 | 对应"同指纹单节点改名"；不需要看名字 |
| P2 | **完整归一化名精确相等**（双向一一映射） | 辅助 | 否（名称未变） | 仅用于延续既有绑定，不用于跨指纹合并 |
| P3 | **编号配对**：组内两侧各有唯一编号且数量相等 | 弱 | 是（编号不变） | 仅当 P2 之后仍有剩余时；必须整体一一映射，结果标 `weak_binding` |
| P4 | **持久化槽位锚定**：按 `occurrence_seq` 升序把剩余节点分配给剩余身份 | 最弱 | 是 | 结果标 `identity_ambiguous=1` + 事件；分配依据是上一次持久化的槽位，不是本次返回顺序 |
| P5 | 新建身份（`occurrence_seq = max+1`） | — | — | 只处理"节点数多于身份数"的剩余项 |

**归一化规则（禁止去编号）**

只做"装饰剥离"，不做"内容归一"：

1. 去首尾空白；全角转半角；连续空格合一；
2. 去 emoji、国旗、Unicode 装饰符号；
3. 去限速/倍率前缀（`[1x]`、`2x`、`100M`、`倍率` 类，复用现有 `strip_speed_prefix`）；
4. 去机场后缀（`·XX机场`、`| XX`）；
5. 大小写统一为小写。

**保留**：编号、地区词、协议词、序号、括号内容。因此 `香港01` 与 `香港02` 的 `name` 键不同；**禁止**生成"去编号后哈希"，也**禁止**任何相似度/编辑距离/模糊匹配。

### 4.4 匹配流程（可执行伪代码）【修订 R1】

```
def resolve_snapshot(airport, returned_nodes, existing_identities):
    # 0. 分组
    groups = {airport, base_fingerprint}
    bindings = []            # (identity_id, node)
    used_identities, used_nodes = set(), set()

    # 1. 强键：stable_id
    for node in returned_nodes with node.stable_id:
        cand = groups[node.base_fp] where source_node_id == node.stable_id
                       and stable_id_seen_count >= 2
        if exactly one cand and cand not used:
            bind(cand, node, reason="stable_id")
            used += both

    # 2. 结构性单候选（改名场景）
    for group in groups:
        free_ids  = group identities not used and lifecycle in (active, missing)
        free_nodes= group returned nodes not used
        if len(free_ids) == 1 and len(free_nodes) == 1:
            bind(free_ids[0], free_nodes[0], reason="single_candidate")
            used += both

    # 3. 完整名精确匹配（一一映射，双向唯一）
    for group in groups:
        name_map_id  = {normalize(id.current_raw_name): id for free ids}
        name_map_node= {normalize(n.raw_name): n for free nodes}
        for name in intersection(name_map_id, name_map_node):
            bind(name_map_id[name], name_map_node[name], reason="exact_name")

    # 4. 弱键：编号配对（仅剩余、两侧数量相等、编号唯一）
    for group in groups with remaining:
        if count(free_ids) == count(free_nodes) and both sides have unique nums:
            for num in matching_nums:
                bind(..., reason="number_pair", weak=True)

    # 5. 槽位锚定（仅剩余、数量相等）
    for group in groups with remaining and count equal:
        for (id, node) in zip(sort_by(occurrence_seq), sort_by_stable_key(free_nodes)):
            bind(id, node, reason="slot_anchor", ambiguous=True)

    # 6. 剩余节点 → 新身份（追加 seq）；剩余身份 → missing
    ...

    # 7. 冲突检测（任何一步违反以下不变量 → 不覆盖，记事件）
    if a node name equals another identity's previous name and that identity is bound
        to a different node → event "name_swap_suspected"，不交换绑定
    if new node's fingerprint == existing identity's fingerprint but stable_id differs
        → 冲突：以 stable_id 为准，旧身份 missing，记 "stable_id_conflict"
```

**槽位锚定的 `sort_by_stable_key`**：优先 `stable_id` 的字典序，其次编号，最后 `raw_name` 字典序。它只影响"这一次怎么分"，不构成身份证据，因此必须打 `ambiguous` 标记；下一次若仍无法区分，**沿用上一次的槽位分配**（`occurrence_seq` 不变），不重新洗牌。

### 4.5 关键不变量（评审重点）

1. **绑定一经持久化，不会因"本次顺序"改变**：P4 使用 `occurrence_seq`，与到达顺序无关。
2. **不允许把一个已存在身份的绑定，静默转给另一个身份**。强键冲突时（P0 与既有绑定矛盾）→ 旧身份转 missing，新身份建立，记 `stable_id_conflict`；不覆盖。
3. **missing 命中规则**：匹配可作用于 `missing` 身份（30 天内）；命中后恢复 `active`，状态回 `unknown`，不继承旧健康。
4. **同名不等于同身份**：P2 仅在"组内一一映射成立"时生效；若两个身份同名（歧义数据）→ 跳过 P2，直接 P4 + 标歧义。
5. **过滤节点**：`airport_filtered_nodes` 中被准入的节点必须带 `origin_node_id`（见 R8），重新进入缓存池时恢复原 `nodes.id` 与身份，不新建。

### 4.6 `config_version` 判定：决策表【修订 R2】

先给结论：**只有 P0/P1 级证据才能在同一身份下递增 `config_version`；其余一律新身份。**

| # | fingerprint | stable_id | server:port | 名称 | 判定 | config_version | 历史 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 相同 | 任意 | 相同 | 变 | 同身份，仅改名 | 不变 | 连续；记 `rename` |
| 2 | 相同 | 不同（冲突） | 任意 | 任意 | **不同身份**（同配置双实例） | 各自独立 | 旧身份 missing，记 `stable_id_conflict` |
| 3 | 不同 | 相同且已稳定 ≥2 次 | 任意 | 任意 | 同身份，新配置 | +1，`config_changed` | 旧版本 closed，结果保留但不参与判定 |
| 4 | 不同 | 无 | 相同 | 相同 | **疑似关联，不同身份** | 新身份 v1 | 旧 missing；记 `probable_successor`，不继承 |
| 5 | 不同 | 无 | 相同 | 不同 | 新身份 | 新身份 v1 | 旧 missing |
| 6 | 不同 | 无 | 不同 | 相同 | 新身份（疑似迁移） | 新身份 v1 | 旧 missing；`probable_successor` |
| 7 | 不同 | 无 | 不同 | 不同 | 新身份 | 新身份 v1 | 旧 missing |
| 8 | 不同 | 相同但仅出现 1 次 | 任意 | 任意 | 新身份（证据不足） | 新身份 v1 | 旧 missing；待下次拉取再确认 |

**明确写死**：
- 服务器地址与端口相同、名称相同，**不足以**证明身份相同（第 4 行）。
- 名称相似、端点相似只产生"疑似关联"记录，**不得**继承历史、不得抬升 config_version。
- 第 4 行若未来要自动判为"同身份新版本"，必须另立"身份连续性判定方案"（多因子证据 + 双次确认），列为待确认 C1。

**旧配置结果的隔离**：`health.validity` 校验 `result.config_version == node.config_version`；新身份天然是新的 `node_id`，旧结果不可能命中。双重保险，不依赖单点。

### 4.7 能力边界（必须写进 UI 与文档）【修订 R1】

当同机场存在 **N 个 fingerprint 完全相同、且无 stable_id、名称也完全无法区分**的节点时：

- 系统能保证：不因返回顺序变化而反复改绑；每个槽位有独立历史；不错误合并。
- 系统不能保证：槽位与"机场后台的某一台具体服务器"一一对应。
- 处理方式：全部标 `identity_ambiguous=1`，前端显示"同配置 ×N，按首次观测锚定"，并提供导出。

### 4.8 身份匹配测试场景（10 个，P0 交付）

| # | 场景 | 预期 |
| --- | --- | --- |
| I1 | 单节点改名（同指纹） | 同 identity，版本不变，有 rename 事件 |
| I2 | 两重复节点，顺序交换，名称不变 | 绑定不变（P2 精确名），无歧义 |
| I3 | 两重复节点，顺序交换 + 一个改名 | 未改名者 P2 绑定；改名者 P3/P4；标记弱绑定，不洗牌 |
| I4 | 两重复节点，全部改名 | P4 槽位锚定，`ambiguous=1`，槽位不随顺序变化 |
| I5 | 有 stable_id，改名 + 配置变 | 同 identity，config_version+1 |
| I6 | 消失 20 天后同配置返回 | 恢复原 identity 与原版本，状态 unknown |
| I7 | 消失 20 天后不同配置返回 | 旧 identity 仍 missing；新 identity v1；有 probable_successor |
| I8 | 重复组中 1 个消失、30 天内返回 | 原槽位恢复；其余不受影响 |
| I9 | 重复组新增 1 个 | 新身份 seq+1；既有槽位不重排 |
| I10 | 过滤节点准入回池 | 恢复原 `nodes.id`，不新建身份 |

---

## 5. 节点生命周期模型（修订 §5.3/5.4）

三态与进入退出条件沿用 v0.1 §5.1–5.2，补充：

1. `missing` 只由**被接受**的拉取触发；`suspect`/失败/解析异常**不触发** missing（R6）。
2. `retired` 只改 `lifecycle`，**不删 `nodes` 行**（保证 `node_state_history`、结果表、前端历史不断锚）。
3. `retired → active` 允许，但状态从 `unknown` 重新开始。
4. 机场 `enabled=0` 属于"停用"，不改 lifecycle，只冻结检测与下发（v0.1 待确认项，本轮定为规则）。
5. `missing` 期间：撤销其 `task_jobs(queued)`，不产生新任务；已有结果保留但失效（不参与资格）。

---

## 6. 健康状态机与"有效检测结果"【修订 R3】

### 6.1 有效检测结果（比 v0.1 更严格）

必须同时满足：

1. `engine="mihomo"` 且真实经代理（TCP-only 恒无效）；
2. `config_version == node.config_version`；
3. `rule_version == 当前生效`；
4. 有 `started_at/finished_at`，且结束时节点身份与配置版本未变（完成复核）；
5. `failure_source != engine/scheduler/system`；
6. 不在目标事故窗口内；
7. 非 `canceled`。

不满足 → 入库但 `valid=0`，不参与任何计数与状态。

### 6.2 逐目标状态（替代"节点级 last_valid_at"）

新增 `node_target_state`，每个 `(node_id, target)` 一行，权威字段：

`last_valid_at`、`last_result`（pass/fail/unknown）、`config_version`、`rule_version`、
`failure_source`、`ttl_override`、`consecutive_fail`、`consecutive_pass`、`updated_at`。

- 必需目标（当前为 `G`、`W` 两个延迟目标）各自的 TTL 独立计算，默认 90 分钟（D1）。
- `nodes` 不再保存单一 `last_valid_at`（v0.1 的该字段取消）。
- 发布资格**逐目标**校验（见 §10.1），任一必需目标过期 → 节点不具备资格，即使另一目标刚刷新。
- 业务检测目标（ChatGPT/Telegram/YouTube…）若采纳 C5（推荐），也写 `node_target_state`，但**只用于展示与命名**，永不进入资格；其 TTL 默认 3× 业务频率（270 分钟）。

### 6.3 统一状态定义

| 状态 | 语义 | 下发 | 进入条件 |
| --- | --- | --- | --- |
| `unknown` | 无任何当前版本有效结果 | 否 | 新身份 / 新 config_version / 迁移 / retired→active |
| `healthy` | 最近一次有效结果为通过 | 是 | unknown 首次有效通过（含恢复确认完成） |
| `observe` | 1 次有效失败，仍在容忍内 | 是（且逐目标未过期） | healthy 失败 1 次；或 unknown 首次失败 |
| `unstable` | 连续 `T-1` 次有效失败 | 否 | observe 继续失败；或 recovering 失败后未达 T |
| `unavailable` | 连续 ≥`T` 次有效失败 | 否 | unstable 继续失败；或 recovering 期间有效失败 |
| `recovering` | 从不可用恢复的第 1 次成功 | 否 | unavailable 收到有效通过 |
| `stale`（正交标记） | 某个必需目标 `last_valid_at + ttl` 已过期 | **否** | 时间到期（不改 `state` 字段，只改 `stale_targets` 派生值） |

`T` 默认 3（`settings.fail_threshold`，不改默认）。`observe` 区间为 `1 … T-2`；`T=2` 时无 observe，`T=1` 时直接 unavailable。

### 6.4 完整状态迁移表

| # | 当前 | 事件 | 条件 | 目标 | 副作用 |
| --- | --- | --- | --- | --- | --- |
| 1 | unknown | 有效通过 | 双目标（或该节点被判定的目标）通过 | healthy | `fail_streak=0`, `success_streak=1`（不进入 recovering） |
| 2 | unknown | 有效失败 | `T ≥ 2` | observe | `fail_streak=1` |
| 3 | unknown | 有效失败 | `T == 1` | unavailable | `fail_streak=1` |
| 4 | healthy | 有效失败 | `T ≥ 3` | observe | `fail_streak=1`；仍可下发 |
| 5 | healthy | 有效失败 | `T == 2` | unstable | `fail_streak=1`；停发 |
| 6 | observe | 有效通过 | — | healthy | `fail_streak=0` |
| 7 | observe | 有效失败 | `fail_streak+1 == T-1` | unstable | 停发 |
| 8 | observe | 有效失败 | `fail_streak+1 >= T` | unavailable | 停发 |
| 9 | unstable | 有效通过 | — | healthy | 清零 |
| 10 | unstable | 有效失败 | `>= T` | unavailable | 停发 |
| 11 | unavailable | 有效通过 #1 | — | recovering | `success_streak=1`，记 `recovering_since` |
| 12 | recovering | 有效通过 #2 | 与 #1 间隔 ≥ 30 分钟 | healthy | `success_streak=2`，清零 fail |
| 13 | recovering | 有效通过 #2 | 间隔 < 30 分钟 | recovering | 不推进（间隔不足，按无效确认处理，仅记日志） |
| 14 | recovering | 有效失败 | — | unavailable | `success_streak=0`，回不可用 |
| 15 | 任意 | 引擎/系统/目标事故结果 | — | 不变 | `valid=0`；只记事件 |
| 16 | 任意 | 必需目标过期 | 时间 | 状态不变 | `stale` 标记；停发 |
| 17 | 任意 | 新 config_version | 版本切换 | unknown | 旧结果隔离 |
| 18 | 任意 | lifecycle=missing | 拉取 | 状态冻结 | 撤销任务；不发 |

### 6.5 迁移伪代码

```
def apply(outcome, node, target):
    if not is_valid(outcome, node):                 # §6.1
        record_invalid(outcome); emit_if_system(outcome); return
    tgt = target_state.upsert(node, target, outcome)

    s = node.state
    if outcome.pass:
        node.fail_streak = 0
        if s == "unavailable":
            node.state = "recovering"; node.success_streak = 1; node.recovering_since = now
        elif s == "recovering":
            if now - node.recovering_since >= 30min and target_fresh(node):
                node.state = "healthy"; node.success_streak = 2
            # else 保持 recovering
        else:
            node.state = "healthy"; node.success_streak += 1
    else:
        node.success_streak = 0
        node.fail_streak += 1
        if s == "recovering":
            node.state = "unavailable"
        elif node.fail_streak >= T:
            node.state = "unavailable"
        elif node.fail_streak >= max(2, T-1):
            node.state = "unstable"
        else:
            node.state = "observe"
    write_state_history(...); sync_legacy_status(node)
```

### 6.6 TCP-only 与系统故障边界（与 v0.1 一致，明确写死）

- `engine=tcp` → `valid=0`，只能进"诊断"页，不写 `node_target_state` 的 `last_result`。
- 引擎降级→ `system_events(engine_degraded, critical)`，全局暂停发布；恢复后正常。
- 批次超时/进程重启 → 未完成任务 `valid=0`，不补罚。

### 6.7 边界测试（10 个，P1 交付）

| # | 场景 | 预期 |
| --- | --- | --- |
| S1 | unknown 首次通过 | healthy，可发 |
| S2 | healthy 单次失败 | observe，仍可发 |
| S3 | observe 连续失败到 T-1 | unstable，停发 |
| S4 | unstable 再失败到 T | unavailable |
| S5 | unavailable 一次成功 | recovering，停发 |
| S6 | recovering 第二次成功但间隔 10 分钟 | 仍 recovering |
| S7 | recovering 第二次成功，间隔 35 分钟 | healthy |
| S8 | recovering 期间失败 | 回 unavailable |
| S9 | G 刚刷新、W 过期 | 不具备资格（逐目标断言） |
| S10 | 引擎异常 3 次 | 状态不变、streak 不变、事件 3 条 |
| S11 | TCP-only 通过 | valid=0、无资格、healthz degraded |

---

## 7. 三类检测的独立调度设计（修订 §7.5，新增 R7）

### 7.1–7.4（未修订）

时间模型、到期计算、优先级、业务 90 分钟独立、测速 17:00–24:00 迁移规则，均按 v0.1 §7.1–7.4 执行（Q5/Q6/Q7）。

### 7.5 per-node 调度下的统计口径【新增 R7】

原"批次覆盖率"在 per-node 调度下失效，必须改用**滚动窗口**口径：

| 概念 | 定义 |
| --- | --- |
| 检测覆盖窗口 | `coverage_window = 2 × base_interval`（默认 60 分钟），滚动 |
| 活跃节点 | `lifecycle=active` 的节点数（窗口内不变动的口径：取窗口结束时刻） |
| 目标有效覆盖 `cov(t)` | 窗口内存在"当前 config_version + 当前 rule_version + valid=1"结果的活跃节点数 / 活跃节点数 |
| 节点池健康快照 | 某一时刻按逐目标资格表达式算出的 `publishable` 集合 + 其 `health_snapshot_hash` |
| 有效节点统计范围 | 仅 `active`；`missing/retired` 不计入分子分母；`stale` 节点计入分母、不计入分子 |
| 系统故障期间 | `engine_degraded` 或 `scheduler_stall` 或 `db` 异常期间，该窗口标 `invalid_window`，不参与零健康确认 |
| 机场异常期间 | 存在未关闭 `count_drop/config_burst/empty_subscription` 事件的机场，其节点从分子分母同时剔除，并单独报告 |

**零健康确认条件**（替代"本批次覆盖率 ≥80%"）：

1. 每个必需目标 `cov(t) ≥ 90%`；
2. 窗口内无 `invalid_window`；
3. 无未关闭的机场异常事件（涉及该机场的节点已剔除后仍满足 1）；
4. 按逐目标资格算出 `publishable = 0`；
5. 连续两次评估（间隔 ≥10 分钟）都满足 1–4。

只有 5 成立才创建 `empty_confirmed` 事件（`system_events`，`kind='empty_confirmed'`，`immutable=1`），**24 小时从该事件 `confirmed_at` 起算**，后台任务重复运行不能刷新。

### 7.6 任务持久化与重启（未修订，补一条）

`task_jobs` 的重启恢复逻辑不变；新增：`detect` 任务在恢复时校验 `nodes.lifecycle` 与 `config_version`，已变化则丢弃（幂等键里已含版本，重复也不会执行）。

---

## 8. 并发、队列、超时与恢复（未修订）

配额矩阵、幂等键、超时层级、重启恢复步骤与 v0.1 §8 一致。补充两条与本轮修订相关：

1. `task_jobs` 保留期：`done` 30 天、`failed/canceled` 90 天，`interrupted` 永久直到人工关闭。
2. 发布任务（`kind=publish`）幂等键改为 `pub:{active_version}:{content_hash}`，避免同一目标版本重复执行。

---

## 9. 机场订阅异常保护与轮换识别【修订 R6】

### 9.1 五类结果分类（未修订）

`fetch_error / parse_error / empty_subscription / suspect / ok` 的判定与缓存语义保持 v0.1 §9.1。

### 9.2 骤减保护：主规则（Q8，不得改成 OR）

```
baseline = median(最近 7 个自然日"最后一个 applied=1 版本的 accepted_count")
触发条件（必须同时）：
    accepted_count <= baseline * 0.5
    且 baseline - accepted_count >= 10
```

### 9.3 小样本与历史不足策略【新增 R6】

原方案"历史不足 3 天不启用保护"是漏洞，现按四种情形分别处理，**任何情形都不得静默替换缓存**：

| 情形 | 判定模式 | 确认要求 | 处理 |
| --- | --- | --- | --- |
| 新机场（无任何 applied 版本） | 首次基线 | 无需确认 | 首次结果作为基线，`applied=1`，记 `baseline_established` |
| 历史 < 3 天但已有基线 | 小样本模式 | **连续 3 次**独立拉取一致 | 满足则接受；不满足保持缓存 + `suspect` |
| `baseline < 10` 的机场 | 小样本模式 | 连续 3 次一致；若 `baseline >= 5` 且降幅 ≥50%，**追加人工确认** | 同上；人工出口 `accept-change` |
| `baseline >= 10` | 主规则（7 天中位数） | 连续 2 次一致 | 与 Q8 一致 |
| 任意机场出现 0 节点（HTTP 200 空壳） | 保护 | **一律人工确认** | 绝不自动接受；记 `empty_subscription` |

**"连续两次/三次一致"的判定标准**（必须可执行）：

1. 两次拉取间隔 ≥ 5 分钟（防 CDN 缓存同一响应）；
2. `content_sha256` 不相同但节点集合一致时，按集合判定：
   - 数量差 ≤ `max(10%, 2)`；
   - 身份集合 Jaccard ≥ 0.9；
   - 变更指纹集合的对称差 ≤ `max(10%, 2)`；
3. 两次都满足才算"一致"；任一不满足 → 计数器归零，继续复核（最多 5 次，之后保持保护并升级告警）。

**轮询导致的暂时变化**：机场按 `interval_minutes` 轮询，不同时间点可能返回不同子集（滚动池）。判定一致时要求"两次独立拉取"必须是**两次真实 HTTP 请求**，不能用同一响应的重放；对已知滚动池（连续 3 个版本均呈"部分子集"特征）记 `rolling_pool` 标记，允许按并集口径比较，但仍不允许 0 节点自动接受。

### 9.4 配置突变保护（未修订）

`changed_config / total ≥ 60%` 且 `total ≥ 10` → `suspect`，确认规则同 §9.3（大机场 2 次、小样本 3 次）。

### 9.5 轮换识别（未修订）

列表/出口/混合的分类与 `rotation_hint` 不变。出口观测模块默认关闭（C7），关闭时 `rotation_hint=unknown`。

---

## 10. 订阅生成、整体原子发布、去重与回滚【修订 R5 / R7】

### 10.1 发布资格表达式【修订 R3】

```
eligible(node) =
      node.lifecycle == 'active'
  AND node.state IN ('healthy','observe')
  AND ∀ t IN required_targets(G, W):
        EXISTS target_state(node, t)
        AND ts.config_version == node.config_version
        AND ts.rule_version   == current_rule_version
        AND ts.last_result    == 'pass'
        AND ts.last_valid_at + ttl(t) > now

publishable = { node | eligible(node) }
```

- 逐目标短路：任一目标过期即整节点不合格（修复"Google 刷新鲜、YouTube 过期仍下发"）。
- 业务目标不进入 `required_targets`（业务检测不改变健康判定，Q6）。
- `observe` 可发：单次失败不摘节点。

### 10.2 单一权威与目录结构【修订 R5】

**权威定义（必须记住这一条）**：

> **运行时唯一权威 = 文件系统 `data/sub/active.json`。**
> `publish_versions` 是目录索引与审计镜像；`data/sub/sub_all.*` **不再是发布源**，仅作为历史遗留路径的兼容副本（可停止生成）。

```
data/sub/
  active.json                     # {"version":123,"sha256":"...","switched_at":"..."}
  versions/000123/
    clash.yaml  singbox.json  base64.txt  loon.txt
    manifest.json.gz              # 完整节点配置快照（可重建）
    meta.json                     # 统计/原因/health_version/airport_versions/rule_version
    checksums.txt                 # 5 个文件的 sha256
```

**读取路径统一**：`builder.read(fmt)` 改为 `publish.pointer.resolve(fmt)`：

1. 读 `active.json`；缺失/损坏 → 取 `versions/` 中最大版本且 checksums 通过者，重建指针并记 `pointer_repaired`；
2. 校验 `checksums.txt` 中目标文件；不一致 → 拒绝服务该格式（500 + 事件），**不回退到旧 `sub_all.*`**；
3. 返回文件内容。

四种旧 URL（`/sub/all`、`/sub/all/{token}`、`/{token}/{fmt}`、带/不带斜杠）与 UA 自适应、Token 鉴权全部不变；两种 `sub_publish` 模式全部保留（C4 已定）。

### 10.3 发布流程（九步，任一步失败都不影响已生效版本）

```
1. 计算 content_hash（identity_id + config_version + 展示名 + protocol + server + port + params）
2. 与 active.meta.content_hash 相同 → 记 skipped，结束
3. 版本号 = max(versions/)+1；渲染 4 格式到内存；4 个全部 validate（逐个断言，全过才继续）
4. 写 versions/<v>.tmp/：manifest.json.gz、meta.json、4 文件、checksums.txt
5. fsync 每个文件 → fsync 目录
6. rename versions/<v>.tmp → versions/<v>        ← 目录原子
7. 写 active.json.tmp（含新版本号与 checksums 总哈希）→ fsync → os.replace  ← **提交点**
8. DB：INSERT publish_versions(active=0) → UPDATE 旧 active=0 / 新 active=1（失败可重试，不影响服务）
9. 写 share_history；清理超出保留数的非 active 版本（默认 30）
```

**崩溃/失败恢复矩阵**

| 崩溃点 | 现象 | 恢复 |
| --- | --- | --- |
| 3–4 之前 | 只有 tmp 或无 | 启动清理 `*.tmp`，active 不变 |
| 5–6 之间 | tmp 残留 | 同上 |
| 6 之后、7 之前 | 新目录完整但未提交 | 目录保留为"未激活版本"，不服务；下次发布复用或标记 orphan |
| 7 之后、8 之前 | 已生效但 DB 无记录 | 启动扫描 `active.json` → 若 `publish_versions` 无此版本 → 从 `meta.json` 重建记录（`recovered=1`） |
| 8 失败（DB 锁/满） | 已生效、目录无记录 | 同上重试；DB 不可用时不阻塞读取 |
| 9 失败 | 已生效 | 清理任务下次补做 |

**DB 与指针冲突时的裁决**：以 `active.json` 为准；若其版本目录 checksums 校验失败 → 取 DB `active=1` 且目录完整的版本重建指针，记 `pointer_conflict`。

### 10.4 去重（未修订）

同 `content_hash` 不生成新版本；`share_history` 也只在真实切换时写。

### 10.5 零健康节点：确认与 24 小时计时【修订 R7】

事件模型（`system_events`，`kind='empty_confirmed'`，不可变）：

| 字段 | 含义 |
| --- | --- |
| `confirmed_at` | 首次满足 §7.5 条件 1–5 的时间（**唯一计时起点**） |
| `state` | `counting / paused / expired / canceled` |
| `paused_ms` | 累计暂停时长（系统/机场异常期间） |
| `deadline` | `confirmed_at + 24h + paused_ms` |
| `evidence` | 覆盖率、各目标 cov、剔除机场列表 |

规则：

1. **部分节点恢复**（`publishable ≥ 1`）→ 事件 `canceled`，计时清零，正常发布。
2. **系统异常**（`engine_degraded/scheduler_stall/db`）→ `paused`，`paused_at` 记时；恢复后累加 `paused_ms`，deadline 顺延；**不重置** `confirmed_at`。
3. **机场异常**（未关闭的 `count_drop/config_burst/empty_subscription`）→ 同上暂停；机场节点剔除后若 `cov` 不足，事件状态保持但不推进。
4. **重复评估不能刷新计时**：同一事件行 `id` 不变，只允许更新 `paused_ms`；任何"重新确认"不得写新的 `confirmed_at`（除非事件被 canceled 后再次成立 → 新事件）。
5. **到期动作**：先重新验证（cov ≥90%、无异常、`publishable=0`）：
   - 通过 → 发布 `minimal` 版本（0 节点 + meta + 明确 `empty_confirmed` 标记），指针切换；
   - 不通过（覆盖率不足）→ 顺延 30 分钟，记 `expiry_deferred`，**不发布空订阅**；
   - 出现 ≥1 可发布节点 → 事件 canceled，正常发布。
6. 24 小时内发布资格仍未恢复但 `publishable>0` 且不足 → 正常按实际集合发布（不为凑数保留旧节点）。

### 10.6 回滚（未修订语义，明确重校验）

1. 选择目标版本 → 读取其 `manifest`；
2. 逐节点重校验 `eligible()`（当前 lifecycle/state/逐目标新鲜度/config_version）；
3. 生成"可恢复 N / 排除 M（原因分布）"预检结果，展示给用户确认；
4. 确认后以"当前可恢复集合"生成**新版本**（`reason=rollback_from:<v>`），走完整发布流程；
5. 目标版本 manifest 缺失/checksums 失败 → 拒绝回滚，给出明确原因。

### 10.7 四格式发布测试（P3 交付）

| # | 场景 | 断言 |
| --- | --- | --- |
| P1 | 正常发布 | 4 文件同版本、checksums 全过、指针切换 |
| P2 | 第 3 种格式校验失败 | 不建版本、指针不动、旧订阅可读 |
| P3 | 步骤 6 后 kill -9 | 新版本不生效；重启后无 tmp 残留 |
| P4 | 步骤 7 后 kill -9 | 新版本生效；重启后 DB 记录被重建 |
| P5 | 指针文件损坏 | 自动修复到最大有效版本，事件记录 |
| P6 | 读者并发读取时切换 | 每次读取要么全旧要么全新（无混合版本） |
| P7 | 同内容重复发布 10 次 | 版本数 +0 |
| P8 | 回滚到 v(n-3) 且其中 2 节点已 unavailable | 新版本排除这 2 个并列出原因 |

---

## 11. 数据库结构、关系与迁移范围【修订 R8】

### 11.1 修正说明（对 v0.1 的自我纠正）

| v0.1 问题 | v0.2 处理 |
| --- | --- |
| 注释"nodes 新增 7 列"，实际 DDL 12 列 | 明确为 **12 个必增字段**，逐列解释（§11.2） |
| `node_events` 与 `system_events` 职责重叠 | **合并**为一张 `system_events`（`scope` 区分） |
| 表数量 11 张 | 收敛为 **9 张核心 + 1 张可选 + 1 张迁移审计** |
| 未调查 `tasks` 表 | 已调查：空表、6 列、无代码引用、不在 SCHEMA（§11.6） |
| 把演示库 137 节点当生产规模 | 明确"未知，需 P-1 只读普查"（§11.7） |
| 过滤节点迁移会丢 id | 提供两方案，推荐并入 `nodes`（§11.5） |
| 时间策略未统一 | 明确"继续本地时间 + 唯一 helper"，禁用 `datetime('now')`（§11.8） |
| WAL 迁移未说明 | 补完整步骤（§12.6） |
| 三类回退未区分 | 补 schema/代码/数据三种回退（§12.7） |
| P-1 承担全部业务迁移 | 拆分：P-1 只做安全底座（§17） |

### 11.2 `nodes` 新增字段（12 个，逐列说明）

| # | 字段 | 类型/默认 | 职责 | 为何必须 |
| --- | --- | --- | --- | --- |
| 1 | `identity_id` | INTEGER NULL | 指向 `node_identities` | 身份与当前快照解耦的唯一锚点 |
| 2 | `config_version` | INTEGER 1 | 当前配置版本号 | 结果隔离、资格判定 |
| 3 | `first_seen_at` | TEXT NULL | 该节点首次进入机场的时间 | 槽位锚定、缺失恢复、UI 解释 |
| 4 | `lifecycle` | TEXT 'active' | active/missing/retired | 生命周期与健康正交 |
| 5 | `missing_since` | TEXT NULL | 开始缺失时间 | 30 天保留期计算 |
| 6 | `state` | TEXT 'unknown' | 6 态健康状态 | 唯一权威状态字段 |
| 7 | `state_since` | TEXT NULL | 当前状态开始时间 | 恢复间隔、UI、审计 |
| 8 | `fail_streak` | INTEGER 0 | 连续**有效**失败数 | 失败确认（不再复用 fail_count） |
| 9 | `success_streak` | INTEGER 0 | 连续有效成功数 | 恢复确认 |
| 10 | `last_failure_source` | TEXT NULL | 最近失败归因 | UI 解释"为什么没下发" |
| 11 | `ambiguous` | INTEGER 0 | 身份歧义标记 | 能力边界透明化 |
| 12 | `next_due_at` | TEXT NULL | 下次基础检测到期 | per-node 调度（Q5） |

> `last_valid_at` **不新增**（v0.1 有，v0.2 取消）：有效期改为逐目标存 `node_target_state`。
> 若采纳"过滤节点并入 nodes"方案，另加 `filtered INTEGER 0` + `filter_keyword TEXT`（见 §11.5，待确认）。

`nodes.status` 保留为**派生缓存**，由 `sync_legacy_status()` 单向写入；新逻辑一律不读它（R4）。

### 11.3 表清单（9 核心 + 1 可选 + 1 审计）

| 表 | 职责 | 必须独立？ | 可否复用 | 主键 | 关键外键 | 生命周期/保留 | 阶段 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `node_identities` | 身份及生命周期 | 是（missing 期必须存在） | 不可并入 nodes | id | airport_id | 长期；retired 后仍保留 | P0 |
| `node_config_versions` | 配置版本与参数快照 | 是 | 不可（nodes 只存当前） | id | identity_id | 长期 | P0 |
| `node_state_history` | 状态迁移解释 | 是 | 不宜塞 logs（需按节点查） | id | node_id, identity_id | 180 天 | P1 |
| `node_target_state` | 逐目标有效期与结果 | 是（R3 核心） | 不可（多目标多行） | id | node_id | 长期（覆盖式更新），历史在结果表 | P1 |
| `airport_fetch_versions` | 订阅版本与变化统计 | 是 | 不可（fetch_logs 无节点级明细） | id | airport_id | 180 天 / 至少 30 个 applied | P0 |
| `publish_versions` | 发布目录与审计 | 是 | 不可（share_history 无 manifest） | id | —（版本号唯一） | 30 个 | P3 |
| `detection_rules` | 规则版本快照 | 是 | 不可（结果需引用） | id | — | 长期 | P1 |
| `task_jobs` | 持久任务/幂等/恢复 | 是 | 不可 | id | — | done 30d / failed 90d | P2 |
| `system_events` | 系统/机场/目标/节点事件 | 是 | 与原 airport_events 合并 | id | airport_id?, node_id? | 180 天；未关闭永久 | P-1 建表，P0+ 使用 |
| `schema_migrations` | 迁移审计 | 是（审计需要） | 可退化为 `user_version` | version | — | 永久 | P-1 |
| `node_exit_observations`（可选） | 出口 IP 观测 | 可选 | 不可 | id | node_id | 90 天 | 待 C7 |
| ~~`airport_events`~~ | 已合并入 `system_events(scope='airport')` | — | — | — | — | — | — |

### 11.4 核心 DDL（修正版）

```sql
-- 身份
CREATE TABLE node_identities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  base_fingerprint TEXT NOT NULL,
  occurrence_key TEXT NOT NULL DEFAULT '',   -- sid:<id> | num:<n> | name:<h> | slot:<seq>
  occurrence_seq INTEGER NOT NULL DEFAULT 0,
  source_node_id TEXT,
  stable_id_seen_count INTEGER NOT NULL DEFAULT 0,   -- P0 证据门槛
  current_config_version INTEGER NOT NULL DEFAULT 1,
  lifecycle TEXT NOT NULL DEFAULT 'active' CHECK(lifecycle IN ('active','missing','retired')),
  first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  missing_since TEXT, retired_at TEXT,
  rotation_hint TEXT NOT NULL DEFAULT 'unknown' CHECK(rotation_hint IN ('unknown','list','exit','mixed')),
  related_identity_id INTEGER REFERENCES node_identities(id),
  ambiguous INTEGER NOT NULL DEFAULT 0, note TEXT
);
CREATE UNIQUE INDEX uq_identity ON node_identities(airport_id, base_fingerprint, occurrence_key);
CREATE INDEX idx_identity_life ON node_identities(airport_id, lifecycle);

-- 配置版本
CREATE TABLE node_config_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_id INTEGER NOT NULL REFERENCES node_identities(id),
  version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL, params_hash TEXT NOT NULL,
  params TEXT NOT NULL, protocol TEXT NOT NULL, server TEXT NOT NULL, port INTEGER NOT NULL,
  sample_raw_name TEXT,
  change_reason TEXT NOT NULL CHECK(change_reason IN
    ('initial','config_changed','stable_id_confirmed','readopt')),
  first_seen_at TEXT NOT NULL, last_seen_at TEXT, closed_at TEXT,
  UNIQUE(identity_id, version)
);

-- 状态历史
CREATE TABLE node_state_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  identity_id INTEGER NOT NULL, config_version INTEGER NOT NULL,
  from_state TEXT NOT NULL, to_state TEXT NOT NULL, lifecycle TEXT NOT NULL,
  reason_code TEXT NOT NULL, detail TEXT, rule_version INTEGER NOT NULL, ts TEXT NOT NULL
);
CREATE INDEX idx_state_node ON node_state_history(node_id, id DESC);

-- 逐目标状态（R3）
CREATE TABLE node_target_state (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  target TEXT NOT NULL,                     -- G / W / biz:<group_ident>
  config_version INTEGER NOT NULL, rule_version INTEGER NOT NULL,
  last_valid_at TEXT, last_result TEXT CHECK(last_result IN ('pass','fail','unknown')),
  failure_source TEXT, ttl_minutes INTEGER,
  consecutive_fail INTEGER NOT NULL DEFAULT 0,
  consecutive_pass INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  UNIQUE(node_id, target, config_version)
);
CREATE INDEX idx_tstate_target ON node_target_state(target, last_valid_at);

-- 订阅版本
CREATE TABLE airport_fetch_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  version INTEGER NOT NULL, trigger TEXT NOT NULL, fetched_at TEXT NOT NULL,
  http_status INTEGER, content_sha256 TEXT,
  parsed_count INTEGER NOT NULL DEFAULT 0, accepted_count INTEGER NOT NULL DEFAULT 0,
  added INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0,
  changed INTEGER NOT NULL DEFAULT 0, reappeared INTEGER NOT NULL DEFAULT 0,
  filtered_added INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL CHECK(status IN ('ok','suspect','rejected','fetch_error','parse_error','empty_subscription')),
  suspect_mode TEXT,                 -- normal|small_sample|new_airport|rolling_pool
  suspect_reason TEXT, consistency_count INTEGER NOT NULL DEFAULT 0,
  applied INTEGER NOT NULL DEFAULT 0, supersedes_version INTEGER,
  UNIQUE(airport_id, version)
);

-- 发布目录
CREATE TABLE publish_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  version INTEGER NOT NULL UNIQUE, created_at TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('ok','empty_confirmed','minimal','legacy_baseline')),
  node_count INTEGER NOT NULL, added INTEGER NOT NULL DEFAULT 0, removed INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT NOT NULL, health_version TEXT NOT NULL,
  airport_versions TEXT NOT NULL, rule_version INTEGER NOT NULL,
  manifest_path TEXT NOT NULL, dir_checksum TEXT,
  prev_version INTEGER, active INTEGER NOT NULL DEFAULT 0, recovered INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX uq_pub_active ON publish_versions(active) WHERE active=1;

-- 规则版本
CREATE TABLE detection_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rule_version INTEGER NOT NULL UNIQUE, created_at TEXT NOT NULL,
  scope TEXT NOT NULL DEFAULT 'global', payload TEXT NOT NULL,
  checksum TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, note TEXT
);

-- 任务
CREATE TABLE task_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('detect','biz','speed','publish','backup')),
  target_type TEXT, target_id INTEGER, idempotency_key TEXT NOT NULL, payload TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','done','failed','canceled','interrupted')),
  attempts INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 2,
  not_before TEXT, started_at TEXT, finished_at TEXT, heartbeat_at TEXT,
  worker TEXT, last_error TEXT, created_at TEXT NOT NULL,
  UNIQUE(idempotency_key)
);
CREATE INDEX idx_job_pick ON task_jobs(state, not_before, priority DESC);

-- 系统/机场/目标/节点事件（合并）
CREATE TABLE system_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scope TEXT NOT NULL CHECK(scope IN ('system','airport','target','node')),
  airport_id INTEGER REFERENCES airports(id), node_id INTEGER REFERENCES nodes(id),
  kind TEXT NOT NULL, level TEXT NOT NULL CHECK(level IN ('info','warning','critical')),
  first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  occurrences INTEGER NOT NULL DEFAULT 1,
  payload TEXT, immutable INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','closed')),
  closed_at TEXT, note TEXT
);
CREATE INDEX idx_se_open ON system_events(state, level);
CREATE INDEX idx_se_scope ON system_events(scope, airport_id, state);

-- 迁移审计
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL,
  checksum TEXT, duration_ms INTEGER,
  result TEXT NOT NULL CHECK(result IN ('ok','failed','rolled_back'))
);
```

### 11.5 过滤节点与 `nodes` 的身份迁移【修订 R8.3】

现状：`airport_filtered_nodes` 与 `nodes` 是两张表、各自自增 id；准入时 `INSERT nodes` + `DELETE filtered` → **旧 id 丢失**，历史与身份无法延续。

| 方案 | 做法 | 优点 | 代价 |
| --- | --- | --- | --- |
| **A（推荐）** | 并入 `nodes`：加 `filtered INTEGER`、`filter_keyword TEXT`，准入只 `UPDATE`，不搬行 | id 永不丢；身份统一；查询简单 | 前端/接口需兼容 `filtered`；`nodes` 行数增加（过滤节点也占行） |
| B | 保留两表，`filtered` 表加 `origin_node_id`，准入时按 origin 恢复 | 改动小 | 双表同步、历史仍可能断；两处身份逻辑 |
| C | 保留两表，准入时新建 node 但复制历史 | 无 | **不推荐**：伪造身份连续性 |

方案 A 需你确认（C2）。在确认前，P0 实现按 B 兜底（保证 id 不丢），不阻塞其他设计。

### 11.6 遗留 `tasks` 表调查结论【新增】

| 项目 | 结论 |
| --- | --- |
| 结构 | `id, name, status, started_at, finished_at, detail`（6 列，无索引） |
| 数据 | 演示库 0 行；仓库新库不存在该表 |
| 代码引用 | **无**（`grep -rn "tasks"` 只命中局部变量 `tasks = []`） |
| 来源 | v1.8.7 的 `SCHEMA` 未定义，属于旧版本残留 |
| 处理 | P-1 **不删除**；迁移时仅忽略并计入 `legacy_orphans` 报告；是否删除待观察一个 release（C3） |

### 11.7 真实生产规模调查【新增 R8.4】

v0.1 引用的 137 节点来自 `npdemo` 演示库，**不能代表生产**。P-1 增加一个只读普查（不在本阶段执行）：

```
读取（只读连接，不写）：
  airports 数量/启用数、nodes 数量/按机场分布、单机场最大节点数
  latency_results/results/speed_runs 行数与最老/最新时间
  DB 文件大小、-wal/-shm 大小
  airport_filtered_nodes 数量、重复配置组（fingerprint 相同）数量
输出 → 《生产库规模与重复配置普查报告》（人工确认后再定并发与保留参数）
```

在普查完成前，所有"默认值"仅作为工程默认，不作为容量承诺。

### 11.8 时间存储策略【新增 R8.7】

现状：所有业务时间用 `db.now()` 写本地时间（`Asia/Shanghai`），但清理用 `datetime('now')`（UTC）→ 偏差 8 小时（`db.py:583-585`）。

**决策（推荐，需确认 C4）**：**继续使用本地时间存储**，理由：现有百万级历史行、前端展示、评分窗口全部按本地时间；改 UTC 需要全表重写且易错。

配套硬约束：

1. 全库禁止 `datetime('now')`；统一 `db.now()` 与 `db.now_offset(days)`；
2. 迁移时增加启动断言：`abs(db.now() - 文件mtime) < 1h` 之类的一致性检查；
3. 新增表全部沿用本地时间；
4. 文档明确"DB 内时间为 UTC+8，接口输出 ISO8601 带 +08:00"。

### 11.9 外键与完整性

- **新表**全部声明外键；连接建立时 `PRAGMA foreign_keys=ON`。
- **旧表**（`results/latency_results/speed_*`）已有 `node_id` 但无外键，SQLite 无法在不重建表的前提下补 FK。处理：
  1. 不重建旧表；
  2. 以"软引用 + 周期校验"替代：维护任务每周跑一次孤儿检查（`node_id` 不存在于 `nodes`），发现则记 `system_events`，**不自动删除**；
  3. 删除节点一律禁止（只置 lifecycle），从根本上避免孤儿。

---

## 12. 历史数据迁移与兼容【修订 R4 / R8】

### 12.1 迁移原则（修订）

1. 只做加法；不改主键；不改指纹；
2. 备份 → 副本迁移 → 校验 → 原子替换；
3. 每一步以 `schema_migrations.version` 幂等；
4. **P-1 只做 M0/M1（安全底座与空表创建）**，业务回填 M2–M6 放到 P0/P1/P3，逐阶段执行；
5. 任何"推断历史"的字段，宁可留空/置 0，不伪造。

### 12.2 P-1 的迁移范围（收窄）

| 步骤 | 内容 | 阶段 |
| --- | --- | --- |
| M0 | `PRAGMA user_version` 初始化、备份、`schema_migrations` 建表 | P-1 |
| M1 | 只建 `schema_migrations` 与 `user_version`；**不建业务表、不加业务列**（各阶段自带建表） | P-1 |
| M2 | 身份与配置版本回填 | P0 |
| M3 | 状态与逐目标状态回填 | P1 |
| M4 | 结果版本/归因回填 | P1 |
| M5 | 基线发布版本与目录 | P3 |
| M6 | 规则版本 1、默认设置、时间断言 | P1/P-1 各半 |

### 12.3 状态回填规则（纠正 v0.1 错误）【修订 R4】

v0.1 曾写"`fail_streak = fail_count`"，**错误**：旧 `fail_count` 混入了引擎异常（实测 E4），不能当作连续有效失败。

**新规则（安全初始化）**

| 输入证据 | 映射 | 理由 |
| --- | --- | --- |
| 最近一次有效延迟结果（当前版本、非 engine 错误、TTL 内）双目标通过 | `state=healthy`, `fail_streak=0` | 有真实证据 |
| 最近一次结果在 TTL 内、至少一个目标失败且 `error_type != 'engine'` | `state=observe`, `fail_streak=1` | **最高只到 observe**，绝不进 unstable/unavailable |
| 最近结果已超 TTL，或只有 `engine` 错误 | `state=unknown`, `fail_streak=0` | 证据不足，宁可从零开始 |
| 无任何结果 | `state=unknown` | 同上 |
| 旧 `fail_count` | **仅写入 `legacy_fail_count` 审计列**（`system_events` payload 或迁移报告），不参与任何计算 | 保留统计价值，不参与判定 |

**关键约束**：迁移后不允许任何节点因历史数据进入 `unavailable`；首轮检测后按新规则自然归位。

### 12.4 `valid` 与 `rule_version=0` 的处理【修订 R4】

- 所有历史 `latency_results/results`：`rule_version=0`、`valid=0`、`config_version=1`、`failure_source=NULL`。
- 含义：**可查询、可统计、可展示，但永不获得发布资格**（资格要求 `valid=1` + 当前 rule_version）。
- 明确否定 v0.1 的"统一 `valid=1`"。
- 若 P1 需要"历史成功率"展示，单独按 `ok/error_type` 计算，标注"历史口径（v1）"，与当前判定口径分开。

### 12.5 升级瞬间的下发保护【新增，配合 R4】

因为历史结果 `valid=0`，升级后第一轮检测完成前 `publishable` 可能为 0。**不能**据此触发 `empty_confirmed`，也不能把订阅清空：

1. 迁移完成 → 写 `system_events(kind='migration_recovery', state='open')`；
2. 发布任务在 `migration_recovery` 期间**只读** active 版本、不生成新版本；
3. 解除条件：每个必需目标 `cov ≥ 90%`（§7.5）或 60 分钟到期（取先到者）；到期仍未覆盖 → 记 warning，继续保留 active 并延长 30 分钟；
4. 解除后关闭事件，按正常资格发布。

### 12.6 WAL / SHM / 连接替换步骤【新增 R8.8】

```
迁移前：
 1. 停止所有调度与后台协程（不再产生写）
 2. 关闭所有连接（thread-local 池全部 close）
 3. PRAGMA wal_checkpoint(TRUNCATE)   # -wal 归零
 4. 记录 db / db-wal / db-shm 大小与 mtime

副本迁移：
 5. sqlite3 backup API → db.migrating（含 WAL 内容，一致快照）
 6. 在 db.migrating 上执行迁移 + integrity_check + quick_check
 7. 行数比对（关键表）、外键抽查、索引存在性

替换：
 8. 关闭 db.migrating
 9. rename db → db.old ；rename db.migrating → db
10. 删除旧的 db-wal / db-shm（新库尚无 WAL；若不删，SQLite 可能回放旧 WAL）
11. 重开连接，执行 PRAGMA journal_mode=WAL + user_version 校验
12. 启动自检（仅 DB 级：open/write/read/integrity）

失败回滚：
13. 若 9–11 任一步失败：rename db.old → db，删除新 db 及其 -wal/-shm，恢复连接
14. 写 schema_migrations(result='failed') 与 system_events(migration_failed)
```

**必须验证**：目标文件系统（NAS/NFS/overlay）上的 `rename` 是否原子；若不原子（NFS 常见），改用"单文件 DB + 迁移期间停机 + 写前备份"，并在计划中标注该环境差异。

### 12.7 三种回退，必须分别说明【新增】

| 回退类型 | 场景 | 做法 | 数据影响 |
| --- | --- | --- | --- |
| **Schema 回退** | 迁移失败、校验不过 | 用 premigrate 备份整库替换；删除新表 | 回到迁移前 |
| **代码回退** | 新版本有 bug，但已写入业务数据 | 直接部署上一镜像；新列有默认值、旧代码忽略；`nodes.status` 仍被双写 | **不丢数据**，新功能数据暂不展示 |
| **数据回退** | 数据被误改/误删 | 选择备份恢复 + 重放迁移到当前 schema | 丢失备份点之后的数据 |

**版本兼容承诺**：P-1/P0/P1 的所有变更均为加法，允许"只回代码、不回库"。

---

## 13. 备份、恢复与升级保护（修订范围，方法沿用）

### 13.1 备份（未修订方法，明确 P-1 边界）

沿用 v0.1 §13.1 的每日/手动/迁移前/恢复前四类，保留数与校验流程不变。

### 13.2 P-1 只做"安全底座"【修订 R9】

P-1 交付范围：

1. `schema_migrations` + `user_version`；
2. 迁移前快照 + 校验（`quick_check` + 行数 + 抽样）；
3. copy-migrate-swap（§12.6）；**只迁移 schema 版本，不迁移任何业务表**；
4. 恢复接口的完整性校验（`integrity_check` + 表/列存在性 + schema 版本）；
5. 失败保护（原库不动、degraded 启动）；
6. 备份轮转与失败事件。

**P-1 不做**：完整自检体系、引擎/队列/磁盘巡检、`/healthz` 分级、启动自检门禁（全部留到 P6）。P-1 只保留一个"DB 可打开 + 迁移成功"的最小启动门禁。

### 13.3 升级流程（未修订）

`upgrade.sh` 先调备份接口并校验 manifest，失败中止；启动后迁移 + 最小门禁；critical 不启动调度。P6 再把门禁升级为完整自检。

---

## 14. 前端展示（修订补充）

沿用 v0.1 §14 的状态徽标、解释文案、机场事件时间线。本轮新增/调整：

1. **节点详情**：分目标展示 `G / W` 各自"最近有效时间 + 结果 + TTL 剩余"，过期目标用红色；不再显示单一"最近检测时间"作为资格依据。
2. **解释文案新增**："暂不下发：YouTube 目标结果已过期 47 分钟"（逐目标口径）。
3. **空订阅倒计时**：显示"计时中 / 已暂停（原因：引擎故障）/ 剩余 X 小时"，暂停时明确标注。
4. **订阅页**：当前生效版本来自指针；版本列表标注 `active`；增加"指针修复"事件提示。
5. **机场页**：`suspect_mode`（normal / small_sample / new_airport / rolling_pool）与"已确认 2/3 次"进度。
6. **身份歧义**：列表内标"同配置 ×N"，详情显示槽位号与"无法区分物理节点"的说明。
7. **迁移恢复期**：顶部横幅"升级后首次全量检测进行中，订阅保持上一版本"。

---

## 15. 已有成熟功能保留清单（未修订）

与 v0.1 §15 完全一致（21 项），并再次确认：

- 四种订阅格式与四个 URL 变体、UA 自适应、Token 鉴权**不变**；
- 两种 `sub_publish` 模式**都保留**；
- 测速面板操作能力与 50MB 上限、机场排除**不变**；
- Mihomo 检测、TCP 诊断、评分、过滤、前端布局**不变**；
- TCP-only 永不获得生产健康资格（本轮再次写死）。

---

## 16. 测试体系与场景覆盖（修订补充）

基础矩阵沿用 v0.1 §16.2（22 项）。本轮新增三组，必须随阶段交付：

| 组 | 场景数 | 阶段 |
| --- | --- | --- |
| 身份匹配 I1–I10（§4.8） | 10 | P0 |
| 状态机 S1–S11（§6.7） | 11 | P1 |
| 发布原子性 P1–P8（§10.7） | 8 | P3 |
| per-node 覆盖与零健康（新增） | 6 | P2/P3 |
| 小样本骤减保护（新增） | 5 | P0 |
| 迁移/回退（新增） | 6 | P-1/P5 |

**per-node 覆盖与零健康（6）**：

1. 60 分钟窗口内 95% 节点完成检测 → `cov ≥90%`，可判定零健康；
2. 部分节点未到期（覆盖率 70%）→ 不得确认零健康；
3. 引擎故障期间 → 窗口 invalid，不确认；
4. 机场 suspect 期间 → 该机场节点剔除，其余参与；
5. 零健康成立后重复任务跑 10 次 → `confirmed_at` 不变；
6. 24h 内恢复 1 个节点 → 事件 canceled、正常发布。

**小样本保护（5）**：新机场首拉、历史 2 天、baseline=6 骤减到 2、0 节点空壳、连续 3 次不一致。

**迁移/回退（6）**：fail_count 不映射、历史结果 valid=0、迁移中断原库不动、代码回退后旧功能可用、DB 恢复后重放迁移、WAL 残留清理。

---

## 17. 阶段边界与已确认决策引用【修订 R9】

### 17.1 边界（修正 v0.1 的两处越界）

| 阶段 | 交付 | 明确不做 |
| --- | --- | --- |
| **P-1** | 备份、schema 版本、迁移前快照、恢复验证、迁移失败保护、最小启动门禁、测试夹具 | 不建业务表、不做业务回填、不做身份/状态逻辑、不做完整自检 |
| **P0** | 身份匹配（R1）、配置版本（R2）、missing/retired、过滤节点 id 延续、机场版本表、小样本保护 | 不改状态机、不改发布门槛 |
| **P1** | 状态机（R3）、逐目标状态、有效结果、目标事故、TCP 边界、结果版本回填、`routes.py:1002` 修复 | 不改调度节奏、不改订阅格式 |
| **P2** | per-node 调度、task_jobs、配额、超时、重启恢复 | 不改判定、不改发布 |
| **P3** | 版本目录、单指针、四格式原子、去重、回滚、零健康 24h、基线版本 | 不改渲染内容 |
| **P4** | 业务 90 分钟独立、测速窗口迁移、源屏蔽窗口 | 不改测速算法、不改评分 |
| **P5** | 归档与清理、孤儿策略、规则版本历史、保留口径 | 不改判定阈值 |
| **P6** | 完整自检、`/healthz` 分级、启动门禁、升级保护与回退演练 | 不改业务表结构 |

### 17.2 已确认决策核对表

| 决策 | 本方案落点 | 状态 |
| --- | --- | --- |
| Q1 备份/迁移保护前置 | §13.2、§12.6、P-1 | 已遵循 |
| Q2 missing 30 天、最短 7、转 retired 保留历史 | §5 | 已遵循 |
| Q3 不改指纹 | §4.2 | 已遵循 |
| Q4 稳定 ID 优先、持久槽位、歧义记录 | §4.3–4.4 | 已遵循（并收紧名称用法） |
| Q5 每节点 30 分钟 + 抖动 | §7.1 | 已遵循 |
| Q6 业务 90 分钟、失败不影响健康 | §7.3、§10.1 | 已遵循 |
| Q7 测速 17–24、仅迁移旧默认、50MB | §7.4、§15 | 已遵循 |
| Q8 7 天中位数、50% 且 ≥10、两次确认 | §9.2 | 已遵循（未改 AND） |
| Q9 24h 上限、事件绑定 | §10.5 | 已遵循（新增暂停语义） |
| Q10 30 个版本、完整可恢复 | §10.2–10.3 | 已遵循（manifest + 四格式全存） |
| Q11 两次有效 Mihomo 成功、间隔 30 分钟 | §6.4/§6.5 | 已遵循 |
| Q12 表结构逐项审查 | §11 | 已遵循（11→9+1+1） |

---

## B. 设计修订对照表

| # | 原设计问题（v0.1） | 修订内容（v0.2） | 章节 | 是否完全解决 |
| --- | --- | --- | --- | --- |
| 1 | 身份匹配优先级与伪代码不一致；用"去编号哈希"；可能因顺序漂移 | 五级匹配（stable_id → 单候选 → 完整名精确 → 编号配对 → 持久槽位）；禁止去编号哈希与相似匹配；绑定持久化、冲突不覆盖；10 个测试 | §4.3、§4.4、§4.7、§4.8 | 是（物理身份不可知边界已显式声明） |
| 2 | 把所有 fingerprint 变化当作同身份新配置 | 8 行决策表；只有稳定 ID（连续 2 次）才升 config_version；同端点同名只记"疑似关联"，列为待确认 | §4.6、C1 | 是（保留了能力但降级为待确认） |
| 3 | 单一 `last_valid_at`，Google 新鲜可替 YouTube 背书 | 新增 `node_target_state`；逐目标 TTL/结果/版本；资格逐目标短路；11 个状态机测试 | §6、§10.1、§11.3 | 是 |
| 4 | `fail_streak = fail_count`；历史结果统一 valid=1 | 历史只到 `observe`；`valid=0`、`rule_version=0`；fail_count 仅审计；新增迁移恢复期保护 | §12.3、§12.4、§12.5 | 是 |
| 5 | 四格式仍逐个替换，可能跨版本混合 | 版本目录一次落盘 + `active.json` 单指针；读者只认指针；取消 `sub_all.*` 发布源；崩溃矩阵与修复；8 个测试 | §10.2–10.3、§10.7 | 是 |
| 6 | "历史不足 3 天不保护"是漏洞 | 四种情形独立策略；小样本 3 次确认/人工；0 节点一律人工；一致性的可执行判定标准 | §9.3 | 是 |
| 7 | 用"批次覆盖率"判零健康，per-node 下失效 | 滚动覆盖窗口、逐目标 cov≥90%、两次评估、事件绑定 24h、暂停/恢复/到期重验 | §7.5、§10.5 | 是 |
| 8 | 表数量与字段注释不一致；未调查 tasks；过滤节点丢 id；规模误判；时间/WAL/回退缺失 | 12 字段逐列解释；11→9+1+1；tasks 调查结论；过滤两方案；规模普查；时间策略；WAL 13 步；三类回退 | §11、§12 | 大部分是（3 项转 C2/C3/C4） |
| 9 | P-1 越界（自检骨架 + 全部业务迁移） | P-1 只做安全底座与最小门禁；业务迁移拆到 P0/P1/P3/P5；自检留 P6；Q1–Q12 核对表 | §13.2、§17 | 是 |

---

## C. 待确认事项（只列真正未决的）

> Q1–Q12 已确认，不再列入。

### C1｜"同端点 + 同名 + 指纹变化"是否允许自动判为同一身份的新配置版本？

- **问题**：机场只轮换密钥/参数（server:port 与名称不变），是否视为同一节点升级了 config_version？
- **为什么不能直接定**：这是推断，不是证据；误判会把 A 节点的历史挂到 B 节点，且无法回退。
- **推荐**：**不自动**。按 §4.6 第 4 行处理：新身份、旧身份 missing、只记 `probable_successor`。等有了"多因子连续性判定"（两次拉取一致 + 参数差异类型白名单 + 稳定性）再开。
- **其他方案**：A. 首轮自动、失败回滚（风险最高）；B. 仅当该机场历史从未出现"同端点同名多实例"时自动（需机场画像）。
- **风险**：不自动 → 机场正常轮换密钥时身份会换一次，历史断开（但可解释、可关联）；自动 → 静默错挂历史，最危险。

### C2｜过滤节点与 `nodes` 是否合并（§11.5 方案 A / B）

- **问题**：为保住旧 id，是否把 `airport_filtered_nodes` 并入 `nodes`（加 `filtered` 列）。
- **为什么不能直接定**：会改变现有表语义与前端/接口行为，属于"成熟功能改造"，需你授权。
- **推荐**：A（并入，id 永不丢，逻辑单一）。
- **其他**：B（保留两表 + `origin_node_id`），改动小但双表同步。
- **风险**：A → 过滤节点占 `nodes` 行数、需改前端筛选；B → 长期双实现，仍有断链风险。

### C3｜遗留 `tasks` 表何时清理

- **问题**：空表、无引用、旧版本残留，是否随 P-1 删除。
- **为什么不能直接定**：无法 100% 确认旧版本是否有外部脚本/备份流程依赖。
- **推荐**：保留一个 release 周期（P6 后）再删；期间只读忽略。
- **风险**：留着 → 无害但混淆；删早 → 若有外部依赖会静默破坏。

### C4｜数据库时间策略：继续本地时间 + 统一 helper，还是迁移为 UTC

- **问题**：现有全库本地时间（UTC+8），清理代码用 UTC 导致偏差。
- **为什么不能直接定**：改 UTC 要重写历史时间字段与所有查询，属高风险全局变更。
- **推荐**：保留本地时间；禁用 `datetime('now')`；统一 `db.now()/now_offset()`；加启动一致性断言。
- **其他**：全库迁 UTC + 展示层转换（正确性最好，工作量与风险最大）。
- **风险**：保留 → 需要严格代码纪律（已用 lint 规则约束）；迁 UTC → 迁移窗口长、易出现混合时区。

### C5｜`node_target_state` 是否纳入业务目标

- **问题**：业务目标（ChatGPT/YouTube/Telegram）是否也写逐目标状态表。
- **为什么不能直接定**：写 → 表行数上升（节点×标签）；不写 → 业务标签新鲜度仍需单独计算。
- **推荐**：**写**，但只用于展示与命名（`target='biz:<ident>'`），不进资格。
- **风险**：写 → 行数约 `节点数 × (2 + 标签数)`，百级节点可接受；不写 → 命名"过期标签"逻辑要重复实现。

### C6｜`empty_confirmed` 暂停期间是否计入 24 小时

- **问题**：系统/机场异常导致无法判定时，24h 是继续走还是暂停。
- **为什么不能直接定**：继续走 → 异常期间可能"到期发布空订阅"，风险高；暂停 → 需定义暂停上限。
- **推荐**：**暂停并顺延**（`paused_ms`），同时设硬上限 72 小时，超过则强制人工确认。
- **风险**：暂停 → 旧订阅保留时间变长；不暂停 → 异常误伤订阅。

### C7｜出口观测模块是否启用（原 D9）

- **问题**：不启用则"出口轮换"只能记为 unknown，无法满足识别要求。
- **为什么不能直接定**：需额外出口流量与外部端点依赖。
- **推荐**：默认关闭，作为可选能力；开启时低频（6h/抽样 20%）。
- **风险**：关闭 → 出口轮换不可识别（但不会误判）；开启 → 少量流量与外部依赖。

### C8｜发布指针与 DB 的最终权威（已给推荐，需你确认）

- **问题**：§10.2 定"文件指针权威、DB 为镜像"，是否需要反过来。
- **推荐**：指针权威。理由：切换必须是单文件原子操作；DB 事务无法与文件目录原子绑定。
- **风险**：指针权威 → DB 短暂滞后（可由启动重建修复）；DB 权威 → 切换需两阶段，崩溃窗口更大。

---

## D. 修订后仍然存在的风险与验证场景

| # | 风险 | 触发 | 缓解 | 验证场景 |
| --- | --- | --- | --- | --- |
| 1 | 同配置多节点物理身份不可知 | 无 stable_id、名称不可区分 | 槽位锚定 + 歧义标记 + 导出 | I4、I9 |
| 2 | 名称互换被当成改名 | 机场把两节点名字对调 | 保持既有绑定、记 `name_swap_suspected`，不合并历史 | I2/I3 |
| 3 | stable_id 被机场复用 | 机场把旧 id 给新节点 | P0 要求连续 2 次一致；冲突时旧身份 missing + 事件 | I5、冲突用例 |
| 4 | 指纹变化导致历史断开 | 密钥轮换、参数改版 | 新身份 + `probable_successor`；不静默合并 | I7、C1 |
| 5 | 逐目标有效期导致"半新半旧"节点被下发 | 只判节点级 | 资格逐目标短路 | S9 |
| 6 | 小机场保护过度阻塞真实变化 | baseline 小、人工未处理 | 3 次确认 + 人工出口 + 事件升级 | 小样本 5 例 |
| 7 | 空壳 200 响应被当真实变化 | CDN 错误页 | 0 节点一律人工确认 | 空壳用例 |
| 8 | 发布指针损坏/DB 滞后 | kill -9、磁盘满 | checksums 校验 + 启动修复 + DB 重建 | P3/P4/P5 |
| 9 | 读者在切换瞬间读到混合版本 | 并发读 | 只读指针 + 单目录，禁止读 `sub_all.*` | P6 |
| 10 | 迁移中断 | 断电/磁盘满 | copy-migrate-swap + premigrate 备份 | 迁移 6 例 |
| 11 | 代码回退后新列/新表干扰 | 回滚镜像 | 加法式 schema、`status` 双写、旧代码忽略 | 代码回退用例 |
| 12 | 升级后首轮检测前订阅被清空 | `valid=0` 导致 0 可发布 | `migration_recovery` 期只读 active | §12.5 用例 |
| 13 | 24h 计时被后台任务刷新 | 重复评估 | 事件不可变 + `confirmed_at` 只写一次 | 零健康第 5 例 |
| 14 | 时间口径混乱 | 混用 `datetime('now')` | 统一 helper + lint 规则 | 清理边界用例 |
| 15 | 索引/外键缺失导致慢查询与孤儿 | 历史表无 FK | 周期孤儿检查 + 不删节点 | P5 用例 |

---

**阶段 1 修订到此结束。** 未改代码、未建迁移文件、未跑迁移、未动生产配置、未开始 P-1。请先确认 C1–C8（至少 C1、C2、C4、C8），我再出 P-1 的实施计划；批准后才进入实施。
