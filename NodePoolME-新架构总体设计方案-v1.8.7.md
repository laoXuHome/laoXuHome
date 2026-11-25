# NodePoolME 新架构总体设计方案

**文档版本**：v0.1（阶段 1 交付，待审阅）
**代码基准**：`v1.8.7` / `e721797`（`backend/config.py:6`）
**前置文档**：《NodePoolME 现有架构审查报告（阶段 0）》
**决策依据**：Q1–Q12 确认结果 + 《NodePoolME 新架构总体设计与分阶段重构任务书》
**本阶段边界**：纯设计。未修改代码、未改数据库、未创建迁移文件、未改配置、未执行重构。

---

## 0. 设计摘要

一句话：**保留"检测 → 判定 → 命名 → 出订阅"这条成熟主干，在它外面加三样东西——身份、时间、版本。**

1. **身份层**：`nodes` 从"身份载体"降级为"当前配置快照"，身份与配置版本独立成表；节点消失不再删除，进入 `missing`（默认 30 天）。
2. **时间层**：每个节点有自己的 `next_due_at`（30 分钟 ± 抖动）；每条结果有 `config_version` + `rule_version` + `valid_at` + `failure_source`；过期即失去下发资格。
3. **版本层**：每次真实发布生成不可变版本（保留 30 个，含完整节点配置 manifest），内容哈希去重，指针原子切换，回滚=生成新版本而不是改写历史。

四条硬边界：指纹算法不改；主键不改；不引入外部数据库/消息队列/多进程；TCP 回退只做诊断，永不获得健康资格。

---

## 1. 新旧架构对照

| 维度 | v1.8.7 现状（代码位置） | 目标架构 | 变化级别 |
| --- | --- | --- | --- |
| 节点身份 | 身份 = `nodes` 行 = `(airport_id, fingerprint)`，`db.py:50-67`；消失即硬删，`fetcher.py:224-231` | 身份 `node_identities` 独立、长期；`nodes` 只存当前快照 | **新增**（不动指纹） |
| 配置历史 | 无；改名靠 UPSERT 覆盖 `raw_name`，`fetcher.py:133-144` | `node_config_versions` 记录每一版配置与生效区间 | **新增** |
| 节点消失 | 当次 DELETE（实测 E2） | `lifecycle=missing`，30 天后 `retired`，历史不动 | **改语义** |
| 健康状态 | `available/unavailable/unknown` 三态，`manager.py:226-249`、`310-334` | 6 态 + `stale` 正交标记，含观察与恢复确认 | **增强** |
| 失败计数 | 任意失败 `fail_count++`，含引擎异常（实测 E4） | 仅 `failure_source=node` 计入；系统类只记事件 | **改语义** |
| 结果时效 | 无；10 天前结果仍可下发（实测 E4） | `last_valid_at + ttl`，默认 90 分钟 | **新增** |
| 结果版本绑定 | 仅 `node_id/batch_id/target`，`db.py:129-166` | 加 `config_version/rule_version/started_at/failure_source/engine` | **增强** |
| 检测节奏 | 全局批次，统一 `test_interval_minutes`，`manager.py:465-599` | 每节点 `next_due_at` + 抖动 + 优先级 | **改调度** |
| 业务检测 | 随基础批次全跑，`manager.py:421-433`；`interval_minutes` 为死字段 | 独立 90 分钟调度，可按键值配置 | **改调度** |
| 测速 | 窗口 18:00–23:30，`config.py:123-124` | 17:00–24:00，仅迁移旧默认值 | **改默认** |
| 并发 | 全局/标签/IP/网段，`manager.py:337-391` | 增加"单机场"与"单目标"，统一配额表 | **增强** |
| 任务持久化 | 全内存：`state`、`speed_queue.jobs`、`runtime_gate` | `task_jobs` 落库，幂等键，重启可恢复 | **新增** |
| 订阅发布 | 逐格式 `os.replace` + 单一 `meta.json`，`builder.py:852-935` | 版本目录 + manifest + 内容哈希 + 指针原子切换 | **新增** |
| 发布回滚 | 无 | 版本列表 + 回滚（带资格重校验） | **新增** |
| 零健康节点 | 无限期保留旧订阅，`builder.py:884-895` | 三分支：异常不发布 / 确认零健康 24h 收敛 / 超时出最小订阅 | **改语义** |
| 机场异常 | 仅 `last_status` + `fetch_logs` | 版本表 + 事件表 + suspect 两次确认 + 人工接受 | **新增** |
| 备份 | 手动、无轮转、无完整性检查，`routes.py:1416-1480` | 自动 + 轮转 + 校验 + 迁移前快照 + 恢复验证 | **增强** |
| 迁移 | 启动时线性 ALTER，无版本无回滚，`db.py:314-485` | `schema_migrations` + copy-migrate-swap | **增强** |
| 自检 | `/healthz` 恒 ok，`routes.py:1603-1611` | ok/degraded/critical 三级 + 周期自检 | **新增** |
| 前端 | 3 态筛选、机场页、订阅页 | 增加 missing/observe/recovering/stale、版本页、解释文案 | **增强** |
| 成熟能力 | 解析、Mihomo、四格式、测速、评分、过滤 | **全部保留，不改行为** | **不变** |

---

## 2. 总体模块划分

### 2.1 分层（自上而下，纵向）

```
① 接入层
   api/routes.py（拆分：airports / nodes / publish / system / settings）
   保留现有 URL，新增只增不改

② 编排层（唯一"状态改变"入口）
   core/work_scheduler.py    每节点到期计算、优先级、配额、组批
   core/task_queue.py        task_jobs 持久化、幂等、重启恢复
   core/runtime_gate.py      引擎改写互斥（沿用）
   scheduler/manager.py      批次执行者（保留，瘦身为"跑一批"）

③ 领域层（纯函数/纯服务，不写 HTTP）
   lifecycle/identity.py     身份解析、配置版本、缺失/恢复
   health/state_machine.py   状态迁移唯一写入口
   health/validity.py        有效结果定义、失败分类、目标事故
   fetch/service.py          下载、版本、变化统计、suspect 判定
   publish/versioning.py     资格、manifest、原子切换、回滚
   scoring/*                 评分（不动）

④ 基础设施层
   testers/engine.py         Mihomo / TCP（TCP 仅诊断）
   testers/speedtest.py      测速（不动算法）
   database/db.py            Schema、迁移、连接、日志
   backup/service.py         备份/恢复/校验
   selfcheck/service.py      自检
```

### 2.2 新增目录（仅 5 个包，不重排现有文件）

```
backend/
  lifecycle/__init__.py, identity.py, resolver.py
  health/__init__.py, state_machine.py, validity.py
  publish/__init__.py, versioning.py, manifest.py
  core/__init__.py, work_scheduler.py, task_queue.py
  backup/__init__.py, service.py
  selfcheck/__init__.py, service.py
```

现有 `services/fetcher.py`、`services/speed_queue.py`、`subscriptions/builder.py`、`scheduler/manager.py` **原位保留**，按阶段逐步把职责"搬进新包"，搬迁完成前旧函数仍是唯一实现（避免双实现）。

### 2.3 依赖规则（评审硬约束）

1. 依赖只能向下：`api → core/scheduler → domain → infra`；禁止 domain 反向 import api。
2. 状态只有一个写入口：`health.state_machine.transition()`；其他模块只能读。
3. 身份只有一个解析入口：`lifecycle.identity.resolve_snapshot()`；`fetcher` 不再直接算身份。
4. 结果只有一种落库形状：所有检测写 `detection results` 时都必须带 `config_version/rule_version/failure_source`，由 `health.validity` 统一校验。
5. 禁止在 domain 层直接调用 `builder.publish()` 以外的方式写 `data/sub/`。

---

## 3. 模块职责与依赖关系

| 模块 | 职责（做什么） | 明确不做什么 | 依赖 | 复用现状 |
| --- | --- | --- | --- | --- |
| `core/work_scheduler` | 计算每个节点/每个标签的 `next_due_at`，按优先级组批，发任务 | 不做判定、不写状态 | task_queue, db, settings | 替代 `job_cycle` 的"全量快照"逻辑 |
| `core/task_queue` | `task_jobs` CRUD、幂等、重试、心跳、重启恢复 | 不执行业务 | db | 替代 `speed_queue.jobs` 内存队列 |
| `lifecycle.identity` | 快照 → 身份/配置版本/缺失/恢复；歧义标记 | 不判断健康 | db, parser.fingerprint | 复用 `fingerprint()`，新增 resolver |
| `health.validity` | 判定一条结果是否"有效"、失败归因、目标事故 | 不改状态 | db, engine outcome | 复用 `Outcome.error_type` 并扩展 |
| `health.state_machine` | 状态迁移、`fail_streak/success_streak`、`stale` 计算 | 不做探测 | db, detection_rules | 替代 `_apply_latency_gate` / `_record` 中的状态段 |
| `fetch.service` | 下载/解析/版本/变化统计/suspect | 不直接改 `nodes` | parser, db, identity | 扩展现有 `fetcher` |
| `publish.versioning` | 资格集合、manifest、哈希、版本目录、指针、回滚 | 不探测 | builder(渲染), db | 扩展现有 `publish` |
| `testers.engine` | 真实探测、错误分类、引擎状态 | 不判定健康 | mihomo | 保留；TCP 降级改为"显式降级" |
| `scheduler/manager.py` | 执行一个批次块、进度、暂停/停止 | 不再决定"测谁" | core, health, engine | 保留外壳 |
| `backup.service` | 备份、轮转、校验、恢复、迁移前快照 | 不改业务表 | db | 扩展 routes 中的散装实现 |
| `selfcheck.service` | 周期自检、事件、`/healthz` 数据源 | 不修数据 | db, engine, queue | 新增 |

---

## 4. 节点身份与配置版本模型

### 4.1 三个概念分离

| 概念 | 回答的问题 | 载体 | 生命周期 |
| --- | --- | --- | --- |
| **identity** | "这是同一台物理/逻辑节点吗" | `node_identities` | 长期（含 missing/retired） |
| **config_version** | "它现在用的是哪一版配置" | `node_config_versions` | 长期，随配置变化递增 |
| **node 行** | "当前这一版配置的运行时快照" | `nodes` | 随身份状态变化 |

