# NodePoolME 新架构总体设计方案 v1.6

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.5
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改任何配置与生产数据。**
**本轮范围**：四项——nodes UPSERT 身份冲突、`foreign_key_check` 语义与迁移验证顺序、节点档案测试与连接契约闭环、示例 SQL 语法。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 修订索引（v1.5 → v1.6）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | nodes UPSERT 身份冲突必须显式失败，禁静默保留旧身份 | §3.6 | 修正 |
| P0-2 | `foreign_key_check` 独立于 `foreign_keys`；迁移验证三期重排 + COMMIT 后失败恢复 | §4.5、§4.7 | 修正 |
| P0-3 | R2/R3 增历史关联不变项；五类连接契约 + 运行期写前校验 | §3.6.6、§4.3、§4.6 | 补齐 |
| P1 | 示例 SQL 去非法字段、修正 REPLACE 语法、标注伪代码、附语法核对结果 | §3.6.3、附录 A | 修正 |

未修订：Q1–Q12、六个关系触发器、`trg_nodes_delete_guard`、"A 路径部分完整性、不等价 B"、C12 未确认且默认 A、C-2 的 `PRAGMA foreign_key_list` 入向检查与"任何入向即停"、17 步主序号、系统故障 `valid=0` 隔离、30 天 missing、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式兼容、评分算法、前端布局。**C11–C20 全部未确认。**

---

## 0. 本轮修的是什么

| # | v1.5 的写法 | 缺陷 | 本轮证据 |
| --- | --- | --- | --- |
| P0-1 | `ON CONFLICT ... DO UPDATE SET status=...`（`SET` 不含身份列） | incoming 身份与现存不同也返回成功，旧身份被静默保留 | 实测：现存 `identity=10`，incoming `identity=11`，语句 **OK**，行内仍为 10 |
| P0-2 | 一处写"OFF 时 `foreign_key_check` 返回空"，一处写"独立于开关" | 自相矛盾；迁移顺序无法据此确定 | 实测：`foreign_keys=OFF` 时 `foreign_key_check` **仍返回 2 行违规** |
| P0-3 | R2/R3 只查节点行 | 历史/结果/任务/预留四张子表未断言；连接契约未分类型、无运行期复检 | — |
| P1 | 示例用 `last_seen`（非基准字段）、`REPLACE INTO nodes(id=5, ...)`（非法语法） | 示例本身就不可执行 | 语法核对见附录 A |

v1.6 的三句话：**UPSERT 在节点表上必须能被看见冲突；`foreign_key_check` 与 `foreign_keys` 是两回事；连接契约要在每次写入前复检，不是初始化时看一眼。**

---

## 1. 保留的既定设计

Q1–Q12 全部保留；指纹算法不改；身份与生命周期原则不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康最多留上一版 24h、硬上限 72h；30 个发布版本；Q11 两次有效 Mihomo 成功且间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不重做。

**六个关系触发器一字不改**：`trg_nodes_rel_ins`、`trg_nodes_rel_upd`、`trg_ident_del`、`trg_cv_del`、`trg_ident_airport_upd`、`trg_cv_pk_upd`；`trg_nodes_delete_guard` 同样一字不改。**A 路径仍是部分引用完整性，不等价于 B；B 仍需 C12 批准（未确认）。**

---

## 2. 基准 `nodes` 与 A/B 路径（不变）

| 事实 | 说明 |
| --- | --- |
| `nodes` 有 `id` PK、`UNIQUE(airport_id, fingerprint)` | 基准 |
| 无 `identity_id`、无 `config_version`、**无 `last_seen`** | 基准 |
| 有 `status`（默认 `unknown`）、`fail_count`（默认 0） | 基准 |

| 路径 | 是否重建 | 约束强度 | 前置 |
| --- | --- | --- | --- |
| **A（默认）** | 否 | 部分完整性 | 无需 C12 |
| **B（可选）** | 是（12 步） | 真 `NOT NULL` + 真复合外键 + `ON DELETE RESTRICT` | **C12 未确认** |

---

## 3. P0-1：身份引用完整性与节点档案保护

### 3.1 关系不变式（不变）

```
I1  nodes.identity_id 非空 ∧ nodes.config_version 非空
I2  identity 存在 ∧ identity.airport_id = nodes.airport_id
I3  (identity_id, config_version) 存在于 node_config_versions
I4  父记录被引用时不可删除
I5  nodes 行是机器档案，不可被删除重建
I6  同一 (airport_id, fingerprint) 只能对应一个 identity 与一个 config_version
```

`I6` 是本轮新增的**语义不变式**：`(airport_id, fingerprint)` 是节点在机场内的稳定键，它一旦存在，其身份与配置版本就是**既成事实**，不允许通过写入路径改变。理解 `I6` 是理解 §3.6 的前提。

### 3.2 父表、索引、六个关系触发器（v1.5 不变，摘要）

```sql
CREATE TABLE node_identities (
  identity_id INTEGER PRIMARY KEY AUTOINCREMENT,
  airport_id  INTEGER NOT NULL,
  stable_id TEXT,
  generation INTEGER NOT NULL DEFAULT 1,
  lifecycle  TEXT NOT NULL DEFAULT 'active'
             CHECK (lifecycle IN ('active','missing','retired')),
  related_identity_id INTEGER REFERENCES node_identities(identity_id) ON DELETE SET NULL,
  first_seen_at TEXT NOT NULL, last_present_at TEXT, created_at TEXT NOT NULL,
  FOREIGN KEY (airport_id) REFERENCES airports(id)
);

CREATE TABLE node_config_versions (
  identity_id INTEGER NOT NULL, config_version INTEGER NOT NULL,
  fingerprint TEXT NOT NULL, params_hash TEXT, protocol TEXT, server TEXT,
  port INTEGER, display_name TEXT, change_reason TEXT NOT NULL DEFAULT 'initial',
  opened_at TEXT NOT NULL, closed_at TEXT,
  PRIMARY KEY (identity_id, config_version),
  FOREIGN KEY (identity_id) REFERENCES node_identities(identity_id)
);

ALTER TABLE nodes ADD COLUMN identity_id INTEGER;
ALTER TABLE nodes ADD COLUMN config_version INTEGER;
CREATE UNIQUE INDEX uq_nodes_id_identity ON nodes(id, identity_id);
CREATE INDEX idx_nodes_identity ON nodes(identity_id, config_version);
```

