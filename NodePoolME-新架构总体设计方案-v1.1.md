# NodePoolME 新架构总体设计方案 v1.1

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`
**设计基准**：v1.0
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：仅三项阻断问题（P0-A 失败链 SQL / P0-B 历史迁移映射 / P0-C CHECK 约束迁移）。**未重新设计已过审章节。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C17 未批准）

---

## 修订索引（v1.0 → v1.1）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-A | `fail_chain()` 的 NULL 语义、pass 断链、排序确定性、`chain_stale` 不可达 | §3 | 修正 |
| P0-B | 历史 `unavailable` 状态的迁移映射与「历史未追认」 | §9.7、§10.3 | 补齐 |
| P0-C | `detection_task_runs` 的 CHECK 实际迁移（重建表 12 步） | §10.4 | 补齐 |

未修订：零健康九步顺序与参与集合（v1.0 §2）、`apply_result` 主流程（v1.0 §4，仅 §10.4 补 CHECK 迁移）、`fresh()`、快照对齐、外键三期、stable_id 六边界、Q1–Q12、30 天 missing、不改指纹、per-node 30 分钟、业务 90 分钟、测速窗口与 50MB、骤减双条件、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`、评分算法、前端布局。**C11–C17 全部未确认。**

---

## 0. 本轮修的是什么

三项都不是新设计，而是**上一版在真实 SQLite / 真实旧数据上跑不通的地方**：

| # | 表层问题 | 真实原因 |
| --- | --- | --- |
| P0-A | 「pass 打断链」在代码里没发生 | SQL 三值逻辑：`failure_source NOT IN (...)` 对 `NULL` 返回 `NULL`（非 `TRUE`），行被 `WHERE` 静默丢弃 |
| P0-B | 迁移后老故障节点「秒变健康」 | 新列默认 0，把"旧系统当前仍 unavailable"抹平了 |
| P0-C | 文档说"扩展 CHECK"，实际做不到 | SQLite 不支持 `ALTER TABLE` 改 `CHECK`，只能重建表 |

**共同教训**：文档里"逻辑上成立"和"在 SQLite 上成立"是两件事。v1.1 只补这三处，不加新功能。

---

## 1. 保留的既定设计

Q1–Q12 全部保留；`missing` 30 天（最短 7）；不改指纹；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减"7 天中位降 ≥50% 且绝对减 ≥10" + 两次独立拉取确认；零健康最多留上一版 24h、硬上限 72h；30 个可恢复版本；恢复两次独立有效 Mihomo 成功且间隔 ≥30 分钟（Q11）；TCP-only 永不合格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不改。

---

## 2. 零健康判定（v1.0 定稿，不改）

九步顺序（零分母在 `cov` 之前）：`all_disabled` → `scope_blocked(invalid_window)` → `scope_blocked(empty_unverified)` → `no_nodes` → `zero_denominator` → `scope_blocked(no_response)` → `cov`/`rep`/`U_unk` → `normal` → `zero_health`。集合口径与状态表沿用 v1.0 §2。

**唯一受影响处**：`U_unk` 的判定依赖 §3 的 `has_fail_evidence()`，本节 P0-A 修正后，证据链才真正可用。

---

## 3. P0-A：失败链查询的 NULL 语义与断链

### 3.1 `failure_source` 的存储语义（必须先定）

| 结果类型 | `mode` | `failure_source` | 说明 |
| --- | --- | --- | --- |
| 正常 Mihomo **成功** | `mihomo` | **`NULL`** | 没有发生失败，所以没有失败来源。这是语义正解，不是缺数据 |
| 正常 Mihomo **失败**（超时、握手失败、5xx 等业务性失败） | `mihomo` | `NULL` 或具体业务码 | 两者都算有效失败；`NULL` 不改变其"有效失败"属性 |
| TCP-only 降级 | `tcp_only` | `NULL` | 由 `mode` 排除，与 `failure_source` 无关 |
| 引擎异常 | `mihomo` | `engine` | 系统类，不计入、不断链 |
| 调度异常 | 任意 | `scheduler` | 同上 |
| 系统异常（DB/磁盘/进程） | 任意 | `system` | 同上 |
| 目标服务事故（上游 5xx 集群级） | `mihomo` | `target_incident` | 同上 |

### 3.2 v1.0 的 SQL 缺陷

```sql
-- v1.0（错）
WHERE ... AND failure_source NOT IN ('engine','scheduler','system','target_incident')
```

在 SQLite 中 `NULL NOT IN (...)` 的结果是 `NULL`，`WHERE` 视同不成立 → **所有 `failure_source IS NULL` 的行（包括正常成功）被整体丢弃**。后果：链扫描看不到 pass，于是"遇 pass 断链"永远不触发，一条跨越多次成败的历史被连成一条虚假的连续失败链（P0-A.1、P0-A.2）。

