# NodePoolME 新架构总体设计方案 v1.4

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.3
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：仅 P0-1（A 路径身份引用完整性）与 P0-2（C-2 入向外键识别）。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 修订索引（v1.3 → v1.4）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | A 路径补齐：机场归属、插入/更新/删除全路径、孤儿防护、能力边界 | §3 | 补齐 |
| P0-2 | C-2 入向引用识别改为"任何入向引用即停止"，弃用单一正则 | §6 | 修正 |

未修订：Q1–Q12、v1.3 的 17 步迁移顺序、P0-3 的 `valid=0` 隔离、30 天 missing、指纹算法、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式兼容、评分算法、前端布局。**C11–C20 全部未确认。**

---

## 0. 本轮修的是什么

v1.3 的 A 路径只做了"非空 + 版本存在"，漏了三件事；C-2 的入向引用判定则用了一个不可能完备的正则。

| # | v1.3 的写法 | 缺陷 |
| --- | --- | --- |
| P0-1 | 四个触发器只查 `identity_id` 非空、`config_version` 存在 | 不校验**机场归属**；删除父记录留孤儿；`UPDATE OF airport_id` 不触发重新验证 |
| P0-2 | `REFERENCES\s+"?t"?` + "本表是子表则允许重建" | 正则漏引号/大小写/schema 限定/表级复合 FK；且"有出向外键"与"是否被引用"是两件无关的事 |

v1.4 的原则：**A 路径要把"插入、更新、删除"三条写入路径全部堵住，并如实声明它是部分完整性；C-2 只要存在任何入向引用就停止——不猜、不修、不赌。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；指纹算法不改；身份与生命周期原则不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康最多留上一版 24h、硬上限 72h；30 个发布版本；Q11 两次有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不重做。

---

## 2. 基准 `nodes` 与 A/B 路径

| 事实 | 说明 |
| --- | --- |
| `nodes` 有 `id` PK、`UNIQUE(airport_id, fingerprint)` | 基准 |
| 无 `identity_id`、无 `config_version` | 基准 |
| 有 `status`、`fail_count` | 基准代码 |

| 路径 | 是否重建 | 约束强度 | 前置 |
| --- | --- | --- | --- |
| **A（默认）** | 否 | **部分完整性**：四类触发器覆盖 INSERT/UPDATE/DELETE，但不等价于复合外键 | 无需 C12 |
| **B（可选）** | 是（12 步） | 真 `NOT NULL` + 真复合外键 + 父表 `ON DELETE RESTRICT` | **C12 需批准** |

**C12 状态：未确认。** 本文默认 A；B 仅在获批后启用，**不得**在实施时自行选择（P0-1 前置约束）。

---

## 3. P0-1：A 路径的完整引用完整性

### 3.1 关系模型（要守住的三条不变式）

```
I1  nodes.identity_id 非空 ∧ nodes.config_version 非空
I2  identity 存在 ∧ identity.airport_id = nodes.airport_id      ← v1.3 漏掉的一条
I3  (identity_id, config_version) 存在于 node_config_versions
I4  父记录被引用时不可删除（identity、config_version）
```

`I2` 是"身份不得跨机场"的唯一实现点；`I4` 是"不留孤儿"的唯一实现点。二者缺一，A 路径就不成立。

### 3.2 父表与唯一索引（沿用 v1.3，补充删除侧支撑）

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
  protocol       TEXT,
  server         TEXT,
  port           INTEGER,
  display_name   TEXT,
  change_reason  TEXT NOT NULL DEFAULT 'initial',
  opened_at      TEXT NOT NULL,
  closed_at      TEXT,
  PRIMARY KEY (identity_id, config_version),
  FOREIGN KEY (identity_id) REFERENCES node_identities(identity_id)
);

ALTER TABLE nodes ADD COLUMN identity_id INTEGER;
ALTER TABLE nodes ADD COLUMN config_version INTEGER;
CREATE UNIQUE INDEX uq_nodes_id_identity ON nodes(id, identity_id);   -- 复合外键父键
CREATE INDEX idx_nodes_identity ON nodes(identity_id, config_version); -- 删除侧 EXISTS 用
```

### 3.3 写入侧：插入与更新

```sql
-- ① 插入：四条件一次判完（任一不满足即 ABORT）
CREATE TRIGGER trg_nodes_rel_ins BEFORE INSERT ON nodes
WHEN NEW.identity_id IS NULL
  OR NEW.config_version IS NULL
  OR NOT EXISTS (SELECT 1 FROM node_identities i
                  WHERE i.identity_id = NEW.identity_id
                    AND i.airport_id  = NEW.airport_id)          -- I2
  OR NOT EXISTS (SELECT 1 FROM node_config_versions v
                  WHERE v.identity_id    = NEW.identity_id
                    AND v.config_version = NEW.config_version)   -- I3