> 关键：`nodes.id` 仍是运行期句柄（前端、结果表外键都用它），**不改变主键**。身份通过 `nodes.identity_id` 关联；配置版本通过 `nodes.config_version` 关联。节点消失时 `nodes` 行保留（`lifecycle=missing`）；超过保留期只把 `lifecycle` 改为 `retired`，**行不删除**（否则 `node_state_history` 与结果表的外键会失去锚点）。

### 4.2 基础键：指纹（不改算法）

`fingerprint(protocol, server, port, params 子集)`（`parsers/subscription.py:94`）继续作为 `base_fingerprint`。
**本次不改任何参与字段。** 若未来要改，按 Q3 走"双指纹（`fingerprint` + `fingerprint_v2` 并存 + 过渡期）"方案，另立设计。

### 4.3 occurrence 区分键（解决 Q4 与实测 E3）

同一机场内 `base_fingerprint` 相同的多条节点，需要 `occurrence_key` 区分。解析优先级（**严格按此顺序，命中即停**）：

| 优先级 | key 形态 | 来源 | 适用 |
| --- | --- | --- | --- |
| 1 | `id:<stable_id>` | 机场/订阅链接自带稳定 ID（如 `#id=` 或参数中的节点 id） | 当前解析器未提取，先留能力位（`source_node_id`），不假设存在 |
| 2 | `num:<编号>` | 名称归一化后**唯一**的编号 token（`香港01`、`美国-3`、`(2)`） | 名称含稳定编号 |
| 3 | `name:<sha1(归一化名)>` | 完整归一化名（去国旗/表情/限速前缀/机场后缀，保留主体与编号） | 名称稳定且组内唯一 |
| 4 | `ord:<seq>` | 首次观测顺序序号，持久化在 `node_identities.occurrence_seq` | 前三者都不可用 |

**归一化规则**（只在身份比较时使用，不改变展示名）：
1. 去首尾空白、全角转半角；
2. 去 emoji/国旗/装饰符号；
3. 去限速前缀（`[1x]`、`2x`、`倍率`、`100M` 等，复用现有 `strip_speed_prefix` 思路，不新增规则）；
4. 去机场后缀（`·XX机场`、`|XX`）；
5. 剩余文本小写化后取 SHA1 前 16 位。

### 4.4 每次拉取的匹配流程（伪代码，供 P0 实现）

```
for each returned node in airport:
    base = fingerprint(node)
    group = identities where airport_id=a and base_fingerprint=base

    # 1) 稳定 ID
    if node.source_node_id and group has identity with same source_node_id:
        bind; continue
    # 2) 编号键
    if numkey(node) and group has identity with same occurrence_key:
        bind; continue
    # 3) 同名延续（rename 的反向保护）
    if group has unbound identity whose current raw_name == node.raw_name:
        bind; continue
    # 4) 归一化名键
    if group has unbound identity with occurrence_key == name:<sha1>:
        bind; continue
    # 5) 新成员：按首次观测顺序追加
    create identity(occurrence_seq = max+1, occurrence_key = ord:<seq>)
```

**收尾**：本次未被绑定的 identity → `lifecycle=missing`；`nodes` 行保留，`state` 冻结，`missing_since=本次拉取时间`。

**歧义处理**（Q4 第 5 条）：
- 若第 5 步创建时，组内已有 `missing` 身份且其旧名与本次某条"仅编号不同" → 不自动合并，记 `identity_ambiguous` 事件，`nodes.ambiguous=1`。
- 若同名延续命中，但该 identity 的 `missing_since` 距今 < 30 天 → 走"恢复"流程（见 §5.3），不是新建。
- 任何情况下不得把旧 identity 的历史改挂到新 identity。

### 4.5 配置版本判定（"不能把 fingerprint 变化都当成同一身份的新配置"）

同一身份下是否新建 `config_version`，按证据分级：

| 证据 | 判定 | 结果 |
| --- | --- | --- |
| 指纹完全相同（仅名称变） | 同身份、同配置 | 记 `rename` 事件，`config_version` 不变（Q 补充约束 1） |
| 指纹变 + 同一 `source_node_id` | 同身份、新配置 | `config_version+1`，`reason=config_changed` |
| 指纹变 + `server:port` 不变 + 归一化名不变 | 同身份、新配置（密钥/参数轮换） | `config_version+1`，`reason=params_rotated` |
| 指纹变 + `server:port` 变 + 名不变 | **疑似迁移**，不自动合并 | 旧身份→missing；新身份创建；记 `probable_successor_of` 关联（仅供展示/分析） |
| 指纹变 + 名与端点都变 | 新身份 | 旧身份→missing |
| 指纹变 + 有编号键可对齐 | 同身份、新配置 | `config_version+1`，`reason=enumerated_change` |

**旧配置结果的处理**：`config_version` 一变，旧版本的检测结果**不参与新版本判定**（`health.validity` 校验 `result.config_version == node.config_version`），但完整保留供追溯。这正是任务书"旧检测结果不能污染新配置"的落地点。

### 4.6 重复配置与"物理身份不可知"的边界（必须写进文档与 UI）

- `ord:` 键意味着：**同配置、无任何稳定区分属性的节点，系统只能保证"不来回抖动"，不能保证物理上一一对应**。UI 对这类节点显示"同配置 × N，身份按首次观测锚定"。
- 该限制已在 Q4 中确认，不作为缺陷，但要可解释、可导出（`GET /api/nodes?ambiguous=1`）。

---

## 5. 节点生命周期模型

### 5.1 三态定义

| lifecycle | 含义 | 参与检测 | 参与下发 | 历史保留 |
| --- | --- | --- | --- | --- |
| `active` | 最近一次**被接受的**拉取结果里存在 | 是 | 是（还需健康资格） | 是 |
| `missing` | 连续缺席，但仍在保留期内 | 否 | 否 | 是（全量） |
| `retired` | 超过保留期，或人工归档 | 否 | 否 | 按历史策略（见 §12.5） |

### 5.2 进入/退出条件

| 迁移 | 触发 | 副作用 |
| --- | --- | --- |
| `active → missing` | 一次**被接受**的拉取中不存在该身份/配置 | `missing_since=now`；冻结状态；撤销其在队列中的待办；写状态历史 |
| `missing → active` | 重新出现且身份匹配（§4.4 命中同一 identity） | 配置一致：恢复原 `config_version` 与状态机；配置不同：新建版本并回到 `unknown` |
| `missing → retired` | `now - missing_since > missing_retention_days`（默认 30，最短 7） | 写 `retired_at`；`nodes` 行归档（保留但标记）；不再计入任何统计 |
| `active → retired` | 人工归档 / 机场被删除 | 同上，额外 `airport_removed=1` |
| `retired → active` | 重新出现且身份匹配 | 允许恢复，但状态从 `unknown` 重新开始（不继承旧的 Healthy） |

### 5.3 "消失后恢复"的正确语义

1. 配置一致（同 `config_version`）→ 恢复原身份与版本，状态进入 `unknown`，因为期间没有有效结果；**不直接恢复 Healthy**，等首次有效检测（Q11 精神一致）。
2. 配置不同（新版本）→ 旧版本 `closed_at`，新版本 `unknown`，旧结果保留。
3. 期间历史评分仍可查询，但不参与任何"当前"判定。

### 5.4 与评分的关系

评分只读 `identity_id` 维度历史（跨配置版本），只用于展示与排序，**不写入任何资格位**。`missing`/`retired` 期间的历史不删除、不参与 7 天窗口的"当前质量"计算。

---

## 6. 健康状态机与"有效检测结果"

### 6.1 有效检测结果的定义（先定义，再谈状态）

一条结果要能改变健康状态，必须**同时**满足：

1. `engine == "mihomo"` 且该次探测真实经过代理（TCP 回退恒不满足）；
2. `config_version == node.config_version`；
3. `rule_version == 当前生效规则版本`；
4. 探测完成（非 `canceled`、非批次中断、非进程重启丢弃）；
5. `failure_source != engine/scheduler/system`；
6. 不计入"目标事故"窗口（见 §6.3）；
7. `started_at` 与 `finished_at` 均存在，且节点在结束时仍是同一 `identity_id + config_version`（结束时复核，对应任务书 7 节）。

不满足的结果：**照常入库**（用于诊断与追溯），标记 `valid=0`，**绝不改变** `fail_streak/success_streak/state`。

### 6.2 状态机（6 态 + stale）

符号：`T = fail_threshold`（默认 3，沿用 `settings.fail_threshold`）；`R = recover_confirm_count`（默认 2）；`GAP = recover_confirm_gap_minutes`（默认 30）。

```
                    valid pass (streak=0)
        ┌──────────────────────────────────────────┐
        │                                          │
     Unknown ──valid fail(1..T-2)──► Observe ──valid fail(T-1)──► Unstable
        │                              │                            │
        │                              │ valid fail(T)              │ valid fail(T)
        │                              ▼                            ▼
        └────────────────────────► Unavailable ◄────────────────────┘
                                       │
                        valid pass #1  │  (进入恢复观察)
                                       ▼
                                   Recovering
                                       │ valid pass #2 且 间隔 ≥ GAP
                                       ▼
                                    Healthy
```

| 状态 | 进入条件 | 退出条件 | 可下发 | 说明 |
| --- | --- | --- | --- | --- |
| `unknown` | 新身份/新配置版本/迁移回填/`retired→active` | valid pass → Healthy；valid fail → Observe | 否 | 对应任务书"新节点未完成首次有效检测不得下发" |
| `healthy` | 从 unknown/observe/unstable 得到 valid pass；或 Recovering 第 2 次通过 | valid fail → Observe（`fail_streak=1`）；stale 到期 → 仅置 stale，不改状态 | 是（且非 stale） | 一次失败留在 healthy 之外的 observe，避免抖动 |
| `observe` | 第 1 次 valid fail（`1 ≤ streak < T-1`） | valid pass → Healthy；再失败到 `T-1` → Unstable | 是（若 `last_valid_at` 未过期） | 单次失败不摘节点，符合"一次失败不能立即认定不可用" |
| `unstable` | `streak = T-1`（默认 2） | valid pass → Healthy；valid fail → Unavailable | 否 | 连续两次失败先停发，但保留快速回升路径 |
| `unavailable` | `streak ≥ T` | valid pass → Recovering | 否 | 只有有效失败能到这里，系统故障不会 |
| `recovering` | 从 unavailable 得到第 1 次 valid pass | 第 2 次 valid pass 且间隔 ≥ GAP → Healthy；valid fail → Unavailable | 否 | 满足"不能凭一次成功立即恢复" |
| `stale`（正交） | `now - last_valid_at > result_ttl_minutes` | 新的 valid 结果写入即清除；状态不变 | **否** | 与状态并存，UI 显示"状态：Healthy（结果过期）"；不因过期把状态改坏 |