六个关系触发器（插入/更新/父删除/父改机场/父改 PK）与 `trg_nodes_delete_guard` 的完整定义见 v1.5 §3.3/§3.4/§3.7.2，本轮不改。其效果已实测：

| 用例 | 结果 |
| --- | --- |
| 跨机场 identity 插入（airport 1 vs identity 属 airport 2） | `ABORT: nodes identity relation invalid` |
| 改 `airport_id` 导致归属不匹配 | `ABORT: ... invalid after update` |
| 改 `config_version` 到不存在的版本 | `ABORT: ... invalid after update` |
| 删被引用的 config_version | `ABORT: config_version still referenced by nodes` |
| 删被引用的 identity | `ABORT: identity still referenced` |
| 删已回填节点 | `ABORT: node archive delete forbidden` |

### 3.3 完整性断言（不变）

NULL=0、跨机场=0、孤儿版本=0、一节点一身份、触发器 7 个、`trg_ident_del` 引用清单与 `foreign_key_list` 自洽。

### 3.4 P0-1：nodes UPSERT 的身份冲突（本轮重写）

#### 3.4.1 已验证的缺陷

```sql
-- 现存：id=1, airport_id=1, fingerprint='F1', identity_id=10, config_version=1
INSERT INTO nodes(airport_id, fingerprint, identity_id, config_version, status, fail_count)
VALUES (1, 'F1', 11, 1, 'unknown', 0)
ON CONFLICT(airport_id, fingerprint) DO UPDATE
SET status = excluded.status, fail_count = excluded.fail_count;
```

实测结果：**语句 OK**，`id` 仍为 1，`identity_id` 仍为 **10**（incoming 的 11 被丢弃）。

原因链条：插入阶段 `trg_nodes_rel_ins` 校验的是 **incoming** 关系（(11,1) 合法）→ 通过；唯一键冲突 → `DO UPDATE` 分支只写 `SET` 里的列 → 身份列没进 `SET` → `BEFORE UPDATE OF identity_id, config_version` **不触发** → 冲突被静默吞掉。

这不是"UPSERT 用错"，而是**UPSERT 本身无法表达"身份必须一致"这个条件**：SQLite 的 `DO UPDATE ... WHERE` 若条件不成立，只是**不更新**并返回成功（仍然静默），而 `RAISE` 在 `WHERE` 里不可用。因此**数据库层无法把"身份不一致"变成错误**。

#### 3.4.2 结论：nodes 禁止 UPSERT，改用身份感知的两段式写入

| 规则 | 内容 |
| --- | --- |
| R-1 | `nodes` 表**禁止** `INSERT ... ON CONFLICT ... DO UPDATE/DO NOTHING`（包含任何形式的 UPSERT） |
| R-2 | 写入必须走唯一入口 `upsert_node_identity_aware()`（§3.4.3），在 `BEGIN IMMEDIATE` 内完成"读—比对—写" |
| R-3 | 身份或版本不一致时**抛出显式错误**，不写库、不返回成功 |
| R-4 | 身份/配置的**真实变更**由 §3.4.4 的正式流程完成，不得借 UPSERT 偷渡 |
| R-5 | 数据库层保留六触发器 + 档案守卫作为兜底；L1 代码门禁扫描 `nodes` 写入路径中的 `ON CONFLICT` |

#### 3.4.3 可执行 SQL + 伪代码（标注：以下 Python 为**伪代码**，SQL 为可执行语句）

**四情形判定表**

| 情形 | 现存行 | incoming | 处理 |
| --- | --- | --- | --- |
| C1 新增 | 无 | 任意合法 | `INSERT`（由 `trg_nodes_rel_ins` 校验） |
| C2 一致 | 有，identity 与 cv **均相同** | 同 | `UPDATE` 普通字段（`status`/`fail_count`） |
| C3 身份冲突 | 有，identity **不同** | — | **显式失败** `IDENTITY_CONFLICT` |
| C4 版本冲突 | 有，identity 同、cv **不同** | — | **显式失败** `CONFIG_VERSION_CONFLICT` |

**可执行 SQL（C2 分支）**

```sql
UPDATE nodes
   SET status = :status, fail_count = :fail_count
 WHERE id = :id
   AND identity_id = :identity_id
   AND config_version = :config_version;
```

**伪代码（唯一写入口）**

```python
# 伪代码：不是可执行 SQL，也不是最终实现
def upsert_node_identity_aware(conn, airport_id, fingerprint, identity_id, config_version, status, fail_count):
    with immediate_tx(conn):                      # BEGIN IMMEDIATE：写事务立即取写锁
        row = conn.execute(
            "SELECT id, identity_id, config_version FROM nodes "
            "WHERE airport_id = ? AND fingerprint = ?", (airport_id, fingerprint)).fetchone()
        if row is None:                                                      # C1
            conn.execute(
                "INSERT INTO nodes(airport_id, fingerprint, identity_id, config_version, status, fail_count) "
                "VALUES (?,?,?,?,?,?)",
                (airport_id, fingerprint, identity_id, config_version, status, fail_count))
            return "inserted"
        node_id, cur_identity, cur_cv = row
        if cur_identity != identity_id:                                      # C3
            raise IdentityConflict(node_id, cur_identity, identity_id)       # 不写库
        if cur_cv != config_version:                                         # C4
            raise ConfigVersionConflict(node_id, cur_cv, config_version)     # 不写库
        changed = conn.execute(                                              # C2 + CAS
            "UPDATE nodes SET status = ?, fail_count = ? "
            "WHERE id = ? AND identity_id = ? AND config_version = ?",
            (status, fail_count, node_id, identity_id, config_version)).rowcount
        if changed != 1:
            raise ConcurrentModification(node_id)                            # 见 §3.4.5
        return "updated"
```

**冲突的处理出口**（不是静默，也不是自动迁移）