BEGIN SELECT RAISE(ABORT,'nodes identity relation invalid (null/cross-airport/version)'); END;

-- ② 更新：三个字段任一出现在 SET 中就整体重验（不是只验 config_version）
CREATE TRIGGER trg_nodes_rel_upd BEFORE UPDATE OF airport_id, identity_id, config_version ON nodes
WHEN NEW.identity_id IS NULL
  OR NEW.config_version IS NULL
  OR NOT EXISTS (SELECT 1 FROM node_identities i
                  WHERE i.identity_id = NEW.identity_id
                    AND i.airport_id  = NEW.airport_id)
  OR NOT EXISTS (SELECT 1 FROM node_config_versions v
                  WHERE v.identity_id    = NEW.identity_id
                    AND v.config_version = NEW.config_version)
BEGIN SELECT RAISE(ABORT,'nodes identity relation invalid after update'); END;
```

**为什么用 `UPDATE OF airport_id, identity_id, config_version`**：SQLite 的 `UPDATE OF` 只要这三列出现在 `SET` 里就触发，**即使值未变**。这正是"关系变更必须整体重验"的语义；若只写 `WHEN NEW.x <> OLD.x`，`UPDATE nodes SET airport_id=airport_id` 会绕过检查。

### 3.4 删除侧：父记录保护

```sql
-- ③ 禁止删除仍被 nodes 引用的 identity
CREATE TRIGGER trg_ident_del BEFORE DELETE ON node_identities
WHEN EXISTS (SELECT 1 FROM nodes n WHERE n.identity_id = OLD.identity_id)
BEGIN SELECT RAISE(ABORT,'identity still referenced by nodes'); END;

-- ④ 禁止删除仍被 nodes 引用的 config_version
CREATE TRIGGER trg_cv_del BEFORE DELETE ON node_config_versions
WHEN EXISTS (SELECT 1 FROM nodes n
              WHERE n.identity_id = OLD.identity_id
                AND n.config_version = OLD.config_version)
BEGIN SELECT RAISE(ABORT,'config_version still referenced by nodes'); END;

-- ⑤ 禁止把 identity 移到另一个机场（否则既有 nodes 的 I2 立刻失效）
CREATE TRIGGER trg_ident_airport_upd BEFORE UPDATE OF airport_id ON node_identities
WHEN NEW.airport_id <> OLD.airport_id
 AND EXISTS (SELECT 1 FROM nodes n
              WHERE n.identity_id = OLD.identity_id
                AND n.airport_id <> NEW.airport_id)
BEGIN SELECT RAISE(ABORT,'identity airport change breaks nodes relation'); END;

-- ⑥ 禁止改 identity 的归属后留下不匹配的版本行（PK 变更）
CREATE TRIGGER trg_cv_pk_upd BEFORE UPDATE OF identity_id, config_version ON node_config_versions
WHEN EXISTS (SELECT 1 FROM nodes n
              WHERE n.identity_id = OLD.identity_id
                AND n.config_version = OLD.config_version)