补充规则：
- `T=1` 时无 observe/unstable，直接 unavailable；`T=2` 时 observe 只有 1 档。
- `recovering` 期间任何 invalid 结果不影响；valid fail 立即回 unavailable。
- `retired`/`missing` 不是健康状态，是生命周期，与状态正交。
- 状态每次迁移写 `node_state_history`（from/to/reason/rule_version），并在 `state_since` 上留时间。

### 6.3 失败归因（`failure_source`）

| 取值 | 触发 | 计入 streak | 处理 |
| --- | --- | --- | --- |
| `node` | mihomo 探测：connect/timeout/status/body 异常，且非目标事故 | 是 | 正常状态机 |
| `probe_url` | 探测 URL 本身不可用（DNS/证书/连续多节点同错且目标外部可达） | 否 | 记事件，考虑换探测点；不改状态 |
| `target_incident` | 同一目标在本批次内 ≥30% 且 ≥10 个节点同错，且外部直连该目标异常 | 否 | 开 `target_incident` 事件，冻结该目标结果，冷却 15 分钟后复检 |
| `engine` | mihomo 未启动/重载失败/端口异常 | 否 | 引擎故障事件；本批结果标 `valid=0` |
| `scheduler` | 批次超时、被暂停/停止、进程重启 | 否 | 批次事件；不补罚 |
| `system` | DB 写失败、磁盘满、时钟跳变 | 否 | 系统事件；结果标 invalid |
| `canceled` | 用户停止 | 否 | 不入状态机 |

**目标事故判定**（P1 新增，解决"目标站故障误伤节点"）：
- 仅对同一 `test_target` 在同一批次块内聚合；节点数 <10 不启用（避免小样本误判）。
- 触发后：该目标本批结果全部 `valid=0, failure_source=target_incident`；写 `system_events(kind=target_incident)`；冷却期内该目标只做 1 个"探针节点"复检。
- 冷却结束且探针通过 → 关闭事件，恢复正常判定；探针也失败 → 继续冷却并升级告警。

### 6.4 TCP 回退安全边界（任务书补充约束 2，高优先级）

| 场景 | 允许 | 禁止 |
| --- | --- | --- |
| Mihomo 正常 | 参与健康判定 | — |
| Mihomo 不可用，TCP 可连 | 记录 `engine=tcp`、`valid=0`，作为"连接层诊断"展示 | **不得**产生 valid pass/fail；**不得**获得下发资格 |
| Mihomo 启动失败 | 写 `system_events(engine_down)`；`/healthz=degraded`；批次可继续但全部结果 invalid | **不得**静默降级后照常发布 |
| 启动时只有 TCP 可用 | 允许网页可用（诊断模式），订阅发布**暂停**并明确提示 | 不得生成"全部通过"的订阅 |

具体改动点（P1 落地）：`engine.py:284-296` 的自动降级改为"降级 + `state.degraded=True` + 事件"；`manager` 在 `engine != mihomo` 时不写 `fail_streak`、不产生资格、不触发 `publish`；前端顶部常驻红色横幅。

---

## 7. 三类检测的独立调度设计

### 7.1 时间模型（统一用"到期时间"，不用"全局周期"）

所有时间存本地时区字符串（沿用现状），但计算统一在 `Asia/Shanghai`。

| 任务 | 到期字段 | 默认频率 | 抖动 | 说明 |
| --- | --- | --- | --- | --- |
| 基础健康检测 | `nodes.next_due_at` | 30 分钟 | ±10%（±3 分钟）+ 节点哈希固定偏移 0–180s | 每节点独立（Q5） |
| 业务检测 | `test_groups.next_due_at` + 节点级 `last_biz_at` 反查 | 90 分钟（可按键值配） | ±10% | Q6；与基础完全独立 |
| 测速 | `task_jobs.not_before`（窗口内随机） | 每日 1 次（窗口 17:00–24:00） | 窗口内均匀随机 | 保持现有队列语义 |
| 发布 | 事件驱动（资格集合变化）+ 可选定时 | 去抖 5 分钟 | — | 见 §10 |
| 维护 | APScheduler 6h | 6 小时 | — | 沿用 |

### 7.2 调度循环（替代 `job_cycle` 的"全量快照"）

```
每 30s:
  1. 取 due 任务：SELECT nodes WHERE lifecycle='active' AND next_due_at<=now LIMIT N
  2. 排序：unknown 新节点 > unavailable 复核 > stale 将过期 > 其余
  3. 受配额约束组批（≤200/块，≤global，≤per-airport，≤per-target）
  4. 入队 task_jobs（幂等键去重）
  5. 执行块：prepare(≤200) → 并发探测 → 结束复核身份/版本 → 写结果
  6. 无论成功失败，写回 next_due_at = now + interval + jitter
```

关键点：
- **不再存在"全局批次必须跑完所有节点"**；未到期节点不参与，未检测节点天然不会被判失败。
- `batches` 表语义从"一轮全量"改为"一个执行块"（`batch_kind=detect_block`），字段兼容；进度双环改用 `task_jobs` 汇总。
- 暂停/停止保留：`state.running/paused/stop_requested` 继续控制当前块，停止后已排队的 detect 任务标 `canceled`，`fail_streak` 不变。

### 7.3 业务检测独立调度

- `test_groups` 增 `next_due_at`；到期后为该组生成 `biz` 任务。
- 每个节点只测"有资格"的组（`lifecycle=active` 且非 stale）；单组并发受 `group_concurrency` 与新增 `per_target` 配额约束。
- 结果写 `results(test_type='business', config_version, rule_version, valid)`。
- **不影响健康状态**（现状 `manage_status=not probes` 已保证，继续保留并文档化）。
- 展示命名用的业务标签，取"最近一次有效业务结果"；若结果早于 `business_ttl`（默认 3× 频率=270 分钟）→ 保留上一次已知标签但标记 `stale`，不擅自改名（避免订阅名在两次发布间抖动，见 D5）。

### 7.4 测速调度

- 保留 `speed_queue` 的窗口分散与 `every_days`；队列改为写 `task_jobs`（`kind=speed`），进程重启后可恢复。
- 窗口默认 17:00–24:00；迁移规则：仅当 DB 值仍为 `18:00/23:30` 时改写（Q7）。
- 互斥：检测块与测速批之间仍由 `runtime_gate` 串行；**新增**"测速批之间允许检测插入"（不再整窗独占）。
- 测速结果只影响速度标签/前缀，永不进入健康判定（现状正确，保持不变）。

---

## 8. 并发、队列、超时与任务恢复

### 8.1 配额矩阵（统一在 `core/work_scheduler` 计算，执行器只消费）

| 配额 | 默认 | 作用域 | 来源 |
| --- | --- | --- | --- |
| `global_concurrency` | 10 | 全进程探测请求 | 现有设置 |
| `airport_concurrency`（新） | 3 | 单机场同时探测节点 | 新增设置 |
| `group_concurrency` | 5 | 单检测目标 | 现有 |
| `ip_concurrency` | 1 | 同出口 IP | 现有 |
| `subnet_concurrency` | 2 | 同网段 | 现有 |
| `speed_parallel_nodes` | 4 | 测速批内节点 | 现有 |
| `block_size` | 200 | 单次内核重载节点数 | 现有常量 |
| `queue_max`（新） | 2000 | `task_jobs(queued)` 上限 | 新增 |

超限策略：**拒绝入队并降级为"下个 tick 再来"**（不丢任务、不无限增长），同时 `system_events(queue_backlog)` 告警。

### 8.2 任务表与幂等

`task_jobs` 的幂等键（唯一索引，重复插入直接返回已有任务）：

| 任务 | 幂等键 | 说明 |
| --- | --- | --- |
| 基础检测 | `detect:{identity_id}:{config_version}:{rule_version}:{due_bucket}` | `due_bucket = floor(next_due_at/30min)`，同一到期窗口只跑一次 |
| 业务检测 | `biz:{group_id}:{node_id}:{due_bucket}` | 同上 |
| 测速 | `speed:{node_id}:{config_version}:{window_date}` | 同日同版本只排一次 |
| 发布 | `pub:{content_hash}` | 内容相同的发布不重复执行 |
| 备份 | `backup:{date}:{kind}` | 每日自动备份只一次 |

### 8.3 超时与看门狗

| 层级 | 超时默认 | 超时动作 |
| --- | --- | --- |
| 单请求 | `test_timeout`（8s） | 记 `timeout`，按归因分类 |
| 单节点（含 3 轮 × 双目标 + 标签） | 60s | 节点任务 `failed(timeout)`，结果 invalid，不惩罚 |
| 单块（≤200 节点） | `max(15min, 200×单节点/并发)` | 中断块，未完成节点 `next_due_at` 顺延，不写失败 |
| 单任务 | `task_jobs` 心跳 60s | 超过 3 个心跳无更新 → 标 `interrupted`，按 `max_attempts` 重排 |
| 迁移/备份 | 10min | 中断并按备份恢复（§13） |

### 8.4 重启恢复

启动顺序（`main.py` lifespan 内）：

1. `task_jobs`：所有 `running` → `interrupted`；`attempts < max_attempts` 的 detect/biz/speed 任务重新置 `queued`；发布任务仅在 `content_hash` 仍有效时重排。
2. `batches`：沿用现状把 `running` → `aborted`（`db.py:484`），但**新增**"未完成节点不补失败、不扣分"的显式约束。
3. `nodes`：重算 `stale`（只读计算，不写状态机）；清理"上一进程留下的 `next_due_at` 在过去"的节点 → 立即到期，按优先级排队。
4. `runtime_gate`：归零；若上次是测速持有，标记 `gate_recovered` 事件。
5. 自检（§13.4）通过后才允许发布定时任务启动。

### 8.5 去重与互斥的层级

1. **入队去重**：幂等键（DB 唯一索引）——对抗"前端连点 / 两个 tick 撞车"。
2. **执行互斥**：`runtime_gate` 单所有者（检测块 / 测速批）。
3. **引擎改写互斥**：`operation_lock`（现状保留）。
4. **发布互斥**：`publish` 版本指针更新用 DB 事务 + 文件锁（`data/sub/.lock`），防两个发布并发切换。

