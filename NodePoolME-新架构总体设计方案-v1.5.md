# NodePoolME 新架构总体设计方案 v1.5

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.4
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：仅三项——REPLACE 与 UPSERT 的规则矛盾、`nodes` 档案的 REPLACE 保护、`foreign_keys=OFF` 时身份删除保护不完整。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 修订索引（v1.4 → v1.5）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | 拆开 REPLACE 与 UPSERT：删除路径 vs 更新路径，各挂各的守卫 | §3.6 | 修正 |
| P0-2 | `nodes` 档案 `BEFORE DELETE` 守卫 + 全项目 REPLACE 审查清单 | §3.7 | 补齐 |
| P0-3 | 连接级 PRAGMA 强制 + `trg_ident_del` 显式覆盖配置版本与身份子表 | §4、§3.4 | 补齐 |

未修订：Q1–Q12、v1.4 的六个关系触发器、A 路径"部分完整性、不等价 B"、C12 未确认且默认 A、C-2 用 `PRAGMA foreign_key_list` 权威识别且任何入向即停、17 步迁移主序号、系统故障 `valid=0` 隔离、30 天 missing、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式兼容、评分算法、前端布局。**C11–C20 全部未确认。**

---

## 0. 本轮修的是什么

v1.4 把"禁止 REPLACE / UPSERT"写成了同一条，结果自相矛盾，也漏了两个真实缺口。

| # | v1.4 的写法 | 缺陷 |
| --- | --- | --- |
| P0-1 | §3.6 写"禁父表 REPLACE/UPSERT"，同时又说"UPSERT 走 UPDATE 分支不删行" | 一句话里既禁又用，规则不成立；`REPLACE` 与 `DO UPDATE` 的机制完全不同，却被合并 |
| P0-2 | 只禁父表 REPLACE，没管 `nodes` 自己 | `nodes` 有 `UNIQUE(airport_id, fingerprint)`，`INSERT OR REPLACE` 会删掉原节点行再插新行 → `id` 变、历史与身份关联脱钩 |
| P0-3 | `trg_ident_del` 只查 `nodes` | `foreign_keys=OFF` 时，identity 无节点引用但仍有版本行 → 删 identity 留下孤儿版本；且没有把"每连接必须开 `foreign_keys`"写成运行期强制规则 |

v1.5 的核心一句话：**REPLACE 与 UPSERT 是两条不同路径，必须在两个不同位置拦；`foreign_keys` 不是"当前值"，是"连接契约"。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；指纹算法不改；身份与生命周期原则不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康最多留上一版 24h、硬上限 72h；30 个发布版本；Q11 两次有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不重做。

**A 路径六个关系触发器（v1.4 §3.3/§3.4）一字不改**：`trg_nodes_rel_ins`、`trg_nodes_rel_upd`、`trg_ident_del`（本轮仅扩充 `WHEN` 内的引用清单，判定结构不变）、`trg_cv_del`、`trg_ident_airport_upd`、`trg_cv_pk_upd`。**A 路径仍是部分引用完整性，不等价于 B；B 仍需 C12 批准。**

---

## 2. 基准 `nodes` 与 A/B 路径（不变）

| 事实 | 说明 |
| --- | --- |
| `nodes` 有 `id` PK、`UNIQUE(airport_id, fingerprint)` | 基准 |
| 无 `identity_id`、无 `config_version` | 基准 |
| 有 `status`、`fail_count` | 基准代码 |

| 路径 | 是否重建 | 约束强度 | 前置 |
| --- | --- | --- | --- |
| **A（默认）** | 否 | 部分完整性：触发器覆盖 INSERT/UPDATE/DELETE，但不等价于复合外键 | 无需 C12 |
| **B（可选）** | 是（12 步） | 真 `NOT NULL` + 真复合外键 + 父表 `ON DELETE RESTRICT` | **C12 需批准，未确认** |

---

## 3. P0-1 / P0-2：A 路径的身份引用完整性与档案保护

### 3.1 关系不变式（不变）

```
I1  nodes.identity_id 非空 ∧ nodes.config_version 非空
I2  identity 存在 ∧ identity.airport_id = nodes.airport_id
I3  (identity_id, config_version) 存在于 node_config_versions
I4  父记录被引用时不可删除
I5  nodes 行是"机器档案"，不可被删除重建（本轮新增，见 §3.7）
```

### 3.2 父表与索引（不变）

```sql
CREATE TABLE node_identities (
  identity_id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id  INTEGER NOT NULL,
  stable_id   TEXT,
  generation  INTEGER NOT NULL DEFAULT 1,
  lifecycle   TEXT NOT NULL DEFAULT 'active'
              CHECK (lifecycle IN ('active','missing','retired')),
  related_identity_id INTEGER REFERENCES node_identities(identity_id) ON DELETE SET NULL,
  first_seen_at TEXT NOT NULL,
  last_present_at TEXT,
  created_at  TEXT NOT NULL,
  FOREIGN KEY (airport_id) REFERENCES airports(id)
);

CREATE TABLE node_config_versions (
  identity_id    INTEGER NOT NULL,
  config_version INTEGER NOT NULL,
  fingerprint    TEXT NOT NULL,
  params_hash    TEXT,
  protocol TEXT, server TEXT, port INTEGER, display_name TEXT,
  change_reason  TEXT NOT NULL DEFAULT 'initial',
  opened_at TEXT NOT NULL,
  closed_at TEXT,
  PRIMARY KEY (identity_id, config_version),
  FOREIGN KEY (identity_id) REFERENCES node_identities(identity_id)
);

ALTER TABLE nodes ADD COLUMN identity_id INTEGER;
ALTER TABLE nodes ADD COLUMN config_version INTEGER;
CREATE UNIQUE INDEX uq_nodes_id_identity ON nodes(id, identity_id);
CREATE INDEX idx_nodes_identity ON nodes(identity_id, config_version);
```

### 3.3 插入与更新（v1.4 不变，仅复述要点）