BEGIN SELECT RAISE(ABORT,'config_version key change breaks nodes relation'); END;
```

**为何不选"级联"**：`ON DELETE CASCADE` 会**删掉节点行**——节点是"这台机器的档案"，删除它等于丢失历史与发布记录。因此删除侧一律 `ABORT`，要求调用方先解绑（把 nodes 移到新 identity 或修正版本）再删。

### 3.5 完整性与一致性的可验证断言（迁移后与运行期）

| 断言 | SQL 形态 |
| --- | --- |
| 无 NULL | `SELECT COUNT(*) FROM nodes WHERE identity_id IS NULL OR config_version IS NULL` == 0 |
| 无跨机场 | `SELECT COUNT(*) FROM nodes n JOIN node_identities i USING(identity_id) WHERE i.airport_id <> n.airport_id` == 0 |
| 无孤儿版本 | `SELECT COUNT(*) FROM nodes n LEFT JOIN node_config_versions v ON v.identity_id=n.identity_id AND v.config_version=n.config_version WHERE v.identity_id IS NULL` == 0 |
| 一节点一身份 | `nodes.identity_id` 唯一索引保证"一行一值"；`legacy_node_identity_map.identity_id` UNIQUE 保证"一身份一节点" |
| 触发器齐备 | `sqlite_master` 中六个触发器名全部存在 |

### 3.6 能力边界（P0-1.5，必须如实声明）

> **A 路径提供的是"部分引用完整性"，不等价于 B 路径的复合外键。**

| 场景 | A 路径是否守住 | 说明 |
| --- | --- | --- |
| 常规 `INSERT` / `UPDATE` / `DELETE`（含 `UPDATE OF` 三列） | 是 | §3.3/§3.4 六个触发器 |
| `INSERT OR REPLACE` 到**父表**（`node_identities` / `node_config_versions`） | **可能绕过** | SQLite 在 `REPLACE` 因冲突删除旧行时，`BEFORE DELETE` 触发器**仅在 `PRAGMA recursive_triggers=ON` 时**才触发 |
| 直接 `DROP TABLE` 父表 | 否 | 触发器随表消失；需迁移脚本禁止 |
| 维护工具 / 外部进程批量改写 | 否（仅靠触发器） | 工具可先 `DROP TRIGGER` 再改；属于"有意破坏"，只能靠审计发现 |
| `PRAGMA foreign_keys=OFF` | 与 A 无关 | 触发器不受该 PRAGMA 影响；但**子表**的真外键会失效（见 §6 边界） |
| 同事务内先删父再插子 | 是（先删即 ABORT） | 顺序无关，删除时已检查 |

**因此必须做的两件配套**：

1. **每个连接设 `PRAGMA recursive_triggers=ON`**（默认 OFF），否则 `REPLACE` 路径的删除触发器不生效；
2. **禁止对父表使用 `INSERT OR REPLACE` / `UPSERT`**，写入统一走 `INSERT ... ON CONFLICT DO UPDATE`（`UPSERT` 的 UPDATE 分支会触发 `BEFORE UPDATE`，不会静默删行）。二者写入 `system_events(code_violation)` 时可观测。

### 3.7 A 路径是否可靠？——结论与保留

| 检查项 | 结论 |
| --- | --- |
| 能否覆盖插入/更新/删除三条常规路径 | 能（六个触发器 + 索引） |
| 能否覆盖机场归属 | 能（I2 进入 INSERT 与 UPDATE 的 `WHEN`） |
| 能否防止孤儿 | 能（父删除 ABORT） |
| 能否覆盖 `REPLACE`/`DROP`/外部工具 | **不能完全覆盖**（见 §3.6） |
| 是否等价于复合外键 | **否** |

**保留结论**：A 路径在当前约束下**可以接受作为过渡实现**（覆盖全部正常写入路径 + 两个配套开关），但**不能宣称与 B 等价**；B 路径（重建 `nodes` 拿真 `NOT NULL` + 复合外键 + `ON DELETE RESTRICT`）仍是**待 C12 批准的加固方案**，本文不擅自启用。

### 3.8 测试 A1–A10

| # | 初始 | 步骤 | 预期库 | 预期业务 | 失败时不变项 |
| --- | --- | --- | --- | --- | --- |
| A1 | 机场 1 有 identity 10（`airport_id=1`）、版本 (10,1)；机场 1 有节点行待插 | `INSERT nodes(airport_id=1, identity_id=10, config_version=1)` | 插入成功；`nodes` +1 行 | 正常关联 | 父表不变 |
| A2 | identity 20 属于机场 2；机场 1 有节点行 | `INSERT nodes(airport_id=1, identity_id=20, config_version=1)` | `ABORT: nodes identity relation invalid` | 拒绝跨机场 | `nodes` 行数不变 |
| A3 | `identity_id=99` 不存在 | 同上插入 | `ABORT` | 拒绝无身份节点 | 同上 |
| A4 | identity 10 只有版本 1；插 `config_version=2` | 同上插入 | `ABORT` | 拒绝无版本关联 | 同上 |
| A5 | 节点 N（机场 1、identity 10） | `UPDATE nodes SET airport_id=2 WHERE id=N` | `ABORT`（I2 不成立） | 机场归属不可单方面改 | `airport_id` 仍 1；`nodes` 其他列不变 |
| A6 | 节点 N（identity 10、cv=1）；identity 11 无版本 1 | `UPDATE nodes SET identity_id=11` | `ABORT`（I3 不成立） | 换身份必须同时有对应版本 | `identity_id` 仍 10 |
| A7 | 节点 N 引用 (10,1) | `DELETE FROM node_config_versions WHERE identity_id=10 AND config_version=1` | `ABORT: config_version still referenced` | 拒绝孤儿 | 版本行仍存在 |
| A8 | 节点 N 引用 identity 10 | `DELETE FROM node_identities WHERE identity_id=10` | `ABORT: identity still referenced` | 拒绝孤儿 | identity 行仍存在 |
| A9 | 节点 N（10,1）；先插版本 (10,2) | `UPDATE nodes SET config_version=2 WHERE id=N` | 成功；断言 §3.5 四条全过 | 正常升级 | 旧版本行保留（不删） |
| A10 | 迁移完成 | 跑 §3.5 四条断言 | 全为 0 / 触发器 6 个存在 | 无孤儿 | — |

**补充可观测性**：A2/A5/A7/A8 触发 ABORT 时，应用层捕获并写 `system_events(code_violation, detail=...)`，便于发现"有代码在绕过关系"。

---

## 4. P0 迁移顺序（v1.3 定稿，不变；仅补触发器数量）

| 步 | 对象/动作 | 阶段 | 依赖 | 回滚 |
| --- | --- | --- | --- | --- |
| 0 | 备份、`quick_check`、记录 `foreign_keys`、`busy_timeout`、`recursive_triggers` | before-begin | — | 无 |
| 1 | 预检 `sqlite_master`（C-1/C-2 分支）、旧表行数/时间范围 | before-begin | — | 无 |
| 2 | `node_identities` + 索引 | in-tx | airports | 整事务 |
| 3 | 逐行建 identity（按 `nodes.id` 升序）+ `legacy_node_identity_map` | in-tx | 步 2 | 整事务 |
| 4 | `node_config_versions` + 每条 identity 写 `version=1` | in-tx | 步 2/3 | 整事务 |
| 5 | `nodes` 加两列 + 回填 + `uq_nodes_id_identity` + `idx_nodes_identity` + **6 个触发器** | in-tx | 步 3/4 | 整事务 |
| 6 | `node_target_state`、`node_state_history` | in-tx | 步 5 | 整事务 |
| 7 | `identity_stable_ids` / `identity_config_pending` / `identity_presence_log` | in-tx | 步 2 | 整事务 |
| 8 | `detection_rules` + `uq_rules_active` | in-tx | — | 整事务 |
| 9 | `detection_tasks` | in-tx | 步 5、8 | 整事务 |
| 10 | `detection_task_runs` | in-tx | 步 9 | 整事务 |
| 11 | `target_results` + 三索引 | in-tx | 步 5、9 | 整事务 |
| 12 | `node_id_reservations` + `restore_authorizations` + 回池三触发器 | in-tx | 步 5 | 整事务 |
| 13 | `airport_identity_daily` / `airport_union_snapshot` / `legacy_cutover` | in-tx | airports、旧表 | 整事务 |
| 14 | 状态回填（§7.4 S-A～S-E） | in-tx | 步 6、13 | 整事务 |
| 15 | `foreign_key_check`（只读）+ 行数/映射/关系断言（§3.5） | in-tx | 全部 | 中断即 ROLLBACK |
| 16 | 恢复 `foreign_keys` / `recursive_triggers`，复查 `foreign_key_check`，写 `schema_migrations(success)` | after-commit | — | 不写 success |

**断言补充**：步 5 后必须验证 6 个触发器全部存在（`trg_nodes_rel_ins`、`trg_nodes_rel_upd`、`trg_ident_del`、`trg_cv_del`、`trg_ident_airport_upd`、`trg_cv_pk_upd`）；步 15 必须跑 §3.5 四条数据断言。

---

## 5. 系统故障与 `fresh()` 隔离（v1.3 定稿，不变）

```sql
valid INTEGER NOT NULL CHECK (valid IN (0,1)),
CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))
```

| 记录 | `valid` | 健康证据 | 入链 | 推进恢复 |
| --- | --- | --- | --- | --- |
| 有效 pass（`mihomo`，`failure_source IS NULL`） | 1 | 是 | 否（断链） | 是 |
| 有效 fail（同上） | 1 | 是（失败证据） | 是 | 重置 |
| engine / scheduler / system / target_incident | **0** | 否 | 否（透明） | 否 |
| TCP-only | **0** | 否 | 否 | 否 |

`latest_valid()` 只取 `valid=1`，因此系统故障永不覆盖 TTL 内的新鲜 pass；`fail_chain()` 同样只扫 `valid=1`；系统故障不重置 `observing` 计数。SF1–SF7 沿用。

---

## 6. P0-2：C-2 的入向引用判定

### 6.1 v1.3 的两个错

```python
# 错 1：单一正则不可能完备
sqlite_master.sql LIKE 'REFERENCES\s+"?t"?'
# 错 2：把"本表有出向外键"当成"可以重建"的理由
if inbound and has_outbound: allow_rebuild   # ← 逻辑不相干
```

一条表的出向 FK 说明它依赖别人，**完全不说明**别人是否依赖它。只要存在任何入向引用，`DROP`/`RENAME` 就会影响引用方（SQLite 在 `legacy_alter_table=OFF` 时会尝试改写引用方 SQL，行为随版本变化；`ON` 时则留下悬空引用）。因此：**任何入向引用 → 停止**（P0-2.1）。

### 6.2 权威识别方法：`PRAGMA foreign_key_list` 遍历

```python
def inbound_fk_scan(conn, target):
    """返回引用 target 的 (child_table, fk_row) 列表；无法判定时抛 Inconclusive"""
    results = []
    tables = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    for (child,) in tables:
        if child == target:                       # 自引用也要算入向
            pass
        try:
            fks = conn.execute(f'PRAGMA foreign_key_list({quote_ident(child)})').fetchall()
        except Exception as e:
            raise Inconclusive(f"pragma failed on {child}: {e}")
        for fk in fks:
            # fk 列序：id, seq, table, from, to, on_update, on_delete, match
            if fk[2].lower() == target.lower():
                results.append((child, fk))
    return results
