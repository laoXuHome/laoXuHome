# NodePoolME P5 数据结构与状态说明

- 版本：v2.042
- 日期：2026-11-28
- 数据存储：SQLite
- 设计方式：P5 独立旁路表，不改 P1–P4 已验收表结构与判定规则。

## 一、设计原则

1. 竞争状态按「节点 × 类别」独立保存，主键为 `(node_id, category)`。
2. 当前状态与历史分离：`np5_state` 保存当前状态，`np5_history` 保存每次变化。
3. 运行记录与状态分离：`np5_runs` 保存每轮竞争，`np5_events` 保存跳过、配置等事件。
4. 所有表懒创建：首次访问 P5 时执行 `CREATE TABLE IF NOT EXISTS` 与索引创建，不进入冻结的基线结构 profile。
5. P5 不写 `np_nodes`、`np2_*`、`np3_*`、`np4_*`；只读 P1–P4 证据。
6. 当前状态可重建：历史记录保留证据 key、准入快照、配置版本与原因。

## 二、状态定义

| 状态键 | 中文 | 含义 |
| --- | --- | --- |
| `observation` | 观察 | 新节点、数据不足、恢复确认期 |
| `candidate` | 候选 | 满足准入，正在积累晋级确认 |
| `preferred` | 优选 | 正式进入该类别优选名单 |
| `eliminated` | 淘汰 | 来源失活、机场停用，退出该类别竞争 |

状态排序：`preferred(0) < candidate(1) < observation(2) < eliminated(3)`，用于稳定排序。

一个节点在六类中各有独立记录。例如：

```
香港01 / standard  → preferred
香港01 / gpt       → preferred
香港01 / youtube   → candidate
香港01 / telegram  → observation
```

不存在一个全局状态覆盖六类。

## 三、`np5_state` 当前状态表

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `node_id` | INTEGER | P1 节点 ID，联合主键 |
| `category` | TEXT | 竞争类别，联合主键 |
| `state` | TEXT | 观察/候选/优选/淘汰 |
| `score` | REAL | 最近一次 P4 七天质量分 |
| `maturity` | REAL | 最近一次数据成熟度 |
| `p80_ms` | INTEGER | 最近一次 TCP P80 |
| `delay_grade` | TEXT | 延迟等级：`excellent/good/normal/fair/severe/fail/none` |
| `speed_grade` | TEXT | 速度等级：`excellent/good/poor/danger/empty/excluded` |
| `speed_mb_s` | REAL | 最近一次下载速度 MB/s |
| `admission_ok` | INTEGER | 当前准入是否通过 |
| `admission_reason` | TEXT | 首个硬失败/pending 原因码 |
| `admission_json` | TEXT | 完整准入检查快照 |
| `observation_started_at` | TEXT | 观察起点 |
| `observation_until` | TEXT | 观察截止 |
| `candidate_since` | TEXT | 进入候选时间 |
| `preferred_since` | TEXT | 进入优选时间 |
| `eliminated_since` | TEXT | 进入淘汰时间 |
| `last_evaluated_at` | TEXT | 最近证据评价时间 |
| `last_change_at` | TEXT | 最近状态变化时间 |
| `last_evidence_key` | TEXT | 最近证据幂等键 |
| `consecutive_failures` | INTEGER | 连续不达标次数 |
| `consecutive_successes` | INTEGER | 连续有效成功次数/候选确认次数 |
| `advantage_count` | INTEGER | 对最弱成熟优选的连续领先确认次数 |
| `advantage_target_id` | INTEGER | 当前替换目标节点 ID |
| `recovery_required` | INTEGER | 是否需要恢复确认 |
| `last_reason` | TEXT | 最近原因码 |
| `config_version` | INTEGER | 状态使用的配置版本 |
| `detail_json` | TEXT | P4 证据时间、业务状态等详情 |
| `updated_at` | TEXT | 行更新时间 |

索引：

- `idx_np5_state_category(category, state, score)`：类别计数与排序。
- `idx_np5_state_node(node_id)`：节点详情。