```sql
CREATE TRIGGER trg_nodes_rel_ins BEFORE INSERT ON nodes
WHEN NEW.identity_id IS NULL OR NEW.config_version IS NULL
  OR NOT EXISTS (SELECT 1 FROM node_identities i
                  WHERE i.identity_id = NEW.identity_id AND i.airport_id = NEW.airport_id)
  OR NOT EXISTS (SELECT 1 FROM node_config_versions v
                  WHERE v.identity_id = NEW.identity_id AND v.config_version = NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes identity relation invalid (null/cross-airport/version)'); END;

CREATE TRIGGER trg_nodes_rel_upd BEFORE UPDATE OF airport_id, identity_id, config_version ON nodes
WHEN NEW.identity_id IS NULL OR NEW.config_version IS NULL
  OR NOT EXISTS (SELECT 1 FROM node_identities i
                  WHERE i.identity_id = NEW.identity_id AND i.airport_id = NEW.airport_id)
  OR NOT EXISTS (SELECT 1 FROM node_config_versions v
                  WHERE v.identity_id = NEW.identity_id AND v.config_version = NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes identity relation invalid after update'); END;
```

`UPDATE OF` 三列 = "出现在 SET 就重验"，即使值未变。

### 3.4 删除侧：父记录保护（P0-3 补齐版）

v1.4 的 `trg_ident_del` 只查 `nodes`。`foreign_keys=OFF` 时真外键全失效，若某 identity 已无节点引用、但仍有版本行或身份子表行，删 identity 就会留下孤儿。**删除守卫必须显式覆盖全部引用表，不能把安全寄托在 `foreign_keys`。**

```sql
CREATE TRIGGER trg_ident_del BEFORE DELETE ON node_identities
WHEN EXISTS (SELECT 1 FROM nodes                WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM node_config_versions WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_stable_ids   WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_config_pending WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_presence_log WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM node_identities       WHERE related_identity_id = OLD.identity_id)
BEGIN SELECT RAISE(ABORT,'identity still referenced (nodes/config_versions/identity_*)'); END;

CREATE TRIGGER trg_cv_del BEFORE DELETE ON node_config_versions
WHEN EXISTS (SELECT 1 FROM nodes
              WHERE identity_id = OLD.identity_id AND config_version = OLD.config_version)
BEGIN SELECT RAISE(ABORT,'config_version still referenced by nodes'); END;

CREATE TRIGGER trg_ident_airport_upd BEFORE UPDATE OF airport_id ON node_identities
WHEN NEW.airport_id <> OLD.airport_id
 AND EXISTS (SELECT 1 FROM nodes WHERE identity_id = OLD.identity_id AND airport_id <> NEW.airport_id)
BEGIN SELECT RAISE(ABORT,'identity airport change breaks nodes relation'); END;

CREATE TRIGGER trg_cv_pk_upd BEFORE UPDATE OF identity_id, config_version ON node_config_versions
WHEN EXISTS (SELECT 1 FROM nodes
              WHERE identity_id = OLD.identity_id AND config_version = OLD.config_version)
BEGIN SELECT RAISE(ABORT,'config_version key change breaks nodes relation'); END;
```

**引用清单是"下限清单"**：`trg_ident_del` 的 `WHEN` 里那五张表是 P0 内确定存在的引用方。P1+ 若新增引用 `identity_id` 的表（例如 `restore_authorizations` 若带 identity 列），**必须同步把该表加入 `WHEN`**，并在 §3.5 断言里加一条"引用清单与 `sqlite_master` 实际外键清单一致"的核对项。这是规则，不是建议。

**为何仍然 ABORT 而非级联**：级联会删掉 `nodes` 行，等于销毁机器档案（违反 I5）。

### 3.5 完整性断言（不变，新增一条）

| 断言 | SQL 形态 |
| --- | --- |
| 无 NULL | `SELECT COUNT(*) FROM nodes WHERE identity_id IS NULL OR config_version IS NULL` == 0 |
| 无跨机场 | `nodes JOIN node_identities USING(identity_id) WHERE i.airport_id <> n.airport_id` == 0 |
| 无孤儿版本 | `nodes LEFT JOIN node_config_versions ON (identity_id, config_version) WHERE v.identity_id IS NULL` == 0 |
| 一节点一身份 | `uq_nodes_id_identity` + `legacy_node_identity_map.identity_id` UNIQUE |
| 触发器齐备 | **7 个**触发器名全部存在（六个关系触发器 + `trg_nodes_delete_guard`） |
| 引用清单自洽 | `trg_ident_del` 的 `WHEN` 覆盖了 `PRAGMA foreign_key_list` 中所有引用 `node_identities` 的父表 |

### 3.6 P0-1：REPLACE 与 UPSERT 的区别（本轮重写）

#### 3.6.1 四种写法的机制

| 写法 | 冲突时的真实动作 | 是否删行 | 走哪条触发器链 | 规则 |
| --- | --- | --- | --- | --- |
| `INSERT OR REPLACE INTO t ...` | **删除**冲突行，再插入新行 | **是** | `BEFORE DELETE`（仅 `recursive_triggers=ON`）+ `BEFORE INSERT` | **禁止** |
| `REPLACE INTO t ...` | 同上（同义写法） | **是** | 同上 | **禁止** |
| `INSERT ... ON CONFLICT(col) DO UPDATE SET ...` | **原地更新**冲突行 | 否 | `BEFORE UPDATE OF <SET 中列>`（+ 插入阶段的 `BEFORE INSERT`） | **允许**（受 UPDATE 触发器约束） |
| `INSERT ... ON CONFLICT(col) DO NOTHING` | 静默跳过 | 否 | 仅插入阶段 | **限用**（仅追加型表） |

**关键区别不是"新旧"，而是删行不删行**。`REPLACE` 的删除发生在插入之前、同一语句内；`DO UPDATE` 永远不删行。v1.4 把两者合成一句"禁 REPLACE/UPSERT"，等于把安全的写法一起禁掉、又把危险的写法只写在注释里。