```

**为什么这是权威**：`PRAGMA foreign_key_list` 读的是 SQLite **解析后的**外键定义，天然覆盖：

| 合法写法 | 例 | PRAGMA 是否识别 |
| --- | --- | --- |
| 普通 | `REFERENCES nodes(id)` | 是 |
| 双引号标识符 | `REFERENCES "nodes"(id)` | 是 |
| 方括号 / 反引号 | `REFERENCES [nodes](id)` / ``REFERENCES `nodes`(id)`` | 是 |
| 大小写差异 | `REFERENCES NODES(id)` | 是（比较时 `lower()`） |
| schema 限定 | `REFERENCES main.nodes(id)` | 是（`table` 返回 `nodes`） |
| 转义引号 | `REFERENCES "no""des"(id)` | 是（返回真实名） |
| 表级复合 FK | `FOREIGN KEY(a,b) REFERENCES nodes(c,d)` | 是（多行 `fk`，每行 `table='nodes'`） |
| 带 `ON DELETE`/`MATCH` | `... ON DELETE RESTRICT` | 是 |

### 6.3 双保险：保守文本扫描（只用于"加严"，不用于"放行"）

```python
FK_TOKEN_RE = re.compile(r'(?i)\breferences\b')

def text_scan_maybe_refs(conn, target):
    """返回 True / False / None(无法判定)"""
    rows = conn.execute(
        "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND type IN ('table','trigger','view')"
    ).fetchall()
    verdict = False
    for (sql,) in rows:
        s = strip_comments_and_strings(sql)        # 去注释、去字符串字面量
        if not FK_TOKEN_RE.search(s):
            continue
        # 逐个 REFERENCES 之后取"直到 ( 或 空白"的标识符段，去引号/方括号/反引号，
        # 若其中任意一段（去掉 main./temp. 前缀后）等于 target（忽略大小写）→ True
        found = extract_ref_targets(s)
        if found is None:
            return None                             # 含无法解析的构造 → 不可判定
        if any(t.lower() == target.lower() for t in found):
            verdict = True
    return verdict