## 四、`np5_history` 状态变化历史

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER | 自增主键 |
| `at` | TEXT | 变化时间 |
| `node_id` | INTEGER | 节点 ID |
| `category` | TEXT | 竞争类别 |
| `from_state` | TEXT | 变化前状态 |
| `to_state` | TEXT | 变化后状态 |
| `before_score` | REAL | 变化前分数 |
| `after_score` | REAL | 变化后分数 |
| `admission_json` | TEXT | 变化时准入检查快照 |
| `reason` | TEXT | 变化原因码 |
| `replaced_node_id` | INTEGER | 被替换节点 ID |
| `replace_reason` | TEXT | 替换原因 |
| `config_version` | INTEGER | 使用的参数版本 |
| `evidence_key` | TEXT | 证据幂等键 |
| `detail_json` | TEXT | 成熟度、速度、P80、分差等详情 |

索引：

- `idx_np5_history_node(node_id, category, id DESC)`
- `idx_np5_history_category(category, id DESC)`

历史只追加，不因当前状态变化而删除。降级、淘汰、替换均保留旧记录。

## 五、`np5_runs` 竞争运行记录

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER | 自增主键 |
| `started_at` | TEXT | 开始时间 |
| `finished_at` | TEXT | 结束时间 |
| `trigger` | TEXT | `manual` / `auto` |
| `status` | TEXT | `running/success/partial` |
| `categories` | TEXT | 本轮类别 JSON |
| `nodes_scanned` | INTEGER | 节点/类别处理数 |
| `changes` | INTEGER | 状态变化数 |
| `message` | TEXT | 部分失败的说明 |
| `detail_json` | TEXT | 每类别扫描、变化、错误明细 |

索引：`idx_np5_runs_at(id DESC)`。

## 六、`np5_events` 事件表

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER | 自增主键 |
| `at` | TEXT | 事件时间 |
| `event` | TEXT | 事件类型 |
| `node_id` | INTEGER | 可选节点 |
| `category` | TEXT | 可选类别 |
| `reason` | TEXT | 事件原因 |
| `detail_json` | TEXT | 详情 |

索引：`idx_np5_events_at(id DESC)`。

事件包括运行跳过、配置变更、恢复默认等，用于审计并发与参数操作。

## 七、参数存储

参数写入现有 `app_settings` 表：

| 键 | 默认 | 范围 |
| --- | --- | --- |
| `p5_observation_days` | 3 | 1–7 |
| `p5_candidate_score` | 80 | 70–95 |
| `p5_retain_score` | 70 | 60–85 |
| `p5_failure_limit` | 3 | 2–5 |
| `p5_recovery_successes` | 2 | 2–5 |
| `p5_replace_gap` | 8 | 5–15 |
| `p5_cycle_minutes` | 60 | 10–1440 |
| `p5_config_version` | 1 | 每次变更递增 |

校验规则：

1. 必须为整数。
2. 必须在字段范围内。
3. `p5_retain_score <= p5_candidate_score`。
4. 未知参数拒绝。
5. 恢复默认写入默认值并提升版本。

## 八、状态变化流程

### 1. 新节点

```
无记录 → observation
  observation_until = first_seen_at + observation_days
  recovery_required = 0
```

观察期结束：

- 准入通过 → `candidate`，首个达标样本计 1 次确认。
- 准入 pending/硬失败 → 保持 `observation`，原因记录。

### 2. 候选

```
candidate
  ├─ 准入 pending → 保持候选，不累计失败
  ├─ 硬失败 → observation，recovery_required=1
  ├─ 分数不足 → 保持候选，consecutive_successes=0
  ├─ 第一次达标 → 保持候选，candidate_confirming
  ├─ 有成熟优选且分差不足 → 保持候选，mature_priority
  ├─ 有成熟优选且分差达标一次 → 保持候选，replacement_confirming
  ├─ 有成熟优选且分差达标两次 → preferred，替换最弱成熟优选
  └─ 无成熟优选且连续两次达标 → preferred
```

### 3. 优选

```
preferred
  ├─ 保留准入通过 → preferred，retained
  ├─ 单次低于保留线 → preferred，retain_watch，failures+1
  ├─ pending → 保持原状态，不累计失败
  ├─ 速度 danger → observation，recovery_required=1
  ├─ 业务过期 → observation，recovery_required=1
  └─ failures 达到门槛 → observation，recovery_required=1
```

