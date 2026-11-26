# NodePoolME 新架构总体设计方案 v1.3

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.2
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：P0-1 身份外键依赖 / P0-2 完整迁移顺序 / P0-3 系统故障与 `fresh()` / P0-4 C-2 安全重建；C18、C19 只补边界说明，**仍待确认**。
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C19 未批准）

---

## 修订索引（v1.2 → v1.3）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | `nodes` 无 `identity_id`；身份字段、唯一索引、复合外键父键、映射 | §3 | 修正 |
| P0-2 | 完整 P0 依赖图与 14 步迁移顺序（含阶段与回滚范围） | §4 | 补齐 |
| P0-3 | 系统故障记录 `valid=0`；`latest_valid()`/`fresh()` 不被覆盖 | §5 | 修正 |
| P0-4 | C-2 安全重建：标识符引用、真实 DDL 识别、未知字段策略、失败即停 | §6 | 修正 |
| C18 | TCP-only 记录边界（仍待确认） | §7.1 | 边界说明 |
| C19 | 旧结果表停写切换边界（仍待确认） | §7.2 | 边界说明 |

未修订：Q1–Q12、指纹算法、身份与生命周期总体原则、30 天 missing、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式与现有发布兼容、评分算法、前端布局。**C11–C19 全部未确认。**

---

## 0. 本轮修的是什么

v1.2 的四类问题都是"设计里的对象在真实库上不存在或不存在得刚刚好"：

| # | v1.2 的写法 | 基准事实 | 后果 |
| --- | --- | --- | --- |
| P0-1 | `FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)` | `nodes` **没有** `identity_id`，也没有 `UNIQUE(id, identity_id)` | 建表直接失败：父键不存在 |
| P0-2 | 迁移顺序只列了 8 步 | 身份层 6 张表、状态层、授权层未纳入依赖图 | 顺序错则外键建不上，或回填在 Schema 之前 |
| P0-3 | `valid` 默认 1，系统故障也 `valid=1` | `latest_valid()` 取"最新 `valid=1`" | 一条 engine 异常就把新鲜 pass 顶掉，节点被判失效 |
| P0-4 | `SELECT COUNT(*) FROM ?` + 按设计 DDL 建新表 | 表名不能绑定参数；未知自定义列会被丢 | 脚本报错或静默丢数据 |

v1.3 的立场：**父键先存在，才允许子表引用；资格先写清，才允许落库；结构没认全，就不许重建。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；指纹算法不改；身份与生命周期总体原则不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康最多留上一版 24h、硬上限 72h；发布保留 30 个版本；恢复两次有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不重做。

---

## 2. 基准 `nodes` 的事实起点（P0-1.1）

| 事实 | 来源 |
| --- | --- |
| 有 `id INTEGER PRIMARY KEY` | 基准 `SCHEMA` |
| 有 `UNIQUE(airport_id, fingerprint)` | 基准 `SCHEMA` |
| **无** `identity_id` | 基准 `SCHEMA`；阶段 0 报告 §4 已记录 |
| **无** `config_version` | 同上 |
| 无 `first_seen_at` / `last_seen_at` / `missing_since` | 同上 |
| 有 `status`（`unknown/available/unavailable`）与 `fail_count` | 基准代码 |

因此 v1.2 里所有 `REFERENCES nodes(id, identity_id)` 都是**指向不存在的父键**。这不是笔误，是缺少一次"父表准备"步骤。

---

## 3. P0-1：身份字段、父键与映射

### 3.1 两条路径（C12 未批准 → 默认 A）

| 路径 | 是否重建 `nodes` | 能否得到真 `NOT NULL` 与复合外键 | 是否需要 C12 |
| --- | --- | --- | --- |
| **A（默认）** | 否 | `identity_id`/`config_version` 物理可空 → 用**触发器**强制非空；`nodes` 侧的复合外键**不能**加（`ALTER` 不支持），改用触发器校验 | 不需要 |
| **B（可选）** | 是（12 步重建） | 真 `NOT NULL` + 真复合外键 | **需要 C12 批准** |

**C12 状态**：仍为**待确认**。本文默认走 A，B 只作为获批后的增强，**不得**在实施时自行选择 B（P0-1.7）。

### 3.2 身份的产生、回填与验证（P0-1.3）

```sql
-- ① 身份表（父表，先建）
CREATE TABLE node_identities (
  identity_id     INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id      INTEGER NOT NULL,
  stable_id       TEXT,                       -- 旧库无稳定 ID → 迁移期可为 NULL
  generation      INTEGER NOT NULL DEFAULT 1,
  lifecycle       TEXT NOT NULL DEFAULT 'active'
                  CHECK (lifecycle IN ('active','missing','retired')),
  related_identity_id INTEGER REFERENCES node_identities(identity_id) ON DELETE SET NULL,
  first_seen_at   TEXT NOT NULL,
  last_present_at TEXT,
  created_at      TEXT NOT NULL,
  FOREIGN KEY (airport_id) REFERENCES airports(id)
);
CREATE INDEX idx_ident_airport ON node_identities(airport_id, lifecycle);
```