```

**判定逻辑（只加严）**：

| PRAGMA 结果 | 文本扫描结果 | 最终结论 |
| --- | --- | --- |
| 发现入向 | — | **停止** |
| 无入向 | `True` | **停止**（宁可误停） |
| 无入向 | `None` | **停止**（不可判定） |
| 无入向 | `False` | 可继续（仍需 §6.5 其他条件） |

### 6.4 最终安全判定流程（P0-2.3）

```python
def c2_precheck(conn, target):
    ddl = get_ddl(conn, target)
    if ddl is None:                        return STOP, "no_table"
    cols = pragma_table_info(conn, target) # 名称/类型/非空/默认/PK
    if not cols:                           return STOP, "cols_unreadable"
    idxs = pragma_index_list(conn, target)
    trgs = get_triggers(conn, target)
    fks  = pragma_foreign_key_list(conn, target)

    # ① 入向引用（任何形式）
    try:
        inbound = inbound_fk_scan(conn, target)
    except Inconclusive as e:
        return STOP, f"inbound_inconclusive:{e}"
    text = text_scan_maybe_refs(conn, target)
    if inbound or text is True or text is None:
        return STOP, "has_inbound_reference"

    # ② 自有出向引用（允许，但要 OFF）
    needs_fk_off = bool(fks)

    # ③ 列与约束
    for c in cols:
        if c.notnull and c.dflt is None and c.name not in DESIGN_COLS:
            return STOP, f"extra_notnull_no_default:{c.name}"
        if has_constraint_beyond_design(c):   # UNIQUE/PK/CHECK/REF
            return STOP, f"extra_constraint:{c.name}"

    # ④ 索引/触发器可安全处理
    if any(idx_uses_missing_col(i, cols) for i in idxs):  return STOP, "idx_missing_col"
    if any(trg_references_missing_col(t, cols) for t in trgs): return STOP, "trg_missing_col"

    # ⑤ 数据可无损搬运（全列可读、无生成列）
    if any(c.generated for c in cols):      return STOP, "generated_column"

    return GO, {"needs_fk_off": needs_fk_off}
