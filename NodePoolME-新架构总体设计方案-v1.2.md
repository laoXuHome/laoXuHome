# NodePoolME 新架构总体设计方案 v1.2

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.1
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：仅"数据库基准对齐"三项（P0-A 真实旧结果结构 / P0-B 真实旧状态字段 / P0-C 新表创建分支）。**未扩展总体架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C17 未批准）

---

## 修订索引（v1.1 → v1.2）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-A | 旧 `results`/`latency_results` 无新架构字段；新表 `target_results` 完整 DDL | §2、§3 | 基准对齐 |
| P0-B | 旧 `nodes.status`（非 `state`）；状态映射；历史未追认字段归属 | §7 | 基准对齐 |
| P0-C | 基准无 `detection_*` 三表，C-1 为主；C-2 动态读取真实 DDL | §8 | 基准对齐 |

未修订：Q1–Q12、零健康九步与参与集合、`fresh()`、快照对齐、回池令牌与外键三期、stable_id 六边界、30 天 missing、不改指纹、per-node 30 分钟、业务 90 分钟、测速窗口与 50MB、骤减双条件、30 个版本、TCP-only 不合格、四格式/四 URL/UA/Token/两种 `sub_publish`、评分算法、前端布局。**C11–C17 全部未确认。**

---

## 0. 本轮修的是什么

v1.1 的 `fail_chain()` 写得很严谨，但它查的是一张**当时并不存在**的表：v1.1 用的 `results.target`、`valid`、`mode`、`failure_source`、`config_version`、`rule_version`、`finished_at`、`last_result`、`result_id` 这九个字段，基准 v1.8.7 的 `results` 一个都没有。同理 v1.1 的 `nodes.state` 在基准里叫 `nodes.status`。

| # | v1.1 的写法 | 基准实况 | 后果 |
| --- | --- | --- | --- |
| P0-A | 在 `results` 上查 target/valid/mode/version | `results` 只有 `id,node_id,group_id,batch_id,ok,latency_ms,error_type,message,ts`；per-target 记录在 `latency_results`，且同样无版本/模式字段 | SQL 直接报 `no such column`；若"补默认值"则旧数据伪装成新证据 |
| P0-B | `nodes.state` 取值 `healthy/observe/unavailable/missing` | `nodes.status`，初始 `unknown`，代码里是 `available/unavailable` | 迁移脚本读错列名；`available` 被误当 `healthy` |
| P0-C | "扩展 CHECK 或重建已有表" | 基准**没有** `detection_tasks` / `detection_task_runs` / `detection_rules` | 按"已有表"写迁移，实际要新建；C-2 成了假分支 |

v1.2 的立场：**旧表是历史档案，新表是证据源，两者不相通；任何"为了让旧数据可用而填默认版本号"的做法一律禁止。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；`missing` 30 天（最短 7）；不改指纹；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立拉取确认；零健康最多留上一版 24h、硬上限 72h；30 个可恢复版本；恢复两次独立有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 永不合格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不改。

---

## 2. 基准 Schema 核对结果（事实层）

### 2.1 旧结果表（`backend/database/db.py` 的 `SCHEMA`）

```sql
-- results：节点级一次检测的汇总
id, node_id, group_id, batch_id, ok, latency_ms, error_type, message, ts

-- latency_results：按目标的延迟明细
id, node_id, batch_id, target, ok, latency_ms, error_type, message, ts
```

**关键事实**（决定了 v1.1 的错误）：

| 事实 | 说明 |
| --- | --- |
| `results` **没有** `target` | 节点级汇总，一个节点一次检测一行，无法拆分目标 |
| `latency_results` **有** `target` | 唯一带目标维度的旧表 |
| 两表都**没有** `valid` / `mode` / `failure_source` | 无法区分 Mihomo 与 TCP-only，无法区分系统故障与真实失败 |
| 两表都**没有** `config_version` / `rule_version` | 无法证明"同版本连续失败" |
| 时间列叫 `ts`，不是 `finished_at` | 语义相近，但**不能**直接当新字段用 |
| 主键叫 `id`，不是 `result_id` | 同上 |

### 2.2 旧节点表（状态字段）

```sql
nodes: ..., status, fail_count, ...（另有 fingerprint 等既有字段，未改动）
```

| 事实 | 说明 |
| --- | --- |
| 列名是 `status` | 不是 `state` |
| 初始值 `unknown` | 新建/未检测 |
| 代码中出现的取值 | `unknown` / `available` / `unavailable`（**无** `healthy` / `observe` / `missing`） |
| `fail_count` | 节点级累计失败次数，无目标维度、无版本维度 |

### 2.3 新架构对象在基准中是否存在

| 对象 | 基准 e721797 | 结论 |
| --- | --- | --- |
| `detection_tasks` | **不存在** | 新架构新增（P0 创建） |
| `detection_task_runs` | **不存在** | 新架构新增（P0 创建） |
| `detection_rules` | **不存在** | 新架构新增（P0 创建） |
| `target_results`（本设计引入） | **不存在** | 新架构新增（P0 创建） |
| `schema_migrations` / `system_events` | **不存在** | P-1 创建（Q1） |

**术语纪律**：本文凡称"新表"，均指"基准中不存在、由本设计新增"；凡称"旧表"，均指基准 `SCHEMA` 中已存在者。**不得**出现"基准已有的 `detection_task_runs`"这类表述。

---

## 3. P0-A：新架构结果表 `target_results`（唯一证据源）

### 3.1 为什么新建表，而不是给旧表补字段

三条理由，缺一不可：