**身份产生规则（迁移期，1:1）**：为每个既有 `nodes` 行生成**恰好一条** identity，`airport_id` 取该行 `airport_id`，`stable_id=NULL`（旧库没有），`generation=1`，`first_seen_at=created_at`（旧行无 `first_seen_at`，用 `airports`/批次时间的可用近似；无则用迁移时刻并记 `evidence='backfill'`）。**禁止**一台机器生成两条身份，也**禁止**两条 nodes 行共用一条身份（旧库 `UNIQUE(airport_id,fingerprint)` 已保证机场内唯一）。

**可审计映射表**（P0-1.6，"不产生无身份节点或错误关联"）：

```sql
CREATE TABLE legacy_node_identity_map (
  node_id     INTEGER PRIMARY KEY,
  identity_id INTEGER NOT NULL UNIQUE,
  mapped_at   TEXT NOT NULL,
  rule        TEXT NOT NULL,        -- 'legacy_1to1'
  FOREIGN KEY (node_id) REFERENCES nodes(id),
  FOREIGN KEY (identity_id) REFERENCES node_identities(identity_id)
);
```

映射的三条验证（迁移后必须全过）：

| 验证 | 断言 |
| --- | --- |
| 覆盖 | `SELECT COUNT(*) FROM legacy_node_identity_map` == 迁移前 `nodes` 行数 |
| 唯一 | `identity_id` 在 map 内唯一；`node_id` 在 map 内唯一 |
| 双向 | `nodes.identity_id` 全部非空；每个非空值都能在 map 中找到且 `map.node_id = nodes.id` |

### 3.3 `nodes` 加列与父键准备（P0-1.2、P0-1.4、P0-1.5）

```sql
-- ② 配置版本表（先于 nodes.config_version 的回填）
CREATE TABLE node_config_versions (
  identity_id     INTEGER NOT NULL,
  config_version  INTEGER NOT NULL,
  fingerprint     TEXT NOT NULL,
  params_hash     TEXT,
  protocol        TEXT,
  server          TEXT,
  port            INTEGER,
  display_name    TEXT,
  change_reason   TEXT NOT NULL DEFAULT 'initial',
  opened_at       TEXT NOT NULL,
  closed_at       TEXT,
  PRIMARY KEY (identity_id, config_version),
  FOREIGN KEY (identity_id) REFERENCES node_identities(identity_id)
);

-- ③ nodes 加两列（物理可空，触发器兜底）
ALTER TABLE nodes ADD COLUMN identity_id    INTEGER;
ALTER TABLE nodes ADD COLUMN config_version INTEGER;

-- ④ 复合外键所需的父键唯一索引（P0-1.4 的关键）
CREATE UNIQUE INDEX uq_nodes_id_identity ON nodes(id, identity_id);

-- ⑤ 非空与存在性由触发器强制（A 路径没有真 NOT NULL / 复合 FK）
CREATE TRIGGER trg_nodes_identity_ins BEFORE INSERT ON nodes
WHEN NEW.identity_id IS NULL
BEGIN SELECT RAISE(ABORT,'nodes.identity_id is required'); END;

CREATE TRIGGER trg_nodes_identity_upd BEFORE UPDATE OF identity_id ON nodes
WHEN NEW.identity_id IS NULL
BEGIN SELECT RAISE(ABORT,'nodes.identity_id must not be null'); END;

CREATE TRIGGER trg_nodes_cv_fk BEFORE INSERT ON nodes
WHEN NEW.identity_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM node_config_versions v
                 WHERE v.identity_id = NEW.identity_id
                   AND v.config_version = NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes.config_version not in node_config_versions'); END;

CREATE TRIGGER trg_nodes_cv_fk_upd BEFORE UPDATE OF config_version, identity_id ON nodes
WHEN NEW.identity_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM node_config_versions v
                 WHERE v.identity_id = NEW.identity_id
                   AND v.config_version = NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes.config_version not in node_config_versions'); END;
```

**为什么必须 `UNIQUE(id, identity_id)`**：SQLite 的复合外键要求父键"被 PK 或**唯一索引**覆盖"。`id` 是 PK，但 `(id, identity_id)` 不是；不建这个唯一索引，`target_results`/`detection_tasks` 的 `REFERENCES nodes(id, identity_id)` 会报 `foreign key mismatch`。加列路径下这条索引**必须**在建任何子表之前存在（P0-1.5）。

**回填顺序（不可倒置）**：

```
node_identities 建表 → 逐行插入 identity（按 nodes.id 升序，保证 identity_id 稳定）
→ legacy_node_identity_map 写入
→ nodes.identity_id 回填（UPDATE ... FROM map）
→ nodes.config_version 回填为 1，并为每条 identity 写 node_config_versions(1, fingerprint)
→ 建 uq_nodes_id_identity
→ 建三个触发器
→ 验证：无 NULL、无孤儿、map 全覆盖
```

### 3.4 旧节点到身份的映射规则（P0-1.6）

| 旧行 | 映射 | 说明 |
| --- | --- | --- |
| 任意 `nodes` 行（`status` 任意） | 1 条新 identity，`lifecycle='active'` | 旧库无 `missing/retired` 概念，不臆造 |
| `status='unavailable'` | 同上 + 健康 `unavailable` + 全目标保守恢复（§7.4） | 身份是"这台机器"，与健康状态正交 |
| `status='available'` | 同上 + 健康 `unknown` | 旧"可用"不升级为 `healthy` |
| 同机场同 `fingerprint` 重复行 | **不应存在**（旧库有唯一约束）；若存在 → **停止迁移**，报 `duplicate_fingerprint` | 不能猜哪台是"真机" |