---

## 9. 机场订阅异常保护与轮换识别

### 9.1 拉取结果分类（五类，绝不合并）

| 类别 | 判定 | 缓存 | 事件 | 版本表 |
| --- | --- | --- | --- | --- |
| `fetch_error` | 下载失败/超时/HTTP≠2xx | 保留 | `fetch_failed` | 记一行（accepted=0） |
| `parse_error` | 解析异常/0 个可识别节点/校验不过 | 保留 | `parse_failed` | 记一行（status=parse_error） |
| `empty_subscription` | 解析成功但机场明确返回空列表 | 保留 + 复核 | `empty_subscription` | 记一行（status=empty_subscription） |
| `suspect` | 成功但数量/配置突变触发保护 | **保留** | `count_drop` / `config_burst` | 记一行（status=suspect, applied=0） |
| `ok` | 成功且通过保护 | 替换 | 关闭相关事件 | 记一行（applied=1） |

### 9.2 数量骤减保护（按 Q8 精确落地）

基准：`baseline = median(最近 7 个自然日"最后一个 applied=1 版本的 accepted_count")`（不足 3 天 → 不启用保护，只记录）。

```
suspect 条件： accepted_count <= baseline * 0.5  且  baseline - accepted_count >= 10
```

保护流程（严格 6 步）：

1. 本次结果**不写库**（不替换缓存），只写 `airport_fetch_versions(status='suspect', applied=0)`。
2. 不触发任何发布（`publish` 只看 `applied=1` 的最新版本）。
3. 写 `airport_events(kind=count_drop, severity=high, state=open)` + 日志 + 前端横幅。
4. 立即安排复核拉取（`+5 分钟`，不受机场 `interval_minutes` 限制）。
5. 复核结果与 suspect 快照**一致**（节点数差 ≤10% 且 集合相似度 ≥90%）→ 连续两次一致，接受：写 `applied=1`，`status=ok`，`confirmed_after=2`。
6. 两次不一致 → 继续复核（最多 3 次），期间保持保护；3 次仍不一致 → 保持 `suspect` 并升级告警，**不强行接受**，等待人工"接受本次变化"或"继续复核"。

人工出口（防永久阻止真实变化）：`POST /api/airports/{id}/accept-change` → 以当前结果 `applied=1`，事件 `closed`，记录操作者与理由。

### 9.3 配置突变保护

条件：一次 ok 拉取中，`changed_config / total ≥ 60%` 且 `total ≥ 10`。
处理同上（`kind=config_burst`），因为它通常是"机场换了入口/协议参数模板"，也可能是"抓错源"。两次一致才接受。

### 9.4 轮换识别（列表 / 出口 / 混合）

每次 `applied=1` 后计算并写 `airport_events(kind=rotation_detected)` + `node_identities.rotation_hint`：

| 类型 | 判定依据 | 记录 |
| --- | --- | --- |
| 列表轮换 | 身份集合有变化（新增/消失/恢复），但出口观测集合基本不变 | `rotation_hint=list` |
| 出口轮换 | 身份集合不变或仅名称变化，而出口 IP 集合变化 ≥30% | `rotation_hint=exit` |
| 混合 | 两者同时满足 | `rotation_hint=mixed` |
| 未知 | 无出口观测或样本不足 | `rotation_hint=unknown` |

**出口观测（可选模块，默认关闭）**：
- 频率：每节点每 6 小时一次、随机抽样 ≤20% 节点/机场；探针走 `https://www.cloudflare.com/cdn-cgi/trace`（小流量），记录 `exit_ip/colo/country` 到 `node_exit_observations`。
- **只作观测**：不改身份、不改健康、不改配置版本（任务书"出口 IP 变化只能作为观测信息"）。
- `rotation_hint` 可随观测更新，但永不成为永久标签（可回落到 unknown）。

### 9.5 机场订阅版本

`airport_fetch_versions` 每次拉取一行（含失败），`version` 每机场自增；`content_sha256` 用于识别"内容未变"（相同则 `changed=0`，仍记版本但不触发变化事件）。发布侧只引用 `applied=1` 的最近版本。

---

## 10. 订阅生成、版本管理、去重与回滚

### 10.1 下发资格表达式（唯一判定入口）

```
publishable(node) =
      node.lifecycle == 'active'
  AND node.state IN ('healthy','observe')
  AND node.last_valid_at + ttl > now
  AND EXISTS(valid result for node.config_version, rule_version=current, target=G) AND G 达标
  AND EXISTS(valid result ..., target=W) AND W 达标
```

说明：
- `observe` 可下发：单次失败不摘节点（任务书"一次失败不能立即认定不可用"）。
- `unstable`/`unavailable`/`recovering`/`unknown` 不下发。
- 业务标签不进入表达式（现状正确）。
- 评分不进入表达式（现状已解耦，继续保持）。

### 10.2 发布触发与去重

```
触发源：
  a) 一次 detect 块结束后，若资格集合哈希 != 当前生效哈希
  b) 定时发布（沿用 time/interval 两模式）
  c) 人工发布
去抖：同一哈希 5 分钟内只发一次
内容哈希 = sha1(排序后的 [identity_id, config_version, 展示名, protocol, server, port, params])
        （不含延迟、不含状态文本 → 抖动与延迟变化不产生新版本）
哈希相同 → 记账 skipped，不写盘、不建版本、不动指针
```

### 10.3 版本目录与真正的可重建性（Q10）

```
data/sub/
  active.json                 # {"version": 123, "sha256": "...", "switched_at": "..."}  ← 唯一指针
  versions/
    000123/
      manifest.json.gz        # 完整节点快照（见下）
      meta.json               # 统计、原因、health_version、airport_versions、rule_version
      clash.yaml / singbox.json / base64.txt / loon.txt   # 渲染产物（校验后写入）
      checksums.txt           # 每个文件的 sha256
  sub_all.yaml ...            # 兼容现有读取路径的"当前副本"
```

`manifest.json.gz` 必须包含可重建所需的**全部**字段：`identity_id, config_version, display_name, protocol, server, port, params(完整), udp/tls 等渲染所需字段, raw_name`。**不保存**：延迟、检测时间、状态（这些属于当次健康快照，记在 `meta.json` 的 `health_version`）。

### 10.4 原子发布流程（指针 + 副本）

```
1. 计算 content_hash；与 active 相同 → 结束
2. 生成版本号 = max+1；渲染 4 种格式到内存并 validate（沿用现有 validate）
3. 写 versions/<v>.tmp/：manifest、meta、4 文件、checksums；fsync 文件
4. rename → versions/<v>/（目录级原子）
5. DB 事务：INSERT publish_versions(active=0) → UPDATE active=1, prev.active=0
6. 切换指针 active.json（临时文件 + os.replace）
7. 从版本目录复制到 data/sub/sub_all.*（逐个 os.replace）
8. 写 share_history（沿用现有趋势）
```

崩溃一致性：
- 停在 4 之前 → 只留 tmp，启动时清理；
- 停在 5–7 之间 → `active.json` 指向新版本但副本可能旧 → **启动一致性修复**：对比副本 sha256 与 active 版本 `checksums.txt`，不一致则从版本目录重写副本。
- 任何一步失败 → 指针不变，旧订阅继续服务；写 `system_events(publish_failed)`。

### 10.5 三分支（对应任务书 9 节与 Q9）

| 情形 | 判定 | 动作 |
| --- | --- | --- |
| 检测未完成 / 系统异常 / 引擎降级 | 本块有效节点覆盖率 < 80%，或 engine≠mihomo，或批次中断 | **不发布**；保留 active；`empty-confirmed` 计时器不启动；写事件 |
| 完整检测确认 0 健康节点 | 覆盖率 ≥80% 且 0 个 publishable | 记 `publish_versions(status='empty_confirmed')`；启动 24h 倒计时（写 `settings.empty_confirmed_at`）；期间保留 active |
| 24h 到期仍为 0 | 定时检查 | 发布 `minimal` 版本（空节点 + 元信息），切换指针；前端红色提示 |
| 正常 | ≥1 publishable | 正常生成/去重/切换 |

`empty_confirmed` 期间若恢复出健康节点 → 清除倒计时，正常发布。

### 10.6 回滚（不是"把旧节点标成健康"）

```
POST /api/sub/rollback {version}
1. 读取目标版本 manifest
2. 逐节点重校验当前资格（lifecycle/state/config_version/stale）
3. 生成回滚清单：可恢复 N 个、已被排除 M 个（附原因）
4. 若用户确认：以"当前可恢复节点"为内容生成**新版本**（reason=rollback_from:<version>）
5. 新版本走正常发布流程；历史版本永不被改写
```

若目标版本 manifest 缺失/损坏 → 拒绝回滚并给出原因（不允许"假回滚"）。

---

## 11. 数据库 Schema 草案

> 以下为设计草案（不落地为迁移文件）。SQLite 语法；时间统一 `TEXT`（`YYYY-MM-DD HH:MM:SS`，本地时区，与现状一致）；布尔用 `INTEGER 0/1`。

### 11.1 现有表变更

```sql
-- nodes：从"身份载体"变为"当前快照"（7 列，均可空/有默认，旧代码可忽略）
ALTER TABLE nodes ADD COLUMN identity_id INTEGER REFERENCES node_identities(id);
ALTER TABLE nodes ADD COLUMN config_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE nodes ADD COLUMN first_seen_at TEXT;
ALTER TABLE nodes ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active';       -- active|missing|retired
ALTER TABLE nodes ADD COLUMN missing_since TEXT;
ALTER TABLE nodes ADD COLUMN state TEXT NOT NULL DEFAULT 'unknown';          -- 6 态
ALTER TABLE nodes ADD COLUMN state_since TEXT;
ALTER TABLE nodes ADD COLUMN last_valid_at TEXT;
ALTER TABLE nodes ADD COLUMN fail_streak INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN success_streak INTEGER NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN last_failure_source TEXT;
ALTER TABLE nodes ADD COLUMN ambiguous INTEGER NOT NULL DEFAULT 0;
-- 兼容：status 继续保留并双写（available/unavailable/unknown），P4 后再决定是否弃用
CREATE INDEX idx_nodes_due ON nodes(lifecycle, next_due_at);
CREATE INDEX idx_nodes_identity ON nodes(identity_id);
```