1. 旧 `results` 无 `target`，加列会把节点级汇总硬拆成目标级，属于**伪造维度**；
2. 旧记录无 `config_version`/`rule_version`/`mode`，补默认值等于**伪造版本与模式**（P0-A.9 明令禁止）；
3. 旧表仍在被 v1.8.7 的运行代码写入（升级前），混写会让"证据"与"运行数据"不可分。

因此：**旧表保持原样、原用途、只读归档；新证据只写入 `target_results`。**

### 3.2 完整 DDL（P0-A.5 的逐项落地）

```sql
CREATE TABLE target_results (
  result_id        INTEGER PRIMARY KEY AUTOINCREMENT,   -- 单调主键，兼作排序次键
  node_id          INTEGER NOT NULL,
  identity_id      INTEGER NOT NULL,                     -- 身份维度（同一 node 归属校验）
  target           TEXT    NOT NULL,                     -- 'G' / 'W' / ...（必需目标枚举见检测规则）
  config_version   INTEGER NOT NULL,                     -- 执行时的节点配置版本
  rule_version     INTEGER NOT NULL,                     -- 执行时的规则版本
  verdict          TEXT    NOT NULL CHECK (verdict IN ('pass','fail')),
  valid            INTEGER NOT NULL DEFAULT 1 CHECK (valid IN (0,1)),
  mode             TEXT    NOT NULL CHECK (mode IN ('mihomo','tcp_only')),
  failure_source   TEXT    CHECK (failure_source IS NULL
                                  OR failure_source IN ('engine','scheduler','system','target_incident')),
  finished_at      TEXT    NOT NULL,                     -- 检测完成时刻（ISO，到秒）
  ttl_seconds      INTEGER NOT NULL CHECK (ttl_seconds > 0),
  latency_ms       INTEGER,
  task_id          TEXT,                                 -- 关联检测任务（可空：手工/兜底检测）
  batch_id         INTEGER,                              -- 兼容既有批次概念，仅审计
  message          TEXT,                                 -- 原始错误摘要（审计）
  recorded_at      TEXT    NOT NULL,                     -- 落库时刻
  FOREIGN KEY (task_id) REFERENCES detection_tasks(task_id) ON DELETE SET NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
);

CREATE INDEX idx_tr_chain   ON target_results(node_id, target, finished_at DESC, result_id DESC);
CREATE INDEX idx_tr_time    ON target_results(finished_at);
CREATE INDEX idx_tr_task    ON target_results(task_id);
```

**逐项对应 P0-A.5 要求**：

| 要求 | 字段/约束 |
| --- | --- |
| 主键 | `result_id INTEGER PRIMARY KEY AUTOINCREMENT` |
| node / identity | `node_id` + `identity_id`，复合外键指向 `nodes(id, identity_id)` |
| target | `target TEXT NOT NULL` |
| config_version | `config_version INTEGER NOT NULL` |
| rule_version | `rule_version INTEGER NOT NULL` |
| verdict / last_result | `verdict`（`pass`/`fail`）；`last_result` 不再存表，由"最新有效行"投影得到 |
| valid | `valid`（0/1），仅 `fail_chain` 要求 `=1` |
| mode | `mode`（`mihomo`/`tcp_only`） |
| failure_source | `failure_source`（NULL 或四类系统码） |
| finished_at | `finished_at`（到秒） |
| TTL | `ttl_seconds`（按目标存，不依赖全局常量漂移） |
| 审计 | `message`、`latency_ms`、`batch_id`、`task_id`、`recorded_at` |

**`failure_source` 的语义**（与 v1.1 §3.1 一致，此处为落库约束）：正常成功为 `NULL`；正常失败为 `NULL` 或业务错误码（业务码不进入 `CHECK` 枚举，只落 `message`）；四类系统故障显式写入枚举值。`CHECK` 只允许 `NULL` 与四个系统值，**防止把业务错误码误写成 `system`**。

### 3.3 `last_result` 与 `TTL` 的落点

- `last_result` **不是列**：由 `target_results` 中"该 (node, target) 最新有效行"求得（`ORDER BY finished_at DESC, result_id DESC LIMIT 1`）。
- `last_pass_at` 同理：取最新 `verdict='pass'` 且 `valid=1` 的 `finished_at`。
- TTL 判定用该行的 `ttl_seconds`，不用当前配置里的常量（配置可能已改；旧结果的 TTL 应按当时规则算）。

### 3.4 `fail_chain()` 重写（基于真实新表）

```python
def fail_chain(node, target, t, W, T):
    rows = sql("""
        SELECT result_id, finished_at, verdict, mode, failure_source
          FROM target_results                     -- ← 只查新表，绝不查 results/latency_results
         WHERE node_id = ?
           AND target = ?
           AND valid = 1
           AND mode  = 'mihomo'
           AND config_version = ?
           AND rule_version   = ?
           AND ( failure_source IS NULL
                 OR failure_source NOT IN ('engine','scheduler','system','target_incident') )
         ORDER BY finished_at DESC, result_id DESC
    """, node.id, target, node.config_version, active_rule_version(t))

    chain = []
    for r in rows:
        if r.finished_at <= t - W:  break        # 越界截断
        if r.verdict != "fail":     break        # 有效 pass 断链
        chain.append(r)
    return chain
```

**v1.1 的四条原则原样保留**：NULL 放行（`IS NULL OR NOT IN`）、pass 断链、系统类透明、`finished_at DESC, result_id DESC` 双键排序。**唯一变化是表名与列名**（`verdict` 替代 `last_result`，`target_results` 替代 `results`）。

`chain_future` 仍按 v1.1 §3.5 在构建链之前判断（`ORDER BY` 后首行 `finished_at > t`）。