| 异常 | 语义 | 后续动作 |
| --- | --- | --- |
| `IdentityConflict` | 同 `(airport_id, fingerprint)` 出现不同 identity | 记 `system_events(code_violation, node_id, cur, incoming)`；**拒绝本次写入**；交人工或身份审计流程判定是"调用方算错身份"还是"映射表被污染" |
| `ConfigVersionConflict` | 同 identity 下同一节点被要求换版本 | 记事件；**拒绝**；配置变更必须走 §3.4.4 |
| `ConcurrentModification` | CAS 未命中（行被并发改） | 重试一次或放弃；记 `concurrent_write_conflict` |

**为什么 C3 不是"进入身份变更流程"而是"拒绝"**：`(airport_id, fingerprint)` 相同意味着**同一台机器、同一份配置**——按定义它就是同一个 identity。出现不同 identity 只能是上游计算错误或映射污染，不存在"合法的身份变更"语义。真正的身份变化一定会伴随 fingerprint 变化（`fingerprint = stable_id + config 摘要`），落到**新键**，走 C1。

#### 3.4.4 身份/配置变化的正式流程（不走 UPSERT）

| 变化 | 触发条件 | 正确路径 |
| --- | --- | --- |
| 配置内容变化（协议/端口/参数） | fingerprint 改变 | 身份管理流程：为**同一 identity** 调用 `open_config_version()` 写 `node_config_versions(identity_id, N+1)`，随后显式 `UPDATE nodes ... SET config_version = N+1 WHERE id = ?`（触发 `trg_nodes_rel_upd` 重验） |
| 稳定身份变化（`stable_id` 变化） | fingerprint 改变 | 新 identity 落库 → 新 `(airport_id, fingerprint)` 键 → C1 插入新行 |
| 同指纹但身份不同 | **不应发生** | §3.4.3 的 `IdentityConflict`，拒绝 + 事件 |

**关键**：`UPDATE nodes SET config_version = N+1` 是**显式语句**，必然触发 `BEFORE UPDATE OF config_version`，关系被重验；而 UPSERT 的 `SET` 若不含该列则完全不触发。这正是"冲突不能藏在普通字段更新里"的实现差异。

#### 3.4.5 并发与事务边界

| 问题 | 处理 |
| --- | --- |
| 两个写入同时到达同键 | `BEGIN IMMEDIATE` 让第二个在第一个 COMMIT 前拿不到写锁；SQLite 单写者模型保证不交错 |
| 读与写之间被改 | 读取与 `UPDATE` 在同一 `IMMEDIATE` 事务内；CAS 的 `WHERE identity_id=? AND config_version=?` 再兜一层；`rowcount != 1` 即判冲突 |
| 两写入身份不同 | 先到者写入；后到者读到已提交的 identity，进 C3 → **抛错**，不覆盖（这是本轮要求的"不允许静默覆盖"） |
| UNIQUE 约束的角色 | 仅作为最后兜底（若有人绕过入口直接 `INSERT`，重复键报 `UNIQUE constraint failed`），**不承担身份一致性判定** |
| 事务时长 | 单行读写，毫秒级；不做网络 IO（检测结果在事务外拿到） |

#### 3.4.6 测试（R 组，含本轮新增）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| R1 | 空表；identity 10（airport 1）、版本 (10,1) 已存在 | 普通 `INSERT`（新键 `F1`，identity 10，cv 1） | OK；`nodes` +1；新 id |
| R2 | 节点 id=1（`F1`，identity 10，cv 1）+ 历史 1 行 + 结果 1 行 | `INSERT OR REPLACE INTO nodes(...)` 同键 | **ABORT `node archive delete forbidden`**；id=1、行内容、历史、结果全不变 |
| R3 | 同上 | `REPLACE INTO nodes (id, airport_id, fingerprint, identity_id, config_version, status, fail_count) VALUES (1, 1, 'F2', 10, 1, 'unknown', 0)` | **ABORT**；id=1、fingerprint 仍 `F1`、历史/结果不变 |
| R4 | 节点 id=1（identity 10，cv 1） | 走 `upsert_node_identity_aware`，incoming 完全一致，`status='available'` | `updated`；id=1；identity/cv 不变；普通字段更新 |
| R5 | 同 R4 | 同上，但 `config_version=9`（不存在） | **`ConfigVersionConflict`**；库不变（CAS 前置比对即抛） |
| R6 | 节点 id=1（identity 10） | 直接执行"非法 UPSERT"（incoming identity 11）→ 证实缺陷 | **语句 OK 且身份仍 10**（这正是被 R-1/R-2 禁止的理由）；走正式入口则为 `IdentityConflict` 且库不变 |
| R7 | 同 R4 | 走正式入口，incoming identity 11 | **`IdentityConflict`**；id/id/identity/cv/历史/结果全不变 |
| R8 | 同 R4 | 走正式入口，incoming cv 2（identity 同） | **`ConfigVersionConflict`**；全不变；随后按 §3.4.4 用 `open_config_version` + 显式 UPDATE 才允许变更 |
| R9 | 节点 id=1（无子行） | 并发两连接各调 `upsert_node_identity_aware`（identity 10 / 11） | 一成一败；胜者身份不被覆盖；败者 `IdentityConflict`；无静默覆盖 |

**R2/R3 的不变项（本轮扩充，P0-3.1）**

| 断言对象 | 断言内容 |
| --- | --- |
| `nodes` | 原 `id` 存在且唯一；`fingerprint`、`created_at`（若基准有则取原值）、`status`、`fail_count`、`identity_id`、`config_version` 全部等于操作前快照 |
| `node_state_history` | 行数不变；`node_id` 关联不变（仍指向原 id）；内容快照一致 |
| `target_results` | 行数不变；`node_id` 关联不变 |
| `detection_tasks` | 行数不变；`node_id` 关联不变 |
| `node_id_reservations` | 行数不变；`node_id` 关联不变 |
| 全库 | `nodes` 行数不变；无新增行 |

实现为"操作前取五张表的行数与 `node_id` 集合快照 → 操作后逐项比较"。

#### 3.4.7 档案保护的三层防线（v1.5 结论保留，本轮补实测）