```sql
-- 检测结果表：加版本与归因（两个表同样处理）
ALTER TABLE latency_results ADD COLUMN config_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE latency_results ADD COLUMN rule_version INTEGER NOT NULL DEFAULT 0;   -- 0 = 遗留
ALTER TABLE latency_results ADD COLUMN failure_source TEXT;
ALTER TABLE latency_results ADD COLUMN engine TEXT;
ALTER TABLE latency_results ADD COLUMN valid INTEGER NOT NULL DEFAULT 1;
ALTER TABLE latency_results ADD COLUMN started_at TEXT;
ALTER TABLE results            ADD COLUMN config_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE results            ADD COLUMN rule_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE results            ADD COLUMN failure_source TEXT;
ALTER TABLE results            ADD COLUMN engine TEXT;
ALTER TABLE results            ADD COLUMN valid INTEGER NOT NULL DEFAULT 1;
CREATE INDEX idx_lat_node_ver ON latency_results(node_id, config_version, ts);
CREATE INDEX idx_res_node_ver ON results(node_id, config_version, ts);
```

```sql
ALTER TABLE speed_runs ADD COLUMN config_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE test_groups ADD COLUMN next_due_at TEXT;
ALTER TABLE airports ADD COLUMN last_version INTEGER NOT NULL DEFAULT 0;
```

### 11.2 新增表

**T1 `node_identities`（身份，长期）**

```sql
CREATE TABLE node_identities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  base_fingerprint TEXT NOT NULL,          -- 现有 fingerprint() 输出，不改算法
  occurrence_key TEXT NOT NULL DEFAULT '', -- id:<sid> | num:<n> | name:<h> | ord:<n>
  occurrence_seq INTEGER NOT NULL DEFAULT 0,
  source_node_id TEXT,                     -- 机场稳定 ID（当前解析器可能为空）
  current_config_version INTEGER NOT NULL DEFAULT 1,
  lifecycle TEXT NOT NULL DEFAULT 'active' CHECK(lifecycle IN ('active','missing','retired')),
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  missing_since TEXT,
  retired_at TEXT,
  rotation_hint TEXT NOT NULL DEFAULT 'unknown' CHECK(rotation_hint IN ('unknown','list','exit','mixed')),
  related_identity_id INTEGER REFERENCES node_identities(id),  -- probable successor，仅关联不合并
  ambiguous INTEGER NOT NULL DEFAULT 0,
  note TEXT
);
CREATE UNIQUE INDEX uq_identity ON node_identities(airport_id, base_fingerprint, occurrence_key);
CREATE INDEX idx_identity_life ON node_identities(airport_id, lifecycle);
CREATE INDEX idx_identity_fp ON node_identities(base_fingerprint);
```

**T2 `node_config_versions`（配置版本）**

```sql
CREATE TABLE node_config_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_id INTEGER NOT NULL REFERENCES node_identities(id),
  version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,
  params_hash TEXT NOT NULL,
  params TEXT NOT NULL,                    -- 完整参数 JSON（可重建渲染）
  protocol TEXT NOT NULL, server TEXT NOT NULL, port INTEGER NOT NULL,
  sample_raw_name TEXT,                    -- 该版本首次出现时的名字（仅追溯）
  change_reason TEXT NOT NULL CHECK(change_reason IN
    ('initial','config_changed','params_rotated','enumerated_change','readopt')),
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT,
  closed_at TEXT,
  UNIQUE(identity_id, version)
);
CREATE INDEX idx_cfg_fp ON node_config_versions(fingerprint);
```

**T3 `node_state_history`（状态变化解释）**

```sql
CREATE TABLE node_state_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  identity_id INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  from_state TEXT NOT NULL, to_state TEXT NOT NULL,
  lifecycle TEXT NOT NULL,
  reason_code TEXT NOT NULL,     -- first_test/fail_1/fail_threshold/recovered/expired/missing/...
  detail TEXT, rule_version INTEGER NOT NULL, ts TEXT NOT NULL
);
CREATE INDEX idx_state_node ON node_state_history(node_id, id DESC);
```

**T4 `airport_fetch_versions`（订阅版本与变化）**

```sql
CREATE TABLE airport_fetch_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  version INTEGER NOT NULL,
  trigger TEXT NOT NULL,             -- schedule|manual|recheck|startup
  fetched_at TEXT NOT NULL,
  http_status INTEGER,
  content_sha256 TEXT,
  parsed_count INTEGER NOT NULL DEFAULT 0,
  accepted_count INTEGER NOT NULL DEFAULT 0,
  added INTEGER NOT NULL DEFAULT 0,
  removed INTEGER NOT NULL DEFAULT 0,
  changed INTEGER NOT NULL DEFAULT 0,
  reappeared INTEGER NOT NULL DEFAULT 0,
  filtered_added INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL CHECK(status IN
    ('ok','suspect','rejected','fetch_error','parse_error','empty_subscription')),
  suspect_reason TEXT,
  applied INTEGER NOT NULL DEFAULT 0,
  confirmed_after INTEGER,           -- 2 = 连续两次一致后接受
  supersedes_version INTEGER,
  UNIQUE(airport_id, version)
);
CREATE INDEX idx_afv_time ON airport_fetch_versions(airport_id, fetched_at);
```

**T5 `airport_events`（机场异常事件）**

```sql
CREATE TABLE airport_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id INTEGER NOT NULL REFERENCES airports(id),
  kind TEXT NOT NULL CHECK(kind IN
    ('fetch_failed','parse_failed','count_drop','config_burst','empty_subscription',
     'rotation_detected','recovered')),
  severity TEXT NOT NULL CHECK(severity IN ('info','warning','high')),
  first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
  occurrences INTEGER NOT NULL DEFAULT 1,
  payload TEXT,                     -- JSON：基线、当前值、样本
  state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','closed')),
  closed_at TEXT, note TEXT
);
CREATE INDEX idx_ae_open ON airport_events(airport_id, state);
```

**T6 `publish_versions`（发布版本）**

```sql
CREATE TABLE publish_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  version INTEGER NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  reason TEXT NOT NULL,             -- scheduled|change|manual|rollback_from:N|empty_confirmed|legacy_baseline
  status TEXT NOT NULL CHECK(status IN ('ok','empty_confirmed','minimal','legacy_baseline')),
  node_count INTEGER NOT NULL,
  added INTEGER NOT NULL DEFAULT 0,
  removed INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT NOT NULL,
  health_version TEXT NOT NULL,     -- 资格集合快照哈希
  airport_versions TEXT NOT NULL,   -- JSON: {airport_id: version}
  rule_version INTEGER NOT NULL,
  manifest_path TEXT NOT NULL,
  prev_version INTEGER,
  active INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX uq_pub_active ON publish_versions(active) WHERE active=1;
CREATE INDEX idx_pub_time ON publish_versions(created_at);
```

**T7 `detection_rules`（规则版本）**

```sql
CREATE TABLE detection_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rule_version INTEGER NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  scope TEXT NOT NULL DEFAULT 'global',
  payload TEXT NOT NULL,   -- JSON：阈值/失败确认/恢复确认/TTL/业务规则/测速规则/发布门槛
  checksum TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  note TEXT
);
```

**T8 `task_jobs`（持久任务）**

```sql
CREATE TABLE task_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('detect','biz','speed','publish','backup','selfcheck')),
  target_type TEXT, target_id INTEGER,
  idempotency_key TEXT NOT NULL,
  payload TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN
    ('queued','running','done','failed','canceled','interrupted')),
  attempts INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 2,
  not_before TEXT, started_at TEXT, finished_at TEXT, heartbeat_at TEXT,
  worker TEXT, last_error TEXT, created_at TEXT NOT NULL,
  UNIQUE(idempotency_key)
);
CREATE INDEX idx_job_pick ON task_jobs(state, not_before, priority DESC);
CREATE INDEX idx_job_target ON task_jobs(kind, target_id, state);
```

**T9 `system_events`（系统事件/自检告警）**

```sql
CREATE TABLE system_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN
    ('engine_down','engine_degraded','db_integrity','disk_low','queue_backlog',
     'scheduler_stall','publish_failed','backup_failed','target_incident',
     'gate_recovered','migration_failed','identity_ambiguous')),
  level TEXT NOT NULL CHECK(level IN ('info','warning','critical')),
  ts TEXT NOT NULL, payload TEXT,
  state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','closed')),
  resolved_at TEXT, note TEXT
);
CREATE INDEX idx_se_open ON system_events(state, level);
CREATE INDEX idx_se_ts ON system_events(ts);
```

**T10 `schema_migrations`（迁移审计）**

```sql
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  applied_at TEXT NOT NULL,
  checksum TEXT,
  duration_ms INTEGER,
  result TEXT NOT NULL CHECK(result IN ('ok','failed','rolled_back'))
);
```

**T11 `node_exit_observations`（出口观测，可选模块）**

```sql
CREATE TABLE node_exit_observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id INTEGER NOT NULL REFERENCES nodes(id),
  identity_id INTEGER NOT NULL, config_version INTEGER NOT NULL,
  exit_ip TEXT, country TEXT, colo TEXT,
  observed_at TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'cloudflare_trace'
);
CREATE INDEX idx_exit_node ON node_exit_observations(node_id, observed_at);
```

### 11.3 表数量说明（对 Q12 的回应）

共 **11 张新表**，超出"约 6 张"。每张表都对应任务书中的一条明确要求，且无法用现有表承载：

| 表 | 对应要求 | 若要合并的替代方案（不推荐） |
| --- | --- | --- |
| T1/T2 | 身份与配置版本 | 并入 `nodes` → missing 期身份无处安放 |
| T3 | 状态变化解释（第 11 节） | 塞进 `logs` → 无法按节点查询 |
| T4/T5 | 机场订阅版本、异常事件（第 1/12 节） | 合并 T5→T9 → 机场维度查询变复杂 |
| T6 | 发布版本/回滚（第 10 节） | 并入 `share_history` → 无 manifest、无法重建 |
| T7 | 规则版本（第 16 节） | 存 `settings` → 历史结果无法引用 |
| T8 | 任务持久化/重启恢复（第 8 节） | 无替代，必须落库 |
| T9 | 系统自检/告警（第 13 节） | 与 T5 合并可省一张 |
| T10 | Schema 版本（Q1） | 用 `PRAGMA user_version` 可省，但缺审计 |
| T11 | 出口轮换识别（补充约束 3） | 不建则无法识别出口轮换（可选模块） |