### 3.5 旧表与新表的边界（P0-A.1、P0-A.6、P0-A.7）

| 边界 | 规则 |
| --- | --- |
| 写入 | 只有新架构检测流程写 `target_results`；旧代码继续写 `results`/`latency_results`（升级窗口内），两者互不干涉 |
| 读取（健康/发布/恢复） | **只读 `target_results`**；`fail_chain`、`fresh()`、`recovery` 一律不得触碰旧表 |
| 读取（历史展示） | UI 的"历史记录"页可读旧表，必须标注"历史（无版本/模式信息，不参与健康判定）" |
| 统计 | 评分/命中率等新口径只算 `target_results`；旧表只做"历史趋势"图，且与新版分轴显示 |
| 关联 | 旧表与新表**不建立**外键或 ID 映射（旧 `id` 语义与 `result_id` 不同，强行映射会产生错误关联） |

---

## 4. 旧数据迁移（P0-A.2、P0-A.3、P0-A.4）

### 4.1 迁移策略：原位保留 + 只读标记（不搬运、不填充）

| 对象 | 处置 | 理由 |
| --- | --- | --- |
| `results` | 原位保留，不改结构、不改数据、不加默认版本列 | 一旦补 `config_version=1` 就等于宣布"这些记录属于版本 1 的有效证据"（P0-A.9 禁止） |
| `latency_results` | 同上 | 虽含 `target`，但无 `mode`/`valid`/版本，无法升级为证据 |
| 旧表索引 | 原样保留 | 旧历史查询仍需它们 |
| 旧表写入 | 升级后**停止**新写入（新代码只写 `target_results`）；旧表转为归档 | 避免"两套证据并存" |

### 4.2 迁移登记（可审计，不伪造）

```sql
-- P0 创建，仅记录"历史边界"，不承载证据
CREATE TABLE legacy_cutover (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name    TEXT NOT NULL,
  row_count     INTEGER NOT NULL,
  first_ts      TEXT,
  last_ts       TEXT,
  cutover_at    TEXT NOT NULL,
  note          TEXT
);
INSERT INTO legacy_cutover(table_name,row_count,first_ts,last_ts,cutover_at,note)
SELECT 'results', COUNT(*), MIN(ts), MAX(ts), :cutover_at, '归档：无版本/模式信息，不参与健康判定'
  FROM results;
INSERT INTO legacy_cutover(...) SELECT 'latency_results', ... FROM latency_results;
```

**这张表的作用**：说明"哪些数据属于旧纪元、多少行、时间范围"，让审计能明确划界；它**不**给旧记录任何证据资格。

### 4.3 迁移前后数据保留与有效性（交付要求第 6 项）

| 维度 | 迁移前 | 迁移后 |
| --- | --- | --- |
| 旧 `results` 行数 | N | N（不变，原位） |
| 旧 `latency_results` 行数 | M | M（不变，原位） |
| 旧记录可查询 | 是 | 是（同表同列，无需改 SQL） |
| 旧记录可统计 | 是 | 是（历史趋势仍可算） |
| 旧记录作为健康证据 | 否（旧系统曾用，但新架构不认） | **否**（永不具备） |
| 新证据写入位置 | — | `target_results` |
| 新证据判定资格 | — | 需同时具备 `valid/mode/版本/ttl/finished_at` |

---

## 5. `apply_result`（沿用 v1.0/v1.1）

唯一流程：步骤 0 幂等 → 1 事务内读 task → 2 `exec_cv`/`exec_rv`/`exec_target` 三比对 → 3 事务内读 node/rule → 4 身份/生命周期/目标/版本校验 → 5 verdict 白名单（非法 → `invalid/invalid_verdict`，`applied=0`）→ 6 登记 → 7 仅 pass/fail 写 `target_results` 与目标状态。

**本轮唯一变化**：步骤 7 写入表从"设计中的结果表"明确为 `target_results`，并要求写入时**同事务**填 `config_version`/`rule_version`/`ttl_seconds`/`task_id`（保证 §3.2 的字段永远非空、可核验）。

---

## 6. `fresh()`（沿用 v1.1，数据源改为新表）

```python
def latest_valid(node, target):
    return q1("""SELECT * FROM target_results
                  WHERE node_id=? AND target=? AND valid=1 AND mode='mihomo'
                    AND config_version=? AND rule_version=?
                  ORDER BY finished_at DESC, result_id DESC LIMIT 1""", ...)

def fresh(node, target, now):
    r = latest_valid(node, target)
    return (r is not None
            and r.verdict == "pass"
            and r.failure_source is None          # Python 判断，不用 SQL NOT IN
            and r.finished_at + r.ttl_seconds > now)
```

`failure_source` 的系统值在 `CHECK` 层已限定为四类，因此 `is None` 等价于"非系统故障"。**保留 v1.1 的警告**：Python 的 `None not in tuple` 为 `True`；若改写成 SQL `NOT IN` 会重新踩 NULL 坑。

---

## 7. P0-B：旧状态字段与映射

### 7.1 字段名纠正

全文（含迁移脚本、UI、文档）统一使用 `nodes.status`；**删除** `nodes.state` 的表述。旧库不存在 `healthy` / `observe` / `missing` 取值，禁止按这三值写判据（P0-B.1、P0-B.2）。

### 7.2 旧状态 → 新架构映射（P0-B.3、P0-B.4）

