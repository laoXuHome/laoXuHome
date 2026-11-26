# NodePoolME 新架构总体设计方案 v1.7

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.6
**本轮性质**：纯设计修订。**未修改代码、未修改数据库、未创建迁移文件、未执行 P-1/P0、未修改生产配置或生产数据。**
**本轮范围**：四项——迁移备份顺序与一致性、COMMIT 后失败恢复统一、配置变化的 fingerprint/config_version 闭环、档案测试子表覆盖与 IdentityConflict 审计持久化。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）

---

## 修订索引（v1.6 → v1.7）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | 备份改到"停写并排空之后"，明确一致性备份方法与验证 | §4.1、§4.2 | 修正 |
| P0-2 | COMMIT 后所有失败统一走同一恢复函数，禁 `sys.exit` 绕过清理 | §4.3 | 修正 |
| P0-3 | 配置变化原子流程：fingerprint + config_version + 节点当前记录同步 | §3.5 | 补齐 |
| P1-1 | R2/R3 四张子表建真实关联；IdentityConflict 独立事务审计 | §3.6、§3.7 | 补齐 |

未修订：Q1–Q12、六个关系触发器判定逻辑（仅按 P0-3 需要把 `fingerprint` 纳入 `UPDATE OF` 列表并加一条等值条件，见 §3.5.3）、`trg_nodes_delete_guard`、"A 路径部分完整性、不等价 B"、C12 未确认且默认 A、C-2 的 `PRAGMA foreign_key_list` 入向检查与"任何入向即停"、17 步主序号、`valid=0` 隔离、30 天 missing、per-node 30 分钟 + 抖动、业务 90 分钟、测速 17:00–24:00 与 50MB、骤减双条件、零健康保护、30 个版本、Q11 两次成功间隔 ≥30 分钟、TCP-only 无生产资格、四格式兼容、评分算法、前端布局。**C11–C20 全部未确认。**

---

## 0. 本轮修的是什么

| # | v1.6 的写法 | 缺陷 |
| --- | --- | --- |
| P0-1 | §4.4 先 `take_backup()`，后 `business_writes_stopped()` | 备份时可能仍有写入与活动事务 → 备份不是一致快照，恢复基线不可信 |
| P0-2 | 恢复失败分支 `sys.exit(2)`；`foreign_key_check` 失败直接恢复备份但未先关连接 | 退出绕过清理；在旧连接仍打开时替换文件；两处失败路径不一致 |
| P0-3 | §3.4.4 只写"更新 `nodes.config_version`" | 漏更新 `nodes.fingerprint` → 节点当前记录与版本表不一致；新指纹再到达时会误入 C1 新建重复节点 |
| P1-1 | R2/R3 子表可能为空；`IdentityConflict` 只"记事件"未定义事务 | 空表行数相等不能证明保护有效；事件若与被回滚事务同库同事务会一起消失 |

v1.7 的四句话：**先停写、再排空、才备份；COMMIT 之后只有一条失败路径；改配置必须同时改指纹；审计事件必须活在另一个事务里。**

---

## 1. 保留的既定设计（摘要）

Q1–Q12 全部保留；指纹算法不改；身份与生命周期原则不改；30 天 missing；per-node 30 分钟 + 抖动；业务 90 分钟独立；测速 17:00–24:00 与 50MB；骤减双条件 + 两次独立确认；零健康最多留上一版 24h、硬上限 72h；30 个版本；Q11 两次有效 Mihomo 成功间隔 ≥30 分钟；TCP-only 无生产健康资格；四格式 / 四 URL / UA / Token / 两种 `sub_publish`；机场排除；评分算法；前端布局不重做。

A 路径：不重建 `nodes`，六个关系触发器 + `trg_nodes_delete_guard`（共 7 个），**部分引用完整性，不等价于 B**；B 需 C12 批准（**未确认**）。

**v1.6 已定稿且本轮不改的部分**（完整文本见 v1.6 对应章节）：

| 内容 | v1.6 位置 | 本轮 |
| --- | --- | --- |
| `node_identities` / `node_config_versions` DDL、索引 | §3.2 | 不改 |
| `trg_nodes_rel_ins` / `trg_ident_del` / `trg_cv_del` / `trg_ident_airport_upd` / `trg_cv_pk_upd` | §3.2 | 不改 |
| `trg_nodes_rel_upd` | §3.2 | **仅扩列清单 + 一条等值条件**（§3.5.3） |
| `trg_nodes_delete_guard` | §3.2 | 不改 |
| `nodes` 禁 UPSERT、`upsert_node_identity_aware` 四情形 | §3.4 | 不改 |
| `foreign_key_check` 语义、连接五类型、`write_guard` | §4.1–§4.3 | 不改（本轮细化备份与恢复） |
| C-2 入向引用判定、M27–M32 | §6 | 不改 |
| `valid=0` 隔离、SF1–SF7 | §7 | 不改 |
| 17 步主迁移序号 | §5 | 不改（仅在阶段 A/B/C 内部细化） |

---

## 2. P0-1：迁移备份的顺序与一致性

### 2.1 新的阶段 A 顺序（严格串行，前一步不成立则中止）

