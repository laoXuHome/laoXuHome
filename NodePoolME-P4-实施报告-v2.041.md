# NodePoolME P4 质量评价与下载速度实施报告

- 版本：v2.041（P4-02 最终边界修正版）
- 日期：2026-11-28
- 阶段：P4 七天质量评价、独立数据成熟度、独立下载速度评价
- 基线：v2.039（P4 初版，暂缓验收）
- 阶段边界：只做评价、测速调度、记录与展示；不实施 P5 智能竞争、晋级淘汰、标准综合优选名单和最终订阅发布。

## 一、阶段目标与完成结论

P4 在 P1 原始节点池、P2 基础健康检测、P3 业务专项检测之上，建立一套可追溯的节点质量档案：

1. 每个原始节点独立计算最近连续七天的质量分，不使用自然周。
2. 数据成熟度独立计算，不并入质量分；数据不足的节点只进入观察，不按零分处理。
3. 下载速度独立四级评价，无数据和机场排除不判为低速。
4. 质量评价与速度评价分别落库、分别展示，历史记录保留。
5. 后台「质量评价」页面同时提供摘要、节点表、节点详情、测速操作和参数设置；桌面端与移动端均可用。

P4 已完成施工。v2.039 经项目负责人审查发现三项问题，v2.040 只做定向修正：P4-01 有效可用率改为三时段加权；P4-02 补齐预热、超时、HTTP 异常等路径的字节累计并让 Worker 共享单源预算；P4-03 取消定时测速的随机时间分散，改为每周期单批次固定队列。P4-01、P4-03 已通过复审；v2.041 只修 P4-02 最后一个边界：`_ByteBudget.take()` 必须按实际 chunk 记账、区分实际/允许/超额，并在预算耗尽时通知所有 Worker 停止。专项与全量回归通过，提交重新验收；不进入 P5。

## 二、数据边界与落库

### 1. 只读的上游证据

| 来源 | 读取内容 | P4 行为 |
| --- | --- | --- |
| P1 `np_nodes` | 节点身份、机场来源、三层归属、P2 健康状态 | 只作为评价对象与展示信息，不修改节点身份、三层归属或健康状态 |
| P2 `np2_checks` | `success/failure/unknown` 快照、`p80_ms`、检测时间、配置版本 | 只读取确定性快照和 TCP P80；不修改 P2 结论 |
| P3 `np3_state` | 业务资格摘要 | 只在详情中展示关联，不修改业务资格 |

P4 不写 `np_nodes`、`np2_checks`、`np2_node_state`、`np3_state`，也不生成任何优选名单。测速排除只写 `airports.speed_excluded`，属于测速与速度评价的独立开关，不改变节点健康或业务资格。

### 2. P4 自有表

| 表 | 用途 |
| --- | --- |
| `np4_current` | 每个节点的最新质量、成熟度、速度等级、评价原因和配置版本 |
| `np4_evaluations` | 按节点×时间桶保存评价历史，支持每日质量变化追踪 |
| `np4_speed_meta` | 每次测速的有效性、归因、流量、配置版本；测速历史仍保留在 `speed_runs` 与 `speed_samples` |
| `np4_events` | 评价、配置变更、机场排除/恢复等事件 |

## 三、交付内容

### 1. 后端模块

- `backend/quality/calculator.py`：纯计算器，输入 P2 快照和配置，输出质量、成熟度、速度等级；不依赖数据库。
- `backend/quality/store.py`：P4 表、配置读写、测速元数据归因、历史查询。
- `backend/quality/service.py`：评价编排、摘要、列表/详情、测速入队、机场排除、定时 tick。
- `backend/api/routes.py`：新增 `/api/quality/*` 接口，全部要求登录。
- `backend/scheduler/manager.py`：新增 `job_quality_p4`，默认每 10 分钟刷新评价；`NODEPOOL_P4_SCHEDULER` 可关闭。
- `backend/services/speed_queue.py`：支持 `17:00–24:00` 测速窗口与跨日判断。
- `backend/testers/speedtest.py`：单次测速全轮共享 50 MB 预算，失败与超时不恢复额度。