| 旧 `status` | 新 `nodes.lifecycle` | 新健康状态 | 恢复要求 | 说明 |
| --- | --- | --- | --- | --- |
| `unknown` | `active` | `unknown` | 无 | 新节点/未检测；需一次新鲜有效检测 |
| `available` | `active` | **`unknown`（不是 `healthy`）** | 无 | 旧"可用"只代表旧判定；必须由新 `target_results` 的新鲜 pass 重新确认 |
| `unavailable` | `active` | `unavailable` | **需要 Q11** | 全部必需目标保守置 `target_ever_unavailable=1`、`observing`、计数 0 |
| `missing`（若代码中存在） | `active` 但 `missing_since` 记旧值 | `unknown` | 视同 `unavailable` 保守处理 | 仅当旧库确有该值时 |
| 其他/空值 | `active` | `unknown` | 无 | 打 `history_unattested=1`，记 `legacy_status='<原值>'` |

**`available` 的红线（P0-B.4）**：绝不映射为 `healthy`。理由：旧系统的"available"由旧判据（TCP 可参与达标、无目标维度、无版本）得出，与新架构的四项校验（版本/规则/模式/系统故障）不同源。迁移后一律 `unknown`，等新检测确认。

### 7.3 字段归属统一（P0-B.10）

| 字段 | 所在表 | 粒度 | 含义 | 用途 |
| --- | --- | --- | --- | --- |
| `history_unattested` | `nodes` | 节点级 | 该节点"历史上是否进过 unavailable"无法追溯 | UI 标记 + 审计；**不参与**任何判定 |
| `target_history_unattested` | `node_target_state` | 目标级 | 该目标"历史上是否进过 unavailable"无法追溯 | UI 标记 + 审计；**不参与**任何判定 |
| `target_ever_unavailable` | `node_target_state` | 目标级 | 已确认进过 unavailable | **唯一**触发 Q11 |
| `ever_unavailable` | `nodes` | 节点级 | 已确认进过 unavailable（任一目标） | 展示/复核 |
| `legacy_status` | `nodes` | 节点级 | 迁移时旧 `status` 的原始值（审计） | **只读展示**，不参与判定 |
| `legacy_fail_count` | `nodes` | 节点级 | 迁移时旧 `fail_count` 的副本（审计） | **只读展示**，不得当 Q11 证据 |

**禁止混用**：迁移脚本中 `history_unattested` 只写 `nodes`，`target_history_unattested` 只写 `node_target_state`；不得用一个字段代表另一种粒度（P0-B.10）。

### 7.4 迁移映射规则（P0-B.5～P0-B.9）

| 情形 | 旧数据判据 | 目标级初始化 | 节点级初始化 |
| --- | --- | --- | --- |
| S-A | `status='unavailable'`，且 `latency_results` 能证明某目标连续 fail ≥ T（同 `batch` 集群内，按旧口径） | 该目标 `ever_unavailable=1`、`observing`、计数 0；其余 0 | `ever_unavailable=1`、`history_unattested=0` |
| S-B | `status='unavailable'`，无可靠目标级证据 | **全部必需目标** `ever_unavailable=1`、`observing`、计数 0 | `ever_unavailable=1` |
| S-C | `status='available'` 但 `fail_count>0` | 全部 `ever_unavailable=0`、`target_ever_fail=1`、`target_history_unattested=1` | `history_unattested=1`、`ever_unavailable=0` |
| S-D | `status='unknown'` | 全部 0、`target_ever_fail=0` | 全 0 |
| S-E | `status='available'` 且 `fail_count=0` | 全 0 | 全 0 |

**`fail_count` 的使用红线（P0-B.8、P0-B.9）**：只允许写入 `target_ever_fail`（诊断）或 `legacy_fail_count`（审计副本），**绝不**写 `recovery_state='confirmed'`、`recovery_success_count`、`confirmed_at`。旧 `fail_count=9` 也不等于"已经两次成功恢复"。

### 7.5 旧历史不得进入新链（P0-B 与 P0-A 的交点）

`latency_results` 虽有 `target`，但缺 `mode`/`valid`/版本/`ttl`，**不得**被 `fail_chain()` 读取，也**不得**用"补默认值"的方式变成可读。RG24 专门验证这一点。

### 7.6 测试 RG19–RG24

| # | 初始（旧库） | 步骤 | 预期库 | 预期业务 | 失败时不变项 |
| --- | --- | --- | --- | --- | --- |
| RG19 | N `status='unavailable'`、`fail_count=4` | 迁移 | 两必需目标 `target_ever_unavailable=1`、`recovery_state='observing'`、计数 0、`first_success_at=NULL`；新架构 `nodes.health='unavailable'` | 迁移后仍需两次成功 | 旧 `latency_results` 不改写 |
| RG20 | N `status='available'`、`fail_count=0` | 迁移 | 新 `health='unknown'`；`ever_unavailable=0`；目标全 0 | **不得** `healthy`；需一次新检测确认 | 旧 `status` 保留在 `legacy_status` |
| RG21 | N `status='unknown'` | 迁移 | `health='unknown'`；全 0；`history_unattested=0` | 首次检测按"首次健康"路径 | 无 |
| RG22 | N `status='available'`、`fail_count=9` | 迁移 | `recovery_state='none'`、`success_count=0`、`confirmed_at=NULL`；`target_ever_fail=1`、`target_history_unattested=1` | 旧计数不能当 Q11 证据 | 不置 `confirmed` |
| RG23 | N `status='unavailable'`，`latency_results` 只有节点级汇总（无可用目标链） | 迁移 | **全部必需目标**置 1、`observing` | 保守：两目标都要两次 | 不得只置其一 |
| RG24 | 旧 `latency_results` 有 G 的 3 条连续 `ok=0` | 迁移后对新链调用 `fail_chain` | 链为空（查 `target_results`） | 旧记录不构成证据 | `target_results` 不新增行 |