| 层 | 手段 | 实测效果 |
| --- | --- | --- |
| L1 代码门禁 | 禁 `nodes` 写入路径出现 `ON CONFLICT`/`REPLACE`（扫描模式 S1–S9，见 v1.5 §3.7.4） | 静态 |
| L2 连接契约 | `foreign_keys=ON` + `recursive_triggers=ON`，**写前复检**（§4.3） | 见 §4 |
| L3 运行期守卫 | `trg_nodes_delete_guard` 等 7 个触发器 | `rt=ON`：REPLACE → ABORT；`rt=OFF` 无子行：REPLACE **成功且 id 1→2**（档案被替换）；`rt=OFF` + `fk=OFF` 有子行：REPLACE **成功且历史 `node_id=1` 悬空** |
| L4 巡检 | 节点数、历史引用、映射覆盖 | 事后发现 |

**实测数据说明"为什么不能只靠 `recursive_triggers`"**：`rt=OFF` 时守卫完全不触发，档案会被静默替换（id 1→2）。因此 L2 的"写前复检"与 L1 的"门禁"都是必要的，不是可选加固。

---

## 4. P0-2 / P0-3：连接契约与迁移验证顺序

### 4.1 `PRAGMA foreign_key_check` 的真实语义

| 事实 | 说明 |
| --- | --- |
| `PRAGMA foreign_keys` | 控制**约束执行**（插入/更新时是否检查父行）。连接级、默认 OFF、事务内设置为 no-op、URI 不可设 |
| `PRAGMA foreign_key_check` | **独立诊断**，返回所有违规行 `(table, rowid, parent, fkid)`。**不受 `foreign_keys` 开关影响** |
| 实测（本轮） | `foreign_keys=OFF`：返回 2 行违规（`nodes→airports`、`node_identities→airports`）；`foreign_keys=ON`：同样返回这 2 行 |
| 实测（本轮） | `BEGIN` 内执行 `PRAGMA foreign_keys=OFF` 后读回仍为 1；`COMMIT` 后仍为 1 → **事务内切换无效** |

**v1.5 §4.2 的错误表述必须删除**：不存在"`foreign_key_check` 在 OFF 时返回空"这回事。（v1.5 曾把它写成"检查通过"的假象来源，属错误归因；正确结论相反——它照样能查出来，因此可以在任意阶段作为可信诊断。）

**推论**：`foreign_key_check` 可用于**事务内预提交检查**与**COMMIT 后终检**，两次都必须做，且都不能用"开关状态"解释结果。

### 4.2 连接类型与契约（P0-3.2）

| 类型 | `foreign_keys` | `recursive_triggers` | 写入权限 | 复检时机 |
| --- | --- | --- | --- | --- |
| **业务写入连接** | 必须 ON | 必须 ON | 可写 | **每次写入前** `write_guard()` |
| 连接池连接 | 必须 ON | 必须 ON | 可写（checkout 后仍需 `write_guard`） | checkout + 写前 |
| 后台任务连接（调度/检测/测速/发布） | 必须 ON | 必须 ON | 可写 | 每次写入前 |
| 迁移专用连接 | 允许窗口内 OFF | 必须 ON | 仅迁移语句 | 三期各自复检（§4.4） |
| CLI 维护连接 | 必须 ON（只读分析亦 ON） | ON | 默认只读；写需显式 `--allow-write` + 复检 | 启动 + 写前 |

**规则**

1. 业务写入连接必须**同时**满足两个 PRAGMA=1；任一不满足 → **不得执行写入**（`write_guard` 抛 `ConnectionContractViolation`，请求失败，不降级）。
2. 迁移专用连接只在**迁移窗口**可调整 `foreign_keys`，且窗口内**业务写入必须已停止**（见 §4.4 前置条件）。
3. 迁移完成后，所有**新连接、池内连接、重连连接**必须重新设置并读回验证——**不假设**"初始化时开过就一直开着"。
4. 连接被外部代码改过 PRAGMA（例如某模块自己 `PRAGMA foreign_keys=OFF`）时，下一次业务写入前的 `write_guard` 必须能发现并拒绝。

### 4.3 写入前复检（`write_guard`）

```python
# 伪代码
def write_guard(conn):
    fk = conn.execute("PRAGMA foreign_keys").fetchone()[0]
    rt = conn.execute("PRAGMA recursive_triggers").fetchone()[0]
    if fk != 1 or rt != 1:
        raise ConnectionContractViolation(fk=fk, rt=rt)      # 拒绝写入，不自动修复
```

| 设计点 | 理由 |
| --- | --- |
| 每次写入前执行，而非只在 checkout | 外部代码可能在拿到连接后改 PRAGMA；只有紧贴写入才能发现 |
| 拒绝而非"顺手修好" | 自动 `SET ON` 会掩盖"有人正在改连接状态"这一事实；契约破坏必须可见 |
| 两条 PRAGMA 读取成本 | 单连接微秒级；相比一次写入可忽略 |
| 与 `create_connection` 的关系 | 建连时设置 + 读回（§4.2）；`write_guard` 是**第二道**，二者不互相替代 |

### 4.4 迁移验证顺序（本轮重排，17 步主序号不变）

**阶段 A：事务前（before-begin）**

1. 创建迁移专用连接，读回 `foreign_keys=1`、`recursive_triggers=1`；
2. 生成备份（文件级：`db` + `-wal` + `-shm`，或 `VACUUM INTO`），记录 sha256 与行数基线；
3. **确认业务写入已停止或只读**（显式检查运行状态开关；未满足则中止，不进入迁移）；
4. 仅在 C-2 判定"重建表有自出向外键"且确有必要时，于**事务外**执行 `PRAGMA foreign_keys=OFF`（并在日志记录"已关闭"与关闭原因）；
5. 预检 `sqlite_master`、旧表行数与时间范围、C-1/C-2 分支。

**阶段 B：事务内（in-tx）**

6. `BEGIN IMMEDIATE`；
7. 执行结构迁移（步 2–13，见 §5）；
8. 数据回填（步 3/4/5/14）；
9. 关系断言（§3.3 六条，全部以 SQL 计数判定，非 0 即抛）；
10. **预提交 `PRAGMA foreign_key_check`**：返回任何行 → `raise PreCommitCheckFailed` → `ROLLBACK`；
11. 行数/映射/触发器计数断言（触发器必须为 7）。

**阶段 C：COMMIT 后（after-commit）**