### 3.3 修正后的查询

```python
SYSTEM_SOURCES = ("engine", "scheduler", "system", "target_incident")   # 只含系统类

def fail_chain(node, target, t, W, T):
    rows = sql("""
        SELECT result_id, finished_at, last_result, mode, failure_source
          FROM results
         WHERE node_id = ?
           AND target = ?
           AND valid = 1
           AND mode = 'mihomo'
           AND config_version = ?
           AND rule_version   = ?
           AND ( failure_source IS NULL                       -- ← 关键：NULL 必须放行
                 OR failure_source NOT IN ('engine','scheduler','system','target_incident') )
         ORDER BY finished_at DESC, result_id DESC           -- ← 时间相同也要确定
    """, node.id, target, node.config_version, active_rule_version(t))

    chain = []
    for r in rows:
        if r.finished_at <= t - W:            break          # 越界 → 链终止
        if r.last_result != "fail":           break          # 有效 pass → 断链
        chain.append(r)                                       # 窗口内的 fail 才入链
    return chain
```

**过滤行为逐类说明（P0-A.5）**：

| 行 | `mode` | `failure_source` | 是否进扫描结果 | 是否入链 | 是否断链 |
| --- | --- | --- | --- | --- | --- |
| 正常成功 | `mihomo` | `NULL` | **是** | 否 | **是（断链）** |
| 正常失败 | `mihomo` | `NULL` | **是** | **是** | 否 |
| 正常失败 | `mihomo` | `timeout` 等业务码 | 是 | 是 | 否 |
| 引擎/调度/系统/目标事故 | 任意 | 四类之一 | 否 | 否 | 否（透明） |
| TCP-only | `tcp_only` | 任意（含 NULL） | 否 | 否 | 否（透明） |
| 旧版本结果 | 任意 | 任意 | 否（版本等值过滤） | 否 | 否 |

> 注意"透明"的含义：系统类与 TCP-only 行**被 `WHERE` 剔除**，因此它既不增加失败次数，也不把前后两次真实失败打断。这是有意的——系统故障不是这台机器的失败。
>
> 同时它带来一个必须承认的副作用：一条引擎异常**夹在** pass 与 fail 之间时，链上看不到它，顺序仍是"pass 后跟 fail"→ 正常断链，不受影响。这一条已由 FE13 覆盖。

### 3.4 排序确定性（P0-A.6）

`ORDER BY finished_at DESC, result_id DESC`：

- `finished_at` 相同（同批次多目标、毫秒级并发）时，用 `result_id` 单调主键做次键；
- 保证同一数据集任意次查询得到**同一顺序**，从而断链点可复现；
- `result_id` 必须单调递增（SQLite `INTEGER PRIMARY KEY` 的 `rowid` 语义即可满足）。

### 3.5 `chain_stale` 的不可达与统一

v1.0 有 `if not (t - W < c[0].finished_at <= t): return chain_stale`。但链内元素是循环中 `> t-W` 才 `append` 的，因此 `c[0]` **不可能** `<= t-W`——**`chain_stale` 分支不可达**（P0-A.7）。

统一后的返回约定（只有两个原因码）：

| 原因码 | 触发条件 | 语义 |
| --- | --- | --- |
| `chain_short` | `len(chain) < T`（含"因越界被提前终止"、"因 pass 断链"、"记录不足"） | 当前不足 T 条连续有效失败 |
| `chain_future` | 最新记录 `finished_at > t`（时钟回拨/时区错乱导致） | 数据时间异常，本次不作证据 |

```python
def has_fail_evidence(node, target, t):
    rows = fetch_rows(node, target, t)        # 同 §3.3 的 SQL（不截断未来行）
    if rows and rows[0].finished_at > t:      # 排序 DESC，首行即最新
        return False, "chain_future"          # 时钟/时区异常，本次不作证据
    c = build_chain(rows, t, W)               # 逐行 break（越界 / pass）
    if len(c) < T:                            return False, "chain_short"
    return True, None
```

> 注意 `chain_future` 的检测**必须在构建链之前**：若把"未来时间"也写进循环 `break`，该分支就会变得不可达——这正是 v1.0 `chain_stale` 的同类错误。v1.1 把两件事分开：**未来行**在入口判、**过期行**在循环里截断（归入 `chain_short`）。

`chain_stale` 从文档与实现中**删除**；原先想表达的"记录过期"已由 `chain_short`（越界被截断）覆盖。同时把"数据时间异常"独立成 `chain_future`，并写 `system_events(clock_skew)`——避免它被误当成普通证据不足而长期无人发现。