**建议保留 11 张**；若你要求压缩，可合并 T5→T9、T10→`settings`，减为 9 张，代价是查询与审计变弱。列为本方案待确认项 D8。

---

## 12. 历史数据迁移与兼容

### 12.1 迁移原则

1. **只做加法**：新表新建、旧表加列（有默认值），不改主键、不改指纹、不改现有列语义。
2. **先备份再迁移**：迁移前生成快照（§13.2）。
3. **copy-migrate-swap**：在数据库副本上跑迁移，校验通过后原子替换（§13.3），失败则原库不动。
4. **可重复执行**：每一步以 `schema_migrations.version` 为幂等键。
5. **不伪造历史**：无法确定的字段留空（如遗留结果的 `config_version` 允许为回填值 1，但 `rule_version=0` 明确表示"未版本化规程"）。

### 12.2 迁移步骤（M0–M8）

| 步骤 | 内容 | 影响 | 可回滚 |
| --- | --- | --- | --- |
| M0 | 备份 + 记录 `user_version=0` | 无 | 删除备份即可 |
| M1 | 建 T1–T11、加列、建索引 | 结构 | 恢复备份 |
| M2 | 回填身份：每个 `nodes` 行建 identity（`base_fingerprint=nodes.fingerprint`，`occurrence_key='ord:<seq>'` 按 `id` 升序），建 config_version=1 | 全量节点 | 恢复备份 |
| M3 | 回填状态：`status=available→state=healthy`（若 `last_tested_at` 超 TTL → 仅置 `stale` 标记，不改 state）；`unavailable→unavailable`；`unknown→unknown`；`fail_streak=fail_count` | 全量节点 | 恢复备份 |
| M4 | 回填结果版本：现有 `latency_results/results` 设 `config_version=1, rule_version=0, valid=1`，`failure_source` 留空 | 历史行 | 支持（旧代码读旧列） |
| M5 | 基线发布版本：从 `data/sub/meta.json` + 当前 `nodes` 生成 `legacy_baseline` manifest；若节点无法对上（id 缺失）→ 标注 `manifest_complete=0`，**不伪造** | 1 行 | 删除该行 |
| M6 | 设置迁移：`speed_window` 仅旧默认迁移；新增 `result_ttl_minutes=90`、`recover_confirm_count=2`、`recover_confirm_gap_minutes=30`、`airport_concurrency=3`、`missing_retention_days=30`、`publish_keep_versions=30`、`empty_confirm_hours=24`；写 `app_version=v1.8.7` | 配置 | 保留旧值可回退 |
| M7 | 创建规则版本 1（`detection_rules`，payload = 当前全部阈值快照） | 1 行 | 删除 |
| M8 | 自检：`integrity_check`、行数比对、外键抽查、发布目录一致性 | — | 失败→自动恢复备份 |

### 12.3 兼容策略

| 兼容点 | 做法 |
| --- | --- |
| 旧代码读新库 | 新列都有默认值；旧代码只读 `nodes.status`（继续双写）→ 可直接回代码 |
| 新代码读旧库 | 迁移后 `identity_id` 全有值；未迁移不允许启动（启动前强制跑迁移） |
| 旧结果的解释 | `rule_version=0` 视为"v1.8.7 规程"，UI 标注"历史（未版本化）"，不参与新规则统计 |
| 旧发布文件 | 保留 `data/sub/sub_all.*` 与 `meta.json` 作为兼容副本；新版本目录并存 |
| 前端旧缓存 | 新字段全部可选渲染，缺省显示"—" |
| 指纹 | 完全不变（Q3） |

### 12.4 数据保留策略（与任务书 14 节对齐）

| 数据 | 默认保留 | 下限保护 |
| --- | --- | --- |
| 当前节点与身份 | 长期 | — |
| 身份/配置版本 | 长期 | — |
| 基础检测明细 | 90 天（可配 30–180） | 不得短于 7 天评分窗口 + 恢复期 |
| 业务检测明细 | 90 天 | 同上 |
| 测速明细 | 90 天 | 同上 |
| 状态变化历史 | 180 天 | 不得短于 missing 保留期 |
| 机场订阅版本 | 180 天 | 至少保留 30 个 applied 版本 |
| 发布版本 | 30 个（20–50 可配） | 至少保留 1 个可回滚版本 |
| 系统日志 | 30 天 | 不得短于 7 天 |
| 系统事件 | 180 天 | 未关闭事件永不清理 |

清理规则：**先归档后删除**（`*.jsonl.gz` 按月归档到 `data/archive/`），删除前校验不触及"近 7 天"与"未关闭事件"；孤儿清理（`db.py:857` 的 `DELETE ... node_id NOT IN`）**取消**，改为"仅清理 `retired` 且超过历史保留期"的节点。

### 12.5 `missing → retired` 后的历史

- identity 与 config_version 永久保留；
- `nodes` 行转为 `retired`（保留行，不删）；
- 检测明细按 §12.4 保留期归档，不随节点退休立即删除；
- 评分的历史聚合（`share_history`）不受影响。

---

## 13. 备份、恢复与升级保护

### 13.1 备份

| 类型 | 触发 | 路径 | 保留 |
| --- | --- | --- | --- |
| 每日自动 | `task_jobs(backup)` 03:30 | `data/backup/auto/nodepool-YYYYMMDD.db` | 7 份 + 4 周 |
| 手动 | API/前端 | `data/backup/manual/nodepool-<ts>.db` | 30 份 |
| 迁移前 | 启动迁移前（强制） | `data/backup/premigrate/nodepool-<schema>-<ts>.db` | 5 份 |
| 恢复前 | 恢复操作前（强制） | `data/backup/prerestore/...` | 5 份 |

实现：`sqlite3.Connection.backup()`（WAL 安全，现有 `routes.py:1422` 已用对）；备份后写 `manifest.json`：`sha256 / size / schema_version / app_version / integrity_check 结果 / table_counts`。

**备份可靠性验证**（不能只看"文件生成成功"）：
1. 打开备份副本执行 `PRAGMA quick_check`；
2. 校验关键表行数与源库一致（允许 ±0）；
3. 抽样读取 100 行 `nodes`；
4. 任一失败 → 删除该备份文件，写 `system_events(backup_failed, critical)`，前端告警。

### 13.2 迁移

```
启动
 ├─ 若 user_version < target:
 │   1. 备份（premigrate）
 │   2. 校验备份可用（quick_check + 行数）
 │   3. cp db → db.migrating
 │   4. 在副本上按 M1..M8 迁移，逐版本写 schema_migrations
 │   5. 副本 integrity_check + 关键约束抽查 + 行数比对
 │   6. fsync → os.replace(db.migrating → db)   ← 原子替换
 │   7. 启动自检通过 → 启动调度
 └─ 任一步失败:
     删除 db.migrating；原库保持；写 migration_failed；
     进程以 degraded 模式启动（只读页面 + 明确提示），不跑检测/发布
```

### 13.3 恢复

```
POST /api/system/restore
1. 校验上传文件 sha256 与 manifest（若有）
2. PRAGMA integrity_check（完整）+ user_version 检查
3. 校验必需表/列存在；行数 sanity（nodes>0、settings 非空）
4. 自动备份当前库（prerestore）
5. 关闭调度 → 替换 DB → 启动迁移（若备份版本较老）
6. 重建发布副本（manifest 与 active 一致性修复）
7. 启动自检 → 恢复调度
失败 → 回滚到 prerestore 备份，写 system_events
```

### 13.4 自检（P6）

| 检查项 | 频率 | 判定 | 级别 |
| --- | --- | --- | --- |
| DB 读写 | 5 min | 写探测表失败 | critical |
| `quick_check` / `integrity_check` | 每日 / 每周 | 非 ok | critical |
| 磁盘剩余 | 5 min | <10% 或 <500MB | warning/critical |
| 引擎存活 | 1 min | 进程/端口异常 | critical |
| 引擎是否降级 TCP | 1 min | `degraded=True` | critical |
| 调度心跳 | 1 min | 超过 3 个 tick 未跑 | critical |
| 队列积压 | 5 min | `queued` > 2000 或最老 > 1h | warning |
| 发布生成器 | 10 min | 最近成功 > 2h 且期间有变化 | warning |
| 备份新鲜度 | 每日 | 最近自动备份 > 36h | warning |
| 时钟 | 启动 + 每小时 | 与 monotonic 漂移 > 5 min | warning |

`/healthz` 返回：`status ∈ ok|degraded|critical`、`reasons[]`、`version`、`schema_version`、`engine`、`queue`、`last_backup_at`。容器 healthcheck 用 `/healthz`（degraded 仍 200，critical 返回 503）。

### 13.5 升级流程（`upgrade.sh` + 应用内）

1. 脚本调 `POST /api/system/backup`（同步等待 manifest 校验通过），失败则中止升级（可 `--force`）。
2. 拉镜像 → 重启。
3. 应用启动 → 迁移（§13.2）→ 自检。
4. 自检 critical → 不启动调度，页面提示"升级自检失败，可回滚到 <版本>"。
5. 回滚：切回上一镜像 + 用 premigrate 备份恢复（脚本提供 `--rollback`）。
6. 记录 `settings.app_version` 与 `schema_version`，前端侧栏显示。

---

## 14. 前端需要展示的状态与解释

### 14.1 缓存池（`Nodes.vue`）

新增列/筛选：

| 展示 | 取值 | 说明 |
| --- | --- | --- |
| 状态徽标 | 健康 / 观察 / 不稳定 / 不可用 / 恢复中 / 未知 | 6 态色板与现有四档色区分开 |
| 过期标记 | `stale` 灰色角标 | "结果过期 X 分钟" |
| 生命周期 | 使用中 / 暂时缺失 / 已归档 | missing 行仍显示，灰化 |
| 配置版本 | `v3` | 点击展开参数 diff（新旧对比，脱敏 password/uuid） |
| 首次出现 | 时间 | 来自 `first_seen_at` |
| 解释文案 | "未下发：连续 2 次失败" 等 | 映射见 14.2 |

### 14.2 解释文案映射（对应任务书 11 节）