---

## 4. P0-2：完整依赖图与 P0 迁移顺序

### 4.1 依赖图（父 → 子）

```
airports（既有）
 ├─ node_identities            [P0-1]
 │   ├─ node_config_versions   [P0-3]  (FK identity_id)
 │   ├─ identity_stable_ids    [P0-3]
 │   ├─ identity_config_pending[P0-3]
 │   ├─ identity_presence_log  [P0-3]
 │   └─ nodes.identity_id / nodes.config_version  [P0-3，回填]
 │        ├─ uq_nodes_id_identity  ← 后续所有复合外键的父键
 │        ├─ node_target_state     [P0-4]
 │        ├─ node_state_history    [P0-4]
 │        ├─ node_id_reservations  [P0-5]
 │        ├─ detection_tasks       [P0-6]
 │        │   └─ detection_task_runs [P0-7]
 │        │   └─ target_results    [P0-8]
 │        └─ restore_authorizations[P0-9]（FK node_id_reservations / nodes）
 ├─ airport_identity_daily      [P0-10]
 └─ airport_union_snapshot      [P0-10]

detection_rules（无依赖）  → 被 detection_tasks 引用
legacy_cutover（只读旧表）  → 位置自由
schema_migrations / system_events → P-1 已建
```

### 4.2 唯一 P0 迁移顺序（17 步，编号 0–16，含阶段与回滚）

| 步 | 对象/动作 | 阶段 | 依赖 | 失败回滚范围 |
| --- | --- | --- | --- | --- |
| 0 | 备份、`quick_check`、记录 `foreign_keys` 原值、`busy_timeout` | before-begin | — | 无（纯读与备份） |
| 1 | 预检 `sqlite_master`：哪些新表已存在 → C-1/C-2 分支；旧表行数与时间范围 | before-begin | — | 无 |
| 2 | `node_identities` 建表 + 索引 | in-tx | airports | 整事务 |
| 3 | 逐行生成 identity（按 `nodes.id` 升序）+ `legacy_node_identity_map` | in-tx | 步 2 | 整事务 |
| 4 | `node_config_versions` 建表 + 为每条 identity 写 `version=1`（`fingerprint` 取 nodes 行） | in-tx | 步 2/3 | 整事务（含 3） |
| 5 | `nodes` 加 `identity_id`/`config_version` + 回填 + `uq_nodes_id_identity` + 四触发器 | in-tx | 步 3/4 | 整事务（含 4/5） |
| 6 | `node_target_state` + `node_state_history` 建表 | in-tx | 步 5（复合外键父键已存在） | 整事务 |
| 7 | `identity_stable_ids` / `identity_config_pending` / `identity_presence_log` 建表 | in-tx | 步 2 | 整事务 |
| 8 | `detection_rules` 建表 + `uq_rules_active` | in-tx | 无 | 整事务 |
| 9 | `detection_tasks` 建表 | in-tx | 步 5、8 | 整事务 |
| 10 | `detection_task_runs` 建表 | in-tx | 步 9 | 整事务 |
| 11 | `target_results` 建表 + 三索引 | in-tx | 步 5、9 | 整事务 |
| 12 | `node_id_reservations` + `restore_authorizations` + 回池三触发器 | in-tx | 步 5 | 整事务 |
| 13 | `airport_identity_daily` / `airport_union_snapshot` / `legacy_cutover` | in-tx | airports、旧表 | 整事务 |
| 14 | **状态回填**：`node_target_state` 初始化（§7.4 S-A～S-E，读 `nodes.status`/`fail_count`/`latency_results`） | in-tx | 步 6 + 步 13（旧表可读） | 整事务 |
| 15 | `foreign_key_check`（只读）+ 行数/列数/映射断言 | in-tx | 全部 | 中断即 ROLLBACK |
| 16 | 恢复 `foreign_keys` 原值、复查 `foreign_key_check`、写 `schema_migrations(success)` | after-commit | — | 不写 success，重跑 |

**顺序的三条硬理由（P0-2.1、P0-2.2、P0-2.3）**：

1. 父表先于子表：`node_identities`（2）→ `node_config_versions`（4）→ `nodes` 两列（5）→ 所有引用 `(id, identity_id)` 的子表（6、9、11、12）。
2. `uq_nodes_id_identity` 必须在步 6 之前建（否则子表建表即报 `foreign key mismatch`）。
3. `node_target_state` 必须先于状态回填（14）存在，且回填读取的 `nodes.status` 必须已在步 5 之后仍可读（旧列不改名）。

**不得遗漏、不得提前（P0-2.7、P0-2.8）**：本表只含 P0 对象；`publish_versions`、发布目录、`airport_*` 之外的聚合留给 P1+；P-1 只保留 `schema_migrations` + `system_events`。

### 4.3 每步的断言（摘要）

| 步 | 断言 |
| --- | --- |
| 3 | map 行数 == `nodes` 行数；identity 无重复 |
| 4 | 每条 identity 恰有 `version=1`；`fingerprint` 与 nodes 行一致 |
| 5 | `nodes.identity_id` 无 NULL；`uq_nodes_id_identity` 存在；三触发器存在 |
| 6 | 复合外键建表成功（父键验证通过） |
| 11 | `target_results` 的 `valid` CHECK 与 `VERDICTS` 一致（§5） |
| 14 | 每条 `(node,target)` 有且仅有一行；`status` 映射符合 §7.4 |
| 15 | `foreign_key_check` 0 行；`COUNT(*)` 与步 1 记录一致 |