| 序 | 动作 | 判定 | 失败处理 |
| --- | --- | --- | --- |
| A1 | 进入 `maintenance` 模式，**拒绝新的业务写入** | 写入入口一律返回 503 | 中止，不备份 |
| A2 | 停止后台写入任务：调度、检测执行、测速、发布构建、结果落库 | 各任务状态为 `stopped`（不接受"正在收尾"当作已停） | 中止 |
| A3 | 排空所有活动写事务；关闭/隔离业务写入连接池及其他写入连接 | 每个连接 `in_transaction == False`；池已关闭或标记 `quarantined` | 中止 |
| A4 | **验证确实没有活动写事务** | 见 §2.3 三项检测，全过才继续 | 中止 |
| A5 | 创建一致性备份（§2.2） | 备份文件存在且大小非 0 | 中止 |
| A6 | 验证备份：可打开、`quick_check`=`ok`、`foreign_key_check`（在**恢复 ON 的连接**上）、SHA256、行数基线、Schema 基线 | 全过 | 删除半成品备份，中止 |
| A7 | 迁移专用连接建连 + 两 PRAGMA 读回 + C-1/C-2 预检 | 全过 | 中止 |
| A8 | 允许进入迁移事务（`BEGIN IMMEDIATE`） | — | — |

**与 v1.6 的差别**：备份（A5）从"最先"移到"停写排空验证之后"；A6 的备份验证独立成步；A7 移到备份之后——因为 PRAGMA 检查若失败，没必要先做备份。

### 2.2 一致性备份方法

**首选（P1 采用）**

| 方式 | 说明 | 适用 |
| --- | --- | --- |
| **`sqlite3` Backup API**（`conn.backup(target)`） | 在线一致性快照；不受 WAL 影响；不阻塞读；写入停止后使用最稳 | **默认** |
| **`VACUUM INTO '<path>'`** | 单条 SQL 生成紧凑一致副本；需目标不存在；不能在事务内执行；需足够磁盘空间 | 备选（空间充足时） |

```sql
-- 方式二：可执行 SQL（在事务外、停写后执行）
VACUUM INTO '/backup/nodepool-20261126T120000Z.db';
```

**两者都必须满足的前提**：A1–A4 已完成（否则快照仍可能包含在途写入的中间状态）。

**文件级备份（仅当无法使用上述两种方式时）——必须全部满足的条件**

| 条件 | 要求 |
| --- | --- |
| C-1 连接关闭 | 所有数据库连接（应用池、后台、迁移前置、CLI）均已 `close()`；进程内无任何持有句柄 |
| C-2 checkpoint | 用新连接执行 `PRAGMA wal_checkpoint(TRUNCATE)`，返回值三列必须是 `(0, N, N)`（busy=0）；再读回 `PRAGMA journal_mode` 与文件大小 |
| C-3 辅助文件 | `-wal` 大小必须为 0 字节；`-shm` 允许存在但不得被复制为"数据源"；不得存在 `-journal`（存在说明有未完成回滚） |
| C-4 同一快照 | 在"所有连接已关闭 + checkpoint 成功 + `-wal`=0"的前提下，`db` 文件本身即为完整状态；**此时不需要**同时复制 `-wal`/`-shm`。若 `-wal` 非 0 却要复制，则该方案**不成立**，必须回退到 Backup API |
| C-5 校验 | 复制后用新连接打开副本：`quick_check`=`ok`、行数基线、`sha256` 记录 |
| C-6 恢复时防旧连接 | 见 §4.3 步骤 2–3：替换前关闭全部连接并递增"连接纪元(epoch)"；恢复后新建池；旧池对象不得复用 |

**明令禁止**："直接 `cp db db-wal db-shm` 三件套"而不做 C-2/C-3/C-4 的验证——三文件非原子拷贝无法保证属于同一时点。

### 2.3 A4 的"无活动写事务"检测（三选二即可，至少两项）

| 检测 | 方法 | 通过条件 |
| --- | --- | --- |
| D1 连接级 | 逐条检查已知连接对象的 `in_transaction` | 全为 False |
| D2 池级 | 池的 `checked_out` 计数、`active` 计数 | 全为 0 |
| D3 库级（只读探测） | 新连接 `BEGIN IMMEDIATE` 后立即 `ROLLBACK`（拿不到写锁说明有写者；能拿到说明写者已清零） | 能立即取得写锁 |

D3 是最有力的证据：SQLite 单写者模型下，若还有活动写事务，`BEGIN IMMEDIATE` 会等待 `busy_timeout` 后失败。

### 2.4 测试（BA 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| BA1 | 业务写入未停（`maintenance` 未开） | 启动迁移 | **A1 中止**；未生成备份；库无变化 |
| BA2 | `maintenance` 已开，但一个后台任务仍持写事务 | 启动迁移 | **A4 中止**（D1/D3 报"有写者"）；未生成备份 |
| BA3 | 备份被截断（写入 0 字节后改名） | A6 校验 | **中止**；删除该备份；不进入事务 |
| BA4 | 备份内容不完整（构造缺表副本） | `quick_check` 或 Schema 基线比对 | **中止** |
| BA5 | WAL 模式，停写后备份 → 迁移失败 → 恢复备份 | 恢复后核对已提交数据 | **恢复前的已提交数据全部存在**（行数与业务主键集合等于基线） |
| BA6 | 恢复完成 | 校验 | SHA256 == 基线；行数 == 基线；`quick_check`=`ok`；`foreign_key_check` 0 行 |

---

## 3. P0-2：COMMIT 之后的统一失败路径

### 3.1 COMMIT 是不可逆边界

| 阶段 | 失败后的动作 | 能否回滚事务 |
| --- | --- | --- |
| 预提交（BEGIN 之后、COMMIT 之前） | `ROLLBACK` | **能**，库回到迁移前状态 |
| COMMIT 之后 | **只能**从备份恢复 | **不能**；任何"回滚"表述都是错误 |

两条路径必须分开定义（任务书 P0-2 要求），下表即定义：