| 情形 | 文案 |
| --- | --- |
| 已下发 | "已下发：基础检测通过（中位延迟 128ms）" |
| 新节点 | "暂不下发：新节点，尚未完成首次有效检测" |
| 连续失败 | "暂不下发：连续 2 次有效失败（阈值 3）" |
| 不可用 | "暂不下发：连续 3 次有效失败" |
| 过期 | "暂不下发：检测结果已过期 42 分钟" |
| 缺失 | "暂不下发：已从机场订阅中消失（12 天）" |
| 配置变化 | "暂不下发：配置已变更（v2），等待重新检测" |
| 引擎异常 | "暂不下发：检测引擎异常，结果无效" |
| 恢复观察 | "恢复观察：第 1 次成功，等待第 2 次确认（≥30 分钟）" |
| 歧义 | "身份存疑：同配置多节点，按首次观测锚定" |

### 14.3 机场页（`Airports.vue`）

- 订阅版本列表：版本号、时间、节点数、新增/消失/变更/恢复、状态（ok/suspect/…）、触发方式。
- `suspect` 横幅：基线 vs 当前、下降百分比、"接受本次变化 / 继续复核"两个按钮（危险操作二次确认）。
- 轮换提示：`列表轮换 / 出口轮换 / 混合 / 未知` + 最近观测时间。
- 事件时间线：拉取失败、解析失败、数量骤减、配置突变、恢复。

### 14.4 订阅页（`Subscription.vue`）

- 当前生效版本（版本号、时间、节点数、哈希前 8 位）。
- 版本列表：与上一版 diff（+N / -N / 改名 N），点击查看被移除节点及原因。
- 回滚：选择版本 → 预检结果弹窗（"可恢复 118 个，排除 9 个：过期 6 / 缺失 2 / 配置变更 1"）→ 确认生成新版本。
- 空订阅倒计时（`empty-confirmed`）：剩余小时数与原因。

### 14.5 仪表盘 / 设置

- 顶部系统健康横幅（ok/degraded/critical + 原因），引擎降级时红色常驻。
- 备份状态卡片：最近成功时间、份数、最近校验结果。
- 设置新增：结果有效期、恢复确认次数/间隔、missing 保留期、发布版本数、单机场并发、空订阅上限小时、suspect 阈值（高级折叠）。

**布局约束**：不改变现有页面结构与操作路径，只加列、加卡片、加弹窗；移动端沿用现有断点。

---

## 15. 已有成熟功能的保留清单（承诺不替换）

| # | 功能 | 处理 |
| --- | --- | --- |
| 1 | 订阅解析（分享链接/base64/Clash YAML 多协议） | 原样保留 |
| 2 | 拉取失败保护（下载/解析/空内容） | 保留，扩展五分类 |
| 3 | 关键词过滤 + 手动准入 | 原样保留（P0 改为状态迁移，不删行） |
| 4 | Mihomo 真实探测 | 原样保留 |
| 5 | 双目标延迟门槛与两档上限 | 保留阈值，聚合方式调整（D2） |
| 6 | 标签只命名、不决定下发 | 原样保留并文档化 |
| 7 | 四层并发（全局/标签/IP/网段） | 保留，新增两层 |
| 8 | 相似节点分散 | 原样保留 |
| 9 | 块内 200 节点重载 | 保留（块由 due 集合派生） |
| 10 | 暂停/继续/停止、进度 | 保留 UI 与语义 |
| 11 | 检测/测速互斥 | 保留 gate，扩展持久化 |
| 12 | 四格式输出 + 写前校验 | 原样保留 |
| 13 | Token 鉴权 / UA 自适应 / 订阅路径 | 原样保留 |
| 14 | 测速算法、50MB 上限、评级 | 原样保留 |
| 15 | 测速源健康 + 直连确认 | 保留，增加多次确认与屏蔽窗口 |
| 16 | 机场排除测速 | 原样保留 |
| 17 | 机场评分（7 天/时段/成熟度/采样） | 原样保留，且只读 |
| 18 | 定时下发两模式 | 原样保留 |
| 19 | 前端 6 页面与移动端 | 保留布局，仅加字段 |
| 20 | 备份/下载/恢复入口 | 保留入口，增强实现 |
| 21 | 流量信息、版本提示 | 原样保留 |

---

## 16. 测试体系与关键场景覆盖计划

### 16.1 测试基建（P-1 一并搭好）

| 设施 | 作用 |
| --- | --- |
| `FakeClock` | 注入时间，测 30 分钟节奏、TTL、恢复间隔、窗口 |
| `FakeEngine` | 可编程返回 ok/超时/连接失败/引擎异常/目标事故 |
| `SchemaFixture(v1.8.7)` | 一份真实旧库快照，测迁移与回填 |
| `TempSubDir` | 测发布版本、原子切换、崩溃恢复 |
| `BackupRoundTrip` | 备份→删库→恢复→自检 端到端 |

### 16.2 必测场景矩阵（对任务书 18 节）

| # | 场景 | 层级 | 阶段 | 断言要点 |
| --- | --- | --- | --- | --- |
| 1 | 改名同配置 | unit | P0 | identity 不变、config_version 不变、有 rename 事件 |
| 2 | 同名异配置 | unit | P0 | 新 config_version 或新身份（按证据），旧结果不参与新判定 |
| 3 | 暂时消失后恢复 | integration | P0 | 不删行、missing→active、状态回 unknown |
| 4 | 列表轮换 | integration | P0 | 身份新增/缺失统计正确，无错误合并 |
| 5 | 出口 IP 轮换 | unit | P0 | 身份不变、仅观测记录（模块关闭时跳过） |
| 6 | 混合轮换 | integration | P0 | 分类为 mixed，不误判 |
| 7 | 拉取失败 | integration | P0 | 缓存不变、版本表记 fetch_error |
| 8 | 解析失败 | integration | P0 | 缓存不变、parse_error |
| 9 | 空订阅 | integration | P0 | empty_subscription，不替换 |
| 10 | 数量骤减 | integration | P0 | suspect、不写库、事件、两次确认后才接受 |
| 11 | 检测中配置变化 | integration | P1 | 结果 valid=0，新配置状态不受影响 |
| 12 | 任务中断 | integration | P2 | 不计失败、可恢复、幂等键生效 |
| 13 | 引擎故障 | integration | P1 | failure_source=engine，streak 不变 |
| 14 | 目标故障 | integration | P1 | 目标事故窗口，所有节点 streak 不变 |
| 15 | 恢复观察 | unit | P1 | 1 次→Recovering，2 次且间隔≥30min→Healthy |
| 16 | 状态过期 | unit | P1 | stale 后不可发布，状态保留 |
| 17 | 订阅生成失败 | integration | P3 | 指针不变、旧订阅可服务 |
| 18 | 零健康节点 | integration | P3 | 三分支行为与 24h 收敛 |
| 19 | 重复任务 | integration | P2 | 同幂等键只执行一次 |
| 20 | 数据库迁移 | integration | P-1/P5 | 旧库→新库、回填完整、失败自动回滚 |
| 21 | 备份恢复 | integration | P-1 | 恢复后行数/哈希/自检一致 |
| 22 | 历史清理 | integration | P5 | 不触碰 7 天窗口、不删未关闭事件 |
| 23 | 发布去重 | integration | P3 | 同内容哈希不生成新版本 |
| 24 | 回滚 | integration | P3 | 回滚生成新版本，过期节点被排除 |
| 25 | 崩溃恢复 | integration | P2/P3 | 重启后副本与指针一致、队列恢复 |

**门禁**：上述场景按阶段"随功能交付"，不允许最后补测；每阶段 CI 必须包含本阶段全部场景 + 全量回归（现有 203 例不得回归）。

---

## 17. P-1、P0–P6 阶段依赖与实施范围

### 17.1 依赖图

```
P-1 备份/迁移/自检地基 ──► P5 的整理/归档依赖它
  │
  ▼
P0 身份与生命周期 ──► P1（config_version）
  │                    │
  ▼                    ▼
P1 状态与有效结果 ──► P2（状态语义决定调度优先级）
  │                    │
  ▼                    ▼
P2 调度与任务持久化 ──► P4（独立调度框架）
  │
  ▼
P3 发布版本与回滚 ──► P6（自检引用发布健康）
  │
  ▼
P4 业务检测与测速整合
  │
  ▼
P5 数据整理与规则版本
  │
  ▼
P6 自检与升级保护
```

### 17.2 每阶段范围 / 风险 / 验收 / 回滚

**P-1 备份、Schema 版本、迁移保护、测试地基**

- 范围：`backup/service`、`schema_migrations`、`copy-migrate-swap`、自检骨架、`FakeClock/Engine`、`upgrade.sh` 前置备份、备份轮转与校验。
- 不改：任何检测/发布/评分行为。
- 风险：原子替换在 Docker 卷上的权限/rename 行为；备份期间 DB 锁。
- 验收：
  1. 旧库启动自动产生 premigrate 备份且 `quick_check=ok`；
  2. 人为让 M2 失败 → 原库未被替换、进程 degraded、事件可见；
  3. `--rollback` 能恢复到迁移前；
  4. 备份轮转按 7+4 生效，过期文件被删且记录日志；
  5. 现有 203 测试全绿。
- 回滚：删新表 + 停用备份 job；代码回退，库无需回滚（新表空闲）。

**P0 节点身份与生命周期**

- 范围：T1/T2、`lifecycle.identity`、`fetcher` 改为"缺失不删"、occurrence 解析、歧义标记、`missing/retired` 评估 job。
- 不改：检测门槛、订阅内容、评分。
- 风险：回填后 `UNIQUE(airport_id,fingerprint)` 与身份唯一索引冲突；重复配置组历史错位（E3）；机场删除时身份孤儿。
- 验收：
  1. 场景 1/3/4/5/6/7/8/9/10 全过；
  2. 一次"只返回 1 个节点"的拉取后，`nodes` 删除数为 0，`missing` 数等于差额；
  3. 137 节点真实库回填后 identity 覆盖率 100%，`ambiguous` 清单可导出；
  4. E3 重放：两次换序拉取后，名称与 identity 的绑定不变；
  5. 订阅内容与 v1.8.7 逐字节一致（同一输入快照对比）。
- 回滚：代码回退 + 恢复 P0 前备份（因新增列被旧代码忽略，也可只回代码）。

**P1 健康状态、有效结果、过期**