---

## 5. P0-3：系统故障记录与 `fresh()` 的隔离

### 5.1 v1.2 的致命路径

v1.2：`valid INTEGER NOT NULL DEFAULT 1`，系统故障记录同样写 `valid=1`；`latest_valid()` 取"最新 `valid=1`"。于是：

```
10:00 有效 pass（TTL 90min）
10:05 engine 异常（valid=1, verdict=fail, failure_source='engine'）
→ latest_valid() 返回 10:05 这条 → fresh() = False → 节点被判失效
```

一条与机器无关的引擎故障，把节点踢出发布（P0-3.4、P0-3.8）。

### 5.2 数据层的资格分层（P0-3.6、P0-3.9）

**核心规则：`valid=1` 只允许给"具备健康判定资格"的记录，且由 `CHECK` 强制。**

```sql
valid INTEGER NOT NULL CHECK (valid IN (0,1)),
...
-- 唯一资格约束：valid=1 ⇔ 真实 Mihomo 业务结果（无系统故障源）
CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))
```

| 记录类型 | `mode` | `failure_source` | `valid` | 是否健康证据 | 是否入链 | 是否推进恢复 |
| --- | --- | --- | --- | --- | --- | --- |
| 有效 pass | `mihomo` | `NULL` | **1** | 是 | 否（断链） | 是 |
| 有效 fail | `mihomo` | `NULL` | **1** | 是（失败证据） | 是 | 重置 |
| engine 异常 | `mihomo` | `engine` | **0** | 否 | **否（透明）** | 否 |
| scheduler 异常 | 任意 | `scheduler` | **0** | 否 | 否 | 否 |
| system 异常 | 任意 | `system` | **0** | 否 | 否 | 否 |
| 目标事故 | `mihomo` | `target_incident` | **0** | 否 | 否 | 否 |
| TCP-only | `tcp_only` | `NULL` | **0** | 否 | 否 | 否 |

**`DEFAULT` 取消**：`valid` 不再有默认值，写入方必须显式声明——避免"忘了传"就变成 1（P0-3.6）。

**为什么系统故障也写进 `target_results`**：审计需要（何时、哪个目标、哪类故障）；但 `valid=0` 保证它在数据层就与证据分离，不靠 UI 文案（P0-3.9）。若因存储压力不想写，可改写入 `system_events`——但**不得**以 `valid=1` 混入结果表。

### 5.3 `latest_valid()` 与 `fresh()`（P0-3.7、P0-3.8）

```python
def latest_valid(node, target):
    return q1("""SELECT * FROM target_results
                  WHERE node_id=? AND target=? AND valid=1
                    AND config_version=? AND rule_version=?
                  ORDER BY finished_at DESC, result_id DESC LIMIT 1""", ...)

def fresh(node, target, now):
    r = latest_valid(node, target)
    return (r is not None
            and r.verdict == "pass"
            and r.finished_at + r.ttl_seconds > now)
```

**三条保证**：

| 保证 | 机制 |
| --- | --- |
| 系统故障不覆盖新鲜 pass | `valid=1` 过滤掉所有 `valid=0` 行 → `latest_valid()` 仍返回 10:00 的 pass |
| 系统故障不推进 `fail_chain()` | 链查询只取 `valid=1`；`valid=0` 行既不计也不断链（透明） |
| TTL 仍按当时 `ttl_seconds` | 取的是 pass 行自身字段，不回读当前配置 |

`fail_chain()` 相应简化（`valid=1` 已蕴含 `mode='mihomo'` 且无系统源）：

```python
rows = sql("""SELECT result_id, finished_at, verdict FROM target_results
               WHERE node_id=? AND target=? AND valid=1
                 AND config_version=? AND rule_version=?
               ORDER BY finished_at DESC, result_id DESC""", ...)
```

> 仍保留 `finished_at DESC, result_id DESC` 双键；`chain_future` 判断不变（首行 `finished_at > t`）。

### 5.4 状态机与恢复（同步说明）

- 目标状态迁移只用 `valid=1` 行：`fail_streak` 只累加有效 fail；`success_streak`/恢复计数只由有效 pass 推进。
- 系统故障**不重置** `observing` 计数（它不是失败，也不是成功）——避免"引擎抖动把恢复进度清零"。
- TCP-only 不推进任何计数（`valid=0`）。

### 5.5 测试 FT-SF1～FT-SF7

| # | 初始 | 步骤 | 预期库 | 预期业务 | 失败不变项 |
| --- | --- | --- | --- | --- | --- |
| SF1 | 10:00 pass（`valid=1`，TTL 90min） | 10:05 engine 异常 | 新增 `valid=0/failure_source='engine'` 行；`latest_valid` 仍返回 10:00 | `fresh=True` | pass 行不被改写 |
| SF2 | 同上 | 10:05 scheduler 异常 | 同上，`valid=0` | `fresh=True` | 同上 |
| SF3 | 同上 | 10:05 system 异常 | 同上，`valid=0` | `fresh=True` | 同上 |
| SF4 | 有效 pass 后连来 3 条 `valid=0` | 调 `fail_chain` | 链为 0 行（`valid=0` 不入扫描） | `has_fail_evidence=False(chain_short)`，但 `fresh=True` | 不写 `fail_streak` |
| SF5 | 三条 engine 异常（`valid=0`） | 调 `fail_chain` | 链 0 行 | 系统异常不能构成连续失败 | `fail_streak` 不变 |
| SF6 | TCP-only pass（`valid=0`, `mode='tcp_only'`） | 调 `fresh` | `fresh=False` | 不能成为健康证据 | 不写恢复计数 |
| SF7 | 10:00 pass → 10:05 engine（`valid=0`）→ 11:30 新 pass（`valid=1`） | 调 `fresh` | 返回 11:30 的 pass | 恢复正常检测后按新有效结果计算；10:00 已过期 | 引擎行仍 `valid=0` |