| 失败点 | 处理函数 | 结果 |
| --- | --- | --- |
| A1–A7（阶段 A） | `abort_before_tx(reason)` | 不建事务；库不变；退出码非零 |
| B6–B11（阶段 B，含预提交 `foreign_key_check`） | `rollback_tx(reason)` | `ROLLBACK`；库回迁移前；退出码非零 |
| C12–C16（阶段 C，含 PRAGMA 恢复失败） | `handle_post_commit_failure(reason)` | **备份恢复**；不写 success；业务写入保持关闭；退出码非零 |
| 恢复流程自身失败 | `handle_post_commit_failure` 内部 `abort_recovery()` | 保持停写；进程非零退出；**不尝试边修边运行** |

### 3.2 `handle_post_commit_failure` 的九步（唯一入口）

| 步 | 动作 | 断言 |
| --- | --- | --- |
| 1 | 保持 `maintenance`（业务写入继续拒绝） | 写入入口 503 |
| 2 | 关闭迁移连接、应用连接池、后台任务连接、CLI 连接；池标记 `dead` | 无任何连接对象处于打开态 |
| 3 | 确认无残留连接或活动事务（D1/D2/D3 三项全过；D3 必须能立即拿到写锁） | 拿不到写锁 → 恢复中止（步骤 9） |
| 4 | 替换 `db` 与必要辅助文件：先删现存 `-wal`/`-shm`，再放入备份 `db`（备份由 §2.2 方式产生，本身自洽） | 文件 SHA256 == 备份 SHA256 |
| 5 | 新建连接（`create_connection`），设置并读回两 PRAGMA | `foreign_keys=1`、`recursive_triggers=1` |
| 6 | `quick_check`、`foreign_key_check`、§3.3 六条关系断言 | 全过 |
| 7 | 与备份基线比对：SHA256、行数、Schema 基线、触发器计数 | 全一致 |
| 8 | 写 `system_events(migration_rollback, reason, backup_sha256, attempt_ts)`；**不写** `schema_migrations(success)` | 事件存在；success 不存在 |
| 9 | 进程非零退出（`sys.exit(3)`）；业务写入**保持关闭**，等待人工确认 | 退出码 3；写入仍 503 |

**硬规则（本轮新增）**

1. **不得在旧连接仍打开时替换数据库文件**（步骤 2–3 是硬前置）；
2. **不得把 COMMIT 后的失败描述为事务回滚**；
3. **备份恢复失败时不得尝试边修边运行**——只能保持停写 + 非零退出 + 人工介入；
4. `sys.exit()` **只能出现在步骤 9 之后**（即清理、恢复、事件记录全部完成之后），任何更早的 `sys.exit` 都视为设计违规；
5. 恢复失败（步骤 3/4/6/7 任一不过）→ 走 `abort_recovery()`：不删备份、不改文件、写入保持关闭、`sys.exit(4)`、`system_events(migration_recovery_failed)`。

### 3.3 伪代码（与 §3.1/§3.2 逐条对齐；标注：伪代码）

```python
# 伪代码：结构示意，非最终实现
def migrate(db_path):
    # —— 阶段 A ——
    try:
        enter_maintenance()                          # A1
        stop_background_writers()                    # A2
        drain_and_close_write_connections()          # A3
        require_no_active_writers()                  # A4（D1/D2/D3）
        backup = consistent_backup(db_path)          # A5（Backup API / VACUUM INTO）
        verify_backup(backup)                        # A6
        conn = open_migration_conn(db_path)          # A7
    except Exception as e:
        abort_before_tx(e)                           # 不建事务，库不变，非零退出
    need_fk_off = c2_needs_fk_off(conn)
    try:
        if need_fk_off:
            conn.execute("PRAGMA foreign_keys=OFF")  # 事务外
        conn.execute("BEGIN IMMEDIATE")              # A8 / B6
        try:
            apply_ddl(conn); backfill(conn)          # B7/B8
            assert_relations(conn)                   # B9
            if conn.execute("PRAGMA foreign_key_check").fetchall():
                raise PreCommitCheckFailed()         # B10
            assert_counts_and_triggers(conn)         # B11
            conn.execute("COMMIT")
        except Exception as e:
            conn.execute("ROLLBACK")
            rollback_tx(e)                           # 预提交失败：能回滚
    except Exception:
        pass                                          # 落到阶段 C 处理
    # —— 阶段 C：任何失败都走同一入口 ——
    try:
        restore_fk(conn)                              # C12：事务外 ON + 读回
        if read(conn, "foreign_keys") != 1:
            raise PostCommitVerifyFailed("fk_readback")
        if conn.execute("PRAGMA foreign_key_check").fetchall():
            raise PostCommitVerifyFailed("fk_check")   # C13
        assert_relations(conn)                        # C14
        assert_counts_and_triggers(conn)
    except Exception as e:
        handle_post_commit_failure(db_path, backup, e)   # 九步；内部只在此退出
    write_schema_migration_success(conn)              # C15：只在全绿之后
    enable_business_writes()                          # C16
```

**注意**：`handle_post_commit_failure` 是阶段 C **唯一**退出点；它内部不调用 `sys.exit` 直到九步走完。

### 3.4 测试（RC 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| RC1 | 迁移进入阶段 C | 注入"恢复 `foreign_keys=ON` 失败" | 走九步；备份恢复；无 success；退出码 3；写入仍关闭 |
| RC2 | 同上 | 注入"COMMIT 后 `foreign_key_check` 违规" | 同上 |
| RC3 | 同上 | 注入"关系断言复跑失败" | 同上 |
| RC4 | 同上，但故意保留一条打开连接 | 执行恢复 | **步骤 3 检测失败**，拒绝替换文件（`abort_recovery`，退出码 4），备份文件未被改 |
| RC5 | 恢复成功 | 检查库与开关 | 无 `schema_migrations(success)`；业务写入仍 503 |
| RC6 | 恢复过程本身失败（备份文件损坏） | — | 退出码 4；写入仍关闭；备份原样保留；`migration_recovery_failed` 事件存在 |