### 3.6 完整性校验（可复核性不变）

`system_events.evidence_chain` 记录入链的 `result_id` 列表（按扫描顺序），审计可逐条打开核对 `finished_at` / `config_version` / `rule_version` / `last_result`。`fail_streak` 仍**不得**单独作为证据（v1.0 §3.3 不变）。

### 3.7 测试 FE11–FE14

| # | 初始数据 | 步骤 | 预期库 | 预期业务 | 失败时不变项 |
| --- | --- | --- | --- | --- | --- |
| FE11 | 目标 G 三条结果：fail(`t-40m`)、**pass(`t-30m`, `failure_source=NULL`)**、fail(`t-10m`) | 调 `fail_chain` | `chain=[t-10m 的 fail]`，长度 1 | `has_fail_evidence=False(chain_short)` | `fail_streak` 不变；`results` 不改写 |
| FE12 | fail(`t-40m`, `failure_source=NULL`)、fail(`t-30m`, NULL)、fail(`t-10m`, 业务码) | 同上 | `chain` 长度 3，按 `finished_at DESC` | `True`；NULL 失败正常计入 | 同上 |
| FE13 | fail(`t-40m`)、engine(`t-30m`)、fail(`t-20m`)、fail(`t-10m`) | 同上 | `chain` 长度 3（engine 行不在结果集） | `True`；系统异常不计数不断链 | 同上 |
| FE14 | 三条 fail 的 `finished_at` 完全相同（同批次），`result_id` 为 11/12/13 | 连续查询 5 次 | 每次顺序均为 `13,12,11` | 断链点可复现；`evidence_chain` 顺序稳定 | 同上 |

---

## 4. `apply_result`（v1.0 定稿，仅补 CHECK 说明）

合法枚举唯一来源：

```python
VERDICTS = ("pass", "fail", "invalid", "stale")
```

执行顺序（不变）：步骤 0 幂等 → 1 事务内读 task → 2 `exec_cv`/`exec_rv`/`exec_target` 三比对 → 3 事务内读 node/rule → 4 身份/生命周期/目标/版本校验 → 5 verdict 白名单（非法 → `invalid/invalid_verdict`，`applied=0`）→ 6 登记 → 7 仅 pass/fail 写状态。

**本轮唯一补充**：`detection_task_runs.outcome` 的 `CHECK` 在既有库上**无法用 `ALTER` 修改**，必须重建表（详见 §10.4）；重建后 `CHECK` 与 `VERDICTS` 仍须同版同集合（TV4 / M13 / M14）。

---

## 5. `fresh()`（沿用 v1.0）

```python
def result_valid(n, g, t, now):
    return (t.last_result == "pass"
            and t.config_version == n.config_version
            and t.rule_version == active_rule_version(now)
            and t.mode == "mihomo"
            and t.failure_source not in SYSTEM_SOURCES
            and t.valid == 1
            and t.last_pass_at + t.ttl > now)
```

**与 §3 的一致性检查**：`fresh()` 里 `failure_source not in SYSTEM_SOURCES` 同样存在 NULL 问题吗？不存在——此处 `NULL not in (...)` 为 `NULL`，Python 的 `not in` 对 `None` 返回 `True`（`None not in tuple` 为 `True`），语义正确：NULL 不是系统故障。**但实现必须用 Python 判断（如上），不得改成 SQL 里的 `NOT IN`**，否则又会踩同一个坑。

---

## 6. presence 快照对齐（沿用 v1.0）

快照 `W_snap(D) = (D-7d 00:00, D 00:00]`，`snapshot_as_of` 精确到秒；仅窗口完全一致才可直接回退；`U_before(t)` 一律用 log；`U7_prev(t)` 仅 `t = 某日 00:00:00` 且 log 不足时用快照；`median7` 只允许快照，缺行 → log 重放 → 仍不足 → `baseline_insufficient`。降级状态：`snapshot_mismatch` / `snapshot_lagging` / `tz_mismatch`。

---

## 7. 外键与迁移三期（沿用 v1.0，§10.4 遵从同一规则）

| 期 | 允许 | 禁止 |
| --- | --- | --- |
| `before-begin` | 备份、`quick_check`、记录 `foreign_keys` 原值、**必要时**（表重建）设 `OFF`、`busy_timeout` | 任何 DDL |
| `in-tx` | `BEGIN IMMEDIATE`、DDL、`foreign_key_check`（只读）、数据搬运 | **任何 PRAGMA 切换** |
| `after-commit` | 恢复 `foreign_keys` 原值并校验、复查 `foreign_key_check`、写 `schema_migrations(success)` | 再次 DDL |