#### 3.6.2 允许 / 禁止清单

| 表 | REPLACE | `DO UPDATE` | `DO NOTHING` |
| --- | --- | --- | --- |
| `nodes` | 禁止 | **允许**（须在 `SET` 中带上完整关系，或 INSERT 部分给全 `identity_id`/`config_version`） | 禁止（冲突必须显式处理） |
| `node_identities` | 禁止 | 允许（`SET` 限 `last_present_at`/`lifecycle`/`stable_id`/`generation`，PLES） | 禁止 |
| `node_config_versions` | 禁止 | 允许（`SET` 限 `closed_at`/`display_name`/`params_hash`，PK 不得改） | 禁止 |
| `node_target_state` / `node_state_history` | 禁止 | 允许 | 允许 |
| `detection_tasks` / `detection_task_runs` | 禁止 | 允许（状态推进） | 允许（幂等闸门） |
| `target_results` | 禁止 | 禁止（证据行不可变，冲突即错） | **禁止**（重复证据必须显式报错） |
| `identity_presence_log` / `airport_*` / 日志类 | 禁止 | 允许 | 允许 |

#### 3.6.3 正确 SQL 示例

```sql
-- ✅ 允许：UPSERT 走 UPDATE 分支，identity/config_version 关系被 BEFORE UPDATE OF 三列重验
INSERT INTO nodes (airport_id, fingerprint, identity_id, config_version, status, fail_count, ...)
VALUES (?, ?, ?, ?, 'unknown', 0, ...)
ON CONFLICT(airport_id, fingerprint) DO UPDATE SET
  last_seen = excluded.last_seen,
  status    = excluded.status;          -- SET 不含 identity_id/config_version → 不触发关系重验，关系保持不变

-- ✅ 允许：需要改版本时，显式带上完整关系（触发关系重验）
UPDATE nodes SET config_version = ? WHERE id = ?;

-- ✅ 允许：两段式（REPLACE 的安全替代，语义明确）
SELECT id FROM nodes WHERE airport_id = ? AND fingerprint = ?;   -- 命中 → UPDATE；未命中 → INSERT

-- ✅ 允许：追加型表的幂等写
INSERT INTO identity_presence_log (identity_id, day, seen) VALUES (?, ?, 1)
ON CONFLICT(identity_id, day) DO UPDATE SET seen = seen + 1;
```

#### 3.6.4 禁止 SQL 示例（代码评审必须打回）

```sql
-- ❌ 禁止：删除原行再插入 → id 变化、历史脱钩
INSERT OR REPLACE INTO nodes (airport_id, fingerprint, ...) VALUES (...);
REPLACE INTO nodes (airport_id, fingerprint, ...) VALUES (...);

-- ❌ 禁止：给 identity 换 id
REPLACE INTO node_identities (identity_id, airport_id, ...) VALUES (10, 1, ...);

-- ❌ 禁止：证据行覆盖
INSERT OR REPLACE INTO target_results (...) VALUES (...);
```

#### 3.6.5 `DO NOTHING` 的使用边界

| 允许 | 禁止 |
| --- | --- |
| 追加/幂等表（presence log、批次表、日志） | `target_results`（重复证据必须暴露，不能静默丢弃第二条） |
| `detection_task_runs` 的幂等闸门（同 token 重复提交） | `nodes` / `node_identities` / `node_config_versions`（冲突意味着身份漂移，必须走显式分支） |

理由：`DO NOTHING` 的语义是"我承认可能已存在，且无需处理"。对档案类表，冲突恰恰是要处理的事件；静默跳过会掩盖身份漂移。

#### 3.6.6 测试（R 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| R1 | 空表 / 新指纹 | 普通 `INSERT` 新节点（带合法 identity/version） | 成功；`nodes` +1；新 `id` |
| R2 | 节点 N（机场 1、指纹 F、id=5） | `INSERT OR REPLACE INTO nodes(airport_id=1, fingerprint=F, ...)` | **整语句失败**（`trg_nodes_delete_guard` 在删除阶段 ABORT）；`id=5` 仍在；行内容不变 |
| R3 | 同上 | `REPLACE INTO nodes(id=5, airport_id=1, fingerprint=F2, ...)`（显式 id，指纹不同） | **失败**（删除阶段守卫 ABORT）；`id=5` 原行、原指纹不变 |
| R4 | 同上 | `INSERT ... ON CONFLICT(airport_id,fingerprint) DO UPDATE SET last_seen=...` | 成功；`id` 仍 5；`identity_id` 不变；关系断言全过 |
| R5 | 同上 | `INSERT ... ON CONFLICT DO UPDATE SET config_version=<不属于该 identity 的版本>` | **失败**（`trg_nodes_rel_upd` ABORT）；`config_version` 回滚为原值 |

**R2/R3 的与 v1.4 的关键差异**：不再依赖"插入阶段查同键"（REPLACE 的删除在插入之前，插入阶段查不到行），而是靠**删除阶段**的 `trg_nodes_delete_guard` 拦；且该守卫由 §4 的连接契约保证"`recursive_triggers` 必为 ON"才可能在 REPLACE 的隐式删除上触发——这正是 §4 存在的理由。

### 3.7 P0-2：`nodes` 档案保护

#### 3.7.1 为什么 `nodes` 需要自己的守卫

`UNIQUE(airport_id, fingerprint)` 让"同机场同指纹"成为冲突键。`INSERT OR REPLACE` 一旦命中，会：

1. 删除原节点行（`id=5`）；
2. 插入新行（新 `id`，AUTOINCREMENT 递增）；
3. `node_state_history`、`target_results`、`detection_tasks`、`node_id_reservations` 里所有 `node_id=5` 的关联**全部指向不存在的节点**（`foreign_keys=OFF` 时更不会被拦）。