12. 恢复 `foreign_keys=ON`，**读回必须为 1**（不为 1 → 非零退出，见 §4.6）；
13. **最终 `PRAGMA foreign_key_check`**：返回任何行 → 走 §4.6 恢复流程；
14. 全量断言复跑（关系、行数、触发器、映射覆盖）；
15. 全部通过 → 才写 `schema_migrations(success)`；
16. 恢复业务写入开关（仅在 15 成功后）。

**关键澄清**：`COMMIT` 之后发现违规，**不可能回滚已提交事务**。阶段 C 的失败处理只有一条路——**从备份恢复**，因此阶段 A 的备份与"业务写入已停止"是硬前置，不是可选项。

### 4.5 迁移伪代码（标注：伪代码；与 §4.4 文字顺序逐条对齐）

```python
# 伪代码：结构示意，非最终实现
def migrate(db_path):
    backup = take_backup(db_path)                 # A2：db + wal + shm + sha256 + 行数基线
    conn = create_connection(db_path)             # A1：建连即设置 + 读回
    if not business_writes_stopped():             # A3
        raise MigrationPrecondition("business writes not stopped")
    need_fk_off = c2_needs_fk_off(conn)           # A4：仅"重建表有自出向外键"时才关
    try:
        if need_fk_off:
            conn.execute("PRAGMA foreign_keys=OFF")            # 事务外
            if read(conn, "foreign_keys") != 0:
                raise MigrationPrecondition("cannot turn fk off outside tx")

        conn.execute("BEGIN IMMEDIATE")                        # B6
        try:
            apply_ddl(conn)                                    # B7
            backfill(conn)                                     # B8
            assert_relations(conn)                             # B9  —— 抛 RelationAssertionError
            bad = conn.execute("PRAGMA foreign_key_check").fetchall()   # B10
            if bad:
                raise PreCommitCheckFailed(bad[:5])
            assert_counts_and_triggers(conn)                   # B11 —— 抛 CountMismatch
            conn.execute("COMMIT")
        except Exception:
            if conn.in_transaction:
                conn.execute("ROLLBACK")                       # B10 失败即回滚
            raise
    finally:
        if need_fk_off:
            conn.execute("PRAGMA foreign_keys=ON")             # C12，事务外
        if read(conn, "foreign_keys") != 1:
            log_critical("fk_restore_failed"); sys.exit(2)     # 非零退出
    # —— C13/C14：COMMIT 之后 ——
    bad = conn.execute("PRAGMA foreign_key_check").fetchall()
    if bad:
        restore_from_backup(db_path, backup)                   # §4.6
        log_event("migration_verify_failed", detail=bad[:5])
        sys.exit(3)                                            # 不写 success，业务写入保持关闭
    try:
        assert_relations(conn); assert_counts_and_triggers(conn)
    except Exception:
        restore_from_backup(db_path, backup)
        sys.exit(3)
    write_schema_migration_success(conn)                       # 只在全绿之后
    enable_business_writes()
```

**硬规则**：不使用 `assert` 作为唯一保护（`python -O` 会移除 `assert`）。全部改用显式异常 + `sys.exit(非零)`；任何终止路径都不得写 `success`、不得开启业务写入。

### 4.6 COMMIT 后失败的恢复流程（可执行顺序）

| 步 | 动作 | 断言 |
| --- | --- | --- |
| 1 | 保持业务写入关闭（开关仍在"maintenance"） | 写入入口返回 503 |
| 2 | 关闭所有连接（应用池 + 后台 + CLI） | 无残留写事务 |
| 3 | 用备份替换 `db`/`-wal`/`-shm`（先删除现存 `-wal`/`-shm`，避免与旧库不匹配） | 文件 sha256 == 备份 sha256 |
| 4 | 开新连接（`create_connection`），`quick_check` | 返回 `ok` |
| 5 | `foreign_key_check` | 0 行 |
| 6 | 断言复跑（关系、行数、触发器、映射） | 全过 |
| 7 | 记录 `system_events(migration_rollback, reason, backup_sha256)` | 事件落库 |
| 8 | 人工确认后才可恢复写入；**不写** `schema_migrations(success)` | — |

备份不可用（文件损坏/缺失）时：保持业务写入关闭，进程非零退出，等待人工介入；**不得**尝试"边修边用"。

### 4.7 测试（FK 组，本轮更新）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| FK1 | ON；identity 10 无 nodes 引用但有版本行 | 删 identity | ABORT（版本表分支） |
| FK2 | 同 FK1，连接 `foreign_keys=OFF` | 同上 | 仍 ABORT |
| FK3 | OFF；identity 被 nodes 引用 | 同上 | ABORT（nodes 分支） |
| FK4 | 池内 8 条连接 | 逐条读两个 PRAGMA | 全 1 |
| FK5 | 断开重连 | 读回 | 全 1 |
| FK6 | 后台/调度线程取连接 | 读回 | 全 1 |
| FK7 | 一次成功迁移 | `foreign_key_check` | 0 行；有 success |
| FK8 | 未走 creator 的连接 | 调 `write_guard` | 抛 `ConnectionContractViolation`，拒绝写入 |
| FK9 | OFF；identity 无 nodes 无版本，但有 `identity_presence_log` 行 | 删 identity | ABORT（子表分支） |
| **FK10** | OFF；制造真实违规（`identity→airports` 缺失） | `PRAGMA foreign_key_check` | **返回违规行**（实测 2 行）——证伪"OFF 返回空" |
| **FK11** | ON；同一违规数据 | 同上 | 同样返回违规行 |
| **FK12** | 事务内 `PRAGMA foreign_keys=OFF` | 读回 | 仍为 1（no-op） |
| **FK13** | 预提交检查故意留下 1 行违规 | 触发 `PreCommitCheckFailed` | 事务 ROLLBACK；库回到迁移前（行数/触发器/映射全等于基线） |
| **FK14** | COMMIT 后注入违规（测试钩子） | 走 §4.6 | 从备份恢复；**无** success；业务写入保持关闭；退出码非零 |
| **FK15** | 恢复 `foreign_keys=ON` 失败（模拟） | — | 进程非零退出；业务写入保持关闭 |

**跨组用例**