### 2. API

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/quality/summary` | 质量与速度摘要、机场列表、当前配置、调度状态 |
| POST | `/api/quality/evaluate` | 手动刷新全部评价 |
| GET | `/api/quality/nodes` | 分页、搜索、质量状态与速度等级筛选 |
| GET | `/api/quality/nodes/{id}` | 节点质量、时段、每日趋势、测速历史、P1/P2/P3 关联 |
| GET | `/api/quality/settings` | 当前值、默认值、范围、说明与权重 |
| PATCH | `/api/quality/settings` | 保存并校验参数，冲突配置返回 400 |
| POST | `/api/quality/speed/test` | 手动、重新、新节点、全部重测入队 |
| PATCH | `/api/quality/airports/{id}` | 排除或恢复机场测速 |

### 3. 前端页面

- 新增 `/quality` 路由与侧栏第 7 项「质量评价」，侧栏共 10 项。
- 页面组成：6 张质量统计卡、三时段覆盖率、速度评价卡、机场排除、筛选、节点表、移动端卡片、节点详情抽屉、参数设置弹窗。
- 节点表展示：质量分、成熟度、有效快照、三时段覆盖、P80、稳定性、严重日/连续失败、速度等级与最近测速时间、操作。
- 节点详情展示：质量分与三项组成、成熟度与不足原因、三时段质量、每日趋势、速度中位数与历史测速、与 P1/P2/P3 的关系。

## 四、关键规则摘要

完整规则见同目录三份专项说明：

- `docs/P4-质量评价计算规则.md`
- `docs/P4-数据成熟度计算规则.md`
- `docs/P4-下载速度等级与计算规则.md`

要点：

1. 质量分固定由「有效可用率 50% + 延迟表现 30% + 延迟稳定性 20%」组成；有效可用率先按时段分别计算成功率，再按配置权重重归一化；仅确定性 Success/Failure 进入分母，Unknown、中断、无效快照完全排除。
2. 延迟只使用 P2 的 TCP Connect P80，不使用中位数、最低值、最高值或简单平均。
3. 三时段按配置权重加权；某时段无数据时只对有时段的时段重归一化，不把空时段判失败。
4. 单日严重故障（有效快照 ≥3 且可用率 <50%）或连续失败 ≥3 次时，质量分封顶 60，避免被七天平均掩盖。
5. 成熟度独立计算：每日有效快照 50%、达标评价天数 25%、7×3 时段覆盖 25%；默认每日 12 次、最低 5 天、成熟度 70%。
6. 未成熟节点 `quality_state=unknown`，只观察，不显示「不合格」，也不获得正式评价资格。
7. 速度四级：优 ≥5 MB/s、良 ≥2 MB/s、差 ≥512 KB/s、危 <512 KB/s；无数据与机场排除均为灰色，不判低速。
8. 速度取最近至多 3 次有效结果的中位数，不用单次最高值；默认有效期 7 天。
9. 单节点单次测速全轮共享 50 MB 预算，所有源、重试、Worker 共用；预热、失败、超时、HTTP 异常均按实际接收字节扣减并计入 `bytes_total`，不能靠重试或多请求绕过。
10. 测速失败按成功、节点自身失败、测速目标故障、检测服务异常、责任不明超时、任务中断分别归因；Unknown 不覆盖历史有效结果。

## 五、P4 定向修正（v2.040 / v2.041）

### 1. P4-01 有效可用率改为三时段加权

**原问题**：`quality_from_checks()` 直接用七天全部 Success/Failure 快照计算总体成功率，三个时段权重只作用于延迟，不影响可用率。

**修复**：

- 先由 `band_stats` 分别得到晚高峰、深夜、白天各自的有效成功率 `success / (success + failure)`。
- 再调用 `_weighted()`，只对至少有一个确定性快照的时段按配置权重重归一化，得到 `available_score`。
- `Unknown`、任务中断、无效快照仍不进入 `valid`，因此不进入任何时段分母。
- 延迟表现、延迟稳定性的现有时段加权逻辑未改；严重日和连续失败封顶规则未改。
- 默认权重仍为晚高峰 50%、深夜 15%、白天 35%。

验证 P4-01 时同时发现 v2.039 的评价批量刷新在 `db.transaction()` 内再次调用单节点保存和存储读取，会触发 SQLite「事务内再开事务」并使 `/api/quality/evaluate` 返回 500。v2.040 将批量刷新改为逐节点评价并按节点保存，评价规则与结果字段不变；新增 `test_evaluate_all_refreshes_and_saves_every_node` 覆盖该路径。

**测试证明**（`tests/test_quality_p4.py`，4 项新增）：

| 测试 | 构造 | 断言 |
| --- | --- | --- |
| `test_availability_is_weighted_by_three_time_bands` | peak 50%、night 100%、day 75% | 默认权重下可用率 66.25，质量分 63.1 |
| `test_availability_renormalizes_when_a_band_has_no_data` | 缺 night，peak 50%、day 75% | 按 `(50×50 + 35×75)/(50+35)` 得 60.3 |
| `test_unknown_never_enters_band_availability_denominator` | peak 额外加入 Unknown | peak 有效数仍为 2、成功率仍 50%，总可用率不变 |
| `test_changing_band_weights_changes_quality_score` | 权重改为 peak 20、night 20、day 60 | 可用率 75、质量分 87.5，且高于原权重结果 |

### 2. P4-02 修复测速流量漏记并共享预算

**原问题**：Worker 在预热阶段收到数据后超时，失败返回没有带回已收字节；正式阶段中途超时只带回 `measured_bytes` 且 `traffic_bytes=0`；HTTP 异常直接返回无字节样本；`_test_source()` 按 Worker 固定配额，不是单源共享预算。

**修复**：

- 新增 `_ByteBudget`，一个 Source 的所有 Worker 共用同一剩余额度；Range 分段按总预算精确切分，切片之和不超过总预算。
- Worker 从首个 HTTP body 数据块起累计 `total_bytes`，预热阶段和正式阶段都计入。
- 预热超时、正式阶段超时、HTTP 异常、连接中断返回时都携带 `bytes=total_bytes`、`traffic_bytes=total_bytes`。
- `_test_source()` 的 `traffic_bytes` 汇总所有 Worker（含失败 Worker），成功结果也用该值作为 `SourceResult.bytes`；`run_node()` 继续用同一个 `remaining` 跨源、跨重试扣减。
- 整轮超时无法取得各 Worker 最终字节时，按该 Source 全部剩余预算保守扣减，不恢复额度。
- `bytes_total` 等于本次实际累计流量，不再只统计成功测速阶段有效样本。

**测试证明**（`tests/test_speed_budget.py`，7 项新增）：

| 测试 | 场景 | 断言 |
| --- | --- | --- |
| `test_warmup_data_then_timeout_is_returned_and_budgeted` | 预热收到 100 字节后超时 | `bytes=100`、`traffic_bytes=100` |
| `test_midstream_timeout_keeps_warmup_and_measured_bytes` | 正式阶段收到 150 字节后超时 | 失败样本仍带回 150 字节，不丢预热字节 |
| `test_http_error_after_partial_data_keeps_received_bytes` | 收到 120 字节后 `httpx.ReadError` | 失败样本带回 120 字节 |
| `test_multi_worker_partial_failure_sums_all_received_bytes` | 两 Worker，一失败 40、一成功 100 | Source 实际为 140 字节，失败 Worker 不被丢弃 |
| `test_multi_source_retries_share_one_50mb_run_budget` | 同一源首次 30 MB、重试 20 MB | 两次额度为 50 MB / 20 MB，总 50 MB |
| `test_retry_after_failure_never_restores_budget` | 连续失败后再次重试 | 第二次只剩 10 MB，总不超 50 MB |
| `test_timeout_source_result_reports_conservative_budget` | 整轮超时 | 按剩余预算保守记为 100 字节，不恢复 |

### 3. P4-03 定时测速改为单批次固定队列

**原问题**：`enqueue_many(..., spread=(left,right))` 为每个节点计算不同 `not_before`，内部使用 `random.uniform(-slot*.3, slot*.3)` 随机分散，跟固定计划原则不一致。

**修复**：

- 删除 `random` 导入与 `spread` 参数；`enqueue_many()` 用同一个 `started = time.time()` 入队所有节点，保持传入节点顺序。
- 抽取 `schedule_once(now)`：每周期最多创建一个批次，写入 `speed_schedule_last_date` 防止当天重复创建；支持窗口外、未到间隔、窗口过短、无可测节点等跳过原因。
- 保留默认 17:00–24:00 窗口与跨日判断；不增加白天自动测速，不增加动态随机频率。
- 调度器仅按 `speed_parallel_nodes` 从统一队列取批次；同一节点由 `_active_for_node()` 去重。
- 手动测速、全部重新测试、新节点测速入口不变，仍走同一队列。

**测试证明**（`tests/test_schedule_p4.py`，4 项新增）：

| 测试 | 场景 | 断言 |
| --- | --- | --- |
| `test_schedule_creates_one_fixed_batch_in_window_and_never_repeats` | 窗口内 3 节点、并发 2 | 只建 3 个任务，节点顺序不变，`not_before` 全部相同；第二次调用 `already_ran`、0 新建 |
| `test_schedule_outside_window_does_nothing` | 12:00 窗口外 | 返回 `outside_window`，队列为空 |
| `test_overnight_window_uses_previous_day_and_does_not_repeat` | 20:00–02:00 跨日窗口，00:30 调用 | 归入前一天窗口日期，第二次调用不重复创建 |
| `test_configured_concurrency_is_the_batch_limit` | 并发设为 3 / 99 | 队列批次上限为 3 / 后端上限 8 |


### 4. P4-02 最终边界修正（v2.041）

**原问题**：`_ByteBudget.take(received)` 只执行 `granted = min(received, remaining); remaining -= granted`。Worker 收到 chunk 后只按 `granted` 扣预算，`total_bytes += len(chunk)` 只用于统计，`len(chunk)-granted` 的超额部分没有进入预算账本；即使 `remaining` 被扣到 0，实际流量也没有被记录为“超出预算”。同时 Worker 只在循环顶部检查 `budget.remaining <= 0`，没有共享事件通知其他已并发 Worker 停止后续读取。

**修复**：

- `_ByteBudget` 增加 `received`、`allowed`、`overage` 与共享 `asyncio.Event`。`take()` 每次按实际 `len(chunk)` 累加 `received`；只有落在剩余额度内的部分增加 `allowed` 并扣 `remaining`，超出部分增加 `overage`；余额为 0 时置位 `exhausted`。
- Worker 每收到一个 chunk 都先 `budget.take(actual)`，再累计 `total_bytes`。`granted < actual` 或事件已置位时标记 `traffic_limited`，当前 Worker 停止继续读取。
- 新增 `_next_chunk()`：有共享预算时，把“读取下一个 body chunk”和“等待 `exhausted` 事件”同时竞速；事件先到就取消读取并返回 `stopped`，因此一个 Worker 耗尽预算后，其他 Worker 不会继续发起下一块下载。
- 已由底层缓冲返回的最后一个 chunk 仍按实际字节入账，超出部分记为 `overage`；不恢复额度，也不转给其他 Worker。
- `SourceResult` 增加 `bytes_allowed`、`bytes_over`、`charged_bytes`。正常结果 `bytes` 为所有 Worker 实际字节之和，`bytes_allowed` 为预算内部分，`bytes_over` 为超额部分；整轮超时时 `bytes` 仍写共享预算已记录的实际字节，`charged_bytes` 按该 Source 全部剩余预算保守扣减，保证重试不恢复未确认额度。
- `run_node()` 用 `charged_bytes` 扣本轮 `remaining`，但 `bytes_total` 仍累计 `result.bytes` 实际流量；运行结果读取时由 `bytes_total` 与 `traffic_limit_bytes` 计算 `bytes_allowed`、`bytes_over`，并在 `message` 中写明三项数值。未修改 `speed_runs` / `speed_samples` 表结构、P4 其他评价规则、P1/P2/P3 或 P5/P6/P7。

**测试证明**（`tests/test_speed_budget.py`，新增 7 项）：

| 测试 | 构造 | 断言 |
| --- | --- | --- |
| `test_budget_take_charges_actual_chunk_and_records_overage` | 预算 5 字节，一次 chunk 8 字节 | `granted=5`、`received=8`、`allowed=5`、`overage=3`，余额 0 且事件置位；后续 4 字节不再分配 |
| `test_worker_last_chunk_over_budget_keeps_actual_and_records_overage` | Worker 预算 5，底层返回 chunk 8 | `bytes=8`、`traffic_bytes=8`、`traffic_limited=True`，预算记录 8 实际 / 5 允许 / 3 超额 |
| `test_budget_exhaustion_notifies_and_stops_other_worker` | 两 Worker，共享预算 100；首个 chunk 120 | 首 Worker 停止，第二 Worker 等事件后 0 读取；Source 实际 120、允许 100、超额 20，消息明示 |
| `test_multi_worker_near_budget_records_actual_allowed_and_over` | 两 Worker 各 60，共享预算 100 | 实际 120、允许 100、超额 20，不把 120 伪装成 100 |
| `test_run_level_bytes_total_keeps_overage_visible` | Source 实际 60 MB、允许 50 MB、超额 10 MB | `bytes_total=60 MB`、`bytes_allowed=50 MB`、`bytes_over=10 MB`，只申请一次 50 MB |
| `test_timeout_charged_bytes_do_not_restore_run_budget` | 整轮超时实际 10 MB，`charged_bytes=50 MB` | 不重试、`bytes_total=10 MB`；已确认预算不恢复 |
| `test_next_chunk_races_exhausted_event_and_cancels_slow_read` | 另一个 Worker 先耗尽预算，本 Worker 正在等慢速 chunk | 事件先到，取消读取并返回 `stopped=True`，不再等待下一块 |


## 六、验证结果

### 1. 自动化测试

| 范围 | 结果 |
| --- | --- |
| P4 修正专项集合（质量 13 + 测速策略 21 + 字节预算 15 + 调度 4） | `53 passed` |
| 全量回归（含 P1/P2/P3） | `499 passed, 1 skipped` |

P4 专项覆盖：质量与成熟度分离、未成熟观察不零分、Unknown 不扣分、严重日封顶、三时段可用率加权与空时段重归一化、速度边界与中位数、Unknown 不覆盖有效速度、机场排除灰色、阈值冲突拒绝。测速策略覆盖：50 MB 共享预算、失败扣减、窗口跨日、队列去重、机场排除、有效结果与无数据区分。v2.040 新增 17 项测试：P4-01 的 4 项、P4-02 的 8 项、P4-03 的 4 项，另有 1 项评价批量刷新事务回归。v2.041 在字节预算集合新增 7 项，覆盖 chunk 超余额、多 Worker 接近上限、耗尽事件停止与慢读取取消、实际/允许/超额区分、运行级流量不丢失和超时不恢复预算。

### 2. 接口实测

- `PATCH /api/quality/settings` 权重合计 100 校验：非法合计返回 400 `weight_sum`。
- 速度阈值顺序校验：`excellent < good` 返回 400 `speed_threshold_order`。
- 每日快照范围校验：超出 6–24 返回 400。
- 合法参数保存与恢复：返回当前值并提升配置版本。
- 机场排除 `PATCH /api/quality/airports/4`：排除、恢复均返回 200，恢复后不丢失其他检测数据。
- `POST /api/quality/speed/test` 对排除机场节点：返回 `created=0, excluded=1`，不误测。
- 节点详情：返回质量、成熟度、速度等级与 3 条历史测速。

### 3. 前端构建

`npm run build` 成功。v2.041 未改前端页面代码，产物 hash 与 v2.040 相同：

- `QualityP4-CBqVLaPd.css`（12.94 kB）
- `QualityP4-CWZjBjdt.js`（29.60 kB）

构建产物已复制到 `backend/static/assets/`，随离线包发布。

### 4. 页面验收截图

- 桌面全页：`nodepool-p4-desktop.png`
- 桌面节点详情：`nodepool-p4-drawer.png`
- 移动端全页：`nodepool-p4-mobile.png`
- 移动端节点详情：`nodepool-p4-mobile-drawer.png`
- 参数设置：`nodepool-p4-settings.png`

桌面表格已压缩列宽并取消固定列，避免右侧重叠；移动端 10 项导航与卡片布局均可用。v2.041 未改页面布局与演示数据，沿用 v2.040 已按三时段加权可用率重新生成的截图。

### 5. 提交与发布

v2.041（P4-02 最终边界修正）：

- 修正提交：`f0a7d5e fix(P4): charge actual speed bytes and stop workers on budget exhaustion (v2.041)`
- 版本标签：`v2.041`
- GitHub Actions：`46113211370`（tag v2.041，success）、`46113201713`（main，success）
- Release：`https://github.com/laoXuHome/NodePoolME/releases/tag/v2.041`
- 离线包：`https://github.com/laoXuHome/NodePoolME/releases/download/v2.041/nodepoolme-v2.041-offline-amd64.tar.gz`（amd64，84.5 MB）
- SHA256：`77cbd579266024bb9be943e98d655d17bc94e520f586c01dabfdf57f120b5716`