结果就是 §0 表格里的"节点 ID 和历史关联丢失"。这不是理论风险：基准代码在 `fetcher.py` 里就有按指纹写节点的路径（P1 会逐条核查写法，见 §3.7.4）。

#### 3.7.2 档案删除守卫

```sql
CREATE TRIGGER trg_nodes_delete_guard BEFORE DELETE ON nodes
WHEN OLD.identity_id IS NOT NULL
   OR EXISTS (SELECT 1 FROM node_state_history   WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM target_results       WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM node_id_reservations WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM detection_tasks      WHERE node_id = OLD.id)
BEGIN SELECT RAISE(ABORT,'node archive delete forbidden (identity/history/results/tasks)'); END;
```

**语义**：迁移后所有节点都已回填 `identity_id`，因此实际效果是"节点行不可删除"。需要下线节点时走 `node_identities.lifecycle = 'missing' → 'retired'`，**不删 `nodes` 行**（与 30 天 missing 一致）。迁移前的未回填行（`identity_id IS NULL` 且无历史）仍可清理，用于迁移脚本自身的收尾。

**创建时机**：`node_state_history` 在步 6、`target_results` 在步 11、`node_id_reservations`/`detection_tasks` 在步 9/12 —— 因此该触发器在**步 12 末**创建（属 17 步内的子步骤，主序号不变）。创建前脚本文本内不得出现任何 `DELETE FROM nodes`。

#### 3.7.3 三层防线（不依赖单一手段）

| 层 | 手段 | 拦什么 | 局限 |
| --- | --- | --- | --- |
| L1 代码门禁 | CI 静态扫描 + 评审清单（§3.7.4），禁止 `REPLACE` 语法 | 从源头不出现 | 只能拦已提交代码 |
| L2 连接契约 | 每连接强制 `recursive_triggers=ON` 并读回验证（§4） | 让 `REPLACE` 的隐式删除能被 `BEFORE DELETE` 看到 | 未开则失效 → 由 §4 拒绝该连接用于写 |
| L3 运行期守卫 | `trg_nodes_delete_guard` + `trg_ident_del` + `trg_cv_del` | 实际 ABORT 删除 | `DROP TRIGGER` / 外部工具可绕过 |
| L4 巡检 | 启动与每日一致性巡检：节点数、历史引用、`legacy_node_identity_map` 覆盖 | 事后发现"行消失但历史还在" | 只能发现，不能阻止 |

**明确回答任务书"不要仅依赖 `recursive_triggers=ON`"**：本设计不把 `recursive_triggers` 当唯一手段，而是把它降级为 L2 的**必要前置**（没有它，L3 对 REPLACE 的隐式删除完全无效）；主防线是 L1（源头不出现）+ L3（真 ABORT）+ L4（可发现）。三者缺一即写明为残余风险（§15 风险表 R1/R2）。

**A 路径做不到的事，如实说**：`recursive_triggers=OFF` 的连接执行 `REPLACE INTO nodes` 时，`BEFORE DELETE` 不触发，档案会被静默替换。A 路径无法在数据库层阻止这种连接——因此 §4 的规则是"这类连接不得用于业务写入"，而非"数据库能防住"。

#### 3.7.4 全项目 REPLACE 写入审查清单（P1 前置动作，本轮不执行）

**扫描模式**（大小写不敏感，覆盖换行与别名）：

| # | 模式 | 说明 |
| --- | --- | --- |
| S1 | `INSERT\s+OR\s+REPLACE` | 显式 REPLACE 冲突算法 |
| S2 | `REPLACE\s+INTO` | 同义写法 |
| S3 | `INSERT\s+OR\s+IGNORE` | 不删行但静默吞冲突，需逐条判断是否掩盖身份漂移 |
| S4 | `OR\s+REPLACE` / `OR\s+IGNORE` | 通用冲突子句（可能出现在 `UPDATE OR REPLACE`） |
| S5 | `ON\s+CONFLICT.*DO\s+UPDATE` | 允许，但需核对 `SET` 列表是否触碰受限列 |
| S6 | `ON\s+CONFLICT.*DO\s+NOTHING` | 按 §3.6.5 边界核对 |
| S7 | 裸词 `REPLACE` | 兜底：捕获拼接 SQL（f-string / `%` / `.format`）里的写法 |
| S8 | `executemany` + 上述任一模式 | 批量写入路径 |

**输出物（审查报告必须逐条给）**：

| 字段 | 内容 |
| --- | --- |
| 位置 | 文件:行号 |
| 语句 | 原始 SQL |
| 目标表 | 解析出的表名 |
| 当前语义 | 冲突时删行 / 更新 / 跳过 |
| 风险 | 是否触碰 `nodes`/identity/版本/证据表 |
| 替代方式 | 两段式 / `DO UPDATE` / 显式 `UPDATE` |
| 语义变化 | **必须写明**：替代后"冲突时做什么"与原写法是否等价 |

**硬规则**：发现 `REPLACE` 时**不得静默改写成 `DO UPDATE`**。二者语义不同——原写法"删旧行、给新 id"，新写法"保留旧行、原位更新"，会改变 `id` 稳定性、`created_at` 归属、历史关联的对象。必须先在审查报告里标出语义差异，再决定：

1. 若业务本来就需要"保留旧行"（`nodes` 一定如此）→ 改 `DO UPDATE`，并在报告中写明"原写法造成 id 漂移，属缺陷修复"；
2. 若业务确实需要"重建行"（例如纯缓存表）→ 保留 `REPLACE`，但该表必须不在 §3.6.2 的禁止清单里，并加白名单注释；
3. 无法判断 → 保持原样，记 `system_events(schema_diff)` 等人工确认。

### 3.8 能力边界（更新版）

> **A 路径提供的是"部分引用完整性"，不等价于 B 路径的复合外键。**