---

## 6. P0-4：C-2 遗留表的安全重建

### 6.1 v1.2 的两个硬错误

```python
q("SELECT COUNT(*) FROM ?", t)      # ← 参数占位符不能绑表名，SQLite 直接报语法错误
# 以及：按设计 DDL 建新表后 INSERT SELECT 只搬设计列 → 未知自定义列静默丢失
```

### 6.2 标识符的安全引用（P0-4.1）

| 规则 | 说明 |
| --- | --- |
| 表名/列名**不得**用 `?` 绑定 | SQLite 只支持值绑定 |
| 必须用**双引号**标识符 `"name"`，并把内部 `"` 转义为 `""` | 防注入与关键字冲突 |
| 先经白名单校验：`^[A-Za-z_][A-Za-z0-9_]{0,62}$` | 拒绝含空格/点/引号的怪名 |
| 生成方式 | `quote_ident(n) = '"' + n.replace('"','""') + '"'`，且在拼接前断言白名单通过 |

```python
def q_table_count(conn, table):
    assert IDENT_RE.match(table), f"unsafe identifier: {table}"
    return conn.execute(f'SELECT COUNT(*) FROM {quote_ident(table)}').fetchone()[0]
```

### 6.3 真实结构识别（P0-4.2）

必须全部读到，缺一项即视为"无法可靠识别"：

| 项 | 来源 |
| --- | --- |
| DDL 文本 | `SELECT sql FROM sqlite_master WHERE type='table' AND name=?`（此处 `?` 绑定**值**，合法） |
| 列（名/类型/非空/默认/PK） | `PRAGMA table_info("t")` |
| 索引 | `PRAGMA index_list("t")` + `PRAGMA index_info("idx")` |
| 外键 | `PRAGMA foreign_key_list("t")` |
| 触发器 | `sqlite_master WHERE type='trigger' AND tbl_name=?`（读 `sql`） |
| 行数 | `SELECT COUNT(*) FROM "t"`（标识符引用） |
| **被引用情况** | 扫 `sqlite_master` 全表 SQL，检索 `REFERENCES\s+"?t"?`；命中即存在**其他表引用本表** |

### 6.4 未知额外字段（P0-4.3）与停止原则

| 额外字段情形 | 处理 |
| --- | --- |
| 纯标量列（有类型、默认值兼容、无约束） | 允许：新表 = 设计列 + 追加这些列，按原类型与默认值 |
| 带 `NOT NULL` 且无默认值 | **停止**（无法为历史 NULL 补齐） |
| 带 `UNIQUE` / `PRIMARY KEY` / `CHECK` / `REFERENCES` | **停止**（约束语义无法可靠移植） |
| 生成列 / 类型无法解析 | **停止** |
| 列名与设计列冲突但类型不同 | **停止** |

**停止原则（本轮新增的安全底线）**：

> 只要出现"无法可靠识别"或"无法无损迁移"的任一情形，**不重建**，保留原表，写 `system_events(event='schema_diff', table=..., reason=...)`，由人工决定。**绝不**为了"跑通迁移"而丢弃未知字段、索引、触发器或外键。

### 6.5 索引与触发器恢复（P0-4.4）

| 对象 | 恢复方式 | 冲突处理 |
| --- | --- | --- |
| 设计必需索引 | 按 §5/§8 的固定名称重建 | 与旧名冲突 → 先建新的（临时名），DROP 旧表后再改名 |
| 旧表自定义索引 | 逐条 `CREATE INDEX`，语句取自 `sqlite_master.sql`（仅替换表名为新的） | 名字冲突 → 加后缀 `_legacy` 并记 `schema_diff(index_renamed)` |
| 旧表触发器 | 仅当触发器 SQL 引用的**所有列**在新表中存在时重建 | 引用缺失列 → **停止**（不静默删触发器） |
| 名称冲突 | 同一名称已存在 | 先 DROP 旧的（属于将被替换的表）；若属于别的表 → **停止** |

### 6.6 存在其他表引用时（P0-4.5）

若 `PRAGMA foreign_key_list` 之外还有**入向引用**（其他表 `REFERENCES 本表`）：

| 情形 | 处理 |
| --- | --- |
| 入向引用存在，且本表是子表（出向 FK） | 允许重建，但必须先 `foreign_keys=OFF`（before-begin） |
| 入向引用存在（本表是父表） | **停止**：重建会让引用方的 FK 指向被 DROP 的表名（SQLite 的 `RENAME` 在 `legacy_alter_table=OFF` 时会尝试改写引用方 SQL，行为随版本变化），风险不可控 |

### 6.7 逐项验证（P0-4.6）