---

## 8. P0-C：新表创建（C-1 为主）与 C-2 条件分支

### 8.1 基准事实与分支选择

基准 `SCHEMA` 不含 `detection_tasks` / `detection_task_runs` / `detection_rules`（§2.3）。因此：

| 分支 | 触发条件 | 概率 |
| --- | --- | --- |
| **C-1 建新表** | 基准库（无三表） | 主路径 |
| **C-2 重建表** | 检测到同名表已存在（试验库/历史遗留，DDL 与设计不符） | 条件分支，必须先读真实 DDL |

**禁止**把 C-2 写成默认路径，也**禁止**用文档里的假设 DDL 去 `CREATE OR REPLACE` 一张真实存在的表（P0-C.8、P0-C.9）。

### 8.2 C-1 完整 DDL（P0-C.3、P0-C.4、P0-C.5）

```sql
-- ① 检测规则（版本化）
CREATE TABLE detection_rules (
  rule_version     INTEGER PRIMARY KEY,
  name             TEXT NOT NULL,
  targets          TEXT NOT NULL,          -- JSON 数组：必需目标列表
  fail_threshold   INTEGER NOT NULL CHECK (fail_threshold > 0),   -- T
  ttl_seconds      INTEGER NOT NULL CHECK (ttl_seconds > 0),
  recovery_gap_sec INTEGER NOT NULL DEFAULT 1800 CHECK (recovery_gap_sec >= 1800),
  effective_from   TEXT NOT NULL,
  active           INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0,1)),
  created_at       TEXT NOT NULL
);
CREATE UNIQUE INDEX uq_rules_active ON detection_rules(active) WHERE active = 1;  -- 同时只有一条有效规则

-- ② 检测任务（创建时固化执行版本）
CREATE TABLE detection_tasks (
  task_id        TEXT PRIMARY KEY,
  node_id        INTEGER NOT NULL,
  identity_id    INTEGER NOT NULL,
  target         TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  rule_version   INTEGER NOT NULL,
  created_at     TEXT NOT NULL,
  FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id),
  FOREIGN KEY (rule_version) REFERENCES detection_rules(rule_version)
);

-- ③ 任务结果登记（幂等闸门 + CHECK 四值）
CREATE TABLE detection_task_runs (
  task_id             TEXT PRIMARY KEY,
  node_id             INTEGER,
  outcome             TEXT NOT NULL CHECK (outcome IN ('pass','fail','invalid','stale')),
  stale_reason        TEXT CHECK (stale_reason IS NULL OR stale_reason IN
                        ('config_version','rule_version','identity','lifecycle','target',
                         'exec_version_mismatch','unknown_task','invalid_verdict','reported_invalid')),
  exec_config_version INTEGER,
  exec_rule_version   INTEGER,
  finished_at         TEXT NOT NULL,
  applied             INTEGER NOT NULL DEFAULT 0 CHECK (applied IN (0,1)),
  recorded_at         TEXT NOT NULL,
  FOREIGN KEY (task_id) REFERENCES detection_tasks(task_id) ON DELETE CASCADE
);
CREATE INDEX idx_runs_node ON detection_task_runs(node_id, recorded_at DESC);
```

**DDL 自检清单（P0-C.4 要求"完整"）**：

| 要素 | 是否具备 |
| --- | --- |
| 主键 | `detection_rules(rule_version)`、`detection_tasks(task_id)`、`detection_task_runs(task_id)` |
| 外键 | tasks→nodes（复合）、tasks→rules；runs→tasks（CASCADE） |
| CHECK | `fail_threshold>0`、`ttl_seconds>0`、`recovery_gap_sec>=1800`、`active∈{0,1}`、`outcome∈4值`、`applied∈{0,1}`、`stale_reason` 白名单 |
| 唯一 | `uq_rules_active`（部分唯一，单活规则） |
| 索引 | `idx_runs_node` |
| 字段 | 版本、目标、阈值、TTL、恢复间隔、时间戳、审计 |

**`VERDICTS` 与 `CHECK` 一致性**：`VERDICTS = ('pass','fail','invalid','stale')` 与上述 `CHECK` **逐项相同**，由 TV4 / M18 断言（比较集合，不比较顺序）。

### 8.3 创建失败的回滚保护（P0-C.6）

| 层 | 措施 |
| --- | --- |
| 事务 | 三表 + 索引 + `uq_rules_active` 全部在**同一个** `BEGIN IMMEDIATE` 内创建 |
| 原子性 | 任一语句失败 → `ROLLBACK` → 库中不残留任何一张半成品表（SQLite DDL 参与事务） |
| 预检 | 先 `SELECT name FROM sqlite_master WHERE name IN (...)`，存在则不建（转 C-2 判定） |
| 后检 | 提交后重查 `sqlite_master` 三表存在、`PRAGMA table_info` 列数/类型匹配、`foreign_key_check` 为空 |
| 登记 | 全部通过才写 `schema_migrations(success)`；失败不写 |
| 阶段边界 | 若失败发生在 P0 中途，P-1 已建的 `schema_migrations`/`system_events` 不受影响（它们已在更早的独立事务中提交） |

### 8.4 C-2 条件分支（真实 DDL 驱动）

若检测到三表之一已存在，**不得**直接覆盖。流程：