| 场景 | A 路径 | 说明 |
| --- | --- | --- |
| 常规 INSERT / UPDATE / DELETE | 守住 | 六个关系触发器 + 档案守卫 |
| `REPLACE`（`recursive_triggers=ON`） | 守住 | 删除阶段 ABORT |
| `REPLACE`（`recursive_triggers=OFF`） | **不守住** | 触发器不触发；靠 §4 拒绝该连接用于写 |
| `DO UPDATE` | 守住 | 走 `BEFORE UPDATE`，关系被重验 |
| `foreign_keys=OFF` + 删 identity | 守住 | `trg_ident_del` 显式查全部引用表（§3.4） |
| `foreign_keys=ON` + 删 identity | 守住（双保险） | 触发器 + 真外键 |
| `foreign_keys=OFF` + 跨机场 identity 关联 | 守住 | `trg_nodes_rel_ins/upd` 不依赖 PRAGMA |
| `DROP TRIGGER` / `DROP TABLE` / 外部工具 | 不守住 | 有意破坏，只能靠 L4 巡检发现 |
| 与 B 路径等价性 | **不等价** | B 有真 `NOT NULL`、真复合外键、`ON DELETE RESTRICT` |

---

## 4. P0-3：连接级 PRAGMA 强制策略（本轮新增）

### 4.1 问题

`PRAGMA foreign_keys` 是**连接级**开关，SQLite 默认 **OFF**，且**不能**通过 URI 参数在连接串里设置（URI 只支持 `vfs`/`mode`/`cache`/`immutable` 等，不含 `foreign_keys`）。更关键的两条：

1. **事务内执行 `PRAGMA foreign_keys` 是 no-op**（SQLite 明确规定，在事务中切换无效），只能在 `BEGIN` 之前或 `COMMIT` 之后切；
2. 每个新建连接都是独立默认值 —— 连接池、重连、后台线程、CLI 工具各自一份状态。

因此"记录当前值"没有任何意义，必须写成**运行期强制规则**并**读回验证**。

### 4.2 强制规则

```python
def create_connection(path, *, readonly=False):
    conn = sqlite3.connect(path, timeout=30, isolation_level=None)
    cur = conn.cursor()
    cur.execute("PRAGMA foreign_keys = ON")
    cur.execute("PRAGMA recursive_triggers = ON")     # REPLACE 的删除守卫依赖此项
    cur.execute("PRAGMA busy_timeout = 5000")
    cur.execute("PRAGMA journal_mode = WAL")          # 只读连接跳过
    # ——读回验证，不做"信任式开启"——
    if cur.execute("PRAGMA foreign_keys").fetchone()[0] != 1:
        conn.close(); raise RuntimeError("foreign_keys not enabled on this connection")
    if cur.execute("PRAGMA recursive_triggers").fetchone()[0] != 1:
        conn.close(); raise RuntimeError("recursive_triggers not enabled")
    return conn
```

**要点**：

| 项 | 规则 |
| --- | --- |
| 唯一入口 | 全项目禁止直接 `sqlite3.connect(...)`，只能走 `create_connection()`；CI 扫描 `sqlite3.connect(` 出现位置 |
| 读回验证 | 必须 `PRAGMA x` 读回 == 1，不等则**关闭连接并抛错**（不是 `assert`、不是日志） |
| 失败后果 | 该连接**不得**用于业务写入；写入路径拿不到连接即整个请求失败（快速失败优于静默降级） |
| 只读连接 | 同样开启（`foreign_key_check` 的判定依赖开关状态，OFF 时它**不做任何检查**并返回空——这会制造"检查通过"的假象） |

**`foreign_key_check` 的陷阱必须写进代码注释**：`PRAGMA foreign_key_check` 在 `foreign_keys=OFF` 的连接上仍会执行检查（它独立于开关）。但反过来，某些工具链会因开关 OFF 而跳过。设计上统一：**任何 `foreign_key_check` 都必须在已读回验证 ON 的同一连接上执行**。

### 4.3 覆盖面（哪些连接必须走这条路径）

| 连接来源 | 是否走 `create_connection` | 验证方式 |
| --- | --- | --- |
| 主应用（FastAPI 请求处理） | 是 | 启动自检 + 单元测试 |
| 连接池新建 / 每次 checkout | 是（pool 的 creator 即 `create_connection`） | checkout 时抽查 `PRAGMA foreign_keys` |
| 断线重连 | 是（重连同样走 creator） | 重连测试 FK5 |
| 调度器 / 检测执行线程 / 后台任务 | 是（禁止线程内自行 connect） | FK6 |
| 测速任务 / 发布构建 | 是 | 同上 |
| CLI 维护工具 / 备份导出 | 是 | 工具单测 |
| 迁移脚本 | **特殊**：`before-begin` 可临时 `OFF`，`after-commit` 必须恢复 `ON` 并读回 | 迁移断言（§4.5） |
| 只读分析（SQLite CLI 手工） | 不受控 | 不写入，风险仅限误操作 |

### 4.4 `foreign_keys=OFF` 时哪些保护仍有效

| 保护 | OFF 时 | 原因 |
| --- | --- | --- |
| `trg_nodes_rel_ins` / `trg_nodes_rel_upd`（非空、身份存在、机场一致、版本存在） | **仍有效** | 触发器不依赖 `foreign_keys` |
| `trg_cv_del` / `trg_ident_del`（父删除守卫） | **仍有效** | 同上（这是 §3.4 必须显式查引用表的原因） |
| `trg_ident_airport_upd` / `trg_cv_pk_upd` | **仍有效** | 同上 |
| `trg_nodes_delete_guard` | **仍有效**（且需 `recursive_triggers=ON` 才能覆盖 REPLACE 的隐式删除） | 同上 |
| 真外键：`nodes → airports`、`identity → airports`、`versions → identity`、`detection_tasks → nodes(id, identity_id)`、`target_results → detection_tasks` | **全部失效** | 无父行检查 |
| 复合外键父键唯一性检查 | **失效** | 同上 |
| `related_identity_id` 的自引用完整性 | **失效** | 已被 `trg_ident_del` 的第六个 `EXISTS` 覆盖 |