---

## 4. P0-3：配置变化的原子闭环

### 4.1 三种变化的语义边界（必须先分清）

| 情形 | `stable_id` | fingerprint | identity | config_version | 正确路径 |
| --- | --- | --- | --- | --- | --- |
| **配置内容变化** | 不变 | **改变** | **不变** | **递增** | §4.3 原子流程 |
| **稳定身份变化** | 改变 | 改变 | **新 identity** | 从 1 开始 | 新 identity 落库 → 新 `(airport_id,fingerprint)` 键 → C1 插入新行 |
| **同 fingerprint 不同 identity** | — | 相同 | 不同 | — | **`IdentityConflict`，拒绝**（§3.4，v1.6 已定） |

**禁止的推论**："fingerprint 变了"不等于"identity 变了"。fingerprint 是 `stable_id + 配置摘要` 的合成，配置变也会让它变；是否有新身份只看 `stable_id`。

### 4.2 为什么必须同时更新 `nodes.fingerprint`

`nodes.(airport_id, fingerprint)` 是唯一键，也是"这台机器现在是什么配置"的当前事实。若只改 `config_version` 不改 `fingerprint`，会出现：

1. `nodes` 声称指纹 A，而 `node_config_versions` 里 `(identity, N)` 记录指纹 B → **当前记录与版本表不一致**（违反 I3 的完整含义与 I6）；
2. 下一次抓取到指纹 B 的节点，按 `(airport_id, B)` 查不到行 → 误入 **C1 新增** → 同机重复建档、历史割裂。

### 4.3 原子流程（同一事务；可执行 SQL + 伪代码）

**前置**：`new_fingerprint = fingerprint(stable_id, new_config)` 由**现有指纹算法**计算（算法不改，Q3）。

**可执行 SQL（事务内按序执行）**

```sql
-- ① 读当前事实（IMMEDIATE 事务内）
SELECT id, identity_id, config_version, fingerprint
  FROM nodes WHERE id = :node_id;

-- ② 占用检查：新指纹是否已被其他节点占用
SELECT id FROM nodes
 WHERE airport_id = :airport_id AND fingerprint = :new_fingerprint AND id <> :node_id;

-- ③ 新版本行
INSERT INTO node_config_versions
       (identity_id, config_version, fingerprint, change_reason, opened_at)
VALUES (:identity_id, :next_cv, :new_fingerprint, 'config_change', :now);

-- ④ 同步节点当前记录（fingerprint 与 config_version 同一语句）
UPDATE nodes
   SET fingerprint = :new_fingerprint,
       config_version = :next_cv
 WHERE id = :node_id
   AND identity_id = :identity_id
   AND config_version = :old_cv;

-- ⑤ 关闭旧版本
UPDATE node_config_versions
   SET closed_at = :now
 WHERE identity_id = :identity_id AND config_version = :old_cv;
```

**伪代码（标注：伪代码）**

```python
# 伪代码
def apply_config_change(conn, node_id, new_config):
    new_fp = fingerprint(stable_id_of(node_id), new_config)   # 现有算法，不改
    with immediate_tx(conn):
        row = conn.execute("SELECT id, identity_id, config_version, fingerprint FROM nodes WHERE id=?", (node_id,)).fetchone()
        if row is None: raise NodeNotFound(node_id)
        _, identity_id, old_cv, old_fp = row
        if new_fp == old_fp:
            return "no_change"                                 # 配置未实质变化
        taken = conn.execute("SELECT id FROM nodes WHERE airport_id=? AND fingerprint=? AND id<>?",
                             (airport_id_of(node_id), new_fp, node_id)).fetchone()
        if taken: raise FingerprintTaken(taken[0])             # ⑥ 整事务失败
        next_cv = conn.execute("SELECT COALESCE(MAX(config_version),0)+1 FROM node_config_versions WHERE identity_id=?",
                               (identity_id,)).fetchone()[0]
        conn.execute("INSERT INTO node_config_versions(identity_id,config_version,fingerprint,change_reason,opened_at) "
                     "VALUES (?,?,?,'config_change',?)", (identity_id, next_cv, new_fp, now()))
        changed = conn.execute("UPDATE nodes SET fingerprint=?, config_version=? WHERE id=? AND identity_id=? AND config_version=?",
                               (new_fp, next_cv, node_id, identity_id, old_cv)).rowcount
        if changed != 1: raise ConcurrentModification(node_id) # ⑦ 回滚，不半完成
        conn.execute("UPDATE node_config_versions SET closed_at=? WHERE identity_id=? AND config_version=?",
                     (now(), identity_id, old_cv))
        return "upgraded"
```

**第 ④ 步的 `WHERE ... AND config_version = :old_cv` 是 CAS**：并发下若别人已推进版本，`rowcount=0` → 抛错 → 整个事务回滚，不会出现"两条版本行都开着但节点指向其中一个"的半完成态。

### 4.4 逐条回答任务书九问