目标 DDL：`restore_authorizations.token` 主键；`nodes.restore_token TEXT REFERENCES ... ON DELETE RESTRICT`；`uq_nodes_restore_token`；回池三触发器。外键负向测试 FK1–FK5 沿用。

---

## 8. stable_id 六种边界（沿用 v1.0）

两路独立（`claim_candidate` 提示 / `node_assignment` 结论）；B1 多 live → `hold`；B2 配置与 live 冲突（H1）→ `released(reused)` + 新建；B3 `reused` 禁止 readopt；B4 `absent` + 配置一致 → readopt；B5 同轮竞争 → 保留 `occurrence_seq` 最小者；B6 不可判定 → `hold`，不得静默继承。

---

## 9. 恢复：曾失败 vs 曾不可用（v1.0 规则 + P0-B 迁移补丁）

### 9.1 两个历史事实

| 字段 | 含义 | 用途 |
| --- | --- | --- |
| `target_ever_fail` | 该目标是否曾发生有效失败（≥1 次） | **仅诊断** |
| `target_ever_unavailable` | 该目标是否曾真正达门槛进入 `unavailable` | **唯一**决定是否需 Q11 恢复确认 |

### 9.2 目标层判定表（不变）

| 条件 | 需要 Q11 | 判定 |
| --- | --- | --- |
| `target_ever_unavailable = 0` | 否 | 当前版本新鲜有效 pass 即可 |
| `= 1` 且 `recovery_state='none'` | 是 | 首次成功 → `observing`（计数 1、`first_success_at`） |
| `= 1` 且 `observing` | 是 | 第二次成功且间隔 ≥30 分钟 → `confirmed` |
| 间隔 <30 分钟 | 是 | 计数不增加 |
| `observing` 期间有效失败 | 是 | 计数归零、`first_success_at=NULL`；若达门槛回 `unavailable` |
| `confirmed` 后再达门槛 | 是 | 重进 `observing`、计数 0 |
| 系统/TCP/stale/过期 | — | 不推进、不重置 |

### 9.3 节点级聚合（不变）

先"全员新鲜"，再"任一 `target_ever_unavailable=1` 且未 `confirmed` → `recovering`"，否则 `healthy`。

### 9.4 配置升级（不变）

`target_ever_unavailable=1` 的目标：恢复证据作废（`observing`、计数 0），需在新 `config_version` 下重新两次；`target_ever_unavailable` 本身不清零。`=0` 的目标只需一次新版本 pass。

### 9.5 v1.0 的迁移缺陷（P0-B 的来源）

v1.0 §10.1 写"历史行默认 `target_ever_unavailable=0`"，理由是"不猜测过去"。这条对**已经恢复的**节点是合理的，但对**迁移前仍处于 `unavailable`** 的节点是灾难：迁移后它们变成"从未不可用"，一次成功 pass 立刻 `healthy`，绕过 Q11（P0-B.1、P0-B.2）。

### 9.6 迁移映射（P0-B 的核心，规则表）

对旧系统每个节点 N 的每个必需目标 G：

| 情形 | 旧数据判据 | `target_ever_fail` | `target_ever_unavailable` | `recovery_state` | 说明 |
| --- | --- | --- | --- | --- | --- |
| M-A | `nodes.state='unavailable'` **且** 目标级结果链可证明 `fail_streak ≥ T`（同版本、窗口按旧口径） | 1 | **1** | `observing`（计数 0、`first_success_at=NULL`） | 有目标级证据，精确置位 |
| M-B | `nodes.state='unavailable'` **但** 无可靠目标级状态（旧系统只有节点级 `state`/`fail_count`） | 1 | **1（保守：全部必需目标）** | `observing`（计数 0） | **不得**默认 0；宁可多要求一次恢复 |
| M-C | `nodes.state ≠ 'unavailable'` 且 `fail_count > 0` | 1 | **0** + `history_unattested=1` | `none` | 历史不可追认（可能曾 unavailable 后又恢复）；只能标"未追认"，不得假装 0 是事实 |
| M-D | `nodes.state ≠ 'unavailable'` 且 `fail_count = 0` | 0 | 0 | `none` | 无失败史 |

**四条硬约束（P0-B 的要求）**：

1. 迁移**必须读取**旧 `nodes.state`、`nodes.fail_count` 与旧 `results`（不得只看新表默认值）。
2. 只要能明确确认"迁移时刻仍 `unavailable`"→ `target_ever_unavailable=1`；无目标级证据时**全部必需目标置 1**（保守）。
3. 旧 `fail_count` **不是** Q11 完成证据：即便 `fail_count=5` 且当前 `healthy`，也只能置 `target_ever_fail=1`，**不得**置 `recovery_state='confirmed'`；`success_count` 一律 0。
4. 不可追认的（M-C）必须落库标记（`target_history_unattested=1`）并在 UI 显示"历史未追认"，禁止静默当 0。