**结论**：OFF 时"身份关系"仍被守住（触发器），"引用存在性"部分失守（无父行的子表插入会被允许）。因此 OFF 只能作为**迁移窗口内的临时状态**，且窗口内不得有业务写入。

### 4.5 迁移期的 OFF 范围与恢复

| 项 | 规定 |
| --- | --- |
| 允许关闭的时机 | 仅 `before-begin`（单表重建前）与 `after-commit` 恢复后 |
| 关闭范围 | 仅迁移专用连接；**不得**影响应用连接（迁移期间应用应处于停写或只读模式） |
| 关闭时长 | 仅覆盖"重建单表"的语句块；重建表已由 C-2 证明**无入向引用**，故关闭期间不存在被破坏的引用 |
| 事务内切换 | **禁止**（no-op，且会造成"以为关了/以为开了"的错觉） |
| 恢复后必做 | `PRAGMA foreign_keys = ON` → 读回 == 1 → `PRAGMA foreign_key_check` 返回 0 行 → 才写 `schema_migrations(success)` |
| 失败处理 | 读回不为 1 或 `foreign_key_check` 有行 → 不写 success、事件记 `migration_verify_failed`、保留备份、等待人工 |
| 异常退出 | `finally` 中无条件执行恢复 + 读回验证；验证失败则进程以非零码退出，禁止继续 |

```python
def migrate(path, target_table):
    conn = create_connection(path)                     # 已 ON
    fk_before = conn.execute("PRAGMA foreign_keys").fetchone()[0]
    try:
        conn.execute("PRAGMA foreign_keys = OFF")      # before-begin，事务外
        conn.execute("BEGIN IMMEDIATE")
        ...                                            # 重建、搬数据、建索引触发器
        bad = conn.execute("PRAGMA foreign_key_check").fetchall()
        assert not bad, f"fk violations: {bad[:5]}"
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK") if conn.in_transaction else None
        raise
    finally:
        conn.execute("PRAGMA foreign_keys = ON")       # after-commit
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
        assert not conn.execute("PRAGMA foreign_key_check").fetchall()
```

### 4.6 测试（FK 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| FK1 | `foreign_keys=ON`；identity 10 无 nodes 引用但有一条 `node_config_versions(10,1)` | `DELETE FROM node_identities WHERE identity_id=10` | **ABORT**（`trg_ident_del` 命中版本行） |
| FK2 | 同 FK1，但连接 `foreign_keys=OFF` | 同上 | **仍 ABORT**（证明守卫不依赖 PRAGMA） |
| FK3 | OFF；identity 10 被 nodes 引用 | 同上 | **ABORT**（`nodes` 分支） |
| FK4 | 连接池预建 8 条连接 | 逐条读 `PRAGMA foreign_keys`、`recursive_triggers` | 全为 1 |
| FK5 | 断开后重连 | 读回两个 PRAGMA | 全为 1（重连走同一 creator） |
| FK6 | 后台/调度线程取连接 | 读回 | 全为 1 |
| FK7 | 完成一次 C-2 重建迁移 | `PRAGMA foreign_key_check` | 0 行；`schema_migrations` 有 success |
| FK8 | 构造一个未走 creator 的连接（模拟违规） | 尝试业务写入 | 被系统拒绝（写入路径校验 `PRAGMA foreign_keys==1`，否则抛错） |
| FK9 | OFF，identity 无 nodes 无版本，但有 `identity_presence_log` 行 | 删 identity | **ABORT**（子表分支） |

---

## 5. P0 迁移顺序（v1.4 的 17 步，主序号不变；仅补子步骤）

| 步 | 对象/动作 | 阶段 | 依赖 | 回滚 |
| --- | --- | --- | --- | --- |
| 0 | 备份、`quick_check`、记录并强制连接 PRAGMA（§4） | before-begin | — | 无 |
| 1 | 预检 `sqlite_master`（C-1/C-2 分支）、旧表行数与时间范围 | before-begin | — | 无 |
| 2 | `node_identities` + 索引 | in-tx | airports | 整事务 |
| 3 | 逐行建 identity（`nodes.id` 升序）+ `legacy_node_identity_map` | in-tx | 步 2 | 整事务 |
| 4 | `node_config_versions` + 每 identity 写 `version=1` | in-tx | 步 2/3 | 整事务 |
| 5 | `nodes` 加两列 + 回填 + `uq_nodes_id_identity` + `idx_nodes_identity` + **六个关系触发器** | in-tx | 步 3/4 | 整事务 |
| 5b | 验证六个触发器存在 + §3.5 前四条断言 | in-tx | 步 5 | 整事务 |
| 6 | `node_target_state`、`node_state_history` | in-tx | 步 5 | 整事务 |
| 7 | `identity_stable_ids` / `identity_config_pending` / `identity_presence_log` | in-tx | 步 2 | 整事务 |
| 7b | 创建 `trg_ident_del`（完整引用清单，§3.4）——此时五张引用表均已存在 | in-tx | 步 7 | 整事务 |
| 8 | `detection_rules` + `uq_rules_active` | in-tx | — | 整事务 |
| 9 | `detection_tasks` | in-tx | 步 5、8 | 整事务 |
| 10 | `detection_task_runs` | in-tx | 步 9 | 整事务 |
| 11 | `target_results` + 三索引 | in-tx | 步 5、9 | 整事务 |
| 12 | `node_id_reservations` + `restore_authorizations` + 回池三触发器 | in-tx | 步 5 | 整事务 |
| 12b | 创建 `trg_nodes_delete_guard`（引用的四张表此时已全部存在） | in-tx | 步 6/9/11/12 | 整事务 |
| 13 | `airport_identity_daily` / `airport_union_snapshot` / `legacy_cutover` | in-tx | airports、旧表 | 整事务 |
| 14 | 状态回填（S-A～S-E） | in-tx | 步 6、13 | 整事务 |
| 15 | `foreign_key_check`（同一已验证 ON 的连接）+ 行数/映射/关系断言 + 触发器计数 == 7 | in-tx | 全部 | 中断即 ROLLBACK |
| 16 | 恢复 PRAGMA（§4.5），复查 `foreign_key_check`，写 `schema_migrations(success)` | after-commit | — | 不写 success |