| # | 问题 | 答案 |
| --- | --- | --- |
| 1 | 新 fingerprint 如何生成 | 现有指纹算法，输入 `stable_id + new_config`（算法不改） |
| 2 | 新版本记录如何创建 | ③ `INSERT node_config_versions(identity_id, next_cv, new_fp, ...)`，`next_cv = MAX(cv)+1`（同 identity 内） |
| 3 | `nodes.fingerprint` 如何同步 | ④ 与 `config_version` **同一条 UPDATE** 写 |
| 4 | `nodes.config_version` 如何同步 | 同上（同一语句） |
| 5 | `(airport_id,fingerprint)` 唯一约束如何保证 | 先 ② 预检 + `UNIQUE` 兜底；预检与写入同事务，无窗口 |
| 6 | 新 fingerprint 已被其他节点占用 | `FingerprintTaken` → **整事务失败**，库不变；交人工（可能是重复抓取或指纹碰撞，不得自动合并） |
| 7 | 失败如何避免半完成 | 单事务；任一步抛错 → `ROLLBACK`，新版本行与 nodes 更新同时消失；④ 的 CAS 防并发 |
| 8 | 原 `id` / identity / 历史如何保留 | ①②③④ 均不触碰 `nodes.id`、`nodes.identity_id`；四张子表只引用 `node_id`，不受影响 |
| 9 | 更新后 I1–I6 是否成立 | 见下表逐条核对 |

**I1–I6 复核（升级完成后）**

| 不变式 | 核对 |
| --- | --- |
| I1 两列非空 | `identity_id` 不变（非空），`config_version=next_cv`（非空） |
| I2 机场一致 | `airport_id` 未改；identity 的 airport 未改 |
| I3 版本存在 | ③ 已插入 `(identity_id, next_cv)` |
| I4 父删除保护 | 不受影响（守卫照旧） |
| I5 档案不可删 | `nodes.id` 未变，行未删 |
| I6 一指纹一身份一版本 | ② 保证新指纹未被占用；`identity_id` 未变；`config_version` 单值 |

### 4.5 触发器的最小修订（P0-3 的必要配套）

v1.6 的 `trg_nodes_rel_upd` 只监听 `airport_id, identity_id, config_version`，若有人**单独**改 `fingerprint`，关系不会被重验，就会出现"节点指纹与版本指纹不一致"。因此本轮对它做**两处最小修订**（判定结构不变，仅扩列 + 加一条等值条件）：

```sql
CREATE TRIGGER trg_nodes_rel_upd
BEFORE UPDATE OF airport_id, identity_id, config_version, fingerprint ON nodes
WHEN NEW.identity_id IS NULL OR NEW.config_version IS NULL
  OR NOT EXISTS (SELECT 1 FROM node_identities i
                  WHERE i.identity_id = NEW.identity_id AND i.airport_id = NEW.airport_id)
  OR NOT EXISTS (SELECT 1 FROM node_config_versions v
                  WHERE v.identity_id    = NEW.identity_id
                    AND v.config_version = NEW.config_version
                    AND v.fingerprint    = NEW.fingerprint)      -- 新增：指纹必须与版本行一致
BEGIN SELECT RAISE(ABORT,'nodes identity relation invalid after update'); END;
```

同理，插入触发器增加同一条指纹等值条件（`trg_nodes_rel_ins` 的 `WHEN` 中 `v.fingerprint = NEW.fingerprint`），否则新建节点可写入与版本行不一致的指纹。

**兼容性**：迁移步骤 4 写 `version=1` 时，`fingerprint` 直接复制自 `nodes.fingerprint`；步骤 5 回填 `identity_id/config_version` 时指纹未动 → 天然满足等值条件。因此不需要额外回填。步 5b 断言新增一条：`nodes.fingerprint` 与 `(identity_id,1)` 的 `fingerprint` 差异数 == 0。

### 4.6 测试（CF 组）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| CF1 | identity 10、cv=1、指纹 `F1`，节点 id=1，历史/结果各 1 行 | `apply_config_change`（新配置 → `F1b`） | 成功；`nodes.id` 仍 1；`fingerprint=F1b`、`config_version=2` |
| CF2 | 同 CF1 | 校验 | `nodes.fingerprint` 与 `(10,2)` 行指纹一致；`(10,1)` 有 `closed_at` |
| CF3 | 同 CF1 | 校验版本表 | 存在 `(10,1)` 与 `(10,2)` 两行；`(10,1)` 仍 `closed_at` 有值且不被删 |
| CF4 | 同 CF1 | 校验子表 | `node_state_history` / `target_results` 的 `node_id` 仍指向 1；行数不变 |
| CF5 | 另一节点 id=2 已占用 `F1b`（同机场） | `apply_config_change` → `F1b` | `FingerprintTaken`；**整事务失败**；`nodes`、版本表、子表全部不变 |
| CF6 | 同 CF1 | 在 ④ 之后注入异常 | 整个事务回滚：无 `(10,2)` 行；`nodes` 仍 `F1`/cv=1 |
| CF7 | 升级完成后（`F1b`, cv=2） | 用 `F1b` 执行 `upsert_node_identity_aware` | **命中 id=1**（走 C2），不新建节点；`nodes` 行数不变 |
| CF8 | 同 CF1 | 单独执行 `UPDATE nodes SET fingerprint='Fx' WHERE id=1`（无版本行） | **ABORT**（`trg_nodes_rel_upd` 的指纹等值条件） |

---

## 5. P1-1：档案保护测试与审计事件持久化

### 5.1 R2/R3 的强化前置

**测试夹具必须为非空**：操作前为**每张**子表插入至少一条指向被测节点的真实记录。

```sql
INSERT INTO node_state_history(node_id, at, status) VALUES (:nid, :t0, 'available');
INSERT INTO target_results(node_id, target, mode, valid, ts) VALUES (:nid, 'chatgpt', 'mihomo', 1, :t0);
INSERT INTO detection_tasks(node_id, rule_version, created_at) VALUES (:nid, 1, :t0);
INSERT INTO node_id_reservations(node_id, token, expires_at) VALUES (:nid, 'tok-1', :t0);
```

> 字段名以最终 DDL 为准；此处列名仅取设计中已确定的部分，实施时以 P0 DDL 为准（不得使用未定义列，见 v1.6 附录 A 的同类约束）。

**操作前后必须逐项比对（快照对象）**