| 用例 | 断言 |
| --- | --- |
| CV1：`recursive_triggers=OFF` 连接调业务写入入口 | `write_guard` 拒绝（不执行 REPLACE，档案不变） |
| CV2：`recursive_triggers=ON` + `foreign_keys=ON` | 业务入口允许；若代码里出现 REPLACE，被 `trg_nodes_delete_guard` 拦（ABORT） |
| CV3：连接运行期被外部改 `PRAGMA foreign_keys=OFF` | 下一次写入前 `write_guard` 抛错拒绝 |
| CV4：迁移连接调 PRAGMA | 应用连接读回不受影响（仍全 1） |
| CV5：重连后 | 两个 PRAGMA 重新设置并读回为 1 |
| R2 + A10 | REPLACE 被拒后 §3.3 六条断言仍全过 |
| FK2 + A8 | OFF 时删被引用 identity 仍 ABORT，无孤儿 |
| FK13 + M32 | 预提交失败回滚后无半成品表、无 success |
| R4 + FE | 正式入口写入后 `fail_chain()` 仍只读 `valid=1` |

---

## 5. P0 迁移顺序（17 步主序号不变，仅补验证位置）

| 步 | 对象/动作 | 阶段 | 依赖 | 失败处理 |
| --- | --- | --- | --- | --- |
| 0 | 备份、`quick_check`、建连读回两 PRAGMA、确认业务写入已停 | before-begin | — | 中止 |
| 1 | 预检 `sqlite_master`（C-1/C-2）、旧表行数与时间范围 | before-begin | — | 中止 |
| 2 | `node_identities` + 索引 | in-tx | airports | 回滚 |
| 3 | 逐行建 identity（`nodes.id` 升序）+ `legacy_node_identity_map` | in-tx | 步 2 | 回滚 |
| 4 | `node_config_versions` + 每 identity 写 `version=1` | in-tx | 步 2/3 | 回滚 |
| 5 | `nodes` 加两列 + 回填 + `uq_nodes_id_identity` + `idx_nodes_identity` + 六个关系触发器 | in-tx | 步 3/4 | 回滚 |
| 5b | 六个触发器存在 + §3.3 前四条断言 | in-tx | 步 5 | 回滚 |
| 6 | `node_target_state`、`node_state_history` | in-tx | 步 5 | 回滚 |
| 7 | `identity_stable_ids` / `identity_config_pending` / `identity_presence_log` | in-tx | 步 2 | 回滚 |
| 7b | `trg_ident_del`（完整引用清单，五张表此时均已存在） | in-tx | 步 7 | 回滚 |
| 8 | `detection_rules` + `uq_rules_active` | in-tx | — | 回滚 |
| 9 | `detection_tasks` | in-tx | 步 5、8 | 回滚 |
| 10 | `detection_task_runs` | in-tx | 步 9 | 回滚 |
| 11 | `target_results` + 三索引 | in-tx | 步 5、9 | 回滚 |
| 12 | `node_id_reservations` + `restore_authorizations` + 回池三触发器 | in-tx | 步 5 | 回滚 |
| 12b | `trg_nodes_delete_guard`（四张子表此时均已存在） | in-tx | 步 6/9/11/12 | 回滚 |
| 13 | `airport_identity_daily` / `airport_union_snapshot` / `legacy_cutover` | in-tx | airports、旧表 | 回滚 |
| 14 | 状态回填（S-A～S-E） | in-tx | 步 6、13 | 回滚 |
| 15 | 关系断言 + **预提交 `foreign_key_check`** + 触发器计数 == 7 | in-tx | 全部 | 回滚 |
| 16 | 恢复 PRAGMA（读回 == 1）+ **COMMIT 后 `foreign_key_check`** + 断言复跑 | after-commit | — | 备份恢复，不写 success |

**创建顺序硬约束**：触发器体内引用的表必须先存在；违反会 `CREATE TRIGGER` 通过但触发时 `no such table`。

---

## 6. C-2 入向引用判定（v1.5 不变）

- 权威：遍历 `sqlite_master` → `PRAGMA foreign_key_list` → 比较 `table`（小写、去 schema 前缀）；覆盖普通/引号/方括号/反引号/大小写/`main.` 限定/转义/表级复合 FK。
- 双保险：保守文本扫描（去注释与字符串字面量），`True` 或 `None` 均判停止。
- **任何入向引用 → 停止**：不 DROP、不 RENAME、不建 `__new`、写 `system_events(schema_diff)`、不写 success。
- 出向外键**不构成**放行理由。M27–M32 不变。

---

## 7. 系统故障与 `fresh()` 隔离（不变）

```sql
valid INTEGER NOT NULL CHECK (valid IN (0,1)),
CHECK (valid = 0 OR (mode = 'mihomo' AND failure_source IS NULL))
```

有效 pass/fail 为 `valid=1`（唯一健康证据源）；engine/scheduler/system/target_incident 与 TCP-only 为 `valid=0`（可写、不参与健康、不入链、不推进恢复、不影响 TTL 内新鲜 pass）。`latest_valid()` 只取 `valid=1`。SF1–SF7 不变。

**与 §3.4 的衔接**：`target_results` 禁 `REPLACE`、禁 `DO NOTHING`——证据行只 `INSERT`，重复即错误。

---

## 8. C18 / C19（边界，仍待确认）

**C18**：TCP-only 允许写 `target_results`（`mode='tcp_only'`、`valid=0`）；禁止参与健康达标、失败链、恢复确认、发布资格。未确认。
**C19**：单开关 `cutover_at`；连续 3 次成功产出后才切；旧表停写与新表启用同事务；失败回滚开关、新数据标 `pre_cutover`、不删旧表。未确认。

---

## 9. DDL 摘要（本轮无新增对象）

本轮**未新增**表或触发器；`nodes` 仍为 7 个触发器（六个关系 + `trg_nodes_delete_guard`）。改动仅在语义层：`nodes` 禁用 UPSERT（代码契约）、`trg_nodes_delete_guard` 的实测边界并入 §3.4.7。示例 SQL 的字段仅使用已确认列（`id`、`airport_id`、`fingerprint`、`status`、`fail_count`）+ 本轮新增列（`identity_id`、`config_version`）。

---

## 10. v1.5 → v1.6 修订对照