```

**七条全满足才继续**（P0-2.3）：真实 DDL 已读 → 列与约束可识别 → 索引触发器可安全处理 → 外键依赖可完整识别（含**无入向**）→ 数据可无损搬运 → 全部验证通过 → 无未预期副作用。任一不成立即 `STOP`。

### 6.5 停止后的处置（必须成套）

| 动作 | 要求 |
| --- | --- |
| 原表 | 保留，不 `DROP`、不 `RENAME`、不改结构 |
| 原数据 | 不读写（除只读统计） |
| 原索引/触发器 | 不增删不改名 |
| 半成品 | **不得**创建 `"{target}__new"`；若已存在（上次异常），本次只做只读识别并记录，不自动清理 |
| 事件 | `system_events(event='schema_diff', table=target, reason=..., detail=json)` |
| 迁移标记 | **不写** `schema_migrations(success)` |
| 人工路径 | 事件中给出足够的 DDL/列/索引/触发器快照，供人工决定：改设计、手工迁移、或放弃该表 |

### 6.6 M27–M32（可执行）

| # | 初始 | 步骤 | 预期库 | 预期业务 | 失败不变项 |
| --- | --- | --- | --- | --- | --- |
| M27 | 表 `A` 有 `FK -> detection_task_runs(task_id)`（普通写法） | 执行 C-2 预检 | `STOP: has_inbound_reference`；无 `__new`；`system_events` 一条 | 停止 | 表/数据/索引/触发器全不变 |
| M28 | 表 `B` 用 `REFERENCES "detection_task_runs"("task_id")`（带引号） | 同上 | 同上（PRAGMA 识别） | 停止 | 同上 |
| M29 | 表 `C` 用 `REFERENCES main.DETECTION_TASK_RUNS(task_id)`（schema + 大写） | 同上 | `STOP`（`lower()` 比较 + 去 schema 前缀） | 停止 | 同上 |
| M30 | 表 `D` 的 DDL 含注释包裹的 `REFERENCES`、`/*...*/`、字符串字面量，文本扫描返回 `None` | 同上 | `STOP: inbound_inconclusive` | 停止（宁可误停） | 同上 |
| M31 | 目标表自己有出向 FK（→ `detection_tasks`），同时被表 `E` 引用 | 同上 | `STOP`（入向优先，不看出向） | 停止 | 同上 |
| M32 | 上述任一停止场景之后 | 检查库状态 | 原表存在、行数不变、索引/触发器数量与名称不变、无 `__new`、`schema_migrations` 无 success | 可安全交给人工 | — |

**M32 的逐项断言（必须全过）**：

```
SELECT COUNT(*) FROM {t}                     == 迁移前记录值
PRAGMA index_list({t}) 名称集合              == 迁移前
SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='{t}' == 迁移前
SELECT COUNT(*) FROM sqlite_master WHERE name='{t}__new' == 0
SELECT COUNT(*) FROM schema_migrations WHERE result='success' == 0（针对本次迁移）
```

---

## 7. C18 / C19（边界说明，仍待确认）

### 7.1 C18：TCP-only 记录范围

| 允许 | 禁止 |
| --- | --- |
| 写 `target_results`（`mode='tcp_only'`、`valid=0`） | 健康达标（`fresh()` 排除） |
| 诊断页展示、执行次数统计 | 连续失败链（`valid=1` 过滤） |
| 审计导出 | 恢复确认计数、订阅发布资格 |

**C18 未确认**（默认按上表实现：允许存，绝不参与判定）。

### 7.2 C19：旧结果表停写

| 环节 | 设计 |
| --- | --- |
| 新流程启用 | `cutover_state='new_active'` + `cutover_at` 写 `system_events` |
| 旧流程停写 | 同一事务、`cutover_at` 之后；旧 writer 读同一开关并拒绝写 |
| 防双写 | 单开关（存 DB，不用配置文件） |
| 防空窗 | 先连续 3 次成功产出并落 `target_results`，才允许切换 |
| 回滚 | 开关留在 `old_active`/`dual_write`；新数据保留并标 `pre_cutover`；不删旧表 |

**C19 未确认**（默认"先验证、单开关、可回滚"，不默认开双写）。

---

## 8. DDL 摘要（本轮变动部分）

```sql
-- 父表（§3.2）
node_identities(identity_id PK, airport_id NOT NULL, ...)
node_config_versions(identity_id, config_version, ..., PRIMARY KEY(identity_id, config_version))
nodes + identity_id + config_version
CREATE UNIQUE INDEX uq_nodes_id_identity ON nodes(id, identity_id)
CREATE INDEX idx_nodes_identity ON nodes(identity_id, config_version)