| 项 | 断言 |
| --- | --- |
| 行数 | 新旧相等（DROP 之前比一次，提交后再比一次） |
| 字段数据 | 双向 `EXCEPT`：`SELECT 全列 FROM old EXCEPT SELECT 全列 FROM new` 与反向，均须为空 |
| 索引 | 名称集合相等（允许 `_legacy` 后缀重命名，需在事件中记录映射） |
| 触发器 | 名称与数量相等；`sql` 除表名替换外逐字相同 |
| 外键 | `PRAGMA foreign_key_list` 集合相等；`PRAGMA foreign_key_check` 0 行 |
| 结构 | 设计列的类型/非空/默认/CHECK 与 §5、§8 一致 |

### 6.8 中途失败与回滚（P0-4.7）

| 时点 | 结果 |
| --- | --- |
| `before-begin` 阶段失败 | 未改库；`foreign_keys` 尚未切换或已切回 |
| `in-tx` 任一步失败 | `ROLLBACK`：新表、搬运、DROP、RENAME 全部撤销；旧表原样 |
| 提交前崩溃 | 自动回滚；`"t__new"` 可能残留 → 启动扫描，确认无 success 行后 `DROP` |
| 提交后崩溃 | 新表生效；`foreign_keys` 由启动钩子置 `ON`；后置校验重跑 |
| 校验失败（提交后） | 不回滚（已提交），写 `system_events(schema_verify_failed)`；从备份恢复需人工 |

**安全网**：C-2 只在"检测到非基准遗留表"时触发；基准库（`sqlite_master` 无该表）永远走 C-1，不进入本流程。

### 6.9 M20 / M21 重写（可执行步骤）

**M20｜检测到意外旧表 → C-2，不覆盖**

- 初始：试验库存在 `detection_task_runs`，但 DDL 为 `(id INTEGER, task TEXT, result TEXT)` 三列，无 CHECK、无 FK、有一个自定义索引 `idx_old`。
- 步骤：① 读 `sqlite_master.sql` + `PRAGMA table_info/index_list/foreign_key_list`；② 判定"无法映射到设计列"（列名全不同）→ 触发停止原则；③ 若判定为可迁移变体，则建 `__new`、动态全列搬运、重建索引、DROP/RENAME；④ 提交后跑 §6.7 六项断言。
- 预期库：走停止路径时 → 原表不动，`system_events(schema_diff, reason='unmappable_columns')`，`schema_migrations` 无 success；走迁移路径时 → 新表含设计列 + 保留可追加列，行数相等，`foreign_key_check` 0 行。
- 预期业务：不静默覆盖、不丢数据；人工可据事件决定。
- 失败不变项：原表行数、索引、数据。

**M21｜C-2 全字段/索引/触发器保留**

- 初始：旧表 = 设计九列 + `extra_note TEXT DEFAULT ''`，另有索引 `idx_extra(extra_note)`、触发器 `trg_extra`（仅引用 `extra_note`）。
- 步骤：① 识别额外列为"纯标量带默认" → 允许；② 新表 = 设计列 + `extra_note`；③ 按 §6.4 动态列搬运；④ 重建 `idx_extra` 与 `trg_extra`（名称不冲突）；⑤ §6.7 六项断言（含双向 `EXCEPT`）。
- 预期库：行数相同；`extra_note` 值逐行一致；索引与触发器存在且 `sql` 等价；`foreign_key_check` 0 行。
- 预期业务：零丢失。
- 失败不变项：`detection_tasks` 数据、原表在回滚场景完好。

---

## 7. C18 / C19：边界说明（仍待确认）

### 7.1 C18：TCP-only 记录的允许范围

| 允许 | 禁止 |
| --- | --- |
| 写入 `target_results`（`mode='tcp_only'`、`valid=0`）用于诊断与审计 | 参与健康达标（`fresh()` 已排除） |
| 在 UI"诊断"页展示 | 参与连续失败链（`valid=1` 过滤） |
| 计入"检测执行次数"统计 | 参与恢复确认计数 |
| — | 影响订阅发布资格 |

**状态**：**C18 待用户确认**。默认按上表实现（允许存、绝不参与判定）。

### 7.2 C19：旧结果表停写的切换边界

| 环节 | 设计 |
| --- | --- |
| 新流程启用时刻 | `cutover_state='new_active'` 写入 `system_events` 的时刻（带 `cutover_at`） |
| 旧流程停写时刻 | 同一事务内、`cutover_at` 之后：旧 writer 关闭 |
| 防双写的机制 | 单一开关（DB 中的 `cutover_state`，非配置文件）；新旧 writer 均读同一开关；`new_active` 后旧 writer 直接拒绝写入 |
| 避免空窗 | **先验证后切换**：新流程连续 N 次（建议 3 次）成功产出并落库 `target_results`，才允许切换；切换前旧流程仍在写 |
| 切换失败回滚 | 开关留在 `dual_write`/`old_active`；新流程数据保留但标记 `pre_cutover`；不删除旧表数据 |
| 双写窗口 | 若确需并行，必须写 `cutover_state='dual_write'` 并在事件中记录起止；窗口内两表都写，**但**健康判定只读 `target_results` |

**状态**：**C19 待用户确认**。默认设计为"先验证、单开关、可回滚"，不默认开启双写。

---

## 8. 更新后的 DDL 摘要（与本轮相关）