| # | v1.5 | v1.6 | 章节 |
| --- | --- | --- | --- |
| P0-1 | 允许 `nodes` 用 `DO UPDATE` 更新普通字段 | 新增 I6；四情形表（C1–C4）；`nodes` **禁 UPSERT**，唯一入口 `upsert_node_identity_aware`（`BEGIN IMMEDIATE` + 读比对 + CAS）；身份/版本冲突显式抛错；变化走 `open_config_version` + 显式 UPDATE；并发与事务边界表；R1–R9 | §3.4 |
| P0-2 | "OFF 时 `foreign_key_check` 返回空"（错误） | 更正为独立诊断、OFF 仍检测（实测 2 行）；`foreign_keys` 仅控执行、事务内 no-op（实测）；阶段 A/B/C 重排，预提交与 COMMIT 后两次检查；COMMIT 后失败=备份恢复流程；伪代码去 `assert`、显式异常 + `sys.exit` | §4.1、§4.4–§4.6 |
| P0-3 | R2/R3 只查节点行；连接契约无分型、无写前复检 | R 组补五张子表 + 六项字段快照；五类连接契约表；`write_guard` 每次写入前复检 + 拒绝而非自愈；CV1–CV5 跨组测试；FK10–FK15 | §3.4.6、§4.2–§4.3、§4.7 |
| P1 | 用 `last_seen`、`REPLACE INTO nodes(id=5,...)` | 删除未定义字段；REPLACE 改标准列清单 + `VALUES`；伪代码显式标注；附录 A 语法核对（8 条语句实测结果） | §3.4.3、附录 A |

---

## 11. 关闭证明

### 11.1 P0-1（nodes UPSERT 身份冲突）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 冲突时比较现存与 incoming 的 identity/cv | §3.4.3 伪代码 | R6/R7 | 已关闭 |
| 仅完全一致才允许普通字段更新 | §3.4.3 C2 | R4 | 已关闭 |
| 不一致显式失败或进正式流程 | §3.4.3/§3.4.4 | R6/R7/R8 | 已关闭 |
| 不静默保留旧身份 | §3.4.1 实测 + R-1..R-5 | R6（反证）/R7 | 已关闭 |
| 不借 UPSERT 偷渡身份迁移 | §3.4.4 | R8 | 已关闭 |
| 配置变化的正式流程 | §3.4.4（`open_config_version` + 显式 UPDATE） | R8 | 已关闭 |
| 可执行 SQL/伪代码 + 竞态处理 | §3.4.3/§3.4.5 | R9 | 已关闭 |
| 并发唯一性与事务边界 | §3.4.5（IMMEDIATE + CAS + UNIQUE 兜底） | R9 | 已关闭 |
| 五条新增测试 | §3.4.6 R4/R6/R7/R8/R9 | — | 已关闭 |

### 11.2 P0-2（`foreign_key_check` 与迁移顺序）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| `foreign_key_check` 不因 OFF 返回空 | §4.1 + 实测 | FK10/FK11 | 已关闭 |
| `foreign_keys` 仅控约束执行 | §4.1 | FK10 | 已关闭 |
| 事务内切换无效 | §4.1 实测 | FK12 | 已关闭 |
| 两者不混为一谈 | §4.1 表述 + §4.4 两次检查 | — | 已关闭 |
| 事务前三项前置（建连读回、停写、必要时事务外关 FK） | §4.4 A1–A5 | FK8 | 已关闭 |
| 事务内：DDL→回填→断言→预提交检查→违规即回滚 | §4.4 B6–B11 | FK13 | 已关闭 |
| COMMIT 后：恢复→读回→终检→断言→才写 success | §4.4 C12–C16 | FK7/FK14 | 已关闭 |
| COMMIT 后失败给出可执行恢复 | §4.6 八步 | FK14 | 已关闭 |
| 伪代码顺序与文字一致 | §4.5 | — | 已关闭 |
| 不用 `assert` 作唯一保护、非零退出 | §4.5 硬规则 | FK15 | 已关闭 |

### 11.3 P0-3（档案测试与连接契约）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| R2/R3 补四张子表关联不变 | §3.4.6 不变项表 | R2/R3 | 已关闭 |
| 原 identity/cv/fingerprint/created_at 不变 | 同上 | R2/R3 | 已关闭 |
| 五类连接契约 | §4.2 | CV1/CV4 | 已关闭 |
| 两 PRAGMA 同时满足才可写 | §4.2 规则 1 | CV1 | 已关闭 |
| 迁移连接窗口内调整、业务停写 | §4.2/§4.4 A3 | CV4 | 已关闭 |
| 迁移后新连接/池/重连重新设置并读回 | §4.2 规则 3 | CV5 | 已关闭 |
| 不把"初始化开过"等于"一直在" | §4.3 | CV3 | 已关闭 |
| 外部改 PRAGMA 后能被发现并拒绝 | §4.3 `write_guard` | CV3/FK8 | 已关闭 |

---

## 12. 测试矩阵（更新）

| 组 | 数量 | 范围 |
| --- | --- | --- |
| 身份 I | 30 | I1–I30 |
| 状态机 S | 34 | S1–S34 |
| 任务 T | 14 | T1–T14 |
| 有效性 V | 4 | V1–V4 |
| 并发 CT | 3 | CT1–CT3 |
| 约束 FT | 23 | FT1–FT23 |
| 令牌 F | 22 | F1–F22 |
| 令牌 FK 父键 | 5 | FKA1–FKA5（自 v1.6 起改前缀，消除与连接组冲突） |
| 发布 P | 14 | P1–P14 |
| 轮询 RP | 12 | RP1–RP12 |
| 零健康 Z | 30 | Z1–Z30 |
| 失败链 FE | 19 | FE1–FE19 |
| 恢复 RG | 24 | RG1–RG24 |
| 系统故障 SF | 7 | SF1–SF7 |
| verdict TV | 4 | TV1–TV4 |
| A 路径关系 A | 10 | A1–A10 |
| **REPLACE/UPSERT R** | **9** | **R1–R9（v1.6 扩至 9）** |
| **连接契约/迁移验证 FK** | **15** | **FK1–FK15** |
| **跨组 CV** | **5** | **CV1–CV5** |
| 迁移 M | 32 | M1–M26 + M27–M32 |

---