v2.040（P4-01/P4-02/P4-03 定向修正，保留历史）：

- 修正提交：`ed5b190 fix(P4): band-weighted availability, complete speed bytes and fixed schedule (v2.040)`
- 版本标签：`v2.040`
- GitHub Actions：`46110341639`（tag v2.040，success）、`46110336390`（main，success）
- Release：`https://github.com/laoXuHome/NodePoolME/releases/tag/v2.040`
- 离线包 SHA256：`c622d3623fb57ead36eb11c2e4754b48798f8104bd636bca326eb9f0a6fc10fe`

文档发布仓库：`laoXuHome/laoXuHome`。

## 七、阶段边界确认

本版未实施：

- 智能节点竞争、候选晋级、成熟节点替换、优选节点淘汰。
- 标准综合优选名单、业务专项优选名单生成。
- 最终关键词过滤与最终订阅发布。
- P5/P6/P7 的任何提前施工。

P4 只输出评价数据和后台展示，供 P5 后续消费；是否进入竞争、是否发布订阅仍由后续阶段决定。v2.041 最终边界修正完成后立即停止，不启动 P5/P6/P7。

## 八、已知约束

1. 七天评价周期在配置页固定为 7 天连续滚动，不提供改成其他天数的入口；这是本阶段对「七天」口径的显式约束。
2. 时区使用配置项，默认 `Asia/Shanghai`；时间桶按本地时间计算，不做夏令时切换。
3. 测速依赖 Mihomo 内核；TCP 引擎下测速返回 `engine_error`，归因为检测服务异常，不判节点低速。
4. 演示数据只用于页面验收，不代表真实节点长期表现。