### 4. 恢复

```
observation(recovery_required=1)
  ├─ 准入 pending → 等待，不增不减
  ├─ 硬失败 → successes=0
  ├─ 有效成功 1 次 → recovery_confirming
  └─ 有效成功达到 recovery_successes → candidate
```

回候选后重新积累两次晋级确认，不能直接回优选。

### 5. 淘汰

```
任意状态 → eliminated
  条件：source_active=0 或 airport_enabled=0
  记录：source_inactive
  影响：只退出该类别，不删除 np_nodes
```

来源恢复且准入通过：

```
eliminated → observation(recovery_required=1)
  reason = source_readmitted
```

## 九、证据与幂等

证据 key 组合：

```
P4 evaluated_at
+ 质量分
+ 数据成熟度
+ TCP P80
+ 速度等级/速度值
+ P1 基础健康
+ P3 业务状态
+ P3 是否过期
+ P3 最后运行时间
```

规则：

1. 同一 key 重复运行不增加成功次数、不累计失败。
2. 观察期时间推进可在无新证据时触发晋级，但不重复计成功。
3. 候选、优选、恢复观察遇到重复 key 直接返回，不重复写状态。
4. 证据缺失时跳过该节点，保留上一份有效状态。

## 十、事务与失败恢复

1. 每类别独立事务。
2. 每节点 `SAVEPOINT p5_node`。
3. 单节点异常：`ROLLBACK TO p5_node`，仅该节点回滚，其他节点继续。
4. 类别异常：类别结果记错误，其他类别继续。
5. 运行状态 `success/partial`，失败说明写入 `np5_runs.message` 与 `detail_json`。
6. 竞争失败不覆盖上一份有效状态。
7. 系统重启后从 SQLite 读取当前状态、历史与运行记录。

## 十一、API 视图

### `GET /api/competition/summary`

返回：

- `categories[]`：六类 `code/label/title/short/states/total`。
- `preferred`：六类优选数。
- `preferred_standard`：标准综合优选数。
- `preferred_business`：五类业务优选数。
- `candidate_total`、`observation_total`、`eliminated_total`：六类合计。
- `distinct`：按状态去重节点数。
- `last_run`、`last_competition_at`。
- `settings`、`config_version`。
- `boundary`：`p1_write/p2_write/p3_write/p4_write=false`，`p5_only=true`，`p6/p7=false`。

### `GET /api/competition/nodes`

参数：

- `category`：默认 `standard`。
- `state`：可选四态。
- `q`：节点名/机场名关键词。
- `page`、`per_page`。

返回当前类别节点行、计数、分页信息。

### `GET /api/competition/nodes/{node_id}`

返回：

- 节点身份与机场来源。
- 六类状态卡。
- 当前类别准入检查明细。
- 当前类别历史。
- P1 原始池保留提示。

### `GET /api/competition/history`

参数：`node_id`、`category`、`limit`。返回追加式历史列表。

### `POST /api/competition/run`

请求体：

```json
{
  "trigger": "manual",
  "categories": ["standard", "gpt"],
  "refresh_p4": true
}
```

`categories` 省略时六类全跑；非法类别返回 400。运行锁忙时返回 `duplicate=true`。

## 十二、Dashboard 数据结构

`/api/dashboard` 的 `competition` 字段：

```json
{
  "preferred_standard": 1,
  "preferred_business": {"gpt":1,"youtube":1,"telegram":1,"github":1,"global":1},
  "candidate_total": 12,
  "observation_total": 18,
  "eliminated_total": 12,
  "last_competition_at": "2026-11-28 14:23:32",
  "categories": [...]
}
```

Dashboard 与竞争摘要同源，不允许前端另算或写死。

## 十三、数据保留与边界

1. 淘汰只改 P5 状态，不删除 P1 原始节点。
2. 降级保留历史分数、成熟度、准入快照。
3. 替换保留被替换节点 ID 与原因。
4. P5 表不登记进冻结的 `SUPPORTED_STRUCTURE_PROFILES`，沿用 P2–P4 旁路表懒创建方式。
5. P5 不写 P1–P4 表，不改变 17 表基线的结构哈希。
6. P5 不生成 P6 订阅文件，不做关键词过滤，不做版本追踪。