```python
# before-begin
ddl        = q("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", t)
columns    = pragma("table_info", t)          # 列名/类型/非空/默认
indexes    = pragma("index_list", t)
fks        = pragma("foreign_key_list", t)
triggers   = q("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND tbl_name=?", t)
rows       = q("SELECT COUNT(*) FROM ?", t)

# 决策
if ddl 与设计等价（列、CHECK、索引、FK 全一致）: skip（幂等）
else: 重建（12 步，全部字段动态复制）

# 重建的搬运必须动态列：
cols = [c.name for c in columns]
INSERT INTO {t}__new (<cols 全列>) SELECT <cols 全列> FROM {t};
```

**四条约束（P0-C.10）**：

1. 列清单来自 `PRAGMA table_info`，**不得**写死文档里的九个字段；
2. 旧表**全部**字段与数据必须搬运，缺列时用 `NULL`/默认值补齐并记 `system_events(schema_diff)`；
3. 索引、触发器、外键按 `PRAGMA` 结果**逐个重建**，重建后核对数量与名称；
4. `foreign_keys=OFF` 只在 `before-begin`，`ON` 只在 `after-commit`（§9 三期规则）。

### 8.5 阶段边界（P0-C.12）

| 阶段 | 创建对象 | 说明 |
| --- | --- | --- |
| **P-1** | `schema_migrations`、`system_events` | Q1 已定：仅安全底座两表 |
| **P0** | `detection_rules`、`detection_tasks`、`detection_task_runs`、`target_results`、`node_identities`、`node_config_versions`、`node_target_state`、`identity_*`、`restore_authorizations`、`legacy_cutover` 等新架构对象 | 身份层、证据层、授权层 |
| **后续（P1+）** | 发布目录/版本相关、`airport_*` 聚合等 | 按 v0.5～v1.1 的归属推进 |

**边界纪律**：P-1 不得创建 `detection_*`（否则 P0 的"是否存在"判定失真）；P0 不得假设 P-1 已建任意业务表。

---

## 9. 迁移三期与执行顺序（合并）

### 9.1 三期

| 期 | 允许 | 禁止 |
| --- | --- | --- |
| `before-begin` | 备份、`quick_check`、记录 `foreign_keys` 原值、需要时设 `OFF`、`busy_timeout`、读取真实 DDL/PRAGMA 自检 | 任何 DDL |
| `in-tx` | `BEGIN IMMEDIATE`、C-1 建表 / C-2 重建、回填、`foreign_key_check`（只读）、行数比对 | **任何 PRAGMA 切换** |
| `after-commit` | 恢复 `foreign_keys` 原值并校验、复查 `foreign_key_check`、Schema 断言、写 `schema_migrations(success)` | 再次 DDL |

### 9.2 本轮迁移顺序（P0）

```
[before-begin]
  备份 → quick_check → 记录 foreign_keys=ON
  预检 sqlite_master（三表是否存在）→ 决定 C-1 / C-2
  统计旧 results / latency_results 行数与时间范围（供 legacy_cutover）
[in-tx]
  ① 建 detection_rules（含 uq_rules_active）
  ② 建 detection_tasks（复合 FK → nodes；FK → rules）
  ③ 建 detection_task_runs（FK → tasks）
  ④ 建 target_results（复合 FK → nodes；FK → tasks；三索引）
  ⑤ 建 legacy_cutover 并写入两条归档记录
  ⑥ 状态映射回填（§7.4 S-A～S-E，读 nodes.status / fail_count / latency_results）
  ⑦ foreign_key_check（只读，必须 0 行）
  ⑧ 行数/列数断言
[after-commit]
  恢复 foreign_keys=ON → 复查 foreign_key_check → M17–M22 断言 → schema_migrations(success)
```

**顺序理由**：`target_results` 的 FK 指向 `detection_tasks`，必须后建；状态回填需在目标表存在之后；`legacy_cutover` 只读旧表，位置自由但放在回填前便于先划界。

---

## 10. 旧表与新表完整对照（交付要求第 5 项）

| 维度 | 旧 `results` | 旧 `latency_results` | 新 `target_results` |
| --- | --- | --- | --- |
| 粒度 | 节点级汇总 | 节点×目标×批次 | 节点×目标×配置版本×规则版本 |
| 主键 | `id` | `id` | `result_id` |
| 目标 | **无** | 有 `target` | 有 `target` |
| 成功/失败 | `ok`（0/1） | `ok`（0/1） | `verdict`（pass/fail） |
| 有效性 | 无 | 无 | `valid` |
| 模式 | 无 | 无 | `mode`（mihomo/tcp_only） |
| 失败来源 | 无（只有 `error_type`） | 无（只有 `error_type`） | `failure_source`（NULL 或四类） |
| 配置版本 | 无 | 无 | `config_version` |
| 规则版本 | 无 | 无 | `rule_version` |
| 时间 | `ts` | `ts` | `finished_at` + `recorded_at` |
| TTL | 无 | 无 | `ttl_seconds` |
| 任务关联 | 无 | 无 | `task_id`（FK → detection_tasks） |
| 健康判定资格 | **无** | **无** | **有**（需全部字段齐备） |
| 迁移处置 | 原位保留、只读归档 | 原位保留、只读归档 | 新建、唯一证据源 |

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
| 失败链 FE | 19 | FE1–FE14 + FE15–FE19 |
| 恢复 RG | 24 | RG1–RG14 + RG15–RG24 |
| verdict TV | 4 | TV1–TV4 |
| 迁移 M | 22 | M1–M16 + M17–M22 |

### 11.2 新增详测

**FE15｜旧 `results` 不进新链**

- 初始：迁移后 `results` 有 N 行（含该节点 5 条 `ok=0`）；`target_results` 该节点 0 行。
- 步骤：对该节点目标 G 调 `fail_chain`。
- 预期库：返回空链；`target_results` 无新增行。
- 预期业务：`has_fail_evidence=False(chain_short)`。
- 不变项：`results` 行数/内容不变。