| 对象 | 比对内容 |
| --- | --- |
| `nodes` | 行数；被删/被换的 `id` 是否仍存在；`id`、`identity_id`、`config_version`、`fingerprint`、`created_at`（若有）、`status`、`fail_count` 全字段快照 |
| `node_state_history` | 行数；`node_id` 集合；`(node_id, at, status)` 内容快照 |
| `target_results` | 行数；`node_id` 集合；`(node_id, target, ts)` 内容快照 |
| `detection_tasks` | 行数；`node_id` 集合；`(node_id, rule_version)` 内容快照 |
| `node_id_reservations` | 行数；`node_id` 集合；`(node_id, token)` 内容快照 |
| 全库 | `nodes` 总行数；`sqlite_master` 中触发器数量与名称集合 |

**判定**：任一对象不等于操作前快照 → 测试失败。**禁止**仅用"空表前后行数都是 0"证明。

### 5.2 `IdentityConflict` 的审计持久化

**关键约束**：审计事件**不能**与被回滚的节点写入共用同一事务——否则 `ROLLBACK` 会把事件一起抹掉。

| 步 | 动作 | 说明 |
| --- | --- | --- |
| 1 | 节点写入事务内检测到身份冲突（C3/C4） | 见 v1.6 §3.4.3 |
| 2 | **回滚该节点写入事务** | 先让写事务明确结束，避免审计写入被它的锁/状态牵连 |
| 3 | 用**独立连接、独立事务**写 `system_events` | 不与步骤 1 共用连接；`BEGIN IMMEDIATE` → `INSERT` → `COMMIT` |
| 4 | 事件字段 | `event='identity_conflict'`, `node_id`, `airport_id`, `fingerprint`, `current_identity_id`, `incoming_identity_id`, `current_config_version`, `incoming_config_version`, `reason`(枚举), `ts` |
| 5 | 审计写失败时 | **节点写入的失败结果不变**（仍抛 `IdentityConflict`）；审计失败单独记日志（`audit_write_failed`）；**绝不**因审计失败而接受冲突写入 |

**伪代码（标注：伪代码）**

```python
# 伪代码
try:
    with immediate_tx(conn):            # 节点写入事务
        ...                             # 检测冲突 → raise IdentityConflict
except IdentityConflict as e:
    rollback_scope(conn)                # 步骤 2：显式结束写事务
    try:
        with immediate_tx(audit_conn):  # 步骤 3：独立连接 + 独立事务
            audit_conn.execute("INSERT INTO system_events(event, node_id, airport_id, fingerprint, "
                               "detail_json, ts) VALUES ('identity_conflict',?,?,?,?,?)",
                               (e.node_id, e.airport_id, e.fingerprint, e.detail_json, now()))
    except Exception as audit_err:
        log_error("audit_write_failed", audit_err)     # 步骤 5：不改变主结果
    raise IdentityConflict(e)           # 仍然失败；不伪装成成功
```

**为什么必须独立事务**：SQLite 的 `ROLLBACK` 只回滚本事务。共用事务 = 事件随回滚消失，等于"审计不存在"；共用连接且不 commit = 事件被后续 `ROLLBACK` 波及。

### 5.3 测试（AU 组 + R 组补齐）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| AU1 | 节点 id=1（identity 10），四张子表各 1 行 | 走正式入口提交 identity 11 | 抛 `IdentityConflict`；`nodes` 全字段不变；四子表快照不变 |
| AU2 | 同 AU1 | 检查 `system_events` | **存在** 1 条 `identity_conflict`，字段含 current=10 / incoming=11 |
| AU3 | 审计连接被模拟为失败（注入 `OperationalError`） | 同上 | 节点仍拒绝（`IdentityConflict`），不写库；日志有 `audit_write_failed`；无 success 语义 |
| AU4 | 审计失败后重试同一次写入 | 再次提交 incoming 11 | 仍拒绝；不得因"上次审计没写成"而放行 |
| R2 | 节点 id=1 + 四子表各 1 行 | `INSERT OR REPLACE` 同键 | `ABORT node archive delete forbidden`；六类快照全等于操作前 |
| R3 | 同上 | `REPLACE INTO nodes (id, airport_id, fingerprint, identity_id, config_version, status, fail_count) VALUES (1, 1, 'F2', 10, 1, 'unknown', 0)` | `ABORT`；快照全等于操作前 |
| R10 | 同上（四子表非空） | `recursive_triggers=OFF` 的连接直接执行 `INSERT OR REPLACE` | **成功且档案被替换**（`id` 变化、子表 `node_id` 悬空）→ 证明 L2 契约（`write_guard` 拒写）是必需而非可选 |

---

## 6. 迁移顺序（17 步主序号不变，阶段 A/C 内部细化）

| 步 | 动作 | 阶段 | 本轮变化 |
| --- | --- | --- | --- |
| A1–A4 | maintenance → 停后台 → 排空关连接 → 验证无写者 | before-begin | **新增顺序，先于备份** |
| A5–A6 | 一致性备份 + 备份验证（sha256/行数/schema/quick_check） | before-begin | **移到停写之后** |
| A7 | 迁移连接 PRAGMA 读回 + C-1/C-2 预检 | before-begin | 移到备份之后 |
| A8/B6 | `BEGIN IMMEDIATE` | in-tx | 不变 |
| B7–B11 | DDL（步 2–13）→ 回填（3/4/5/14）→ 关系断言 → 预提交 `foreign_key_check` → 计数/触发器断言 | in-tx | 不变；步 5b 增"指纹等值"断言 |
| C12–C14 | 恢复 PRAGMA 读回 → 终检 `foreign_key_check` → 断言复跑 | after-commit | 统一失败入口（§3.2） |
| C15–C16 | 写 success → 开放业务写入 | after-commit | 仅在 C12–C14 全绿 |