### 9.7 新增字段

```sql
node_target_state:
  target_ever_unavailable     INTEGER NOT NULL DEFAULT 0,
  target_history_unattested   INTEGER NOT NULL DEFAULT 0,
  recovery_state              TEXT CHECK(recovery_state IN ('none','observing','confirmed')),
  recovery_success_count      INTEGER NOT NULL DEFAULT 0,
  first_success_at            TEXT,
  confirmed_at                TEXT
nodes:
  ever_unavailable            INTEGER NOT NULL DEFAULT 0,
  history_unattested          INTEGER NOT NULL DEFAULT 0
```

### 9.8 迁移后的行为验证（RG15–RG18）

| # | 初始（迁移前旧库） | 步骤 | 预期库 | 预期业务 | 失败时不变项 |
| --- | --- | --- | --- | --- | --- |
| RG15 | N `state='unavailable'`、`fail_count=4`；旧 `results` 有 G 的 3 条同版本连续 fail | 执行迁移 | G 行 `target_ever_unavailable=1`、`recovery_state='observing'`、计数 0；`history_unattested=0` | 迁移后开门即为"待恢复" | 旧 `results` 行不改写；`nodes.state` 仍 `unavailable` |
| RG16 | N `state='unavailable'`，旧库无目标级状态（只有 `fail_count=5`），两必需目标 G/W | 执行迁移 | **G、W 均** `target_ever_unavailable=1`、`observing`、计数 0 | 保守：两个目标都要两次成功 | 不得只置其一个为 1 |
| RG17 | N `state='healthy'`、`fail_count=2`（曾失败后恢复，无历史 `unavailable` 记录） | 执行迁移 | 两目标 `target_ever_unavailable=0`、`target_ever_fail=1`、`history_unattested=1`、`recovery_state='none'` | 一次新鲜 pass 即可 `healthy`；UI 标"历史未追认" | 不置 `confirmed`；`success_count=0` |
| RG18 | 承接 RG15（G `observing`、计数 0） | G 来一条 pass | `recovery_state` 仍 `observing`、计数 1；`nodes.state` **不得** 变 `healthy` | 第一次 pass 只进观察，必须第二次（≥30 分钟） | `target_ever_unavailable` 保持 1；`fail_streak` 归零但状态不升 |

---

## 10. 迁移与兼容

### 10.1 变更清单

| 变更 | 对象 | 方式 |
| --- | --- | --- |
| `target_ever_unavailable` / `target_history_unattested` | `node_target_state` | 加列（默认 0）+ 数据回填（§9.6） |
| `ever_unavailable` / `history_unattested` | `nodes` | 加列（默认 0）+ 回填 |
| `idx_results_chain(node_id, target, finished_at DESC, result_id DESC)` | `results` | 建索引（§3.4 排序需要次键） |
| `outcome` CHECK 扩为 4 值 | `detection_task_runs` | **重建表**（§10.4） |
| 事件字段 `evidence_chain` / `clock_skew` | `system_events` | 语义 |

### 10.2 顺序（三期）

```
[before-begin] 备份 + quick_check + 记录 foreign_keys 原值
               （若需重建 detection_task_runs → foreign_keys=OFF，必须在 BEGIN 之前）
[in-tx]        node_target_state 加列 → nodes 加列 → idx_results_chain
               → 数据回填（§9.6，读旧 state/fail_count/results）
               → detection_task_runs 重建（12 步，§10.4）
               → foreign_key_check（只读）
[after-commit] 恢复 foreign_keys 原值并校验 → 复查 foreign_key_check
               → 行数/关键字段比对 → 写 schema_migrations(success)
```

**回填与重建的顺序不可颠倒**：回填依赖旧 `results` 与旧 `nodes.state`；先重建 `detection_task_runs` 不影响这两者，但先回填能保证"回填失败 → 整事务回滚 → 旧库完好"。

### 10.3 旧库读取口径（P0-B.1）

| 需要的旧数据 | 读取方式 | 缺失时 |
| --- | --- | --- |
| 节点级状态 | `nodes.state`（`healthy`/`observe`/`unavailable`/`missing`） | 视为 `≠unavailable` → 走 M-C/M-D |
| 节点级失败计数 | `nodes.fail_count` | 视为 0 → M-D |
| 目标级链 | 旧 `results` 按 `node_id`+`target` 倒序取连续 fail | 无 → 走 M-B（保守置 1） |
| 旧配置版本 | 旧库无版本概念 → 全部映射为 `config_version=1` | — |