**FE16｜旧 `latency_results` 不获资格**

- 初始：`latency_results` 有 G 的 3 条连续 `ok=0`、`error_type='timeout'`。
- 步骤：调 `fail_chain(G)`；再调 `fresh(G)`。
- 预期库：链空；`fresh=False`（无 `target_results` 行）。
- 预期业务：旧记录不得冒充新证据。
- 不变项：旧表不改写。

**FE17｜旧历史迁移后可查可统计**

- 初始：迁移完成，`legacy_cutover` 两条记录。
- 步骤：按 `ts` 区间查旧 `results`；按 `batch_id` 聚合 `latency_results`；读 `legacy_cutover`。
- 预期库：查询返回原行数；`legacy_cutover.row_count` 与实际一致；`first_ts/last_ts` 正确。
- 预期业务：历史页可展示，标注"不参与判定"。
- 不变项：`target_results` 不被这些查询触碰。

**FE18｜新表完整失败记录可成链**

- 初始：`target_results` 该节点 G 三条 `verdict='fail'`、`valid=1`、`mode='mihomo'`、`failure_source=NULL`、同 `config_version=2`、同 `rule_version=4`、`finished_at` 在窗口内。
- 步骤：调 `fail_chain`。
- 预期库：链长 3，顺序按 `finished_at DESC, result_id DESC`。
- 预期业务：`has_fail_evidence=True`。
- 不变项：无写入。

**FE19｜新表有效 pass 断链**

- 初始：同上，中间插入一条 `verdict='pass'` 的 `target_results` 行（`failure_source=NULL`）。
- 步骤：调 `fail_chain`。
- 预期库：链长 2（只到 pass 之前）。
- 预期业务：不足 3 → `False(chain_short)`。
- 不变项：无写入。

**M17｜基准无新表走 C-1**

- 初始：库中 `sqlite_master` 不含 `detection_*`、`target_results`。
- 步骤：执行迁移。
- 预期库：四张表全部创建；无"表已存在"错误。
- 预期业务：C-1 命中。
- 不变项：旧表不被改动。

**M18｜DDL 与设计一致**

- 初始：C-1 完成后。
- 步骤：`PRAGMA table_info` / `index_list` / `foreign_key_list` / 解析 `sql`。
- 预期库：列名/类型/非空/默认与 §8.2 一致；`uq_rules_active` 存在；`outcome` CHECK 恰为四值；`VERDICTS` 集合相等。
- 预期业务：Schema 契约成立。
- 不变项：数据 0 行。

**M19｜C-1 创建失败不留半成品**

- 初始：同 M17；在创建第三张表时注入失败。
- 步骤：执行迁移。
- 预期库：`ROLLBACK` 后 `sqlite_master` 中无任何新表；`schema_migrations` 无 success。
- 预期业务：可重跑。
- 不变项：旧表与 P-1 两表。

**M20｜意外旧表进 C-2 不覆盖**

- 初始：试验库已有一张字段不同的 `detection_task_runs`（仅 3 个字段）。
- 步骤：执行迁移。
- 预期库：先读真实 DDL；建 `__new` 表；搬运后旧表被替换；`system_events` 记 `schema_diff`。
- 预期业务：不静默覆盖、不丢数据。
- 不变项：旧表在回滚场景下完好。

**M21｜C-2 全字段保留**

- 初始：上述旧表含自定义列 `extra_note`、自定义索引、一个触发器。
- 步骤：C-2 重建。
- 预期库：新表包含 `extra_note` 列且有原数据；索引与触发器按 `PRAGMA` 结果重建；行数相同。
- 预期业务：零数据丢失。
- 不变项：`detection_tasks` 数据。

**M22｜完成后全量校验**

- 初始：迁移完成。
- 步骤：`foreign_key_check`；四表列数/索引数；`uq_rules_active` 唯一性（插两条 active=1 应失败）；`legacy_cutover` 行数。
- 预期库：`foreign_key_check` 0 行；断言全部通过。
- 预期业务：可进入 P0 后续。
- 不变项：无。

---

## 12. v1.1 → v1.2 修订对照

| # | v1.1 | v1.2 | 章节 |
| --- | --- | --- | --- |
| P0-A | `fail_chain` 查 `results`，用 `target/valid/mode/version/…` 九个不存在的列 | 新建 `target_results`（完整 DDL）；`fail_chain` 只查新表；旧两表原位归档、零填充、无资格 | §2、§3、§4 |
| P0-B | `nodes.state` + `healthy/observe/missing` 取值 | `nodes.status` + 真实取值；五类映射（含 `available→unknown`）；`fail_count` 只作诊断；两级 `*_unattested` 分表 | §7 |
| P0-C | 按"已存在三表"写 CHECK 迁移，C-1 只列字段 | 基准无三表 → C-1 为主并给完整 DDL；C-2 动态读 DDL/PRAGMA 后重建；P-1/P0 阶段边界成文 | §8、§9 |

---

## 13. 三项 P0 关闭清单