- 范围：T3/T7、`health.validity/state_machine`、结果加列、TCP 边界、目标事故、`routes.py:1002` 修复。
- 风险：聚合方式变化影响既有下发达标（见 D2）；双写 `status` 不一致；target 事故阈值误判。
- 验收：
  1. 场景 11/13/14/15/16 全过；
  2. 连续 3 次引擎异常后节点状态不变、`fail_streak` 不变，`system_events` 有 3 条；
  3. 10 天前的结果不再具备下发资格；
  4. TCP 模式下 `publishable=0`，`/healthz=degraded`；
  5. 单次失败仍在 `observe` 且继续可下发（不抖动下架）。
- 回滚：代码回退（新列默认值兼容）；如聚合改动引发争议，按 `detection_rules` 切回旧规则版本。

**P2 调度、任务持久化、并发**

- 范围：T8、`core/work_scheduler/task_queue`、`airport_concurrency`、优先级、超时与看门狗、重启恢复。
- 风险：每节点 due 带来大量小批次 → 频繁内核重载；队列积压；时钟跳变。
- 验收：
  1. 场景 12/19/25 全过；
  2. 137 节点下 30 分钟窗口内检测完成率 ≥95%，重载次数 ≤ 节点数/200 × 1.3；
  3. 杀进程重启后，未完成任务恢复且无节点被扣分；
  4. 前端连点"立即检测"10 次，只产生 1 个有效任务；
  5. 单机场并发不超 `airport_concurrency`（用假引擎记录并发峰值）。
- 回滚：关掉 per-node due（切回全局批次开关，保留 1 个 release 的兼容开关），代码回退。

**P3 发布版本、去重、回滚、三分支**

- 范围：T6、`publish/versioning`、版本目录、指针、一致性修复、回滚预检、空订阅收敛。
- 风险：文件系统半写；旧客户端缓存旧副本；回滚选到不含新节点的旧版。
- 验收：
  1. 场景 17/18/23/24 全过；
  2. 同内容重复触发 10 次 → 版本数 +0；
  3. 在步骤 5–7 之间 kill -9 → 重启后副本与 active 一致；
  4. 回滚 v(n-3)：过期节点被排除且有清单；
  5. 0 健康节点 24h 后自动切 minimal，之前保留 active。
- 回滚：保留 `data/sub/sub_all.*` 兼容副本，代码回退即可继续出订阅；版本目录保留不删。

**P4 业务检测与测速整合**

- 范围：`test_groups.next_due_at` 独立调度、`business_ttl`、测速窗口迁移、源屏蔽窗口、队列持久化收尾。
- 风险：命名抖动（两次发布间标签变化）；源屏蔽过度导致覆盖率下降。
- 验收：
  1. 业务检测按 90 分钟独立跑，不随基础批次；
  2. 业务失败不改变任何节点健康状态（批量断言）；
  3. 窗口旧默认迁移正确，自定义值不变；
  4. 单源连续 2 次失败才屏蔽，30 分钟后自动解封；
  5. 白天无自动测速（含跨时区测试）。
- 回滚：窗口/频率改回旧值；业务调度切回随批（保留开关）。

**P5 数据整理、归档、规则版本**

- 范围：清理与归档、孤儿清理改造、规则版本历史、保留策略、口径文档。
- 风险：清理误删 7 天内数据；归档后查询缺失。
- 验收：
  1. 场景 20/21/22 全过（迁移与备份在 P-1 已建，这里验证与清理共存）；
  2. 清理后近 7 天评分结果与清理前一致（对比快照）；
  3. 未关闭事件与 missing 期数据不被清理；
  4. 规则版本切换后，旧结果仍按旧规则解释（测试断言 `rule_version` 关联）。
- 回滚：停用清理 job；恢复最近备份。

**P6 自检与升级保护**

- 范围：`selfcheck`、`/healthz` 分级、启动自检门禁、升级失败保护、回退脚本。
- 风险：自检误报阻塞启动；健康检查拖慢容器。
- 验收：
  1. 10 项自检全部有可复现的故障注入用例；
  2. 引擎降级 → critical + 发布暂停；
  3. 升级自检失败 → 调度不启动、页面可访问、可一键回退；
  4. `/healthz` 在 DB 损坏时返回 503；
  5. 升级全流程演练（备份→迁移→自检→回滚）一次通过。
- 回滚：关闭自检门禁（配置项），恢复上一镜像 + 备份。

---

## 18. 与任务书的冲突、偏差与待确认事项

### 18.1 必须由你裁决的冲突（不擅自选择）

| 编号 | 冲突 | 现状 | 方案建议 | 影响 |
| --- | --- | --- | --- | --- |
| C1 | "不要只用单次最快延迟" vs 现有 best-of-3 门槛 | `manager.py:189-224` 取 3 轮最优 | 改为"3 轮窗口：成功 ≥2/3 且 中位延迟 ≤上限"，发布延迟用中位数；阈值不变 | 部分节点下发达标会变化，需你确认（D2） |
| C2 | 业务检测改为 90 分钟独立后，标签可能"过时" | 现在每批都刷新 | 引入 `business_ttl=270min`，过期保留旧标签并标 stale，不擅自改名 | 订阅显示名稳定，但标签可能滞后 |
| C3 | 发布触发由"每批结束"改为"资格变化 + 去抖" | `manager.py:559-582` | 保留定时发布；事件发布去抖 5 分钟 | 发布更少更稳，但变化生效略有延迟 |
| C4 | 现有 `sub_publish` 两模式与新事件发布并存 | 现状两模式 | 两者共存：事件发布负责"及时"，定时发布负责"兜底" | 需确认是否保留双模式（D4） |
| C5 | `nodes.status` 三态与 6 态并存 | 前端/评分/dashboard 读 `status` | 双写过渡，P4 后前端只读新字段 | 过渡期存在两套字段 |

### 18.2 待你确认的设计参数（D1–D10）

| 编号 | 事项 | 建议默认 | 为什么需要确认 |
| --- | --- | --- | --- |
| D1 | 检测结果有效期 `result_ttl_minutes` | 90（=3× 基础周期） | 太短会误摘节点（网络抖动），太长会留僵尸；直接影响下发 |
| D2 | 聚合方式改为"成功≥2/3 + 中位延迟" | 采纳 | 与现有 best-of-3 行为不同，会改变部分节点达标 |
| D3 | 目标事故阈值 | 同批同目标 ≥30% 且 ≥10 节点 | 大机场可能误触发/小机场不触发 |
| D4 | 是否保留"定时发布"双模式 | 保留 | 与事件发布并存会增加一次发布入口 |
| D5 | 业务标签过期后是否保留旧标签 | 保留 + 标 stale | 影响订阅命名稳定性 |
| D6 | `missing` 保留期与状态历史保留期 | 30 天 / 180 天 | 影响库体积（百节点约每年几万行） |
| D7 | 发布版本保留数与是否保存完整 4 格式文件 | 30 个；只存 manifest + 校验后 4 文件（约 1–3MB/版） | 磁盘占用与"真正可重建"的平衡 |
| D8 | 新表数量 11 张（可压缩到 9） | 11 | 与你"约 6 张"的预期有偏差，需授权 |
| D9 | 是否启用出口观测模块（默认关闭） | 关闭 | 需要额外出口流量与外部依赖；不启用则出口轮换只能"unknown" |
| D10 | 迁移回填时 `available + 已超 TTL` 的节点 | 置 `stale`（状态仍 healthy），首轮检测后转 unknown/observe | 影响升级瞬间的订阅节点数（可能骤减，需你接受） |

### 18.3 本方案未解决的问题（不假设已确认）

1. 机场是否真的提供稳定节点 ID：当前解析器未提取，需真实订阅样本验证（`source_node_id` 可能恒空）。
2. 编号键（`num:`）在真实机场命名中的覆盖率未知，需用生产库 137 节点样本回放统计。
3. 出口观测的外部端点可用性与合规性（`cdn-cgi/trace` 是否被目标机场限制）需实测。
4. SQLite 在 Docker 卷上的目录级 `rename` 原子性需在目标 NAS 文件系统上验证（NFS/overlay 差异）。
5. `missing` 期间若机场整体被禁用（`enabled=0`），生命周期与"停用"的交互需在 P0 明确（建议：停用不改 lifecycle，只冻结检测/下发）。
6. 现有 137 节点库中"同配置重复"的实际数量未知，回填前需先做一次离线统计（只读）。

---

## 附录 A｜关键代码锚点（设计落地时逐条对照）

| 主题 | v1.8.7 位置 | 本方案对应 |
| --- | --- | --- |
| 指纹 | `parsers/subscription.py:94` | §4.2（不改） |
| 硬删节点 | `services/fetcher.py:224-231` | §5.2（改 missing） |
| 重复序号 | `fetcher.py:146-163` | §4.3（occurrence 键） |
| 状态写入 | `scheduler/manager.py:226-249`、`310-334` | §6.2（唯一入口） |
| 引擎降级 | `testers/engine.py:284-296` | §6.4（显式降级） |
| 结果表 | `db.py:129-166` | §11.1（加版本/归因） |
| 发布 | `subscriptions/builder.py:852-935` | §10.3–10.4 |
| 空池保留 | `builder.py:884-895` | §10.5 |
| 测速窗口 | `config.py:123-124` | §7.4 |
| 备份 | `api/routes.py:1416-1480` | §13.1 |
| 健康检查 | `routes.py:1603-1611` | §13.4 |
| 缺陷 `missing` | `routes.py:1002` | P1 修复项 |
| 时区清理 | `db.py:583-585` | P-1 修复项（统一 UTC 存储或统一本地比较） |

## 附录 B｜Schema 关系（纵向）

```
airports
 ├─ node_identities ── node_config_versions
 │        │                    │
 │        └─ nodes ◄───────────┘（nodes.identity_id + config_version）
 │              ├─ node_state_history
 │              ├─ latency_results / results（带 config_version、rule_version）
 │              ├─ speed_runs / speed_samples
 │              └─ node_exit_observations（可选）
 ├─ airport_fetch_versions
 └─ airport_events

publish_versions ── manifest(版本目录)
detection_rules ── 被所有结果/版本引用
task_jobs / system_events / schema_migrations：横向支撑
```

---

**阶段 1 到此结束。** 未进入 P-1 / P0，未修改任何代码、数据库或配置。请先裁决 §18.1 的 C1–C5 与 §18.2 的 D1–D10（至少 D1/D2/D8/D10），确认后我再提交 P-1 的实施计划（修改文件清单、DDL、迁移步骤、测试计划、回滚方案），并等你二次确认后才动代码。