### 10.4 `detection_task_runs` 的 CHECK 迁移（P0-C）

**为什么必须重建**：SQLite 的 `ALTER TABLE` 只支持加列/改名/加删列，**不能修改既有 `CHECK`**；`CREATE TABLE ... CHECK` 在创建时固化为表 SQL 文本，改不了。因此有两种路径：

| 路径 | 条件 | 做法 |
| --- | --- | --- |
| C-1 建新表 | 旧库**尚无** `detection_task_runs`（v1.8.7 实际情况：该表是 v0.6 设计引入的新表） | 直接 `CREATE TABLE` 带四值 `CHECK`，**无重建** |
| C-2 重建表 | 已存在旧表（曾按 v1.0 建过、且 CHECK 只有 3 值或没有 CHECK） | 走 SQLite 官方 12 步重建 |

**C-2 的 12 步（`before-begin` 关 FK，`in-tx` 只做 DDL/DML）**：

```sql
-- [before-begin]
-- PRAGMA foreign_keys = OFF;        ← 必须在 BEGIN 之前
-- 备份 + PRAGMA quick_check; 记录原 foreign_keys 值

-- [in-tx]
BEGIN IMMEDIATE;

-- ① 新表：完整定义（含四值 CHECK，与 VERDICTS 同集合）
CREATE TABLE detection_task_runs__new (
  task_id            TEXT PRIMARY KEY,
  node_id            INTEGER,
  outcome            TEXT NOT NULL
                     CHECK (outcome IN ('pass','fail','invalid','stale')),
  stale_reason       TEXT,
  exec_config_version INTEGER,
  exec_rule_version   INTEGER,
  finished_at         TEXT NOT NULL,
  applied             INTEGER NOT NULL DEFAULT 0 CHECK (applied IN (0,1)),
  recorded_at         TEXT NOT NULL
);

-- ② 全量搬运（旧 outcome 值原样保留；不因新增 invalid 丢行）
INSERT INTO detection_task_runs__new
  SELECT task_id, node_id, outcome, stale_reason,
         exec_config_version, exec_rule_version,
         finished_at, applied, recorded_at
    FROM detection_task_runs;

-- ③ 行数比对（必须在 DROP 之前）
--    SELECT COUNT(*) 两表相等 → 否则 RAISE/ROLLBACK

-- ④ 删除旧表、改名
DROP TABLE detection_task_runs;
ALTER TABLE detection_task_runs__new RENAME TO detection_task_runs;

-- ⑤ 重建索引（若旧表有）
--    CREATE UNIQUE INDEX uq_runs_task ON detection_task_runs(task_id);  -- 已是 PK，可省
--    CREATE INDEX idx_runs_node ON detection_task_runs(node_id, recorded_at DESC);

-- ⑥ 外键检查（只读，允许在事务内）
PRAGMA foreign_key_check;
-- 必须返回 0 行

COMMIT;

-- [after-commit]
-- PRAGMA foreign_keys = ON;         ← 恢复原值（原为 ON 时必须恢复）
-- PRAGMA foreign_key_check;         ← 再查一次，必须为空
-- 校验：SELECT COUNT(*) 与迁移前相等；抽样比对关键字段；写 schema_migrations(success)
```

**六条约束（P0-C 的要求）**：

| # | 要求 | 落地 |
| --- | --- | --- |
| 1 | 检查基准 Schema 的实际 CHECK | C-1 建新表（无旧表）；C-2 重建（有旧表）；文档两种情况都给 |
| 2 | 明确是否需要重建 | 需要（C-2）；C-1 不需要 |
| 3 | 完整迁移顺序 | 上述 12 步，含备份/完整性/行数/关键字段/`foreign_key_check` |
| 4 | 事务内禁止切换 PRAGMA | `OFF` 只在 `before-begin`，`ON` 只在 `after-commit` |
| 5 | 旧 outcome 数据完整保留 | `INSERT ... SELECT` 全量搬运；DROP 前行数比对；`invalid` 是**新增**取值，旧行不受影响 |
| 6 | 无 CHECK 时也要给最终约束 | C-1 的 `CREATE TABLE` 已带四值 CHECK；C-2 的重建表同样带 |

**失败与恢复**：任一断言失败 → `ROLLBACK`；旧表仍在（因为 `DROP` 在事务内，回滚即恢复）；`finally` 恢复 `foreign_keys`；若进程在 `COMMIT` 前崩溃 → 自动回滚，`detection_task_runs__new` 可能残留 → 启动扫描并按 `migration_journal` 判定：未提交则 `DROP`（仅在确认无 success 行时），已提交则忽略。

### 10.5 兼容承诺