| 来源 | 问题 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- | |
| P0-A.1 | 旧/新表未区分 | §2、§3.1、§10 对照表 | FE15/FE16 | 已关闭 |
| P0-A.2 | 旧数据迁移方式 | §4.1 原位归档 | FE17 | 已关闭 |
| P0-A.3 | 旧记录不得丢失 | §4.1、§4.3 | FE17 | 已关闭 |
| P0-A.4 | 旧记录不得获资格 | §3.5、§7.5 | FE15/FE16/RG24 | 已关闭 |
| P0-A.5 | 新表完整 Schema | §3.2（14 字段 + 3 索引 + 2 FK） | FE18/M18 | 已关闭 |
| P0-A.6 | 新旧关联/展示/统计边界 | §3.5、§10 | FE17 | 已关闭 |
| P0-A.7 | `fail_chain` 只查完整记录 | §3.4（四维过滤 + valid/mode） | FE18/FE19 | 已关闭 |
| P0-A.8 | 保留 NULL/断链/透明/排序 | §3.4 | FE11–FE14 沿用 | 已关闭 |
| P0-A.9 | 禁止填充默认值伪装 | §3.1、§4.1、§7.5 | FE16/RG24 | 已关闭 |
| P0-B.1 | 使用 `nodes.status` | §7.1 | RG19–RG21 | 已关闭 |
| P0-B.2 | 不得假设 `healthy/observe/missing` | §7.2 | RG20 | 已关闭 |
| P0-B.3 | 状态映射表 | §7.2 六行 | RG19–RG21 | 已关闭 |
| P0-B.4 | `available` ≠ `healthy` | §7.2 红线 | RG20 | 已关闭 |
| P0-B.5 | 当前 unavailable 保守保留 | §7.4 S-B | RG19/RG23 | 已关闭 |
| P0-B.6 | 不得声称精确重建旧链 | §7.5、§4.1 | RG23/RG24 | 已关闭 |
| P0-B.7 | 全部必需目标保守置 1 | §7.4 S-B | RG23 | 已关闭 |
| P0-B.8 | `fail_count` 非 Q11 证据 | §7.4 红线 | RG22 | 已关闭 |
| P0-B.9 | 已恢复但不可追溯 → 未追认 | §7.4 S-C | RG22 | 已关闭 |
| P0-B.10 | 两级字段归属统一 | §7.3 表 + 禁混用 | RG22/M21 | 已关闭 |
| P0-C.1 | C-1 为主 | §8.1 | M17 | 已关闭 |
| P0-C.2 | 新对象表述 | §2.3、§8.5 | M17 | 已关闭 |
| P0-C.3 | C-1 完整 DDL | §8.2 三表 | M18 | 已关闭 |
| P0-C.4 | 主键/外键/CHECK/唯一/索引 | §8.2 自检清单 | M18/M22 | 已关闭 |
| P0-C.5 | VERDICTS 与 CHECK 一致 | §8.2 | TV4/M18 | 已关闭 |
| P0-C.6 | 创建失败回滚 | §8.3 | M19 | 已关闭 |
| P0-C.7 | C-2 仅条件分支 | §8.1 | M20 | 已关闭 |
| P0-C.8 | 先读真实 DDL | §8.4 | M20 | 已关闭 |
| P0-C.9 | 禁止假设覆盖 | §8.4 | M20 | 已关闭 |
| P0-C.10 | 全字段复制 | §8.4 动态列 | M21 | 已关闭 |
| P0-C.11 | PRAGMA 三期 | §9.1 | M19/M21 | 已关闭 |
| P0-C.12 | P-1/P0 阶段边界 | §8.5 | M17/M22 | 已关闭 |

---

## 14. 未解决问题与待确认

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（三期） | 未确认 |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口（6h / 最近 3 次） | 6h 优先 | 未确认（`W` 同作失败链窗口） |
| C15 | `rep` 门槛（0.90 / 0.60） | 0.90 确认 | 未确认 |
| C16 | retired 回归是否复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| **C18** | `target_results` 的 `verdict` 是否纳入 `mode='tcp_only'` 的 `verdict='pass'` | 建议允许写入（`valid=1` 但 `mode` 排除），保证审计完整 | **新增，未确认** |
| **C19** | 旧 `results` / `latency_results` 归档后是否停止写入（升级即切） | 建议升级即停写、只读 | **新增，未确认** |

**事实缺口（非决策，需实测）**

1. 旧库 `latency_results` 是否真按 `target` 分行、`target` 取值域是什么（决定 S-A 命中率）；
2. 旧库 `nodes.status` 是否还存在设计未列出的取值（如 `deleted`、`disabled`）；
3. 旧 `results` 的 `group_id` 语义（决定历史页能否按检测组聚合）；
4. `target_results` 在万级/十万级行下 `idx_tr_chain` 的实际代价；
5. 生产库是否已有 `detection_*` 或 `target_results` 同名对象（决定 C-1/C-2）。

**已知无解**：SQLite 无法证明调用者身份（回池令牌只能做数据绑定 + 一次性 + 审计）；旧库缺版本与模式字段，**无法**把旧历史升级为证据——这是事实约束，不是文档可修的缺陷。

---

## 15. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | 旧 `available` 被误当 `healthy`，升级后立刻发布未验证节点 | 一律 `unknown`，需一次新检测 | RG20 |
| 2 | 保守映射范围过大（S-B 全目标置 1）导致恢复普遍变慢 | 迁移前统计 S-A 可判定率；UI 显示"待恢复目标数" | RG19/RG23 |
| 3 | 旧历史被误读为证据（运营/脚本层面） | `legacy_cutover` 划界 + UI 标注 + `fail_chain` 只查新表 | FE15/FE16/RG24 |
| 4 | C-1 中途失败留下半成品 | 单事务 + 预检 + 后检 + 不写 success | M19 |
| 5 | C-2 用错假设字段丢列 | 动态 `PRAGMA table_info` 全列复制 | M20/M21 |
| 6 | 双写期（旧代码 + 新代码）数据分裂 | 升级即停旧写（C19 待确认前按"停写"设计） | C19 |

---

**v1.2 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅做数据库基准对齐，未扩展架构。C11–C19 全部待确认。文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