-- 六个触发器（§3.3/§3.4）
trg_nodes_rel_ins / trg_nodes_rel_upd / trg_ident_del / trg_cv_del
trg_ident_airport_upd / trg_cv_pk_upd

-- 结果表资格列（§5，不变）
valid INTEGER NOT NULL CHECK (valid IN (0,1))
CHECK (valid = 0 OR (mode='mihomo' AND failure_source IS NULL))
```

---

## 9. v1.3 → v1.4 修订对照

| # | v1.3 | v1.4 | 章节 |
| --- | --- | --- | --- |
| P0-1 | 四触发器：仅非空 + 版本存在 | 六触发器：插入/更新整体重验（含 `identity.airport_id = nodes.airport_id`）、父删除 ABORT、父移动机场 ABORT、父改 PK ABORT；`idx_nodes_identity`；四条数据断言；能力边界与两条配套（`recursive_triggers=ON`、禁 REPLACE） | §3 |
| P0-2 | 正则判入向 + "本表有出向即可重建" | `PRAGMA foreign_key_list` 遍历（权威）+ 保守文本扫描（只加严）；**任何入向即停止**；七条件全满足才继续；停止处置成套；M27–M32 逐项断言 | §6 |

---

## 10. 关闭证明

### 10.1 P0-1

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 插入四条件 | §3.3 ① | A1–A4 | 已关闭 |
| 更新三字段整体重验 | §3.3 ②（`UPDATE OF`） | A5/A6/A9 | 已关闭 |
| 机场归属校验 | §3.3 I2 | A2/A5 | 已关闭 |
| 删除父记录拒绝 | §3.4 ③④ | A7/A8 | 已关闭 |
| 身份一致性四条 | §3.1 I1–I4 | A1–A10 | 已关闭 |
| 能力边界声明 | §3.6（部分完整性，不等价 B） | — | 已关闭 |
| 不宣称等价、不擅批 C12 | §3.6/§3.7 | — | 已关闭 |
| 迁移后无孤儿 | §3.5 断言 | A10 | 已关闭 |

### 10.2 P0-2

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 任何入向即停止 | §6.1 | M27–M31 | 已关闭 |
| 弃用单一正则、权威识别 | §6.2 | M28/M29 | 已关闭 |
| 无法识别也停止 | §6.3/§6.4 | M30 | 已关闭 |
| 出向不构成放行理由 | §6.1/§6.4 | M31 | 已关闭 |
| 停止后库状态不变 | §6.5 | M32 | 已关闭 |
| 不写 success、不留半成品 | §6.5 | M32 | 已关闭 |

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
| A 路径关系 A | 10 | A1–A10 |
| 迁移 M | 32 | M1–M26 + M27–M32 |

### 11.2 A 组详测（完整五段见 §3.8）

A1–A10 均已按"初始 / 步骤 / 预期库 / 预期业务 / 失败不变项"写全，断言点集中在：`nodes` 行数、`airport_id`、`identity_id`、`config_version`、父表行数、六个触发器存在性。

### 11.3 M 组新增（完整见 §6.6）

M27–M32 覆盖普通引用、引号、大小写 + schema 限定、复杂 DDL 不可判定、出向 + 入向并存、停止后状态不变。

---

## 12. 依赖关系图（最终，与 v1.3 一致，仅补触发器与索引）

```
airports ──> node_identities ──> node_config_versions
                 │                      │
                 ├──> identity_stable_ids / identity_config_pending / identity_presence_log
                 └──> nodes.identity_id + nodes.config_version（回填）
                          │
                          ├── uq_nodes_id_identity（复合外键父键）
                          ├── idx_nodes_identity（删除侧 EXISTS）
                          ├── 6 个关系触发器（A 路径完整性）
                          ├──> node_target_state / node_state_history
                          ├──> node_id_reservations ──> restore_authorizations
                          ├──> detection_tasks（复合 FK + rules）──> detection_task_runs
                          │                                        └──> target_results
                          └──> （状态回填 §7.4）