- 全部加法或"重建后等价"；历史数据不重算（除 §9.6 的显式回填）。
- 四种格式、四 URL、UA、Token、两种 `sub_publish`、测速、评分、前端布局**未改**。
- 前端增量展示：`evidence_chain` 长度、`chain_future` 告警、`target_ever_unavailable`、`history_unattested` 标记、`invalid_verdict` 计数。

---

## 11. 测试矩阵

### 11.1 汇总

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务 T | 14 | T1–T14 |
| 有效性 V | 4 | V1–V4 |
| 并发 CT | 3 | CT1–CT3 |
| 约束 FT | 23 | FT1–FT23 |
| 令牌 F/FK | 27 | F1–F22 + FK1–FK5 |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP12 |
| 零健康 Z | 30 | Z1–Z30 |
| 失败链 FE | 14 | FE1–FE10 + FE11–FE14 |
| 恢复 RG | 18 | RG1–RG14 + RG15–RG18 |
| verdict TV | 4 | TV1–TV4 |
| 迁移 M | 16 | M1–M11 + M12–M16 |

### 11.2 M 组详测（P0-C）

**M12｜旧数据完整迁移**

- 初始：旧 `detection_task_runs` 12 行，`outcome` 分布 `pass×7 / fail×3 / stale×2`（无 `invalid`）。
- 步骤：执行 §10.4 的 12 步。
- 预期库：新表 12 行，`task_id`、`outcome`、`stale_reason`、`exec_*`、`finished_at`、`applied`、`recorded_at` 逐列与旧表一致（可 `EXCEPT` 双向比对为空）。
- 预期业务：历史证据不丢，`stale` 行仍 `applied=0`。
- 不变项：旧表数据在回滚场景下仍可用；`detection_tasks` 不被触碰。

**M13｜四种合法 outcome 均可写入**

- 初始：迁移后的新表。
- 步骤：依次 `INSERT` 四条（`pass`/`fail`/`invalid`/`stale`，`task_id` 各异）。
- 预期库：4 行全部成功写入，`CHECK` 不报错。
- 预期业务：`invalid` 枚举在旧库上也能用（否则 `invalid_verdict` 无法落库）。
- 不变项：已有 12 行不受影响。

**M14｜非法 outcome 被 CHECK 拒绝**

- 初始：同上。
- 步骤：`INSERT` `outcome='timeout'`。
- 预期库：`sqlite3.IntegrityError: CHECK constraint failed`；表行数不变。
- 预期业务：DB 层兜底生效（应用层已在步骤 5 先拒）。
- 不变项：全部行。

**M15｜迁移中途失败**

- 初始：旧表 12 行；在第 ③ 步行数比对处注入失败（或第 ④ 步前 kill）。
- 步骤：执行迁移。
- 预期库：`ROLLBACK` 后旧表 12 行完好；`detection_task_runs__new` 不存在（或残留但**不被使用**）；`foreign_keys` 已恢复原值。
- 预期业务：可重跑迁移，无数据损失。
- 不变项：`schema_migrations` 无 `success` 行。

**M16｜索引/触发器/外键/行数验证**

- 初始：迁移完成。
- 步骤：`PRAGMA foreign_key_check`（期望 0 行）；`PRAGMA index_list(detection_task_runs)`；核对触发器清单（回池 3 + 既有 5）；两表行数比对。
- 预期库：`foreign_key_check` 0 行；索引存在；触发器数量 8；`COUNT(*)` 与迁移前相等。
- 预期业务：结构与约束等价。
- 不变项：数据不变。

---

## 12. v1.0 → v1.1 修订对照

| # | v1.0 | v1.1 | 章节 |
| --- | --- | --- | --- |
| P0-A | `NOT IN` 直接过滤 `failure_source`，NULL 行被丢弃 → pass 不断链 | `(failure_source IS NULL OR ... NOT IN (...))`；NULL 成功断链、NULL 失败入链；四类系统/TCP 透明；`ORDER BY finished_at DESC, result_id DESC`；删 `chain_stale`、增 `chain_future` | §3 |
| P0-B | 迁移默认 `target_ever_unavailable=0`，"当前仍 unavailable"被抹平 | 四情形映射表（M-A～M-D）；无目标级证据时全目标保守置 1；`history_unattested` 标记；`fail_count` 不得当 Q11 证据 | §9.5–9.8、§10.3 |
| P0-C | "扩展 CHECK"不可执行 | C-1 建新表 / C-2 重建表 12 步；`FK OFF` 只在 BEGIN 前；DROP 前行数比对；提交后复查 | §10.4 |

---

## 13. 三项 P0 关闭清单