步 5b 新增断言：`SELECT COUNT(*) FROM nodes n JOIN node_config_versions v ON v.identity_id=n.identity_id AND v.config_version=n.config_version WHERE v.fingerprint <> n.fingerprint` == 0。

---

## 7. 一致性复核（本轮要求交付第 5 项）

| 复核项 | 结论 | 依据 |
| --- | --- | --- |
| 备份是否在停写与排空之后 | **是**（A1→A2→A3→A4→A5） | §2.1、§2.3 |
| 是否验证"无活动写事务" | 是（D1/D2/D3，至少两项；恢复时 D3 必过） | §2.3、§3.2 步 3 |
| 是否验证备份可恢复 | 是（打开 + `quick_check` + 行数 + schema + sha256） | A6、BA6 |
| COMMIT 后失败是否单一路径 | 是（`handle_post_commit_failure` 九步） | §3.2 |
| 是否有 `sys.exit` 绕过清理 | 否（仅九步之后可退出；恢复失败走 `abort_recovery`） | §3.2 硬规则 4–5 |
| 是否在旧连接未关时替换文件 | 否（步骤 2–3 硬前置） | §3.2、RC4 |
| 预提交失败与 COMMIT 后失败是否分开 | 是（`rollback_tx` vs `handle_post_commit_failure`） | §3.1 表 |
| 配置升级是否单事务原子 | 是（②③④⑤ 同一 `IMMEDIATE` 事务 + ④ CAS） | §4.3 |
| 是否更新 `nodes.fingerprint` | 是（④ 与 `config_version` 同语句） | §4.3 |
| 是否保留 `nodes.id` / identity / 历史 | 是（不触碰这两列；子表引用 `node_id`） | §4.4 第 8 问 |
| 是否区分三种变化语义 | 是（§4.1 表） | §4.1 |
| 审计事件是否独立事务 | 是（步骤 2 先回滚、步骤 3 独立连接） | §5.2 |
| 档案测试是否用非空子表 | 是（§5.1 夹具） | §5.1 |
| 触发器是否覆盖单独改 fingerprint | 是（`UPDATE OF` 增 `fingerprint` + 等值条件） | §4.5 |

---

## 8. v1.6 → v1.7 修订对照

| # | v1.6 | v1.7 | 章节 |
| --- | --- | --- | --- |
| P0-1 | 先备份、后停写；文件级"复制三件套"未定义一致性条件 | A1–A8 严格顺序；Backup API/`VACUUM INTO` 为首选；文件级备份六条件（C-1..C-6，wal_checkpoint 返回 `(0,N,N)`、`-wal`=0、无 `-journal`）；A4 三项写者检测；BA1–BA6 | §2 |
| P0-2 | 恢复失败 `sys.exit(2)`；终检失败未先关连接 | COMMIT 不可逆、两阶段分流；九步统一恢复（含关连接、D 检测、sha256、事件、非零退出）；`sys.exit` 仅九步之后；恢复失败 `abort_recovery` 退出码 4；RC1–RC6 | §3 |
| P0-3 | 只更新 `config_version`，漏 `fingerprint` | 三语义表；②→⑤ 五步原子流程（含占用预检、CAS、关闭旧版本）；九问逐条回答；I1–I6 复核；触发器最小修订（`UPDATE OF` 加 `fingerprint` + 等值条件）；CF1–CF8 | §4 |
| P1-1 | 子表可能空；审计未定义事务 | 四子表夹具 + 六类快照比对；审计"先回滚写事务 → 独立连接独立事务 → 失败不影响主结果"；AU1–AU4、R10 | §5 |

---

## 9. 关闭证明

### 9.1 P0-1（备份顺序与一致性）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 先 maintenance / 停后台 / 排空 / 验证 / 才备份 | §2.1 | BA1/BA2 | 已关闭 |
| 备份方式明确（API / VACUUM INTO 优先） | §2.2 | — | 已关闭 |
| 文件级备份的一致性条件（连接关闭、checkpoint、wal/shm/journal、同一快照） | §2.2 C-1..C-6 | BA6 | 已关闭 |
| 备份验证（可开、quick_check、sha256、行数、schema） | A6 | BA3/BA4/BA6 | 已关闭 |
| 恢复时防旧连接 | §3.2 步 2–4、C-6 | RC4 | 已关闭 |
| 五条新增测试 | §2.4 | BA1–BA6 | 已关闭 |

### 9.2 P0-2（COMMIT 后失败）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| COMMIT 为不可逆边界 | §3.1 | — | 已关闭 |
| 六类失败统一进恢复 | §3.2 步 1–9 | RC1–RC3 | 已关闭 |
| 恢复九步顺序（停写→关连接→无残留→替换→新连接→检查→比对→事件→退出） | §3.2 | RC1–RC6 | 已关闭 |
| 不在旧连接打开时替换文件 | 步 2–3 | RC4 | 已关闭 |
| 不把 COMMIT 后失败称回滚 | §3.1 表 | — | 已关闭 |
| 恢复失败不边修边跑 | `abort_recovery` | RC6 | 已关闭 |
| `sys.exit` 不绕过清理 | 硬规则 4–5 | RC1/RC6 | 已关闭 |
| 预提交与 COMMIT 后分别定义 | §3.1 表 | RC1 vs BA1 | 已关闭 |
| 伪代码/流程/测试一致 | §3.3 vs §3.2 | 逐条对齐 | 已关闭 |
| 六条新增测试 | §3.4 | RC1–RC6 | 已关闭 |