```sql
-- target_results（P0-3 修正后的资格列）
valid INTEGER NOT NULL CHECK (valid IN (0,1)),
...
CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))

-- detection_tasks（P0-1 修正后的父键）
FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)

-- target_results（同）
FOREIGN KEY (node_id, identity_id) REFERENCES nodes(id, identity_id)
```

其余字段（`result_id`、`target`、`config_version`、`rule_version`、`verdict`、`mode`、`failure_source`、`finished_at`、`ttl_seconds`、`task_id`、审计列）与 v1.2 §3.2 一致，仅 `valid` 语义与 CHECK 变化。

---

## 9. v1.2 → v1.3 修订对照

| # | v1.2 | v1.3 | 章节 |
| --- | --- | --- | --- |
| P0-1 | 子表直接引用不存在的 `nodes(id, identity_id)` | 先建 `node_identities`/`node_config_versions`、再给 `nodes` 加两列并回填、再建 `uq_nodes_id_identity`、最后建子表；A/B 双路径，B 需 C12 | §3 |
| P0-2 | 8 步，缺身份层与状态层依赖 | 13 步完整顺序（0–16），每步含阶段、依赖、回滚范围、断言 | §4 |
| P0-3 | `valid` 默认 1，系统故障覆盖 pass | 取消默认；`valid=1` 由 CHECK 限定为"有效 Mihomo 业务结果"；系统/TCP 一律 `valid=0` | §5 |
| P0-4 | 表名绑参、按设计 DDL 建表丢列 | 双引号标识符 + 白名单；真实 DDL/PRAGMA 全读；未知列分类；无法无损即停止 | §6 |

---

## 10. 四项 P0 关闭证明

| 来源 | 问题 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- | --- |
| P0-1.1 | 以真实 nodes 为起点 | §2 | M23 | 已关闭 |
| P0-1.2 | 是否重建及原因 | §3.1 A/B 表 | M23/M24 | 已关闭 |
| P0-1.3 | identity 产生/回填/验证 | §3.2、§3.3 | M23 | 已关闭 |
| P0-1.4 | 复合外键父键唯一约束 | §3.3 `uq_nodes_id_identity` | M23 | 已关闭 |
| P0-1.5 | 父表就绪后再建子表 | §4.2 步 5→6/9/11/12 | M24 | 已关闭 |
| P0-1.6 | 旧节点→身份映射 | §3.4 + `legacy_node_identity_map` | M23 | 已关闭 |
| P0-1.7 | C12 仍待确认 | §3.1 明示 | — | 已关闭（待确认） |
| P0-2.1 | 先父后子 | §4.1 依赖图 | M24 | 已关闭 |
| P0-2.2 | 先身份字段再复合外键 | §4.2 步 5/6 | M24 | 已关闭 |
| P0-2.3 | 先 `node_target_state` 再回填 | §4.2 步 6→14 | M25 | 已关闭 |
| P0-2.4 | 回填在 Schema 之后 | §4.2 步 14 | M25 | 已关闭 |
| P0-2.5 | 每步阶段 | §4.2 阶段列 | M24 | 已关闭 |
| P0-2.6 | 每步回滚范围 | §4.2 回滚列 | M26 | 已关闭 |
| P0-2.7 | 不遗漏、不提前 | §4.2 说明 | M26 | 已关闭 |
| P0-2.8 | P-1 只建两表 | §4.2 步 0 注 + §4.1 | M26 | 已关闭 |
| P0-3.1 | 系统异常非失败证据 | §5.2 表 | SF5 | 已关闭 |
| P0-3.2 | 不推进 `fail_chain` | §5.3（`valid=1`） | SF4/SF5 | 已关闭 |
| P0-3.3 | 不推进恢复 | §5.4 | SF4 | 已关闭 |
| P0-3.4 | 不覆盖最后有效结果 | §5.3 `latest_valid` | SF1–SF3 | 已关闭 |
| P0-3.5 | TCP-only 无资格 | §5.2 | SF6 | 已关闭 |
| P0-3.6 | 写入与否 + valid 取值 | §5.2（写、`valid=0`、无默认） | SF1–SF3 | 已关闭 |
| P0-3.7 | `latest_valid` 只取有资格 | §5.3 | SF1 | 已关闭 |
| P0-3.8 | 不使 TTL 内 pass 失效 | §5.3 TTL 用行内 `ttl_seconds` | SF1/SF7 | 已关闭 |
| P0-3.9 | 数据层可区分 | CHECK 约束 | SF1/SF6 | 已关闭 |
| P0-4.1 | 标识符安全引用 | §6.2 | M20 | 已关闭 |
| P0-4.2 | 真实 DDL 识别 | §6.3（7 项） | M20 | 已关闭 |
| P0-4.3 | 未知字段处理 | §6.4 分类 + 停止原则 | M20/M21 | 已关闭 |
| P0-4.4 | 索引/触发器恢复与冲突 | §6.5 | M21 | 已关闭 |
| P0-4.5 | 入向引用处理 | §6.6 | M20 | 已关闭 |
| P0-4.6 | 逐项验证 | §6.7 六项 | M21 | 已关闭 |
| P0-4.7 | 中途失败回滚 | §6.8 | M20/M21 | 已关闭 |

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
| 失败链 FE | 19 | FE1–FE19 |
| 恢复 RG | 24 | RG1–RG24 |
| 系统故障 SF | 7 | SF1–SF7 |
| verdict TV | 4 | TV1–TV4 |
| 迁移 M | 26 | M1–M22 + M23–M26 |