| 来源 | 问题 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- | --- |
| P0-A.1 | `failure_source` 存储语义未定 | §3.1 | FE12/FE11 | 已关闭 |
| P0-A.2 | NULL 导致 pass 被 `WHERE` 过滤 | §3.3 | FE11 | 已关闭 |
| P0-A.3 | 有效 pass 必须断链 | §3.3 循环 `break` | FE11 | 已关闭 |
| P0-A.4 | 系统类/TCP 不计数不断链 | §3.2 表 + §3.3 | FE13 | 已关闭 |
| P0-A.5 | NULL/失败/成功/系统四类过滤行为 | §3.3 逐行表 | FE11–FE13 | 已关闭 |
| P0-A.6 | 同 `finished_at` 顺序不确定 | §3.4 次键 `result_id DESC` | FE14 | 已关闭 |
| P0-A.7 | `chain_stale` 不可达 | §3.5 删除并拆出 `chain_future` | FE14/§3.5 | 已关闭 |
| P0-B.1 | 迁移未读旧状态 | §10.3 读取口径 | RG15/RG16 | 已关闭 |
| P0-B.2 | 当前 unavailable 未置 1 | §9.6 M-A/M-B | RG15 | 已关闭 |
| P0-B.3 | 无目标级状态的保守映射 | §9.6 M-B（全部必需目标置 1） | RG16 | 已关闭 |
| P0-B.4 | 历史不可追认未标记 | `target_history_unattested=1` | RG17 | 已关闭 |
| P0-B.5 | 配置升级重建规则 | §9.4（不变） | RG13 | 已关闭 |
| P0-B.6 | `fail_count` 被当 Q11 证据 | §9.6 硬约束 3 | RG15/RG17 | 已关闭 |
| P0-C.1 | 基准 CHECK 定义未核 | §10.4 C-1/C-2 | M12/M13 | 已关闭 |
| P0-C.2 | 是否需重建 | §10.4（C-2 需重建） | M12 | 已关闭 |
| P0-C.3 | 迁移顺序 | §10.4 12 步 | M12/M15/M16 | 已关闭 |
| P0-C.4 | 事务内切 PRAGMA | §7 + §10.4（OFF 仅 before-begin） | M15/M16 | 已关闭 |
| P0-C.5 | 旧 outcome 保留 | `INSERT ... SELECT` + 行数比对 | M12 | 已关闭 |
| P0-C.6 | 无 CHECK 情况 | C-1 建表即带四值 CHECK | M13/M14 | 已关闭 |

---

## 14. 未解决问题与待确认

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（走三期） | 未确认 |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口（6h / 最近 3 次） | 6h 优先 | 未确认（`W` 同时作为失败链窗口） |
| C15 | `rep` 门槛（0.90 / 0.60） | 0.90 确认 | 未确认 |
| C16 | retired 回归是否复用原 identity | 允许（新建 config_version） | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |

**事实缺口（非决策，需实测）**

1. 旧库 `results` 是否真的按 `target` 分行——若旧表只有节点级结果，M-A 恒不可用，全部走 M-B（保守），恢复成本上升；
2. 旧 `nodes.state` 取值域是否与设计一致（`healthy/observe/unavailable/missing`）；
3. `idx_results_chain` 在 results 万级行下的实际查询代价（链查询每次最多扫 `T×k` 行，仍需压测）；
4. 生产库是否存在 v1.0 时代已建过的 `detection_task_runs`（决定走 C-1 还是 C-2）；
5. SQLite 版本（是否 ≥ 3.35，影响 `ALTER RENAME` 与 `DROP COLUMN` 行为；本设计只用 3.25+ 即可满足的语法）。

**已知无解**：SQLite 无法证明调用者身份，回池令牌只能做到数据绑定 + 一次性 + 审计（v1.0 §7 已声明，本轮不改）。

---

## 15. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | 旧库无目标级结果 → 全库保守置 1，恢复普遍变慢 | 迁移前先做"目标级可判定率"统计；M-A 命中率低时提示用户 | RG16 + 事实缺口 1 |
| 2 | 保守置 1 导致大量误判"曾不可用" | 只对迁移时仍 `unavailable` 的节点置 1（M-A/M-B），健康节点走 M-C/M-D | RG15–RG17 |
| 3 | 重建表遗漏索引/触发器 | M16 清单核对；迁移后自动 `index_list` 比对 | M16 |
| 4 | `chain_future` 因时钟漂移长期告警 | 一次性 `clock_skew` 事件 + UI 提示；不自动修数据 | §3.5 |
| 5 | 重建期间写请求冲突 | `BEGIN IMMEDIATE` 独占写锁；`busy_timeout`；迁移窗口建议停机 | M15 |

---

**v1.1 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅修订三项阻断问题，未扩展架构。C11–C17 全部待确认。文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