### 9.3 P0-3（配置变化闭环）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 新指纹生成（现有算法） | §4.3 前置 | CF1 | 已关闭 |
| 新版本行创建 | ③ | CF3 | 已关闭 |
| 同步更新 fingerprint + config_version | ④ | CF1/CF2 | 已关闭 |
| 唯一约束保证 | ② + UNIQUE | CF5 | 已关闭 |
| 指纹被占用处理 | `FingerprintTaken` | CF5 | 已关闭 |
| 失败无半完成 | 单事务 + CAS | CF6 | 已关闭 |
| 保留 id/identity/历史 | 不触碰两列 | CF4 | 已关闭 |
| I1–I6 成立 | §4.4 复核表 | CF1–CF3 | 已关闭 |
| 三语义区分 | §4.1 | CF7 | 已关闭 |
| 不得等同指纹变化与身份变化 | §4.1 | — | 已关闭 |
| 触发器覆盖单独改指纹 | §4.5 | CF8 | 已关闭 |
| 七条新增测试 | §4.6 | CF1–CF8 | 已关闭 |

### 9.4 P1-1（测试覆盖与审计）

| 要求 | 章节 | 测试 | 状态 |
| --- | --- | --- | --- |
| 四子表各有真实关联 | §5.1 夹具 | R2/R3 | 已关闭 |
| 六类快照逐项比对 | §5.1 表 | R2/R3 | 已关闭 |
| 审计流程五步 | §5.2 | AU1–AU4 | 已关闭 |
| 事件字段完整 | 步 4 | AU2 | 已关闭 |
| 事件不与写事务共用 | §5.2 关键约束 | AU2 | 已关闭 |
| 审计失败不改主结果 | 步 5 | AU3/AU4 | 已关闭 |

---

## 10. 测试矩阵（增量）

| 组 | v1.6 | v1.7 | 变化 |
| --- | --- | --- | --- |
| A 路径关系 A | 10（A1–A10） | 10 | 不变 |
| REPLACE/UPSERT R | 9（R1–R9） | **10** | +R10（rt=OFF 反证） |
| 连接契约/迁移验证 FK | 15（FK1–FK15） | 15 | 不变 |
| 跨组 CV | 5（CV1–CV5） | 5 | 不变 |
| 迁移 M | 32 | 32 | 不变 |
| **备份 BA** | — | **6（BA1–BA6）** | 新增 |
| **COMMIT 后恢复 RC** | — | **6（RC1–RC6）** | 新增 |
| **配置升级 CF** | — | **8（CF1–CF8）** | 新增 |
| **审计 AU** | — | **4（AU1–AU4）** | 新增 |

其余组（I 30 / S 34 / T 14 / V 4 / CT 3 / FT 23 / F 22 / FKA 5 / P 14 / RP 12 / Z 30 / FE 19 / RG 24 / SF 7 / TV 4）不变。

**跨组一致性用例**

| 用例 | 断言 |
| --- | --- |
| BA5 + RC5 | 恢复后已提交数据完整，且无 `schema_migrations(success)` |
| CF1 + R4 | 配置升级后再次身份感知写入命中原 id（不产生重复节点） |
| CF5 + BA6 | 占用冲突失败后，若此时触发恢复，备份与当前库一致（无半成品） |
| AU2 + R7 | 身份冲突拒绝后，审计事件存在且节点数据不变 |
| R10 + CV1 | `rt=OFF` 连接即使执行成功也被 `write_guard` 拒于写入入口之外（顺序：先拒后执行） |

---

## 11. C11–C20 确认状态（不变）

| 编号 | 事项 | 推荐 | 状态 |
| --- | --- | --- | --- |
| C11 | `occurrence_seq` 永久单调 | 是 | 未确认 |
| C12 | P0 一次重建 `nodes` | 是（获批才走 B） | **未确认（本轮未假设已批准）** |
| C13 | `detection_task_runs` 保留期 | 30 天 + 键不重用 | 未确认 |
| C14 | `W_obs` 窗口 | 6h 优先 | 未确认 |
| C15 | `rep` 门槛 | 0.90 / 0.60 | 未确认 |
| C16 | retired 回归复用原 identity | 允许 | 未确认 |
| C17 | `U_unk` 是否可降级 | 不建议 | 未确认 |
| C18 | TCP-only 允许存、不参与判定 | 按 v1.6 §8 | 未确认 |
| C19 | 旧结果表停写切换 | 先验证、单开关、可回滚 | 未确认 |
| C20 | A 路径"物理可空 + 触发器"是否接受 | 建议接受为过渡 | 未确认 |

---

## 12. 风险（更新）

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | 停写判定被"任务正在收尾"糊过去 | A4 用 D3 拿写锁作为硬证据 | BA2 |
| 2 | 文件级备份实际不同源 | 优先 Backup API；文件级须过 C-2/C-3/C-4 | BA6 |
| 3 | COMMIT 后失败被误当回滚 | 文档 + 流程表明确"只能备份恢复" | RC1–RC3 |
| 4 | 恢复时旧连接仍持有旧文件句柄 | 步 2–3 + 连接纪元；拒绝替换 | RC4 |
| 5 | 只改 `config_version` 不改指纹 | §4.3 ④ 同语句 + §4.5 等值触发器 | CF1/CF8 |
| 6 | 审计事件随回滚消失 | 独立连接 + 独立事务 | AU2 |
| 7 | 子表空导致测试假通过 | §5.1 非空夹具 + 内容快照 | R2/R3 |
| 8 | `sys.exit` 早退绕过清理 | 硬规则 4–5 + 代码评审 | RC1/RC6 |

---

**v1.7 到此结束。** 本轮**未修改代码、未修改数据库、未创建迁移文件、未修改生产配置或生产数据**；仅修订四项问题。**C11–C20 全部未确认，C12 仍未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