### 11.2 新增迁移详测（M23–M26）

**M23｜父子建表与身份回填**

- 初始：基准库，`nodes` 12 行（`status` 混合 `unknown/available/unavailable`），无 `identity_id`。
- 步骤：按 §4.2 步 2–5 执行。
- 预期库：`node_identities` 12 行；`node_config_versions` 12 行（`version=1`）；`nodes.identity_id` 全非空；`legacy_node_identity_map` 12 行且一一对应；`uq_nodes_id_identity` 与四触发器存在。
- 预期业务：父键就绪。
- 失败不变项：`nodes` 行数与内容（除两新列）、旧表数据。

**M24｜子表建表依赖**

- 初始：承接 M23。
- 步骤：建 `node_target_state`、`detection_tasks`、`target_results`。
- 预期库：三表创建成功（无 `foreign key mismatch`）；`PRAGMA foreign_key_list` 显示指向 `nodes(id, identity_id)`。
- 预期业务：外键真正生效（插一条 `identity_id` 对不上的行应失败）。
- 失败不变项：已建表与数据。

**M25｜状态回填顺序**

- 初始：承接 M24；旧 `nodes.status='unavailable'` 2 行、`available` 9 行、`unknown` 1 行。
- 步骤：执行 §7.4 回填。
- 预期库：每条 `(node,target)` 一行；`unavailable` 两行的全部必需目标 `target_ever_unavailable=1` 且 `observing`；`available` 行的 `health='unknown'`；`unknown` 行全 0。
- 预期业务：迁移后恢复要求保留。
- 失败不变项：`node_target_state` 无半成品行（事务回滚）。

**M26｜回滚与阶段边界**

- 初始：模拟步 14 失败。
- 步骤：执行迁移至步 14 并注入错误。
- 预期库：`ROLLBACK` 后所有新表不存在；`schema_migrations` 无 success；`system_events`（P-1 已建）保留其迁移前事件。
- 预期业务：可重跑；P-1 成果不被破坏。
- 失败不变项：旧库全表。

---

## 12. 数据库依赖关系图（最终）

```
P-1（已建）: schema_migrations, system_events
                    │（仅被写入，不被依赖）
P0:
airports ──> node_identities ──> node_config_versions
                 │                      │
                 ├──> identity_stable_ids
                 ├──> identity_config_pending
                 ├──> identity_presence_log
                 └──> nodes.identity_id / nodes.config_version（回填）
                         │
                         ├── uq_nodes_id_identity  ← 复合外键父键
                         ├──> node_target_state（复合 FK）
                         ├──> node_state_history
                         ├──> node_id_reservations ──> restore_authorizations
                         ├──> detection_tasks（复合 FK + rules）
                         │        ├──> detection_task_runs
                         │        └──> target_results
                         └──> （回填 §7.4 状态）

detection_rules ──> detection_tasks
airport_identity_daily / airport_union_snapshot（依赖 airports）
legacy_cutover（读旧 results / latency_results）
```

---

## 13. 未解决问题与确认状态

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（获批才走 §3.1 B） | **未确认（本轮未假设已批准）** |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口 | 6h 优先 | 未确认 |
| C15 | `rep` 门槛 | 0.90 / 0.60 | 未确认 |
| C16 | retired 回归复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| C18 | TCP-only 记录允许存、绝不参与判定 | 按 §7.1 | **未确认** |
| C19 | 旧结果表停写切换 | 先验证、单开关、可回滚（§7.2） | **未确认** |
| **C20** | A 路径（不重建）下 `nodes.identity_id` 靠触发器强制非空，是否接受"物理可空" | 建议接受；B 路径获批后可升级 | **新增，未确认** |

**事实缺口（需实测）**：旧 `nodes` 是否存在 `id` 重复或 `(airport_id,fingerprint)` 冲突；`identity_presence_log` 的 30 天体量；`target_results` 增长速率与索引代价；生产库是否已有 `detection_*` 同名表（决定 C-1/C-2）。

**已知无解**：SQLite 无法证明调用者身份（回池令牌仅数据绑定 + 一次性 + 审计）；旧库无版本/模式字段，旧历史无法升级为证据。

---

## 14. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | A 路径的"物理可空 + 触发器"被绕过（如 `PRAGMA recursive_triggers`/工具直写） | 触发器覆盖 INSERT 与 UPDATE OF；迁移后断言无 NULL；B 路径可彻底解决 | M23 |
| 2 | 身份回填错位（一条 nodes 行两条 identity） | map 表一一对应 + 覆盖/唯一/双向三验证 | M23 |
| 3 | 系统故障仍被写成 `valid=1` | CHECK 强制；写入方无默认值可用 | SF1–SF3 |
| 4 | C-2 误判"可迁移"导致丢列 | 未知列分类 + 停止原则 + 双向 EXCEPT | M20/M21 |
| 5 | 迁移中途失败 | 全 P0 在一个 `BEGIN IMMEDIATE`；每步回滚范围明确 | M26 |
| 6 | 回填范围过保守（全目标置 1）导致恢复变慢 | 迁移前统计 S-A 命中率 | RG23 |

---

**v1.3 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅修订四项 P0 并为 C18/C19 补边界说明。**C11–C20 全部未确认**，其中 C12 未被本轮视为已批准。文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