detection_rules ──> detection_tasks
airport_identity_daily / airport_union_snapshot（依赖 airports）
legacy_cutover（只读旧 results / latency_results）
```

---

## 13. C11–C20 确认状态

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（获批才走 B 路径） | **未确认（本文未假设已批准）** |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口 | 6h 优先 | 未确认 |
| C15 | `rep` 门槛 | 0.90 / 0.60 | 未确认 |
| C16 | retired 回归复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| C18 | TCP-only 记录允许存、不参与判定 | 按 §7.1 | 未确认 |
| C19 | 旧结果表停写切换 | 先验证、单开关、可回滚 | 未确认 |
| C20 | A 路径"物理可空 + 触发器"是否接受 | 建议接受为过渡 | 未确认 |

**事实缺口**：旧库是否存在 `(airport_id,fingerprint)` 冲突（决定身份回填能否 1:1）；生产库是否已有 `detection_*` 同名表（C-1/C-2 分支）；`target_results` 增长速率与索引代价；`recursive_triggers` 在各连接的实际设置情况。

**已知无解**：SQLite 无法证明调用者身份；A 路径无法覆盖 `REPLACE`/`DROP`/外部工具（已声明）；旧库无版本/模式字段，旧历史无法升级为证据。

---

## 14. 风险

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | A 路径被 `INSERT OR REPLACE` 绕过（父表删除触发器不触发） | 连接设 `recursive_triggers=ON`；禁父表 REPLACE/UPSERT；越权写 `code_violation` | A7/A8 + 代码评审 |
| 2 | 有人直接用 `DROP TRIGGER` 改数据 | 迁移后断言触发器数量；定期审计 | A10 |
| 3 | 触发器使写入变慢 | 索引 `idx_nodes_identity`；`EXISTS` 为点查 | 压测 |
| 4 | C-2 误停导致迁移中断 | 误停只影响单表；事件给出快照供人工判断 | M30/M32 |
| 5 | `PRAGMA foreign_key_list` 在异常 DDL 上抛错 | 抛错即 `Inconclusive` → 停止 | M30 |
| 6 | 保守映射导致恢复面过大 | 迁移前统计 S-A 命中率 | RG23 |

---

**v1.4 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1 或 P0、未修改任何配置与生产数据**；仅修订两项 P0。**C11–C20 全部未确认，其中 C12 未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