**创建顺序规则（本轮固化为硬约束）**：任何触发器的 `WHEN`/`BEGIN` 里出现的表，必须在**该触发器创建之前**已存在。因此 `trg_ident_del` 在步 7b、`trg_nodes_delete_guard` 在步 12b，绝不提前。违反会导致 `CREATE TRIGGER` 成功但触发时报 `no such table`，或迁移中断。

---

## 6. C-2 入向引用判定（v1.4 不变）

- 权威：遍历 `sqlite_master` 所有表 → `PRAGMA foreign_key_list` → 比较 `table`（小写、去 schema 前缀）。覆盖普通/引号/方括号/反引号/大小写/`main.` 限定/转义/表级复合 FK/`ON DELETE`。
- 双保险：保守文本扫描（去注释与字符串字面量后提取 `REFERENCES` 目标），结果 `True` 或 `None` 均判**停止**，只加严不放行。
- **任何入向引用 → 停止**：不 `DROP`、不 `RENAME`、不建 `__new`、写 `system_events(schema_diff)`、不写 success。
- 出向外键**不构成**放行理由（v1.4 §6.1 已修正）。
- M27–M32 不变。

---

## 7. 系统故障与 `fresh()` 隔离（v1.4 不变）

```sql
valid INTEGER NOT NULL CHECK (valid IN (0,1)),
CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))
```

| 记录 | `valid` | 健康证据 | 入链 | 推进恢复 |
| --- | --- | --- | --- | --- |
| 有效 pass | 1 | 是 | 否 | 是 |
| 有效 fail | 1 | 是 | 是 | 重置 |
| engine / scheduler / system / target_incident | 0 | 否 | 否 | 否 |
| TCP-only | 0 | 否 | 否 | 否 |

`latest_valid()` 只取 `valid=1`；系统故障永不覆盖 TTL 内新鲜 pass；不重置 `observing`。SF1–SF7 不变。

**与 §3.6.2 的衔接**：`target_results` 禁 `REPLACE`、禁 `DO NOTHING` —— 证据行只能 `INSERT`，重复即错误。这条与"系统故障不得覆盖有效结论"是同一条原则的两面。

---

## 8. C18 / C19（边界说明，仍待确认）

**C18**：TCP-only 允许写 `target_results`（`mode='tcp_only'`、`valid=0`）用于诊断与审计；**禁止**参与健康达标、连续失败链、恢复确认、订阅发布资格。未确认。

**C19**：新流程启用以 `cutover_at` 单一开关（存 DB）为准；先连续 3 次成功产出才允许切；旧表停写与新表启用同事务；切换失败回滚开关，新数据保留标 `pre_cutover`，不删旧表。未确认。

---

## 9. DDL 摘要（本轮变动）

```sql
-- 新增（本轮）
CREATE TRIGGER trg_nodes_delete_guard BEFORE DELETE ON nodes
WHEN OLD.identity_id IS NOT NULL
   OR EXISTS (SELECT 1 FROM node_state_history   WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM target_results       WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM node_id_reservations WHERE node_id = OLD.id)
   OR EXISTS (SELECT 1 FROM detection_tasks      WHERE node_id = OLD.id)
BEGIN SELECT RAISE(ABORT,'node archive delete forbidden'); END;

-- 扩充（本轮，判定结构不变）
CREATE TRIGGER trg_ident_del BEFORE DELETE ON node_identities
WHEN EXISTS (SELECT 1 FROM nodes WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM node_config_versions WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_stable_ids  WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_config_pending WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM identity_presence_log WHERE identity_id = OLD.identity_id)
   OR EXISTS (SELECT 1 FROM node_identities WHERE related_identity_id = OLD.identity_id)
BEGIN SELECT RAISE(ABORT,'identity still referenced'); END;
```

触发器总数：**6 → 7**。

---

## 10. v1.3 → v1.4 → v1.5 修订对照

| # | v1.4 | v1.5 | 章节 |
| --- | --- | --- | --- |
| P0-1 | "禁父表 REPLACE/UPSERT"（一句话自相矛盾） | 四写法机制表；REPLACE 挂删除守卫、`DO UPDATE` 挂 UPDATE 触发器；允许/禁止清单；正反 SQL 示例；`DO NOTHING` 边界；R1–R5 | §3.6 |
| P0-2 | 只禁父表 REPLACE | `trg_nodes_delete_guard`（四张引用表 + `identity_id` 非空）；三层防线（门禁/连接契约/守卫/巡检）；全项目 8 类扫描模式 + 审查输出字段 + "不得静默改语义"三条处置 | §3.7 |
| P0-3 | `trg_ident_del` 只查 `nodes` | 显式查版本表 + 三张身份子表 + 自引用；连接级强制 `foreign_keys`/`recursive_triggers` 读回验证、覆盖面 8 类、OFF 时有效性表、迁移期 OFF 范围与恢复代码；FK1–FK9 | §3.4、§4 |

---

## 11. 关闭证明

### 11.1 P0-1（REPLACE 与 UPSERT）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 四种写法明确区分 | §3.6.1 | — | 已关闭 |
| 禁 REPLACE | §3.6.2/§3.6.4 | R2/R3 | 已关闭 |
| 允许 `DO UPDATE` 并说明走 UPDATE 分支 | §3.6.1/§3.6.3 | R4/R5 | 已关闭 |
| `DO NOTHING` 边界 | §3.6.5 | — | 已关闭 |
| 不再混同 UPSERT 与 REPLACE | §3.6（整节重写） | — | 已关闭 |
| 正反 SQL 示例 | §3.6.3/§3.6.4 | — | 已关闭 |
| 冲突时旧父记录不被删除 | §3.6.2 + §3.4 | R2/R3 | 已关闭 |