## 13. 依赖关系图（不变）

```
airports ──> node_identities ──> node_config_versions
                 ├──> identity_stable_ids / identity_config_pending / identity_presence_log
                 └──> nodes.identity_id + nodes.config_version
                          ├── uq_nodes_id_identity / idx_nodes_identity
                          ├── 6 个关系触发器 + trg_nodes_delete_guard
                          ├──> node_target_state / node_state_history
                          ├──> node_id_reservations ──> restore_authorizations
                          ├──> detection_tasks ──> detection_task_runs ──> target_results
                          └──> （状态回填 步 14）
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
| 1 | 有人绕过入口直接 UPSERT，身份静默漂移 | L1 门禁（扫 `nodes` 写入路径的 `ON CONFLICT`）+ 唯一写入口 + 事件审计 | R6（反证）/R7 |
| 2 | `recursive_triggers=OFF` 连接 REPLACE 替换档案 | `write_guard` 拒绝该类连接业务写入；L1 门禁；L4 巡检 | CV1/CV2 |
| 3 | 基准代码已有 REPLACE/UPSERT 写法 | §3.7.4（v1.5）审查清单 + 本轮的"不得静默改语义" | P1 审查报告 |
| 4 | 迁移 COMMIT 后才发现违规 | 阶段 C 备份恢复（§4.6）；业务写入保持关闭；不写 success | FK14 |
| 5 | `assert` 被 `-O` 移除导致漏检 | 全部改显式异常 + `sys.exit` | FK15 |
| 6 | `trg_ident_del` 引用清单漏 P1+ 新表 | 硬规则 + §3.3 自洽断言 | FK9 |
| 7 | 示例 SQL 用未定义字段 | 附录 A 语法核对；仅用已确认列 | 附录 A |
| 8 | C-2 误停导致迁移中断 | 误停只影响单表，事件给快照 | M30/M32 |

---

## 附录 A：可执行 SQL 语法核对结果（本轮实测）

**核对环境**：`/tmp` 沙箱最小复刻库（仅含已确认列：`nodes(id, airport_id, fingerprint, status, fail_count)` + 新增 `identity_id/config_version`；`airports`、`node_identities`、`node_config_versions`、`node_state_history`、`target_results`、`detection_tasks`、`node_id_reservations`、`identity_*`）。**未使用、未触碰仓库代码与生产库**。复刻库列少于生产，故"通过"仅证明语法与触发器语义，不证明生产 DDL 兼容。

| # | 语句（可执行 SQL） | 结果 |
| --- | --- | --- |
| 1 | `INSERT INTO nodes(airport_id,fingerprint,identity_id,config_version,status,fail_count) VALUES (1,'F1',10,1,'unknown',0)` | **OK** |
| 2 | `INSERT OR REPLACE INTO nodes(airport_id,fingerprint,identity_id,config_version,status,fail_count) VALUES (1,'F1',10,1,'available',0)` | **ABORT `node archive delete forbidden`**；id 仍 1；历史 1 行/结果 1 行不变 |
| 3 | `REPLACE INTO nodes (id, airport_id, fingerprint, identity_id, config_version, status, fail_count) VALUES (1, 1, 'F2', 10, 1, 'unknown', 0)` | **ABORT**；id=1、fingerprint 仍 `F1` |
| 4 | `UPDATE nodes SET status='available', fail_count=0 WHERE id=? AND identity_id=10 AND config_version=1` | **OK**；`rowcount=1`；id 不变 |
| 5 | `UPDATE nodes SET config_version=9 WHERE id=?` | **ABORT `nodes identity relation invalid after update`** |
| 6 | `INSERT INTO nodes(...11,1...) ON CONFLICT(airport_id,fingerprint) DO UPDATE SET status=excluded.status`（身份 11 vs 现存 10） | **OK 且身份仍 10**（缺陷实证，故禁 UPSERT） |
| 7 | 同身份 UPSERT：`... VALUES (1,'F1',10,1,'available',0) ON CONFLICT(...) DO UPDATE SET status=excluded.status, fail_count=excluded.fail_count` | **OK**；id=1、identity=10、cv=1、status=`available` |
| 8 | 跨机场：`INSERT INTO nodes(airport_id,fingerprint,identity_id,config_version) VALUES (1,'F9',20,1)` | **ABORT `nodes identity relation invalid`** |
| 9 | `UPDATE nodes SET airport_id=2 WHERE id=?` | **ABORT ... after update** |
| 10 | `DELETE FROM node_config_versions WHERE identity_id=10 AND config_version=1` | **ABORT `config_version still referenced by nodes`** |
| 11 | `DELETE FROM node_identities WHERE identity_id=10` | **ABORT `identity still referenced`** |
| 12 | `DELETE FROM nodes WHERE id=1`（已回填） | **ABORT `node archive delete forbidden`** |
| 13 | `PRAGMA foreign_key_check`（`foreign_keys=OFF`，库内有 2 处违规） | **返回 2 行**：`('nodes',7,'airports',0)`、`('node_identities',30,'airports',0)` |
| 14 | 同数据，`foreign_keys=ON` | **返回同样 2 行** |
| 15 | `BEGIN; PRAGMA foreign_keys=OFF;` 读回 | **仍为 1**（事务内 no-op） |
| 16 | `PRAGMA recursive_triggers=OFF` 下 `INSERT OR REPLACE`（节点无子行） | **OK，id 1→2**（档案被替换，证明 L3 失效场景） |
| 17 | `recursive_triggers=OFF` + `foreign_keys=OFF` + 有子行 → `INSERT OR REPLACE` | **OK，nodes id=2，历史 `node_id=1` 悬空**（孤儿实证） |

**结论**：所有标注"可执行"的示例均通过语法解析；标注为伪代码的 Python 块单独标注、不与 SQL 混排；`last_seen` 等未定义字段已从示例中清除（基准 `nodes` 无此列，若将来确需新增，必须先在设计中给出 DDL + 迁移方式 + 兼容说明，本轮不引入）。

---

**v1.6 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未修改生产配置或生产数据**；仅修订四项问题，并在 `/tmp` 一次性沙箱库中做了语法与触发器语义核对（不影响仓库与生产）。**C11–C20 全部未确认，C12 未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