### 11.2 P0-2（nodes 档案）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 禁对 `nodes` 用任何 REPLACE | §3.6.2/§3.7.2 | R2/R3 | 已关闭 |
| 禁对身份/版本及其他档案表用 REPLACE | §3.6.2 | R2 变体 | 已关闭 |
| 推荐写入方式（两段式/`DO UPDATE`/显式 UPDATE） | §3.6.3 | R1/R4 | 已关闭 |
| 全项目审查 + 8 类扫描模式 | §3.7.4 | — | 已关闭 |
| 现网写法必须给替代与语义变化说明 | §3.7.4 硬规则 | — | 已关闭 |
| 不依赖 `recursive_triggers` 单一手段 | §3.7.3（L1–L4） | — | 已关闭 |
| REPLACE 测试（id/行/身份/历史不变） | §3.6.6 R2/R3 | R2/R3 | 已关闭 |

### 11.3 P0-3（foreign_keys 边界）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 应用连接强制 ON | §4.2 | FK4 | 已关闭 |
| 初始化方式 + 读回验证 | §4.2 代码 + "失败后果" | FK8 | 已关闭 |
| 池/重连/后台/维护全覆盖 | §4.3 | FK4–FK6 | 已关闭 |
| 哪些真外键依赖该设置 | §4.4 | — | 已关闭 |
| OFF 时有效/失效清单 | §4.4 | FK2/FK3/FK9 | 已关闭 |
| identity 删除显式查版本表等 | §3.4 | FK1/FK2/FK9 | 已关闭 |
| 迁移期 OFF 范围与恢复验证 | §4.5 | FK7 | 已关闭 |
| 不只记录当前值 | §4.1/§4.2（读回即失败） | FK4 | 已关闭 |

---

## 12. 测试矩阵

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
| A 路径关系 A | 10 | A1–A10（v1.4 不变） |
| **REPLACE/UPSERT R** | **5** | **R1–R5（新增）** |
| **PRAGMA 契约 FK** | **9** | **FK1–FK9（新增，编号与令牌组 FK1–FK5 区分见注）** |
| 迁移 M | 32 | M1–M26 + M27–M32 |

> 注：令牌组用 `F1–F22` 与 `FKA1–FKA5`（本轮改名以消除歧义），PRAGMA 组用 `FK1–FK9`。

**新增用例明细已写在 §3.6.6（R1–R5）与 §4.6（FK1–FK9）**，每条含初始状态、步骤、预期，并明确"失败不变项"。

**必须纳入回归的跨组用例**：

| 用例 | 断言 |
| --- | --- |
| R2 + A10 | REPLACE 被拒后，§3.5 六条断言仍全过 |
| FK2 + A8 | OFF 时删被引用 identity 仍 ABORT，无孤儿 |
| FK7 + M32 | 迁移恢复后 `foreign_key_check` 空、无 `__new`、有 success |
| R4 + FE | `DO UPDATE` 推进检测后，`fail_chain()` 只读 `valid=1` |

---

## 13. 依赖关系图（最终）

```
airports ──> node_identities ──> node_config_versions
                 │                      │
                 ├──> identity_stable_ids / identity_config_pending / identity_presence_log
                 └──> nodes.identity_id + nodes.config_version（回填）
                          │
                          ├── uq_nodes_id_identity（复合外键父键）
                          ├── idx_nodes_identity（删除侧 EXISTS）
                          ├── 6 个关系触发器
                          ├── trg_nodes_delete_guard（步 12b，引用 4 张表）
                          ├──> node_target_state / node_state_history
                          ├──> node_id_reservations ──> restore_authorizations
                          ├──> detection_tasks ──> detection_task_runs ──> target_results
                          └──> （状态回填 §14/步 14）
detection_rules ──> detection_tasks
airport_identity_daily / airport_union_snapshot（依赖 airports）
legacy_cutover（只读旧 results / latency_results）
```

---

## 14. C11–C20 确认状态

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（获批才走 B） | **未确认（本轮未假设已批准）** |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口 | 6h 优先 | 未确认 |
| C15 | `rep` 门槛 | 0.90 / 0.60 | 未确认 |
| C16 | retired 回归复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| C18 | TCP-only 允许存、不参与判定 | 按 §8 | 未确认 |
| C19 | 旧结果表停写切换 | 先验证、单开关、可回滚 | 未确认 |
| C20 | A 路径"物理可空 + 触发器"是否接受 | 建议接受为过渡 | 未确认 |

---

## 15. 风险（更新）

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | `recursive_triggers=OFF` 的连接执行 REPLACE → 档案静默替换 | §4 连接契约（读回验证、失败即拒）；L1 门禁；L4 巡检 | FK4–FK6、R2 |
| 2 | 代码里已存在 REPLACE 写法（基准 `fetcher.py` 需核查） | §3.7.4 审查清单，逐条给替代与语义变化 | P1 审查报告 |
| 3 | 有人用 `DROP TRIGGER` 绕过 | 触发器计数断言（步 15 == 7）；启动巡检 | 迁移断言 + L4 |
| 4 | `trg_ident_del` 引用清单漏掉 P1+ 新表 → OFF 时留孤儿 | §3.4 硬规则 + §3.5"引用清单自洽"断言 | FK9、A10 |
| 5 | 迁移期 OFF 后忘记恢复 | `finally` 无条件恢复 + 读回 + `foreign_key_check`，失败即非零退出 | FK7 |
| 6 | `DO NOTHING` 被误用于证据表 | §3.6.2 清单 + 评审 | 代码评审 |
| 7 | 触发器使写入变慢 | `idx_nodes_identity` 点查 + 索引 | 压测 |
| 8 | C-2 误停导致迁移中断 | 误停只影响单表，事件给快照供人工判断 | M30/M32 |

---

**v1.5 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅修订三项 P0。**C11–C20 全部未确认，C12 未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
