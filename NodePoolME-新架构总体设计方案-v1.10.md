# NodePoolME 新架构总体设计方案 v1.10

**项目**：laoXuHome/NodePoolME
**代码基准**：`v1.8.7` / `e721797`（`backend/database/db.py`）
**设计基准**：v1.9
**本轮性质**：纯设计修订。**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据。**
**本轮范围**：五项——phase 切换重复与状态表、COMMIT 异常路径 durable 事件时序、`set_phase()` 事件失败补偿、K1 与 S5 职责分离、R10-A1/A2 独立夹具。**未扩展其他架构。**
**文档状态**：**待总体设计最终审查**（本文未自行认定通过；C11–C20 未确认）
**二次修订（Final Two Fixes）**：① 隔离完成前禁止任何数据库事件写入（含 `append_reason`，改走 `migration-fault.log`）；② `UNKNOWN → COMMITTED` 收紧为四条件（token ∧ K1 ∧ S5 ∧ 事件成功），并新增 T7′ 禁止分支（S5 曾失败则永不转 COMMITTED）。改动点见 §0.1。
**三次修订（Final Closure Fixes）**：① quarantine 后普通 SQL 全拒导致原 `ROLLBACK` 执行不到 → 新增 `rollback_for_migration()` 单点通道；② K1 统一为写库唯一闸门，K1 不成立一律不写事件、phase 停 `COMMIT_ATTEMPTED`；③ `UNKNOWN → TX_ROLLED_BACK` 收紧为五条件并新增 T8′。改动点见 §0.2。
**四次修订（S2 异常保护）**：`in_transaction` 读取、`quarantine()`、回滚通道各自独立异常边界；`close()` 兜底必执行；隔离失败即 K1=False，严格按 T6′ 处理。改动点见 §0.3。
**五次修订（Final State-Machine Closure）**：① 拆开路径 α（进程内 COMMIT 异常，先 T6 → UNKNOWN，再只走 T7/T8）与路径 β（崩溃恢复，直接从 `COMMIT_ATTEMPTED` 走 T4/T5），`T4/T5` 不再出现在异常路径；② 关闭接口统一为 `conn_wrapper.close()`，`is_closed` 只在底层成功后置位。改动点见 §0.4。
**六次修订（β′ 跨重启证据）**：T6 事件必须持久化 `k1_proof`、`s5_result`、单调 `s5_failed_ever` 等证据；β′ 启动必须 E1–E3 校验，不得凭 `phase=UNKNOWN` 推断 K1 历史；S5 失败历史永久可追溯且不可清除。改动点见 §0.5。
**七次修订（Evidence Write-Path Integration）**：`system_events` 增加 `migration_id/seq/prev_sha/s5_failed_ever` 一等列与两个 UNIQUE；`write_event` 成为唯一写入通道，T6 证据在写入前构造校验；`append_reason` 同步接入；哈希链与单调性在 `BEGIN IMMEDIATE` 内保证。改动点见 §0.6。

**八次修订（Evidence Integrity Closure）**：① `token_fp` 改为 `system_events` 独立列并接入真实 `INSERT` 与 β′ 校验；② `tx_local` 拆到 `migration_tx_notes`，消除与 DDL 的 3 列 INSERT 冲突；③ `write_event` 在 `BEGIN IMMEDIATE` 内做 C1–C8 全链校验后再追加；④ 路径 α/β′ 均在 `set_phase` 前执行 `hist_gate`（`s5_failed_ever` 永久禁止 T7/T8）。改动点见 §0.7。

**九次修订（Commit Outcome Reconciliation）**：`write_event` 在 `COMMIT`/`ROLLBACK`/`close` 抛错后**真实执行**只读重查（8 字段逐项比对 + 重跑 C1–C8），按 A（已提交→采纳）/ B（确认未提交→失败）/ C（无法确认→停 maintenance）裁决；`emit_event()` 成为 `set_phase` 与 `append_reason` 的唯一事件入口，两个后端的连接/事务/失败/链语义不变。改动点见 §0.8。

---

## 0. 修订索引（v1.9 → v1.10）

| 编号 | 主题 | 章节 | 性质 |
| --- | --- | --- | --- |
| P0-1 | S1 只置进程内待定标记；单次 `COMMIT_ATTEMPTED→UNKNOWN`；禁 `UNKNOWN→UNKNOWN` | §1.1–§1.2 | 修正 |
| P0-2 | durable 事件改到 S2–S5 完成之后写；隔离未确认时只用非数据库日志 | §1.3 | 修正 |
| P0-3 | `set_phase()` 改为"事件先写成功、再改内存状态"；补偿转换明确定义 | §2 | 修正 |
| P1-1 | K1 只看隔离+关闭+句柄不可用；S5 单独定义为瞬时无写者探测 | §3 | 修正 |
| P1-2 | R10-A1/A2 各用独立数据库副本，禁止顺序依赖 | §4 | 修正 |

未修订：Q1–Q12、七个触发器、`nodes` 禁 UPSERT、配置升级原子流程、连接五类型与 `write_guard`、C-2 入向判定、`valid=0` 隔离、17 步主序号、备份首选与 F1–F9、C12–C16 捕获边界、时间与阈值参数、§2.3 判定表（本轮只补 K1/K2 的证明方式，不改判定分支）。**C11–C20 全部未确认；C12 未批准，默认 A 路径。**

### 0.1 二次修订改动点（Final Two Fixes）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0-1 隔离期禁写库 | §3.1 伪代码与禁令表 | `ROLLBACK` 失败分支由 `append_reason()` 改为 `non_db_log()`；新增"隔离期只许写 `migration-fault.log`"硬规则 |
| P0-2 收紧 T7 | §1.2（T7、新增 T7′）、§2.3、§6.3、§8 | `UNKNOWN → COMMITTED` 需四条件；S5 曾失败 → 永久停留 UNKNOWN，禁止转 COMMITTED |
| 测试 | §2.5、§3.4、§7、§8 | 新增 MC19（隔离完成前 DB 写入次数 0）、MC20（K1 成立 + S5 失败 + token 可见 → 仍 UNKNOWN） |

### 0.2 三次修订改动点（Final Closure Fixes）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0-1 quarantine 与 ROLLBACK 矛盾 | §3.1、§1.3 S2/S3、MC15b–15d | 先读 `in_transaction`（属性读）→ `quarantine` → `rollback_for_migration()`（只放行 `ROLLBACK`）→ `close()`；普通 `execute("ROLLBACK")` 仍被隔离拒绝 |
| P0-2 统一 K1 规则 | §1.2（T6、新增 T6′）、§1.3 硬规则 7、§3.1 判定表、§3.2、§3.3、MC14/MC15 | K1 成立才可写事件（S5 成败不影响）；K1 不成立一律不写、不 `set_phase`，phase 停留 `COMMIT_ATTEMPTED` |
| P0-3 收紧 T8 | §1.2（T8、新增 T8′）、§2.3、§5、§8、MC21 | `UNKNOWN → TX_ROLLED_BACK` 需五条件（token 不可见 ∧ 对象不可见 ∧ K1 ∧ S5 ∧ 事件成功）；S5 曾失败即永久 UNKNOWN |

### 0.4 五次修订改动点（Final State-Machine Closure）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0-1 路径分离 | §1.2 路径归属表 + T4/T4′ 改写、§1.3（α/β 两套时序 + 硬规则 3）、§2.2（编号按 phase 决定）、§2.3、§5（新增路径列）、MC25/MC26/MC26b | 路径 α（进程内 COMMIT 异常）只出 T6/T6′ 与 T7/T7′/T8/T8′；路径 β（崩溃恢复）只出 T4/T4′/T5，且其首个 durable 事件即结论事件 |
| P0-2 关闭接口统一 | §3.1 对象关系与契约表、关闭后读取禁令、伪代码 ④、§1.3 S4、MC27/MC27b | 迁移流程统一 `conn_wrapper.close()`；底层成功才置 `is_closed=True`；底层抛错不得伪造；关闭后不读 `conn.in_transaction` |

### 0.5 六次修订改动点（β′ 跨重启证据）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| T6 事件证据字段 | §1.4 必填字段表 | `migration_id`、`old/new_phase`、`k1_proof`（四布尔）、`s5_result`、单调 `s5_failed_ever`、`seq`/`prev_sha`、`ts`/`token_fp` |
| β′ 启动校验 | §1.4 E1–E3、§2.2 β′ 分支、§5 新增行 | 缺证据/不全/不符 → 禁止 T7/T8，停 `UNKNOWN`，一条 `evidence_unverified` |
| S5 失败历史 | §1.4 历史标记规则、§3.2、§3.3、MC34/MC37 | 永久 true、不得清除、拒写清除事件、只认事件流 |

### 0.6 七次修订改动点（Evidence Write-Path Integration）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| T6 证据接入写入路径 | §2.1 `write_event` / `set_phase` 伪代码、字段来源表、`system_events` DDL | `k1_proof` 只读 `rec.k1_state`；`s5_result` 取实际结果；`s5_failed_ever = 历史 OR 本次`；`seq`/`prev_sha` 事务内生成；证据不全 → 返回 `False`、不写 T6 |
| 后续事件统一接入 | §1.2 `append_reason` 伪代码 + 强制约束表 | 全部走 `write_event`；带 `migration_id`/`s5_failed_ever`/`seq`/`prev_sha`；单调性违反拒写 |
| 哈希链与原子性 | §2.1 规范化规则 + 原子性说明 + DDL 两个 UNIQUE | `seq` 从 1、连续 +1、`UNIQUE(migration_id,seq)`；`prev_sha` 首事件 `GENESIS(mid)`；`BEGIN IMMEDIATE` 事务边界；失败不推进 phase、不提交内存标记；断链不重建 |
| note 三态 | §1.4 三分支表 | 链完整才写 note；链断裂只写文件日志；单调性不满足拒写 |
| 测试 | MC38–MC43 |

### 0.7 八次修订改动点（Evidence Integrity Closure）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0-1 `token_fp` 写入路径 | §1.4 字段表/E2、§2.1 DDL + 字段来源表 + `write_event` + `required_evidence_missing`、§2.2 `evidence_ok`、MC38/MC43 | 全篇唯一口径 = `system_events.token_fp` 独立列（`CHECK(length=64)`）；来源锁定凭据行；β′ 读列值比对；缺失/格式错/不符一律拒绝 |
| P0-2 `tx_local` 冲突 | §2.1 两表 DDL + `emit_event` 双后端 + 语义对照、§5 注、MC39/PH7 | 新增 `migration_tx_notes`（无 `seq/prev_sha/token_fp/s5_failed_ever` 列）；tx_local 不进证据链、β′ 不读；不再有与 DDL 冲突的 3 列 INSERT |
| P0-3 全链验证入事务 | §2.1 `write_event` + C1–C8 + 不确定结果处理表；§1.2 `append_reason` 降级为诊断 | `BEGIN IMMEDIATE` 内读全链并校验，通过才分配 `seq`/`prev_sha`；链损坏只写文件日志；结果不确定只读重查、禁止重发 |
| P0-4 历史失败门禁 | §2.2 `hist_gate` + 顺序说明 + T8 说明、§2.3 新行、MC44–MC47 | `not rec.s5_failed_ever` 在 `set_phase` 前判定；T7/T8 同受约束；写入拒写 ≠ 状态禁止，两者分别定义 |
| 一致性 | §6.8、§8 六项核对、§10 风险 22–25 | DDL/INSERT 对齐、事务边界、统一机制、`token_fp` 落库、β′ 恢复、门禁覆盖 | 校验真实持久化行，非内存 payload |

### 0.8 九次修订改动点（Commit Outcome Reconciliation）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0 `COMMIT` 结果确认接入伪代码 | §2.1 `write_event` 重写 + 七态阶段表 + `settle_uncertain` / `reconcile_event` + 三结果表 + 内存一致性 6 条 | `except` 分支不再"回滚即返回 False"，而是构造 `exp`（8 字段）后调用 `reconcile_event`，按 A/B/C 裁决 |
| 逐字段 + 全链比对 | §2.1 `row_fields_equal` 定义 | 8 字段逐项严格比较（`detail_json` 字节级、`ts` 精确），并对实际链重跑 C1–C8 |
| `ROLLBACK`/`close` 语义 | §2.1 阶段表第 7 态 + 三结果表 + §2.3 新行 | 不据异常类型推断；只读连接不可读不得解释为"不存在" |
| 内存一致性 | §2.1 硬规则 1–6、§2.2 成功/失败语义表 | `s5_failed_ever` 与 `phase` 的更新时机与 A/B/C 一一对应 |
| 统一入口 | §2.1 `emit_event` + `set_phase` 重写、§1.2 强制约束表、§6.9 | `set_phase` 两支均调 `emit_event`；业务代码禁止直连两个后端 |
| 测试 | §2.5 MC48–MC56、§7 计数 47→56 | 全部读取真实 SQLite 行，不依赖 mock 返回值 |

### 0.3 四次修订改动点（S2 异常保护）

| 项 | 位置 | 改动 |
| --- | --- | --- |
| P0 S2 异常保护 | §3.1 异常边界表与伪代码、§1.3 S2–S4、MC22–MC24 | `in_transaction` 属性读、`quarantine()`、`rollback_for_migration()` 各自独立 `try`；`close()` 兜底必执行；`had_tx=UNKNOWN` 不参与 K1 |
| K1 严格化 | §3.1 判定表 | `quarantined_ok ∧ close_ok ∧ is_closed ∧ no_tx_read_after_close`；隔离抛错即 K1=False |
| T6′ 执行 | §1.2 T6′ / §5 / §3.3 | 不写 DB 事件、不 `set_phase`、phase 停 `COMMIT_ATTEMPTED`、只写 `migration-fault.log`、maintenance 保持 |

---

## 1. P0-1 / P0-2：COMMIT 异常路径的状态与时序

### 1.1 单一状态源与"待定标记"

`phase` 只能由 `set_phase()` 修改（§2.1）。此外允许一个**非 phase** 的进程内标记：

| 标记 | 类型 | 含义 | 是否等同于 state |
| --- | --- | --- | --- |
| `commit_raised` | bool，进程内 | COMMIT 抛出过异常 | **否**。仅表示"待判定"，不改 phase |
| `isolation_ok` | bool，进程内 | S2–S5 全部通过 | **否** |
| `pending_reason` | str，进程内 | 最近一次失败原因，供事件使用 | **否** |

**规则**：S1 只做 `commit_raised = True; pending_reason = str(exc)`，**不调用 `set_phase`**。v1.9 §2.2 的"S1 → phase=UNKNOWN"与 §2.4 的 `set_phase(COMMIT_ATTEMPTED, UNKNOWN)` 是同一转换写了两次，必然触发 `PhaseMismatch`；本轮删除前者。

### 1.2 最终状态转换（每个合法转换唯一一次）

| # | 旧 → 新 | 触发条件 | 执行点 | 失败处理 |
| --- | --- | --- | --- | --- |
| T1 | `PREPARED → TX_OPEN` | `BEGIN IMMEDIATE` 返回成功 | 紧随 BEGIN | 事件失败只记日志（事务已开，不可回退） |
| T2 | `TX_OPEN → COMMIT_ATTEMPTED` | 发出 COMMIT 之前（凭据行已写入） | COMMIT 前 | 同上 |
| T3 | `TX_OPEN → TX_ROLLED_BACK` | `ROLLBACK` 成功 | 预提交失败路径 | `durable` 事件失败 → 仍终止（不写 success、不开写入） |
| T4 | `COMMIT_ATTEMPTED → COMMITTED`（**仅路径 β**） | 恢复启动 ∧ 本进程未执行 COMMIT ∧ `K1_β` ∧ S5 成功 ∧ token 可见 ∧ `durable` 事件成功 | 恢复流程 R4 | 任一不满足 → **不转换**（T4′），停留 `COMMIT_ATTEMPTED` |
| T5 | `COMMIT_ATTEMPTED → TX_ROLLED_BACK`（**仅路径 β**） | 恢复启动 ∧ 本进程未执行 COMMIT ∧ `K1_β` ∧ S5 成功 ∧ token 与迁移对象均不可见 ∧ `durable` 事件成功 | 恢复流程 R4 | 同上 |
| T4′ | `COMMIT_ATTEMPTED → （无转换）`（路径 β 门禁不满足） | `K1_β` 不成立 / S5 失败 / 结论条件不全 / 事件失败 | — | `K1_β` 成立 → 可写 `migration_note`；不成立 → 只写 `migration-fault.log`；phase 停留 `COMMIT_ATTEMPTED`；保守恢复 |
| T6 | `COMMIT_ATTEMPTED → UNKNOWN` | COMMIT 抛异常 ∧ **K1 成立**（S5 成功或失败均可） | **S5 之后**（唯一时点） | 事件写失败 → 见 §2.4，仍保守恢复 |
| T6′ | `COMMIT_ATTEMPTED → （无转换）` | COMMIT 抛异常 ∧ **K1 不成立**（无论 S5 是否成功） | — | 不写任何 DB 事件、不调 `set_phase`；phase 停留 `COMMIT_ATTEMPTED`；只写 `migration-fault.log`；maintenance + 保守恢复/待人工 |
| T7 | `UNKNOWN → COMMITTED` | token 可见 **∧ K1 成立 ∧ S5 成功 ∧ `durable` 事件写入成功**（四条件）；若为 β′ 入口，另需 **E1–E3 通过 ∧ `s5_failed=False`** | 隔离完成后 / β′ 校验后 | 任一不满足 → 停留 `UNKNOWN` + 保守恢复 |
| T7′ | `UNKNOWN → COMMITTED`（此前 S5 失败过，含 β′ 由事件流恢复出 `s5_failed=True`） | **禁止**——即使后续 token 可见、后续 S5 探测成功 | — | 保持 `UNKNOWN`，继续保守恢复 |
| T8 | `UNKNOWN → TX_ROLLED_BACK` | token 不可见 **∧ 迁移对象不可见 ∧ K1 成立 ∧ S5 成功 ∧ `durable` 事件写入成功**（五条件）；β′ 入口另需 **E1–E3 通过 ∧ `s5_failed=False`** | 隔离完成后 / β′ 校验后 | 任一不满足 → 停留 `UNKNOWN` + 保守恢复 |
| T8′ | `UNKNOWN → TX_ROLLED_BACK`（此前 S5 失败过，含 β′ 由事件流恢复出 `s5_failed=True`） | **禁止**——即使后续 token 与迁移对象均不可见、后续 S5 探测成功 | — | 保持 `UNKNOWN`，继续保守恢复；不写 success、不开放业务写入 |
| — | **`UNKNOWN → UNKNOWN` 禁止** | 需要追加新原因 | — | 用 `append_reason()` 写独立事件（`migration_note`），**不改 phase** |

**路径归属（本轮定稿，两个入口互不混用）**

| 路径 | 入口条件 | 可用转换 | 禁止 |
| --- | --- | --- | --- |
| **α：进程内 COMMIT 异常** | 本进程执行了 COMMIT 且抛异常 | `T6`（K1 成立）或 `T6′`（K1 不成立）→ 之后仅 `T7/T7′/T8/T8′` | **不得**调用 `T4/T5`；不得跳过 `UNKNOWN` 直接判 `COMMITTED`/`TX_ROLLED_BACK` |
| **β：崩溃/重启恢复** | 进程启动时持久 `phase = COMMIT_ATTEMPTED`，且**本进程未执行过 COMMIT** | `T4/T4′` 或 `T5/T4′` | **不得**调用 `T6`（没有 COMMIT 异常）、**不得**调用 `T7/T8`（phase 不是 `UNKNOWN`）；不得先"降到 UNKNOWN"再判 |
| **β′：恢复时持久 phase 已是 `UNKNOWN`** | 启动读到 `UNKNOWN` ∧ **E1–E3 校验通过**（§1.4） | 仅 `T7/T7′/T8/T8′`；`s5_failed` 由事件流恢复 | 不得调用 `T4/T5`；**E1–E3 任一不过即禁止 T7/T8**；不得仅凭 `phase=UNKNOWN` 推断 K1 历史 |

> `K1_β`（恢复路径的原连接终止证明）：进程启动时**不存在**上一进程的原连接。以"单实例锁已取得 ∧ 启动瞬间迁移连接表为空 ∧ 本进程此后未打开过迁移写连接"证明，记 `k1_beta = True`；任一无法确认则 `k1_beta = False` → `T4′`。**不得**用"进程重启了"当作证明，也不用 `is_closed` 之类只对存活对象有意义的标志。

**`append_reason()`（不改变 phase 的唯一合法方式）**

```python
# 伪代码：migration_note 走同一 durable 入口（全链校验在 write_event 事务内完成）
def append_reason(rec, code, detail):
    """在 phase 不变的前提下追加上下文；不允许伪装成状态转换。"""
    payload = dict(phase=rec.phase.name, code=code, detail=detail)
    return emit_event(rec, "migration_note", payload)     # → write_event；链损坏 → 内部拒绝，只写文件日志
```

**所有写入入口的强制约束**

| 约束 | 说明 |
| --- | --- |
| 入口唯一 | **业务代码与状态机只调 `emit_event()`**：`tx_local` 由它分派到 `write_tx_event()`（落 `migration_tx_notes`，不进链），`durable` 由它分派到 `write_event()`（落 `system_events`，含全链校验与提交结果确认）。除 `emit_event` 内部，**不得直接调用两个后端写入函数**（`set_phase`、`append_reason` 亦然） |
| 分派不改语义 | `emit_event` 只做分派，不改变两种后端的连接、事务、失败与证据链语义（见 §2.1 语义对照） |
| `migration_id` / `token_fp` / `seq` / `prev_sha` / `s5_failed_ever` 必带（durable） | 由 `write_event` 在事务内生成并写入独立列；调用方不得传入 |
| `s5_failed_ever` 单调 | 写前校验 + 事务回滚；倒退即 `EvidenceMonotonicityViolation` |
| 全链校验前置 | `verify_full_chain`（C1–C8）在同一 `BEGIN IMMEDIATE` 内执行，通过后才分配 `seq`/`prev_sha` |
| 规范化/哈希唯一 | 全部走 §2.1 的 `canon()` / `canon_event_row()` / `sha256_hex()` |
| 链断裂时的 note | 只写 `migration-fault.log`；**不得**为写 note 而重建、补写、重算、覆盖或删除历史 |
| 预检查不等于安全保证 | `append_reason` 可在事务外做诊断性 `verify_chain()`，但**唯一安全校验**由 `write_event` 事务内完成 |

**为什么必须这样**：`UNKNOWN → UNKNOWN` 在状态机里是无操作，但若写成 `set_phase(UNKNOWN, UNKNOWN)` 会触发旧值断言/守卫（`PhaseMismatch`），把"记录新原因"误当成"状态变化"。记录原因与状态推进是两件事。

### 1.3 durable 事件的确切写入时点（P0-2）

| 事件 | 时点 | 是否允许独立写连接 | 说明 |
| --- | --- | --- | --- |
| `PREPARED→TX_OPEN`、`TX_OPEN→COMMIT_ATTEMPTED` | 事务内即时写 `migration_tx_notes` | **否**（写在迁移事务里，`tx_local`；不进 `system_events`） | 随提交或回滚消失，非持久审计；**β′ 不读该表** |
| `COMMIT_ATTEMPTED→UNKNOWN`（路径 α） | **S2–S5 全部完成之后，且 K1 成立** | 是（此刻原连接已关闭、S5 已探测） | 唯一允许的时点；K1 不成立则不写（T6′） |
| `COMMIT_ATTEMPTED→COMMITTED` / `→TX_ROLLED_BACK`（路径 β） | 恢复流程 R2–R3 完成之后，且 `K1_β` ∧ S5 成立 | 是 | 路径 β 的**首个** durable 事件即该结论事件；不得为"先降级"再写 `→UNKNOWN` |
| `TX_OPEN→TX_ROLLED_BACK` | `ROLLBACK` 返回之后 | 是 | 原写事务已结束 |
| 隔离未确认（K1 不成立）时的失败 | **不写数据库事件** | **否** | 只能用非数据库日志（结构化文件/标准错误），因为库上可能仍有写锁 |

**硬规则**

1. 隔离未确认前，**禁止**用独立连接写任何 `durable` 事件（SQLite 单写者：第二写者会 `SQLITE_BUSY`，且失败会污染恢复判断）；
2. 隔离未确认时，故障记录走**非数据库通道**：`<data_dir>/migration-fault.log`（追加写、含 `migration_id/token/reason/ts`），并在进程退出码中体现；
3. 隔离/恢复确认后的第一个 `durable` 事件按路径固定：**路径 α** 必须是 `COMMIT_ATTEMPTED→UNKNOWN`（T6）；**路径 β** 必须是 `→COMMITTED`（T4）或 `→TX_ROLLED_BACK`（T5）；**路径 β′** 是 `UNKNOWN→COMMITTED`（T7）或 `UNKNOWN→TX_ROLLED_BACK`（T8），且写之前必须先完成 E1–E3 校验（§1.4）。不得在未定义的条件下跳过本路径的首个事件，也不得跨路径套用；
4. 所有 `durable` 写都用短 `busy_timeout`（≤500ms）+ 单次尝试，不重试；
5. **K1 未确认期间的任何异常（含 `rollback_for_migration()` 失败、`close()` 失败）一律只写 `migration-fault.log`**，禁止 `append_reason()` / `write_event()` / 任何 `INSERT`——因为此时原连接可能仍持写锁，写库会 `SQLITE_BUSY` 并把"写不进去"误当成"状态异常"；
6. S7 判定必须**同时**复核 K1、S5 与事件写入成功：走 T7（`UNKNOWN → COMMITTED`）时 S5 曾失败即永久停留 `UNKNOWN`（T7′）；走 T8（`UNKNOWN → TX_ROLLED_BACK`）时 S5 曾失败同样禁止（T8′），即使 token 与对象均不可见；
7. **终止证据是"能否写 DB 事件"的唯一闸门**：路径 α 用 K1（成立 → `T6/T7/T8` 可写事件，S5 成败不影响；不成立 → `T6′`，无论 S5 如何一律不写、不 `set_phase`，phase 停 `COMMIT_ATTEMPTED`）；路径 β 用 `K1_β`（成立 → `T4/T5` 可写；不成立 → `T4′`，同样不写）。

**时序对照（替换 v1.9 §2.2 的 S1–S7 表述）**

| 步 | 动作 | phase | 事件 |
| --- | --- | --- | --- |
| S1 | COMMIT 抛异常 → `commit_raised=True` | 仍 `COMMIT_ATTEMPTED` | 无（仅进程内） |
| S2 | 先读一次 `in_transaction`（属性读，非 SQL，**独立异常边界**，失败记 `UNKNOWN`）→ `quarantine(conn)`（**独立异常边界**，失败仍继续；此后业务 SQL 一律抛 `QuarantinedError`） | 不变 | 无 |
| S3 | `if quarantined_ok and had_tx in (True, UNKNOWN): conn_wrapper.rollback_for_migration()`（仅放行 `ROLLBACK`；隔离未成功则跳过） | 不变 | 无 |
| S4 | `conn_wrapper.close()`（**兜底必执行**，前序任何异常都不中断；底层成功才置 `is_closed`） | 不变 | 无 |
| S5 | 探测连接 `BEGIN IMMEDIATE`→`ROLLBACK`→`close()` | 不变 | 无 |
| S6 | K1 成立 → `set_phase(COMMIT_ATTEMPTED → UNKNOWN)`（T6）；K1 不成立 → **不转换**（T6′） | `UNKNOWN` / 仍 `COMMIT_ATTEMPTED` | **durable（首个）**；失败 → §2.4；K1 不成立时无事件 |
| S7 | 新连接只读查询 token/对象 → 仅按 `T7/T7′` 或 `T8/T8′` 判定 | `COMMITTED` / `TX_ROLLED_BACK` / 停 `UNKNOWN` | 对应转换事件 |

> **路径 α 的次序是硬性的**：`UNKNOWN` 必须由 T6 先落，S7 才有资格查询；S7 只允许 `T7/T7′/T8/T8′`，**绝不允许** `T4/T5`——因为进入 UNKNOWN 后 `COMMIT_ATTEMPTED` 已不是当前状态，T4/T5 的前置状态不再成立。
>
> v1.9 的写法"先查询后判定，再套 T4/T5"由此被拆开：`T4/T5` 只保留给**路径 β（崩溃恢复）**，其前置状态 `COMMIT_ATTEMPTED` 在恢复启动时是真实存在的。

**路径 β（崩溃恢复）的时序**

| 步 | 动作 | phase | 事件 |
| --- | --- | --- | --- |
| R1 | 读持久 `phase`：`COMMIT_ATTEMPTED` → 继续 R2；`UNKNOWN` → 转路径 β′（T7/T8）；其它 → 按该 phase 的既定流程 | 不变 | 无 |
| R2 | 证明 `K1_β`（单实例锁 + 启动瞬间迁移连接表为空 + 本进程未开迁移写连接） | 不变 | 无 |
| R3 | S5 探测（新连接 `BEGIN IMMEDIATE` → `ROLLBACK` → `close()`） | 不变 | 无 |
| R4 | 新连接只读查询 token/对象 → `K1_β ∧ S5` 成立时按结论走 `T4`/`T5`；否则 `T4′` 不转换 | `COMMITTED` / `TX_ROLLED_BACK` / 停 `COMMIT_ATTEMPTED` | **durable（首个）** = T4/T5 事件；`T4′` 时最多一条 `migration_note`（仅当 `K1_β` 成立） |

> 路径 β **没有** `→UNKNOWN` 这一步：它不是"COMMIT 结果一度未知"的现场（现场在上一进程），持久 `COMMIT_ATTEMPTED` 本身就是唯一已知事实，因此 R4 直接给出结论。反过来说，只要走的是路径 α，就**必须**先落 `→UNKNOWN`，不得以"token 已经可见"为由跳过。

### 1.4 β′ 的跨重启证据（本轮新增）

**问题**：路径 α 在 K1 成立、S5 失败时执行 T6，把 phase 落成 `UNKNOWN`。若随后进程崩溃，重启进入路径 β′，新进程**没有**上一进程的 `k1`、`s5_failed` 等内存变量。若 β′ 只看 `phase == UNKNOWN` 就判 T7/T8，等于凭空假设"上一进程 K1 曾成立、S5 从未失败"——而这两件事都可能不成立。

**原则**：`UNKNOWN` 只是"结论未知"的标记，**不携带任何证明**。证明必须来自与该 `migration_id` 绑定的**持久事件**，且必须能被 β′ 独立校验。

**T6 事件的必填证据（durable，缺一即无效）**

| 字段 | 内容 | β′ 校验方式 |
| --- | --- | --- |
| `migration_id` | 本次迁移标识 | 必须与当前 `migration_id` 完全一致 |
| `old_phase` / `new_phase` | `COMMIT_ATTEMPTED` / `UNKNOWN` | 两者必须精确匹配；`new_phase` 非 `UNKNOWN` 即判"与当前 phase 不匹配" |
| `k1_proof` | `{quarantined:true, close_ok:true, is_closed:true, no_tx_read_after_close:true}` 四个布尔 + `evidence_ts` | 四者必须全为 `true` 且字段齐备；缺字段按"无法验证"处理 |
| `s5_result` | `"ok"` / `"failed"` / `"not_run"` | 用于解释当次探测；`not_run` 不得当作 `ok` |
| `s5_failed_ever` | 布尔，**单调不减** | 见下方"历史失败标记" |
| `seq` / `prev_sha` | 事件序号与上一事件规范化 JSON 的 sha256 | `seq` 必须连续 +1、`prev_sha` 必须与上一事件匹配；断链即判"证据不可验证" |
| `ts` / `token_fp` | 事件时间；`token_fp` 为 `system_events.token_fp` **独立列**（64 位小写 hex，非 `detail_json` 内字段） | `ts` 必须落在该迁移时间窗内；`token_fp` 必须是 `^[0-9a-f]{64}$` 且等于当前凭据行重算值；缺失/格式错/不一致一律判失败 |

**S5 失败历史（跨进程、跨重启、不可清除）**

1. `s5_failed_ever` 一旦为 `true`，**永久为 `true`**：后续任何 `migration_phase` 与 `migration_note` 事件都必须携带"≥ 旧值"的该字段，写入前校验单调性，违反即拒绝写事件（`EvidenceMonotonicityViolation`）；
2. `S5` 后续成功**不得**清除该标记：成功只允许追加 `probe_ok` 记录（`s5_result="ok"`、`s5_failed_ever` 沿用旧值），**禁止**写任何"清除/重置"语义的事件；
3. **该标记对路径 α 与 β′ 同等生效**：α 在同一进程内保留 `rec.s5_failed_ever`（由成功写入链后提交），β′ 恢复时取该 `migration_id` 事件链中 `s5_failed_ever` 列的**逻辑或（任一 true 即 true）**，恢复为 `s5_failed = True`；
4. 该状态**不得**存放在仅进程内存或普通易失日志中；`migration-fault.log` 只作辅助排查，不作为 β′ 的判定依据。

**β′ 启动校验（E1–E3，全过才允许 T7/T8）**

| 检查 | 条件 | 不通过时 |
| --- | --- | --- |
| E1 存在性 | 该 `migration_id` 存在 `migration_phase` 事件且 `new_phase=UNKNOWN`、`old_phase=COMMIT_ATTEMPTED` | **禁止** T7/T8 |
| E2 完整性 | `k1_proof` 四布尔全 `true`；`seq/prev_sha` 全链一致（C1–C8）；`token_fp` **列值**为 64 位小写 hex 且等于凭据行重算值；`ts` 落在迁移时间窗；字段无缺失 | **禁止** T7/T8；判"无法验证 K1 历史证明 / token 指纹不符" |
| E3 一致性 | 当前 `phase` 与 T6 事件的 `new_phase` 一致；`s5_failed` 由 `system_events.s5_failed_ever` 列（单调取最后值）恢复，不由 phase 推断、不读 `migration_tx_notes` | **禁止** T7/T8 |

任一项不通过 → **停留 `UNKNOWN`**，不推进 phase、不进入阶段 C、不写 success、maintenance 保持、写入关闭。

**`evidence_unverified` note 的三条处理分支（本轮明确）**

| 情形 | 处理 |
| --- | --- |
| 证据链**完整可验证**、只是 E2 某个内容项不符（如 `token_fp` 不匹配） | 允许写一条 `migration_note(code="evidence_unverified")`，走 §2.1 `write_event`：继承当前 `s5_failed_ever`、`seq = last.seq + 1`、`prev_sha = sha256(canon_event_row(上一事件))`、`token_fp` 取当前凭据行 |
| 证据链**本身损坏/断裂**（缺行、`prev_sha` 对不上、`seq` 跳号、无法读到上一事件） | **禁止**写 DB note（写 note 会需要伪造前序哈希）；只写 `<data_dir>/migration-fault.log`，附 `mid / 失败项 / 观测到的链头` |
| 证据链可读但 `s5_failed_ever` 单调性无法满足（历史 true、待写 false） | 拒写（`EvidenceMonotonicityViolation`），只落文件日志 |

任何情况下都**不得**为写入 note 而补建、重算、覆盖或删除历史事件；链一旦断，只能人工介入。

**T6 事件写不进去时**：仍按 §2.1/§2.4 的既有规则处理——`set_phase` 返回 `False`，内存仍 `COMMIT_ATTEMPTED`，**不得**伪造 `UNKNOWN`、不得开放写入；随后可按 T6′ 的口径停 `COMMIT_ATTEMPTED` + 文件日志 + 保守恢复。

**禁止项（写进设计约束，供实施阶段校验）**

- 不得用"`phase == UNKNOWN`"推断 K1 历史成立；
- 不得用"当前 S5 探测成功"推断历史上从未失败；
- 不得用进程内变量、缓存或易失日志替代 E1–E3；
- 不得为了让 β′ 通过而放宽 K1、S5、T7、T8 的既有条件，也不得补写、改写或删除历史事件。

### 1.5 测试（MC13–MC14、MC25–MC26b、MC34–MC37、PH6–PH8）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC34 | 路径 α：K1 成立、S5 失败、T6 事件写成功（`s5_failed_ever=true`） | **真实进程重启**（新进程、新连接、不复用内存） | β′ 由事件流恢复 `s5_failed=True`；E1–E3 通过后仍 **禁止 T7/T8**（T7′/T8′）；停留 `UNKNOWN`；无 success；写入关闭 |
| MC35 | 路径 α：K1 成立、S5 成功、T6 事件写成功（`s5_failed_ever=false`） | **真实进程重启** | E1–E3 通过，`s5_failed=False`；继续按 T7/T8 完整条件判定（token 可见 → T7；均不可见 → T8）；条件不全则停留 `UNKNOWN` |
| MC36 | 删除 / 篡改 / 伪造 T6 事件（分别构造：缺失、`k1_proof` 缺字段、`seq` 断链、`new_phase` 非 UNKNOWN、`token_fp` 不符） | 启动进入 β′ | E1/E2/E3 对应失败；**不推进 phase**、不进阶段 C、无 success、maintenance 保持、写入关闭；仅一条 `evidence_unverified` note（或文件日志） |
| MC37 | MC34 之后，β′ 中 S5 探测成功 | 追加 `probe_ok` 事件后再次重启 | `s5_failed_ever` 仍为 `true`；`s5_failed=True` 依旧；T7′/T8′ 仍禁止；试图写"清除"语义事件被拒（`EvidenceMonotonicityViolation`） |
| MC13 | COMMIT 抛异常，K1 成立，S5 成功 | 观察事件写入序 | DB 事件中**不存在**早于 S5 的 `→UNKNOWN`；`COMMIT_ATTEMPTED→UNKNOWN` 出现在 S5 之后；S5 前只有进程内标记 |
| MC13b | 同上，但 K1 成立、S5 失败 | 观察 | 仍有 `COMMIT_ATTEMPTED→UNKNOWN`（S5 失败不影响 K1 闸门）；无 `→COMMITTED`/`→TX_ROLLED_BACK` |
| MC14 | 同上，但 `close()` 失败（K1 不成立），探测亦失败 | 观察 | **无任何 DB 事件**；`migration-fault.log` 有记录；phase 停留 `COMMIT_ATTEMPTED`（T6′，未被伪装成 UNKNOWN）；进入保守恢复；写入保持关闭；无 success |
| PH6 | COMMIT 抛异常（K1 成立） | 全程记录转换 | `COMMIT_ATTEMPTED→UNKNOWN` **恰好 1 次**；无 `UNKNOWN→UNKNOWN`；无 `PhaseMismatch`；后续每条结论分支（T7/T8）也各至多 1 次 |
| PH7 | 已处 `UNKNOWN`，再记录一条新原因 | `append_reason("probe_retry_failed", ...)` | 产生 `migration_note` 事件；phase 不变；无异常 |
| PH8 | 构造非法转换（如 `TX_ROLLED_BACK→COMMITTED`） | `set_phase` | 抛 `IllegalTransition`；状态不变；不写事件 |
| MC25 | 路径 α：COMMIT 抛异常、K1 成立、S5 成功、token 可见 | 全程记录 `set_phase` 调用 | 事件序列为 `COMMIT_ATTEMPTED→UNKNOWN` → `UNKNOWN→COMMITTED`；`T4/T5` 调用次数 = **0**；`UNKNOWN→UNKNOWN` = 0；进入阶段 C 一次 |
| MC26 | 路径 β：启动读到持久 `COMMIT_ATTEMPTED`，本进程未执行 COMMIT，`K1_β` 成立、S5 成功 | 分别构造 token 可见 / 均不可见 | 前者 `T4 COMMIT_ATTEMPTED→COMMITTED`；后者 `T5 →TX_ROLLED_BACK`；两者前置 phase 均为 `COMMIT_ATTEMPTED`；`T6` 调用次数 = 0；无 `→UNKNOWN` 事件 |
| MC26b | 路径 β：`K1_β` 基线（单实例锁被占 / 连接表非空） | 判定 | `K1_β=False` → `T4′`；DB 写入 0；phase 停 `COMMIT_ATTEMPTED`；仅文件日志 |

---

## 2. P0-3：`set_phase()` 的事件失败补偿

### 2.1 事件先写、状态后改；tx_local 与 durable 分表分语义；证据随事件构造校验、提交结果由重查裁决

**两张表：durable 证据链 vs tx_local 提示（本轮定稿）**

`system_events` 自 v1.2 起就是本设计新建的表（基准库不存在）。`tx_local` 事件必须随迁移事务提交/回滚，不能进 durable 链；而 durable 链要求 `migration_id/seq/prev_sha/token_fp/s5_failed_ever` 全部 NOT NULL。把两者塞进一张表只能靠可空列 + 伪造序号，因此**拆成两张表**，语义各自闭合。

```sql
-- 设计级 DDL（不是现网表；P-1 实施时才建）

-- ① durable 证据链：唯一可被 β′/T7/T8/T4/T5 采信的来源
CREATE TABLE system_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event           TEXT NOT NULL,        -- 'migration_phase' | 'migration_note' | ...
    migration_id    TEXT NOT NULL,
    seq             INTEGER NOT NULL,     -- 每 migration_id 内从 1 起，连续 +1
    prev_sha        TEXT NOT NULL,        -- 上一事件规范化 JSON 的 sha256；首事件为 GENESIS(mid)
    token_fp        TEXT NOT NULL CHECK (length(token_fp)=64),   -- 64 位小写 hex；T6 必填
    s5_failed_ever  INTEGER NOT NULL CHECK (s5_failed_ever IN (0,1)),
    detail_json     TEXT NOT NULL,        -- 事件正文（含 k1_proof / s5_result 等证据）
    ts              TEXT NOT NULL,        -- ISO-8601 UTC，毫秒
    UNIQUE (migration_id, seq),           -- 数据库级唯一：并发下不可能重复 seq
    UNIQUE (migration_id, prev_sha)       -- 同迁移不允许两个事件共享前序（防分叉）
);

-- ② tx_local 提示：随迁移事务存在，回滚即消失，永不进入证据链
CREATE TABLE migration_tx_notes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    migration_id  TEXT NOT NULL,
    old_phase     TEXT NOT NULL,
    new_phase     TEXT NOT NULL,
    reason        TEXT,
    ts            TEXT NOT NULL
);
```

**为什么无需可空列**：`migration_tx_notes` 根本没有 `seq/prev_sha/token_fp/s5_failed_ever` 列，因此不存在"留 NULL""伪造序号""与 durable 链发生不明关系"的可能；β′ 只读 `system_events`，**永不读取** `migration_tx_notes`，不会把提示当成已持久化证明。

**统一入口 `emit_event()`：一个入口，两个后端**

| 后端 | 连接 | 事务边界 | 落表 | 失败语义 | 是否进入证据链 |
| --- | --- | --- | --- | --- | --- |
| `tx_local` | `rec.conn`（迁移原连接） | 迁移事务内 | `migration_tx_notes` | 写失败只记日志；**phase 仍推进**（非权威） | **否** |
| `durable` | `audit_conn()`（独立审计连接） | 独立事务 `BEGIN IMMEDIATE … COMMIT` | `system_events` | 写失败 → 返回 `False`，**phase 不推进** | **是** |

**字段来源（不接受调用方随意传入）**

| 字段 | 唯一合法来源（durable） | 伪造防护 | tx_local 是否携带 |
| --- | --- | --- | --- |
| `migration_id` | 迁移上下文常量 `MID` | 与凭据行同源 | 携带（普通列） |
| `old_phase` / `new_phase` | `rec.phase` 与转换表（§1.2） | 不在表内即 `IllegalTransition` | 携带 |
| `k1_proof` | `k1_proof_from_state(rec.k1_state)`（§3.1 判定结果 + `evidence_ts` = S4 结束时刻） | `set_phase` / `emit_event` **不接受**该参数 | 不携带（tx_local 无证据语义） |
| `s5_result` | `rec.s5_result`，S5 执行处唯一写入；T6 禁止 `not_run` | 不接受外部传入 | 不携带 |
| `token_fp` | **凭据行指纹**：迁移开始时由 `token_fp_from_credential(token_row)` 计算一次（`sha256_hex(token_bytes)` 的 64 位小写 hex）存入只读的 `rec.token_fp` | `set_phase` / `emit_event` 不接受 `token_fp` 参数；写入前校验 `^[0-9a-f]{64}$` 且等于 `rec.token_fp` | 不携带 |
| `s5_failed_ever` | `历史(链上最后一条列值) OR (s5_result=="failed")` | 历史值只来自已落库链 | 不携带 |
| `seq` | `last.seq + 1`（首事件 1） | 由写事务内生成，调用方不得传入；`UNIQUE(migration_id,seq)` 兜底 | 不携带（无链） |
| `prev_sha` | 首事件 `GENESIS(mid)`；其余 `sha256_hex(canon(上一事件行))` | 写事务内由已验证链计算 | 不携带 |
| `ts` | 当前 UTC 毫秒 | — | 携带 |

**`token_fp` 的完整实现链（P0-1）**

1. **唯一可信来源**：迁移凭据行。`rec.token_fp = token_fp_from_credential(token_row)`，在 T2 之后、S1 之前计算一次，此后只读；
2. **写入路径**：`set_phase` → `emit_event(event, detail)` → durable 后端 `write_event()` 从 `rec.token_fp` 取值，**作为独立列** `token_fp` 与 `detail_json` 同一条 `INSERT` 落库（`detail_json` 内**不重复**该字段，全篇唯一口径 = 独立列）；
3. **写入前校验**：格式（64 位小写 hex）+ 与 `rec.token_fp` 相等 + 与凭据行当前值相等；任一不符 → `required_evidence_missing()` 返回 `"token_fp"`，T6 拒写，`set_phase` 返回 `False`；
4. **β′ 读取路径**：`SELECT token_fp FROM system_events WHERE migration_id=?` 取 T6 行（`E1` 定位的那一条）的**真实列值**，与当前凭据行重算值比对；缺失 / 非 64 hex / 不一致 → E2 失败 → 禁 T7/T8；
5. **不得降级**：`token_fp` 为空字符串、`NULL`、`"unknown"` 之类占位值一律视为缺失（DDL 的 `NOT NULL CHECK(length=64)` 与写入前校验双保险）。

**规范化与哈希规则（唯一口径）**

1. 规范化 JSON：`json.dumps(obj, sort_keys=True, separators=(",",":"), ensure_ascii=False)`
2. 编码：UTF-8（无 BOM）；布尔小写；`null` 保留；整数不写成浮点；时间 `YYYY-MM-DDTHH:MM:SS.sssZ`
3. **参与哈希的字段集合（durable）**：`{event, migration_id, seq, prev_sha, token_fp, s5_failed_ever, detail, ts}`——即事件行的"可重建视图"，`id` 与自增顺序不参与
4. 增删字段必须同时改 `schema_version` 并重新定义哈希集；**旧事件不重算、不改写**
5. `sha256_hex(x)=hashlib.sha256(x.encode("utf-8")).hexdigest()`；`GENESIS(mid)=sha256_hex("GENESIS:"+mid)`
6. `seq` 从 1 起、连续 +1、跨重启不重置、不跳号、不复用、不回填

**`write_event()`：完整证据链验证 + 追加，全部在同一写事务内（P0-3）**

```python
# 伪代码：唯一 durable 写入权威入口 —— 写入 + 提交结果确认（reconcile）一体
def write_event(rec, event, detail):
    exp  = None                    # 本次待写入事件的完整预期（8 字段，供重查逐字段比对）
    conn = None
    st   = "CONN_OPENED"           # 写入阶段标记（见下表）
    try:
        conn = audit_conn()
        st = "BEGINNING"
        conn.execute("BEGIN IMMEDIATE")          # 写锁在事务开始即取得
        st = "TX_OPEN"

        rows = conn.execute(
            "SELECT event,migration_id,seq,prev_sha,token_fp,s5_failed_ever,detail_json,ts "
            "FROM system_events WHERE migration_id=? ORDER BY seq ASC", (MID,)).fetchall()
        verify_full_chain(rows, MID)             # C1–C8 全链校验，缺一即 EvidenceChainBroken

        last = rows[-1] if rows else None
        hist_failed = bool(last.s5_failed_ever) if last else False
        new_failed  = hist_failed or (rec.s5_result == "failed")
        if hist_failed and not new_failed:
            raise EvidenceMonotonicityViolation(MID)
        seq      = (last.seq + 1) if last else 1
        prev_sha = sha256_hex(canon_event_row(last)) if last else GENESIS(MID)
        tfp      = rec.token_fp
        if not re.fullmatch(r"[0-9a-f]{64}", tfp or "") or tfp != credential_token_fp(MID):
            raise EvidenceIntegrityError("token_fp")
        body = canon(dict(detail, schema_version=EVIDENCE_SCHEMA_VERSION))
        ts   = now_iso()                         # INSERT 前固定；重查时用同一值比较
        exp  = dict(event=event, migration_id=MID, seq=seq, prev_sha=prev_sha,
                    token_fp=tfp, s5_failed_ever=int(new_failed),
                    detail_json=body, ts=ts)     # ← 全部 8 列，逐字段可比较

        st = "INSERTING"
        conn.execute("INSERT INTO system_events(event,migration_id,seq,prev_sha,token_fp,"
                     "s5_failed_ever,detail_json,ts) VALUES (?,?,?,?,?,?,?,?)",
                     (event, MID, seq, prev_sha, tfp, int(new_failed), body, ts))
        st = "INSERTED"

        st = "COMMITTING"
        conn.execute("COMMIT")
        st = "COMMITTED"                         # 正常返回 ⇒ 结果确定，无需重查
        rec.s5_failed_ever = new_failed          # 只在确认提交后提交内存
        rec.last_seq = seq
        return True

    except EvidenceMonotonicityViolation:
        safe_rollback(conn)                      # 早于 INSERT，必然未写入
        raise
    except EvidenceChainBroken as e:
        safe_rollback(conn)
        non_db_log("evidence_chain_broken", e)   # 不重建、不补写、不覆盖、不删历史
        return False
    except Exception as e:
        non_db_log("event_write_exception", dict(stage=st, err=e))
        safe_rollback(conn)                      # ROLLBACK 抛错 ⇒ 结果未知，不得据此判定
        if exp is None:                          # 尚未构造出完整预期 ⇒ 根本没到 INSERT
            return False
        return settle_uncertain(rec, exp, st)    # ← 唯一裁决点（见"提交结果确认"）
    finally:
        close_quiet(conn)                        # close 抛错只记日志，不参与结果判定
```

**写入阶段划分（七态，禁止统一归为"事件未写入"）**

| # | 阶段标记 | 已发生的事实 | 可否直接判定结果 | 处理 |
| --- | --- | --- | --- | --- |
| 1 | `CONN_OPENED` | 连接已取，`BEGIN IMMEDIATE` 尚未成功 | **确定未写入**（无事务、无 INSERT） | 直接 `False`，不回滚、不重查 |
| 2 | `TX_OPEN` | `BEGIN IMMEDIATE` 成功，尚未 `INSERT` | **确定未写入** | 回滚即结束，`False` |
| 3 | `INSERTING` | `INSERT` 语句已发出、未见成功返回 | **不确定**（不在设计上赌语句级原子性） | 必须重查确认 |
| 4 | `INSERTED` | `INSERT` 返回成功，`COMMIT` 未开始/未返回 | **与 COMMIT 实际结果绑定** | 必须重查确认 |
| 5 | `COMMITTED` | `COMMIT` 正常返回 | **确定已提交** | 直接采纳，不重查 |
| 6 | `COMMITTING` | `COMMIT` 已发出、抛错 | **未知**（可能已提交、可能未） | 必须重查确认 |
| 7 | rollback/close 抛错 | `ROLLBACK` 抛错 ⇒ 事务最终状态未知（可能已回滚、可能仍挂起）；`close` 抛错 ⇒ 提交结果未改变，但"链是否完整"无法确认 | **均不得据此推断** | 已到过 `INSERT` 就必须重查；**close 抛错绝不等价于"未提交"** |

**提交结果确认 `settle_uncertain()`（唯一裁决点）**

```python
def settle_uncertain(rec, exp, st):
    """只依据真实持久化行裁决；不依据异常类型、不依据 ROLLBACK/close 的返回值。"""
    r = reconcile_event(exp)                     # 独立只读连接，单次尝试
    if r == Outcome.CONFIRMED:                   # A
        rec.s5_failed_ever = bool(exp["s5_failed_ever"])   # 只在此路径补写内存
        rec.last_seq = exp["seq"]
        non_db_log("event_confirmed_after_commit_error", exp["seq"])
        return True                              # 按"已提交"走成功路径；**绝不再次 INSERT**
    if r == Outcome.ABSENT:                      # B
        return False                             # 确认未提交：不推进 phase、不动内存、不补写
    # C：UNREADABLE / MISMATCH / CHAIN_INVALID / UNKNOWN
    non_db_log("commit_outcome_unresolved", dict(stage=st, seq=exp["seq"], result=r))
    halt_migration("commit_outcome_unresolved", exp)   # maintenance 保持；不重发；等人工
    return False

def reconcile_event(exp):
    conn = None
    try:
        conn = readonly_conn()                   # URI mode=ro 的全新连接，不复用 audit_conn
        conn.execute("PRAGMA query_only=1")
        rows = conn.execute(SELECT_CHAIN_SQL, (MID,)).fetchall()
    except Exception as e:
        non_db_log("reconcile_unreadable", e)
        return Outcome.UNREADABLE                # **查询失败 ≠ 事件不存在**
    finally:
        close_quiet(conn)

    if not rows:
        return Outcome.ABSENT if exp["seq"] == 1 else Outcome.UNKNOWN
    try:
        verify_full_chain(rows, MID)             # 对实际持久化链重跑 C1–C8
    except EvidenceChainBroken:
        return Outcome.CHAIN_INVALID
    hit = next((r for r in rows if r.seq == exp["seq"]), None)
    if hit is None:
        # 目标 seq 缺失：只有"链尾 seq < 目标 seq"才能确认未提交
        return Outcome.ABSENT if rows[-1].seq < exp["seq"] else Outcome.UNKNOWN
    if not row_fields_equal(hit, exp):           # 8 字段逐项严格比较（含 detail_json 字节与 ts）
        return Outcome.MISMATCH
    if hit.seq != rows[-1].seq:
        return Outcome.UNKNOWN                   # 目标行后还有事件：非单一写入者，待人工
    return Outcome.CONFIRMED
```

`row_fields_equal(hit, exp)` **必须逐项比全部 8 个字段**，任一项不同即 `MISMATCH`：`event`、`migration_id`、`seq`（整数）、`prev_sha`、`token_fp`、`s5_failed_ever`（转 `int` 后比）、`detail_json`（**字节级比较**，不再做二次规范化以免掩盖篡改）、`ts`（字符串精确相等）。**只判断 `seq` 是否存在不算确认。**

**三种结果与动作（P0 全部落在实际伪代码里）**

| 结果 | 判定条件 | 动作 | phase | 内存 `s5_failed_ever` | 是否重发 |
| --- | --- | --- | --- | --- | --- |
| **A 已提交** | 目标行存在 ∧ 8 字段全一致 ∧ 全链 C1–C8 通过 ∧ 目标行为链尾 | 采纳本次事件，返回 `True`；`set_phase` 按正常成功路径推进 | 正常推进 | 按 `exp["s5_failed_ever"]` 更新 | **禁止**（已落库） |
| **B 确认未提交** | 链为空且 `seq=1`，或链尾 `seq < exp.seq`（且链本身通过 C1–C8） | 返回 `False` | **不推进** | **不更新**（不提前提交） | 禁止（不补写） |
| **C 无法确认** | 只读重查不可用 / 目标行存在但字段不一致 / 链断裂 / 目标行后仍有事件 / 结果自相矛盾 | `halt_migration()`：maintenance 保持、写 `migration-fault.log`、不推进 phase、不开放写入 | 保持原值 | 保持原值 | **禁止**；等人工 |

**内存与持久状态的一致性（硬规则）**

1. `rec.s5_failed_ever` **只能**在 `COMMIT` 正常返回或 A 路径确认后更新；B/C 路径一律不动。
2. `rec.phase` **只能**在 `emit_event` 返回 `True`（含 A 路径采纳）之后更新；`set_phase` 中 `rec.phase = new` 是确认成功后紧邻的下一条语句。
3. 已提交但调用方尚未拿到返回值 ⇒ 走 A 路径恢复确认，**不得**把它当作"未提交"继续另一个转换。
4. 由此排除两类分裂：**(a)** 库里已有 `→COMMITTED` 事件而内存仍按 `UNKNOWN` 走 T8；**(b)** 库里已有 T6 事件而进程把 T6 当作从未发生、重复 `COMMIT_ATTEMPTED → UNKNOWN`。
5. 确认成功到 `rec.phase = new` 之间的窗口内若发生任何异常（进程被杀除外），一律 `halt_migration`，**不得**回退到"事件未写入"分支。
6. `ROLLBACK` 抛错不得推断已回滚；`close` 抛错不得推断未提交；独立只读连接读取失败不得解释为"事件不存在"；任何不确定都不允许重新提交同一逻辑事件。

`verify_full_chain(rows, mid)` 的判定项（**在同一次 `BEGIN IMMEDIATE` 事务内**，任一不过即 `EvidenceChainBroken`）：

| # | 校验 | 说明 |
| --- | --- | --- |
| C1 | `rows` 非空时首行 `seq == 1` | 起点唯一 |
| C2 | 首行 `prev_sha == GENESIS(mid)` | 链锚点 |
| C3 | 相邻行 `seq` 严格 +1，无跳号、无重复 | 连续性 |
| C4 | 每行 `prev_sha == sha256_hex(canon_event_row(前一行))` | 逐条链式对齐（**不只验最后一条**） |
| C5 | 每行 `detail_json` 重新规范化后与库内字节完全一致（`canon(json.loads(detail_json)) == detail_json`） | 防"正文被改但哈希未变" |
| C6 | `token_fp` 逐行满足 `^[0-9a-f]{64}$` | 格式一致 |
| C7 | `s5_failed_ever` 逐行单调不减（`row[i] >= row[i-1]`） | 历史失败不可清除 |
| C8 | 每行 `migration_id == mid`（由查询条件保证，另做断言） | 防跨迁移串链 |

**不得只验尾**：`write_event` 不提供"只读最后一条"的快速路径；任何"看起来连续"的尾行都要以 C1–C8 全链复核为前提。

**`emit_event()` 与 `set_phase()`（统一入口：`set_phase` 只调 `emit_event`）**

```python
# 伪代码：唯一事件入口。全仓只有 emit_event 内部允许调用两个后端写入函数

def emit_event(rec, event, detail):
    """按 DURABILITY_OF 分派后端；原样透传 detail，不再规范化、不改字段、不补默认值。"""
    mode = DURABILITY_OF[event]
    if mode == "tx_local":
        return write_tx_event(rec, event, detail)     # rec.conn / 迁移事务内 / migration_tx_notes
    if mode == "durable":
        return write_event(rec, event, detail)        # audit_conn() / BEGIN IMMEDIATE / system_events
    raise IllegalDurability(event, mode)              # 未登记的事件类型一律拒写

def write_tx_event(rec, event, detail):
    try:
        rec.conn.execute(
            "INSERT INTO migration_tx_notes(migration_id,old_phase,new_phase,reason,ts) "
            "VALUES (?,?,?,?,?)",
            (MID, rec.phase.name, detail.get("new_phase"), detail.get("reason"), now_iso()))
    except Exception as e:
        non_db_log("tx_local_note_failed", e)          # 非权威，失败仅日志
    return True                                        # phase 仍推进（见语义对照）

def set_phase(rec, new, reason):
    """唯一状态转换入口；两种后端都只经 emit_event，不得直连 write_event / write_tx_event。"""
    old = rec.phase
    if (old, new) not in LEGAL_TRANSITIONS:
        raise IllegalTransition(old, new)
    mode = DURABILITY[(old, new)]

    detail = dict(old_phase=old.name, new_phase=new.name, reason=reason,
                  durability=mode)

    if mode == "tx_local":                             # T1/T2：随迁移事务，非权威
        emit_event(rec, "migration_phase", detail)     # → write_tx_event（失败仅日志）
        rec.phase = new                                # tx_local 的 phase 推进与事件写入解耦
        return True

    if (old, new) == (Phase.COMMIT_ATTEMPTED, Phase.UNKNOWN):        # T6：证据必须齐
        detail["k1_proof"] = k1_proof_from_state(rec.k1_state)       # 只读判定结果
        detail["s5_result"] = rec.s5_result                          # 本次实际结果
        missing = required_evidence_missing(rec, detail)             # §1.4 字段 + token_fp 格式/一致性
        if missing or not all_true(detail["k1_proof"]):
            non_db_log("t6_evidence_incomplete", missing); return False

    ok = emit_event(rec, "migration_phase", detail)    # → write_event（内含提交结果确认）
    if not ok:
        return False                                   # B/C 路径：状态不推进
    rec.phase = new                                    # 仅 A/正常提交后推进
    return True
```

**`required_evidence_missing(rec, detail)`（T6 专用，返回缺失/不合格项名或 `None`）**

依次检查：`migration_id`、`old_phase=COMMIT_ATTEMPTED`、`new_phase=UNKNOWN`、`k1_proof` 四布尔全 true 且含 `evidence_ts`、`s5_result ∈ {ok, failed}`（`not_run` 视为缺失）、`token_fp` 存在且 `^[0-9a-f]{64}$` 且等于 `credential_token_fp(MID)`、`rec.s5_failed_ever` 与 `rec.s5_result` 一致（`failed ⇒ True`）。任一不过 → T6 不写、`set_phase` 返回 `False`（MC43）。

**写入结果不确定时的处理**：已完整实现在 `write_event` / `settle_uncertain` / `reconcile_event` 伪代码中（见上），不再以"规则表"形式存在——规则表与伪代码不一致正是本轮 P0。

**语义对照**

| 类型 | 落表 | 事件失败时 | 内存 phase | 可否对外作为"已确认状态" |
| --- | --- | --- | --- | --- |
| `tx_local` | `migration_tx_notes` | 记日志 | **已改为新值** | **不可**（随迁移事务回滚消失；不进证据链，β′ 不读） |
| `durable` | `system_events` | 返回 `False`，**不改** | 仍为旧值 | 旧值仍是唯一确认状态 |
| `durable` 且 T6 证据不全 / `token_fp` 不合格 | `system_events`（无写入） | 返回 `False`，**不写事件** | 仍 `COMMIT_ATTEMPTED` | 旧值仍是唯一确认状态；按 T6′ 处理 |
| `durable` 且链损坏（C1–C8 任一失败） | `system_events`（无写入） | 返回 `False`，**不补写** | 不推进 | 只写 `migration-fault.log`；maintenance |

### 2.2 `COMMITTED` 的五条件门禁（含历史失败门禁）

进入阶段 C 前必须**同时**满足（条件集对三条入口相同，只是转换编号、证据来源与失败去向不同）：

0. **入口证据成立**（仅 β′）：E1–E3 校验通过 ∧ `s5_failed` 由持久事件列恢复为 `False`（§1.4）；α 的 K1 证明来自本进程 §3.1 流程，β 的 `K1_β` 来自启动自证，均不需重读历史事件；
1. token 已确认可见（新连接只读查询成功）；
2. 终止证据成立：路径 α 用 `K1`（§3.1）；路径 β 用 `K1_β`（§1.2 路径表）；路径 β′ 用 **T6 事件内的 `k1_proof`**（§1.4，历史证明，不由当前 phase 推断）；
3. `K2` 成立（§3.2，即 S5 成功）；
4. **历史 S5 失败门禁**：`rec.s5_failed_ever == False`（路径 α 用本进程值，β′ 用事件列恢复值）——为 `True` 时**永久禁止 T7**（T7′），后续 `probe_ok` 不得清除；
5. 对应的 `durable` 状态转换事件写入成功——路径 α 是 `T7`（`UNKNOWN → COMMITTED`），路径 β 是 `T4`（`COMMIT_ATTEMPTED → COMMITTED`），`set_phase` 返回 `True` 且 `rec.phase == COMMITTED`。

**门禁必须在 `set_phase()` 之前执行**：历史失败是**业务状态禁止**，`write_event` 的单调性检查是**写入完整性约束**。前者不能靠后者的"拒写"实现（否则会出现"事件写不进去所以状态没变"的偶然正确），两者必须分别判定、分别测试（MC44/MC45/MC47）。

**转换编号由当前 phase 唯一决定**：当前 `COMMIT_ATTEMPTED` → `T4`；当前 `UNKNOWN` → `T7`。不得互换，也不得"为了套用某个编号"而先改 phase。

**`set_phase` 的成功与失败语义（与 §2.1 的 A/B/C 结果一一对应）**

| `emit_event` 结果 | 含义 | `set_phase` 返回 | `rec.phase` | 调用方后续 |
| --- | --- | --- | --- | --- |
| 正常 `COMMIT` 返回 | 事件确定已提交 | `True` | 改为新值 | 按成功路径继续（α 进阶段 C；β 进阶段 C） |
| A（`COMMIT` 抛错，重查确认存在且全字段一致、全链通过） | 事件**实际已提交**，只是调用方没收到返回值 | `True` | 改为新值 | **按成功路径继续**；不得再判"事件失败"分支 |
| B（重查确认目标行不存在） | 事件确实未提交 | `False` | 保持旧值 | 走本文各失败分支（`append_reason` / 保守恢复） |
| C（不可读 / 字段不一致 / 链断裂 / 自相矛盾） | 结果无法确认 | `False` | 保持旧值 | `halt_migration`：maintenance 保持、只写 `migration-fault.log`、不重试、不开放写入、等人工 |
| T6 证据缺失（未发出 `INSERT`） | 证据不合格 | `False`（不写事件） | 保持 `COMMIT_ATTEMPTED` | 按 T6′ 同口径（停 `COMMIT_ATTEMPTED`、文件日志） |

> 对 `T4/T5/T7/T8` 而言，"事件失败"分支**只对应 B 与 T6 式证据缺失**；A 不得被当作失败处理（否则会造成"库里已有事件、内存却按未提交继续"的分裂）；C 不得被降级为 B。

**`evidence_ok` 的定义**（仅 β′ 需要）：E1 ∧ E2 ∧ E3 全通过 ∧ `s5_failed == False`；为 `False` 时不得进入 T7/T8 判定。

```python
# 伪代码
token_gate = token_visible and k1_or_beta and k2          # ①–③
hist_gate  = not rec.s5_failed_ever                        # ④ 历史失败门禁（α / β′ 共用）
gate       = token_gate and hist_gate

if rec.phase == Phase.COMMIT_ATTEMPTED:        # 只可能是路径 β
    if not (gate and set_phase(rec, Phase.COMMITTED, "recovery_gate_passed")):
        # T4′：不转换，不退化为 UNKNOWN（路径 β 没有 →UNKNOWN 这一步）
        append_reason(rec, "recovery_gate_failed", ...) if k1_beta else non_db_log(...)
        handle_post_commit_failure(...)
    else:
        enter_phase_c(rec)

elif rec.phase == Phase.UNKNOWN:               # 路径 α 或 β′
    if is_beta_prime and not evidence_ok:      # E1–E3 未通过：不得判 T7/T8
        append_reason(rec, "evidence_unverified", ...)
        handle_post_commit_failure(...)
    elif not hist_gate:                        # ④ 历史曾失败 → T7′（永久）
        append_reason(rec, "historical_s5_failure", ...)   # 只记原因，不转换
        handle_post_commit_failure(...)
    elif not token_gate:                       # ①–③ 不全 → 停留 UNKNOWN
        append_reason(rec, "unknown_gate_incomplete", ...)
        handle_post_commit_failure(...)
    elif not set_phase(rec, Phase.COMMITTED, "token_visible_and_isolated"):
        append_reason(rec, "committed_event_failed", ...)     # 仍停留 UNKNOWN
        handle_post_commit_failure(...)
    else:
        enter_phase_c(rec)                     # 唯一的阶段 C 入口
```

**T8（`UNKNOWN → TX_ROLLED_BACK`）同样受 ④ 约束**：`hist_gate` 为 `False` 时一律走 T8′，即使 token 与迁移对象均不可见；判定顺序同样是"历史门禁 → 结论条件 → `set_phase`"。

### 2.3 补偿转换的合法性（明确定义）

| 补偿 | 允许 | 说明 | 失败行为 |
| --- | --- | --- | --- |
| `COMMIT_ATTEMPTED → UNKNOWN` 作为"门禁失败/事件失败的补偿" | **不允许** | `COMMIT_ATTEMPTED→UNKNOWN` 的唯一触发是 T6（COMMIT 抛异常 ∧ K1 成立）。路径 β 门禁失败时不转换（T4′），路径 α 已处 `UNKNOWN`，无需补偿 | 保持 `COMMIT_ATTEMPTED` / 保持 `UNKNOWN`，保守恢复 |
| `UNKNOWN → COMMITTED` 失败后停留 UNKNOWN | 允许（不转换） | 停留即安全 | 走保守恢复 |
| `UNKNOWN → COMMITTED` 但 **S5 曾失败** | **不允许** | S5 失败意味着"探测时刻存在写者"，token 可见也不足以证明外部世界已稳定 | 保持 `UNKNOWN`，继续保守恢复；不写 success、不开放写入 |
| `UNKNOWN → TX_ROLLED_BACK` 但 **S5 曾失败** | **不允许**（T8′） | 同源理由：看不到 token 也不能证明外部写者已消失 | 保持 `UNKNOWN`，继续保守恢复 |
| β′ 的 T7/T8 但 **E1–E3 未通过** | **不允许** | 缺历史 K1 证明或 `s5_failed` 不可恢复时，任何结论都无依据 | 停 `UNKNOWN`；链完整时一条 `evidence_unverified`，链断裂时只写文件日志；不进阶段 C |
| T6 证据构造失败后的"补写" | **不允许** | 不得只补部分字段、不得跳过校验、不得用 `migration_note` 冒充 T6 | 返回 `False`，停 `COMMIT_ATTEMPTED`，文件日志 |
| `token_fp` 缺失 / 非 64 位 hex / 与凭据行不符 | **不允许**（DB 的 `CHECK(length=64)` + 写入前校验双保险） | 指纹是"迁移身份"的一部分，无法降级 | T6 拒写（`set_phase` 返回 `False`）；β′ E2 失败 |
| 事件链 C1–C8 任一失败 | **不允许**追加 | 断链不可自动修复 | 不写事件、不推进 phase、maintenance、只写文件日志 |
| 写入结果不确定（`COMMIT`/`ROLLBACK`/`close` 抛错） | **不允许重发**同一逻辑事件 | 重发会造成重复 `seq` / 分叉链 | 独立只读连接重查：A（一致且链通过）采纳并按成功推进；B（确认不存在）返回失败、不推进；C（不可读/不一致/链断裂）停 maintenance、只写文件日志 |
| 重查发现目标行存在但字段不一致 / 目标行之后仍有事件 | **不允许采纳** | 只凭 `seq` 存在就采纳会引入别人写的或损坏的行 | 判 C：不推进 phase、不开放写入、`migration-fault.log`、等人工 |
| 只读重查不可用（`SQLITE_BUSY`/文件不可读/连接失败） | **不允许解释为"事件不存在"** | 把查询失败当未提交会造成"库里已有事件、再走另一条转换" | 判 C：maintenance 保持、不重发、不开放写入 |
| `close` / `ROLLBACK` 抛错后凭异常类型推断写入结果 | **不允许** | 异常只说明调用没收到确认，不说明落库与否 | 一律走重查；仅有可验证的持久化行才采纳 |
| `COMMIT_ATTEMPTED → UNKNOWN` 但 **K1 不成立** | **不允许**（T6′） | 原连接终止未被证明，写库会撞锁并被误读 | **不转换**，phase 停留 `COMMIT_ATTEMPTED`；只写文件日志；maintenance |
| 二次补偿也失败（T6 事件失败） | — | **不推进任何状态** | 保持 maintenance；非数据库日志；`handle_post_commit_failure`；非零退出；**绝不开放写入** |
| `COMMITTED → UNKNOWN` | **不允许** | 一旦 COMMITTED 已确认，后续失败属阶段 C，由 `handle_post_commit_failure` 处理，phase 不再回退（事件记 `migration_rollback`） | — |

**为什么不需要 "COMMITTED 回退"**：`set_phase` 事件先写，故不存在"内存已是 COMMITTED 但事件未落"的状态。阶段 C 的失败不改变"迁移曾被提交"这一事实，用 `migration_rollback` 事件表达即可；此时库已由备份替换，success 不存在。

### 2.4 三重一致性（PH5 必须断言）

| 维度 | 断言方式 |
| --- | --- |
| 内存 phase | 迁移进程内 `rec.phase.name` 记录到测试输出 |
| 数据库 durable 事件 | `SELECT detail_json FROM system_events WHERE event='migration_phase' ORDER BY id`，解析出 `new_phase` 序列 |
| 实际执行路径 | 是否调用 `enter_phase_c()`（用探针桩记录）、是否写 success、是否开放写入 |

三者必须一致：`COMMITTED` 出现在内存与事件中 ⇒ `enter_phase_c` 被调用一次；事件里没有 `COMMITTED` ⇒ 内存不得为 `COMMITTED` ⇒ 未进入阶段 C ⇒ 无 success、写入仍关闭。

### 2.5 测试（PH9–PH11、PH9b、PH10b + MC19–MC21 + MC38–MC56）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| PH9 | **路径 α**：已 `UNKNOWN`，token 可见、K1/K2 成立，`T7 →COMMITTED` 事件写失败 | 注入写失败 | `set_phase` 返回 False；内存仍 `UNKNOWN`；**不退化、不逆转**（也不得改走 T4）；未进入阶段 C；无 success；写入关闭 |
| PH9b | **路径 β**：`COMMIT_ATTEMPTED`，token 可见、`K1_β`/K2 成立，`T4 →COMMITTED` 事件写失败 | 注入写失败 | 内存仍 `COMMIT_ATTEMPTED`（T4′）；`migration_note` 一条；**无 `→UNKNOWN` 事件**；未进入阶段 C；无 success |
| PH10 | **路径 α**：T6（`→UNKNOWN`）事件与 T7（`→COMMITTED`）事件均失败 | 注入两次失败 | 无任何 `migration_phase` 事件；内存停留 **`COMMIT_ATTEMPTED`**（T6 事件失败 → §2.1 不推进）；maintenance 保持；非数据库日志两条；保守恢复；退出码非零 |
| PH10b | **路径 β**：T4 事件失败且 `migration_note` 也失败 | 注入两次失败 | 无 `migration_phase` 事件；内存停 `COMMIT_ATTEMPTED`；maintenance 保持；文件日志两条；无 success |
| PH11 | 同 PH10 / PH10b | 检查写入入口与 success | 写入 503；`schema_migrations` 中该 mid 无 `success`；三重一致性断言全过（内存 phase、事件序列、`enter_phase_c` 次数三者一致） |
| MC19 | COMMIT 抛异常，且 `rollback_for_migration()` 抛错（如 `SQLITE_BUSY`） | 注入回滚失败；统计 S4/S5 完成前的数据库写入 | S4（close）与 S5（探测）**完成之前**，`system_events` 写入次数 == **0**；回滚失败只出现在 `migration-fault.log`；`close()` 成功则 K1 成立 → S5 后可写 `→UNKNOWN`；`close()` 也失败则按 MC14 走 T6′（停 `COMMIT_ATTEMPTED`）；两种情形均无 success |
| MC20 | `UNKNOWN` 态；K1 成立、S5 曾失败、新连接 token 可见（同一进程走后 T7 判定；另设 β′ 变体：重启后由事件流恢复 `s5_failed=True`） | 走 T7 判定 | **仍为 `UNKNOWN`**（T7′ 禁止）；不进入阶段 C；无 `→COMMITTED` 事件；无 success；保守恢复；写入关闭。β′ 变体结论相同，且必须先有 E1–E3 通过 |
| MC38 | 路径 α，K1 成立、S5 失败（或成功），T6 写入 | **读 DB 实际行**（`SELECT event,migration_id,seq,prev_sha,token_fp,s5_failed_ever,detail_json,ts`），逐字段校验 `migration_id`/`old_phase`/`new_phase`/`k1_proof`（四布尔+`evidence_ts`）/`s5_result`/`s5_failed_ever`/`seq`/`prev_sha`/`ts`，以及 **`token_fp` 独立列**（断言 `length=64`、小写 hex、等于凭据行重算值、`detail_json` 内**不含**该字段）；随后**真实重启**，β′ 用同一套字段复核 | 字段齐全且自洽；`seq=1`、`prev_sha=GENESIS(mid)`；`token_fp` 为真实列值且与凭据行一致；重启后 E1–E3 全过 |
| MC39 | 任意后续转换（T7/T8/T4/T5）与 `migration_note` | 读 DB 实际行 | 每条都含 `migration_id`、`s5_failed_ever`、`seq`、`prev_sha`；`seq` 连续 +1 无跳号；每条 `prev_sha` == 上一事件规范化 JSON 的 sha256（逐条重算验证）；无一条缺少证据字段 |
| MC40 | 已持久化 `s5_failed_ever=true` | 直接调 `write_event`/`append_reason` 要求写 `false` | 抛 `EvidenceMonotonicityViolation`；事务回滚；DB 无新行；`rec.s5_failed_ever` 仍 `true`；`phase` 不变；只落文件日志 |
| MC41 | 两个写入者并发追加事件（线程/进程各一，均走统一入口） | 同时开始写 | 无重复 `seq`（`UNIQUE(migration_id,seq)` 兜底）、无分叉 `prev_sha`（`UNIQUE(migration_id,prev_sha)` 兜底）；失败方得到写失败、不重试、不推进 phase；成功方序严格连续；`s5_failed_ever` 不倒退 |
| MC42 | 人为制造链断裂（删除中间事件 / 篡改 `prev_sha` / 改 `seq`）后追加 `migration_note(evidence_unverified)` | 观察 | **不写** DB note；不重建、不覆盖、不重算历史；只写 `migration-fault.log`；`phase` 不变；无 success |
| MC43 | T6 证据构造失败（缺 `k1_proof` 字段 / 布尔不全 true / `s5_result=not_run` / `token_fp` 缺失 / `token_fp` 非 64 位 hex / `token_fp` 与凭据行不符，逐一构造） | 调 `set_phase(COMMIT_ATTEMPTED→UNKNOWN)` | 每种都返回 `False`；**DB 无 T6 行**（`SELECT count(*)` 为 0）；内存仍 `COMMIT_ATTEMPTED`；不开放写入；文件日志记录对应缺失项 |
| MC44 | 路径 α：T6 时 S5 失败（`s5_failed_ever=true` 已落库），随后同一进程 S5 探测成功且 token 可见 | 走 §2.2 门禁 | `hist_gate=False` → **禁止 T7**；DB 无 `→COMMITTED` 行；一条 `historical_s5_failure` note（`s5_failed_ever` 仍为 1）；未进阶段 C；无 success |
| MC45 | 路径 α：同上，但 token 与迁移对象均不可见 | 走 §2.2 门禁 | `hist_gate=False` → **禁止 T8**（T8′）；DB 无 `→TX_ROLLED_BACK` 行；`s5_failed_ever` 仍为 1；未进阶段 C；无 success |
| MC46 | 路径 β′：真实重启，事件列恢复 `s5_failed_ever=1` | 分别构造 token 可见 / 均不可见 | 前者 T7 被禁止；后者 T8 被禁止；两者均停 `UNKNOWN`；无 success；maintenance 保持 |
| MC47 | 已 `s5_failed_ever=1`；分别构造：① 合法 `probe_ok`（`s5_result="ok"`、`s5_failed_ever` 沿用 1）② 带清除语义的 `probe_ok`（`s5_failed_ever=false` / `clear=true`） | 走 `write_event` / `emit_event` | ① 正常写入（列值仍 1，历史不被清除）② 拒写（`EvidenceMonotonicityViolation`），**DB 实际查验**：无新行、`SELECT MAX(s5_failed_ever)` 仍为 1、已有行该字段仍 true；只落文件日志 |
| MC48 | `INSERT` 真实成功、`COMMIT` 真实提交后，注入驱动层抛错（等价于"提交成功但未收到确认"） | 触发 `write_event` 异常分支；随后用 `mode=ro` 独立连接读取 `system_events` | 走 A：目标 `seq` 行存在、8 字段逐项一致、C1–C8 通过 → 采纳并返回 `True`；`set_phase` 推进 phase；**DB 中该 `seq` 只有一行**（对比写入前后 `count(*)`，无第二次 `INSERT`）；`rec.s5_failed_ever` 与列值一致 |
| MC49 | `INSERT` 后 `COMMIT` 未成功（在 `COMMIT` 前断连/注入失败） | 同上重查 | 走 B：链尾 `seq < 目标 seq` 或无行且 `seq=1` → 返回 `False`；`rec.phase` 不变；DB 无目标行；`rec.s5_failed_ever` 未被提前更新 |
| MC50 | `COMMIT` 抛错后，只读重查不可用（库被独占锁 / 文件权限收回 / 连接失败） | 注入只读连接失败 | 走 C：`halt_migration`；maintenance 保持；无第二次写入尝试（`INSERT` 调用计数 == 1）；业务写入 503；`migration-fault.log` 有 `reconcile_unreadable`；**不把查询失败当成"不存在"** |
| MC51 | 目标 `seq` 行存在，但 `event` / `detail_json` / `token_fp` / `prev_sha` / `ts` 中任一项与本次预期不同（逐项各构造一例） | 重查 | 走 C：`MISMATCH` → 不采纳、不推进 phase、不开放写入、停 maintenance；DB 该行保持被改动后的原样，**不被覆盖或修正** |
| MC52 | ① `ROLLBACK` 抛错而事件实际已提交 ② `ROLLBACK` 抛错而事件确实未提交 ③ `close` 抛错而事件已提交 ④ `close` 抛错而事件未提交 | 四种组合分别构造，逐一读取 DB 实际行 | ①②③④ 均以持久化行为准：已提交 → 采纳（A）、无行 → 失败（B）；**不得依据异常类型猜测**；无重复 `seq`、无分叉链 |
| MC53 | 上述任一不确定场景结束后 | 同时读 `rec.phase`、`rec.s5_failed_ever`、`SELECT phase 事件行 / MAX(s5_failed_ever)` | 三者一致：事件列 `→COMMITTED` 存在 ⇒ `rec.phase==COMMITTED`；列值为 1 ⇒ `rec.s5_failed_ever==True`；不存在"库里已提交、内存仍判另一转换"或"库里有 T6、进程当没发生" |
| MC54 | 触发 T1/T2（`tx_local`）、T6/T7/T8 与 `migration_note`（durable） | 打桩记录 `emit_event` 调用与后端写入函数调用 | 每条事件都先经 `emit_event` 并按其 `DURABILITY_OF` 分派；**`set_phase` / `append_reason` 对 `write_event` / `write_tx_event` 的直接调用计数为 0** |
| MC55 | T1/T2 期间 | 读 `migration_tx_notes` 与 `system_events` | 提示行写入 `migration_tx_notes`；迁移事务提交后可见、回滚后消失；`system_events` 中**无**对应 `tx_local` 行；β′ 启动读取不触达该表 |
| MC56 | durable 事件（T6/T7/T8/note） | 观察 `write_event` 内部 | 仍在 `BEGIN IMMEDIATE` 内执行 C1–C8 全链校验后才 `INSERT`；`emit_event` 未提供任何绕过路径；人为断链后经 `emit_event` 追加仍被拒（只写文件日志） |


---

## 3. P1-1：K1 与 S5 的职责分离

### 3.1 K1（原连接终止证明）——只看四件事

| 条件 | 检查方式 | 禁止 |
| --- | --- | --- |
| 已隔离 | 连接包装对象 `quarantined == True`，其 `execute()` 一律抛 `QuarantinedError` | — |
| `close()` 成功 | **`conn_wrapper.close()`** 返回无异常（底层 close 已成功） | 不得用 `conn.close()` 绕过包装层 |
| 句柄不再可用 | 包装对象 `is_closed == True`；`close()` 后任何方法抛 `ConnectionClosed` | `is_closed` 不得被伪造 |
| **不在关闭后读取事务属性** | — | **禁止** `conn.in_transaction`（对象已关闭，该属性无定义/无意义） |

`in_transaction` 只在 **quarantine 之前**读取一次（属性读，不执行 SQL），用于决定是否需要尝试回滚；读取本身有独立异常边界（见下），读取失败记 `had_tx = UNKNOWN`。读取发生在关闭之前，属"终止尝试"的一部分，**不作为 K1 的组成条件**。

**对象关系与关闭接口（本轮统一）**

| 对象 | 角色 | 关闭方式 | 禁止 |
| --- | --- | --- | --- |
| `conn` | 底层原生连接（`sqlite3.Connection` 一类） | **只由包装层调用**，迁移流程不直接碰 | 迁移流程**不得**直接调用 `conn.close()` |
| `conn_wrapper` | 迁移连接包装层，持有 `conn` + `quarantined` / `is_closed` / `no_tx_read_after_close` | 迁移流程统一调用 `conn_wrapper.close()` | — |
| `conn_wrapper.close()` | 接口契约：内部调用底层 `close()`；**仅当底层返回成功**才置 `is_closed = True` | — | 底层抛错时不得伪造 `is_closed = True`；不得吞掉错误后仍标记成功 |
| `conn_wrapper.rollback_for_migration()` | 隔离后唯一放行 `ROLLBACK` 的内部通道 | — | 不得执行其他 SQL |
| `conn_wrapper.is_closed` | K1 的"句柄不可用"证据 | — | 不得由调用方写入 |

**关闭后的读取禁令**：`is_closed == True` 之后，不得再读 `conn.in_transaction`（也不得读任何底层属性）；K1 的"关闭后未读事务属性"以 `no_tx_read_after_close == True` 记录，该标志只在关闭前那次读取时置位，关闭后若发生任何底层属性访问则置 `False` 并使 K1 失败。

**quarantine 与 ROLLBACK 的执行顺序（本轮修正）**

上一版伪代码是"先 `quarantine`、再 `conn.execute("ROLLBACK")`"，但 quarantine 的语义是**该连接此后所有 `execute()` 抛 `QuarantinedError`**——所以那条 `ROLLBACK` 根本执行不到，K1 永远为 False，恢复路径被自己的安全机制卡死。

修正原则：**保留"先隔离、再终止"，但为迁移终止流程提供唯一一条内部回滚通道**。

| 通道 | 归属 | 允许的 SQL | 对其他 SQL | 隔离后 |
| --- | --- | --- | --- | --- |
| `conn.execute(...)` | 业务/通用 | 任意 | — | **一律 `QuarantinedError`**（含 `ROLLBACK`） |
| `conn_wrapper.rollback_for_migration()` | 仅迁移终止流程（S3） | **只允许 `ROLLBACK`** | 传任何其他语句 → `IllegalRecoverySql` | 唯一放行通道 |
| `conn_wrapper.close()` | 迁移终止流程（S4） | 不执行 SQL | — | 允许 |

`rollback_for_migration()` 的实现约束（设计级，不是代码）：

1. 语句在包装层硬编码为 `"ROLLBACK"`，**不接受调用方传入 SQL**，从根上排除"用恢复通道跑业务写"；
2. 先校验 `quarantined == True` 且 `not is_closed`，否则抛 `IllegalRecoveryState`；
3. 调用次数上限 1 次；重复调用返回 `AlreadyRolledBack`，不重发；
4. 失败（`SQLITE_BUSY`/已无事务/驱动错误）只 `non_db_log("rollback_for_migration_failed", ...)`，**不写数据库事件**，继续走 S4 `close()`；
5. 该通道**不证明**事务状态，只做"尽力终止"；K1 也不因它成功而成立，K1 只看隔离 + close + 句柄。

**S2 的异常保护（本轮修正）**

上一版把 `conn.in_transaction` 与 `quarantine(conn)` 写在异常保护范围之外。这两步任何一步抛出（属性访问触发驱动错误、包装对象构造失败、内部状态锁冲突等），异常都会直接冒泡出迁移终止流程，**跳过 `close()`**，留下一个既未隔离又未关闭的原连接——正是最危险的残留。修正为"三段独立异常边界 + 无条件关闭 + 关闭后统一判定"。

| 步骤 | 异常边界 | 抛错时 | 是否影响后续 |
| --- | --- | --- | --- |
| ① `had_tx = conn.in_transaction` | 独立 `try` | `had_tx = UNKNOWN`，`non_db_log("in_transaction_read_failed")` | **不影响**隔离、回滚尝试、关闭 |
| ② `quarantine(conn)` | 独立 `try` | `quarantined_ok = False`，`non_db_log("quarantine_failed")` | **不影响**关闭（仍必须尝试） |
| ③ `rollback_for_migration()` | 独立 `try`，前置条件 `quarantined_ok` | `non_db_log("rollback_for_migration_failed")` | **不影响**关闭 |
| ④ `conn_wrapper.close()` | 独立 `try`，**兜底必执行**（等价于 `finally` 语义） | `close_ok = False`，`is_closed` 保持 `False`，`non_db_log("conn_close_failed")` | — |

规则细化：

1. **①读取失败 → `had_tx = UNKNOWN`**：未知状态下，隔离成功后仍**尝试一次**回滚（尽力终止；`close()` 本身也会回滚，尝试只是提前结束事务），失败只记日志；**不得**把"尝试过回滚"当作"已知有事务"；
2. **②隔离失败 → `quarantined_ok = False`**：此后**禁止**调用 `conn.execute(...)`（含 ROLLBACK），**也禁止**调用 `rollback_for_migration()`（该通道的前置条件是 `quarantined == True`，隔离未成功时调用只会抛 `IllegalRecoveryState`），只允许走 ④ 关闭；
3. **③ 回滚通道只在 ② 成功后才可尝试**；失败不影响关闭，也不使 K1 成立；
4. **④ 关闭无条件执行**：前面任何一步失败都不得中断关闭流程；关闭失败必须落 `migration-fault.log`；
5. **K1 只看"可确认的事实"**：`quarantined_ok ∧ close_ok ∧ is_closed ∧ 关闭后未读事务属性`。其中 ② 抛错（隔离未确认）或 ④ 抛错（关闭未成功）**必然**使 K1 = False——隔离/关闭这类事实无法用别的事实补偿；而 `had_tx = UNKNOWN` 或 ③ 回滚失败**不**使 K1 为 False（它们不在这四个条件里）。

```python
# 伪代码：三段独立异常边界 + 无条件关闭
had_tx        = UNKNOWN     # UNKNOWN / True / False
quarantined_ok = False
close_ok       = False
k1             = False

try:                                                  # ① 属性读，独立捕获
    had_tx = conn.in_transaction
except Exception as e:
    had_tx = UNKNOWN
    non_db_log("in_transaction_read_failed", e)       # 仅非数据库日志

try:                                                  # ② 隔离，独立捕获
    quarantine(conn)
    quarantined_ok = True
except Exception as e:
    quarantined_ok = False
    non_db_log("quarantine_failed", e)                # 隔离失败不阻断关闭

if quarantined_ok and had_tx in (True, UNKNOWN):      # ③ 唯一内部回滚通道
    try:
        conn_wrapper.rollback_for_migration()         # 仅 ROLLBACK，最多 1 次
    except Exception as e:
        non_db_log("rollback_for_migration_failed", e)   # 不写数据库事件

try:                                                  # ④ 兜底关闭，必执行（统一走包装层）
    conn_wrapper.close()                              # 内部调用底层 close；仅在成功后置 is_closed=True
    close_ok = conn_wrapper.is_closed
except Exception as e:
    close_ok = False
    non_db_log("conn_close_failed", e)

# ⑤ 关闭之后再判定：只读包装对象标志，绝不读 conn.in_transaction
k1 = quarantined_ok and close_ok and conn_wrapper.is_closed and conn_wrapper.no_tx_read_after_close
```

**K1 判定的唯一口径**

| K1 | 条件组合 | 允许写 DB 事件 | phase 去向 |
| --- | --- | --- | --- |
| **成立** | 已隔离 ∧ `close()` 成功 ∧ 句柄不可用 ∧ 关闭后未读事务属性 | **允许**（S5 成功或失败都允许） | 路径 α：T6 → `UNKNOWN`，S7 只按 `T7/T8` 判定（**不出现 T4/T5**） |
| **不成立** | 上述任一缺失（隔离未置位或隔离抛错 / `close()` 抛错 / 句柄仍可用 / 关闭后读过事务属性） | **禁止**，无论 S5 是否成功 | **不转换**，停留 `COMMIT_ATTEMPTED`（T6′）；maintenance + 保守恢复或待人工 |

> `had_tx = UNKNOWN` 本身**不**使 K1 为 False（它不是 K1 的条件）；但"隔离抛错"必然使 K1 为 False，"关闭抛错"也必然使 K1 为 False。

**隔离期的写入禁令（本轮新增，硬性）**

| 阶段 | 允许的记录通道 | 禁止 |
| --- | --- | --- |
| S2–S5 未完成（K1 未确认，或 K1 已确认但 S5 未完成） | `<data_dir>/migration-fault.log`（追加写，含 `migration_id/token/reason/ts`）、标准错误 | `append_reason()`、`write_event()`、`set_phase()`、任何 `INSERT/UPDATE` |
| S5 完成且 K1 成立 | 非数据库日志 + 按 §1.3 写 `durable` 事件 | 早于 `→UNKNOWN` 的其它审计写 |

理由与 §1.3 硬规则 1–2 同源：原连接可能仍持写锁，第二写者会 `SQLITE_BUSY`，把"无法写事件"误判成"迁移状态异常"，污染后续判定；而且一旦写入失败，会诱导流程走向错误的补偿分支。

### 3.2 S5（瞬时无写者探测）——独立职责

| 项 | 定义 |
| --- | --- |
| 目的 | 证明**探测时刻**没有其他写者（含其他进程） |
| 动作 | 新探测连接 `BEGIN IMMEDIATE` → `ROLLBACK` → `close()` |
| 通过 | `busy_timeout` 内取得写锁 |
| **不通过的含义** | 有写者或探测本身失败；**不推断**原连接状态 |
| **不得作为 K1 替代** | K1 为 False 时，即使 S5 通过也**不写 DB 事件、不推进 phase**（停留 `COMMIT_ATTEMPTED`） |
| 关闭要求 | 探测连接必须显式 `close()`；未关闭视为探测失败（避免持锁） |
| **失败历史的持久性** | 每次 S5 结果都必须随下一条 `migration_phase`/`migration_note` 事件持久化（`s5_result` + 单调 `s5_failed_ever`，§1.4）；失败历史跨进程、跨重启永久有效，后续成功**不得清除**；`s5_failed_ever` 只能由 §2.1 统一入口写成一等列，业务代码不得直接赋值 |
| **不得依赖易失状态** | `s5_failed` 不存放在进程内存或 `migration-fault.log` 中作为判定依据；β′ 只认事件流 |

**两者关系**：K1 说"原连接不再持有事务"，S5 说"此刻没有别人在写"。**K1 ∧ S5 才是 K2**（§2.1 的两个条件），任一缺失都不得判定持久化状态。二者职责互不替代：K1 是**能否写入审计事件**的闸门，S5 只影响**能得出哪个结论**（`COMMITTED` / `TX_ROLLED_BACK` 都需要 S5 成功；`UNKNOWN` 只需 K1 成立）。

### 3.3 S5 之后的持续封锁

| 通道 | 手段 | 覆盖 |
| --- | --- | --- |
| 应用写入 | `maintenance` 标志（存 DB）→ 写入入口 503 | 所有请求线程 |
| 后台任务 | 任务状态机 `stopped`；每轮开始复查 maintenance | 调度/检测/测速/发布 |
| 连接池 | 池 `dead`，`checkout` 抛 `PoolClosed` | 池内所有连接 |
| CLI | 写命令需 `--allow-write` 且先读 maintenance | 人工操作 |
| 漏网进程 | `write_guard()` 读 maintenance + 两 PRAGMA，不满足即拒 | 任何走正式入口的写 |
| 完全绕过入口 | 库层约束（触发器/外键）+ 事后 `foreign_key_check` 与巡检 | 兜底可观测 |

**关键补充（本轮）**：S5 是瞬时探测，"探测后又被别人拿到写锁"是必须处理的情形。

| 情形 | 处理 |
| --- | --- |
| S5 通过后、文件替换前，又出现写者 | 替换前**再探测一次**（S5′），失败则 `abort_recovery`（退出码 4），备份不动 |
| `close()` 失败（K1 不成立） | **不判 `UNKNOWN`**：phase 停留 `COMMIT_ATTEMPTED`，**不写任何 DB 事件**（S5 成功也不例外），只写 `migration-fault.log`，maintenance + 保守恢复 / 待人工（T6′） |
| S5 失败但 K1 成立 | 仍 `UNKNOWN`（K2 不成立，故不得判 `COMMITTED`/`TX_ROLLED_BACK`）；**允许**写 `→UNKNOWN` 事件并携带 `s5_result="failed"`、`s5_failed_ever=true`；该事件经 §2.1 `write_event` 落库（`BEGIN IMMEDIATE` + 唯一约束）；随后保守恢复 |
| 重启后 β′ 恢复 | 由 T6/后续事件流重建 `s5_failed`（读 `system_events.s5_failed_ever` 一等列的最后值）；E1–E3 通过且 `s5_failed=False` 才允许 T7/T8；任何历史失败 → 永久禁止 |
| K1、S5 均失败 | 无 DB 事件、仅文件日志、phase 停留 `COMMIT_ATTEMPTED`、保守恢复 |
| 他进程重新取得写锁且拒绝释放 | 不重试、不杀进程；`abort_recovery`，人工介入 |

### 3.4 测试（MC14–MC27）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC14 | COMMIT 抛异常；`close()` 失败；探测也失败 | 判定 | **无任何 DB 事件**；`migration-fault.log` 有记录；phase 停留 `COMMIT_ATTEMPTED`（T6′）；保守恢复；写入关闭；无 success |
| MC15 | COMMIT 抛异常；`close()` 抛错，**S5 成功** | 判定 | K1=False → **仍停留 `COMMIT_ATTEMPTED`**；`system_events` 写入次数 0；无 `→UNKNOWN`；无 success；写入关闭；只写文件日志 |
| MC15b | `rollback_for_migration()` 抛 `SQLITE_BUSY` | 继续 S4/S5 | 只写 `migration-fault.log`；S4–S5 完成前 DB 写入 0；close 成功则 K1 成立、可写 `→UNKNOWN` |
| MC15c | 隔离后调用 `conn.execute("ROLLBACK")` | 观察 | 抛 `QuarantinedError`；DB 无写入；K1 不受影响（不影响判定） |
| MC15d | 隔离后调用 `rollback_for_migration("UPDATE ...")` | 观察 | 抛 `IllegalRecoverySql`；DB 无写入；恢复路径继续按既有规则 |
| MC16 | 探测连接被外部持有写锁 | S5 失败，K1 成立 | 判 `UNKNOWN`；有 `→UNKNOWN` 事件；保守恢复；写入关闭 |
| MC17 | S5 成功，随后注入他进程写锁 | 替换前 S5′ | 检出 → `abort_recovery`（码 4）；文件未替换；备份 sha256 不变 |
| MC18 | token 不可见、对象不可见、S5 成立 | 判定：① 路径 β（`K1_β` 成立，前置 `COMMIT_ATTEMPTED`）② 路径 α/β′（`K1` 成立，前置 `UNKNOWN`） | ① 走 `T5 →TX_ROLLED_BACK`；② 走 `T8 →TX_ROLLED_BACK`；两者终止、无 success；不得交叉（β 不得走 T8） |
| MC21 | K1 成立、**S5 曾失败**、token 不可见、对象不可见（同进程 + β′ 重启变体各一） | 判定 | **仍 `UNKNOWN`**（T8′ 禁止）；无 `→TX_ROLLED_BACK` 事件；不写 success；不开写入；保守恢复；β′ 变体需 E1–E3 通过后方可判定且结论仍为禁止 |
| MC22 | `conn.in_transaction` 属性读取抛异常 | 观察调用序列 | 仍执行 `quarantine()` 与 `close()`（close 尝试次数 = 1）；`had_tx=UNKNOWN` 只用于决定回滚尝试，**不进 K1**；若隔离与关闭均成功则 K1 可成立，否则 K1=False |
| MC23 | `quarantine(conn)` 抛异常 | 观察 | 仍执行 `close()`（尝试次数 = 1）；**不调用** `conn.execute` / `rollback_for_migration()`；K1 = **False**；DB 写入次数 = 0；phase 保持 `COMMIT_ATTEMPTED`；maintenance = 开 |
| MC24 | 属性读与 `quarantine` 均抛异常 | 观察 | 仍执行 `close()`（尝试次数 = 1）；K1 = **False**；DB 写入次数 = 0；phase 保持 `COMMIT_ATTEMPTED`；maintenance = 开；仅 `migration-fault.log`（两条记录、无 success） |
| MC27 | 包装层 `conn_wrapper.close()` 内部底层 `close()` 抛错 | 观察 | `is_closed = False`（未被伪造）；K1 = **False**；DB 写入次数 = 0；phase 保持 `COMMIT_ATTEMPTED`；maintenance = 开；`migration-fault.log` 一条 `conn_close_failed` |
| MC27b | 关闭成功后直接访问 `conn.in_transaction` | 观察 | 抛 `ConnectionClosed`；`no_tx_read_after_close` 被置 `False` → K1 = **False**（证明"关闭后不读事务属性"是可验证约束） |

---

## 4. P1-2：R10-A1 / R10-A2 的独立夹具

### 4.1 问题

v1.9 把两条 REPLACE 并排展示，且都声称 `id: 1 → 2`。若在同一库连续执行，第二次会分配 `id=3`（`AUTOINCREMENT` 不复用），预期与事实不符，也无法判断"第二次破坏"到底破坏了什么。

### 4.2 夹具规范（每个用例独立、可重复）

**每个用例从一个只读基线副本复制出独立库文件**：

```bash
# 夹具（P1 实施时的流程，本轮只定义）
cp baseline/np-A.db      /tmp/case-R10-A1.db
cp baseline/np-A.db      /tmp/case-R10-A2.db
sqlite3 /tmp/case-R10-A1.db "PRAGMA journal_mode=WAL;"
```

**基线库的固定初始状态（两个用例完全相同）**

| 对象 | 值 |
| --- | --- |
| `airports` | `id=1` |
| `node_identities` | `identity_id=10, airport_id=1` |
| `node_config_versions` | `(10, 1, fingerprint='F1')` |
| `nodes` | `id=1, airport_id=1, fingerprint='F1', identity_id=10, config_version=1, status='unknown', fail_count=0` |
| `node_state_history` | 1 行，`(node_id=1, identity_id=10)` |
| `target_results` | 1 行，`(node_id=1, identity_id=10)` |
| `detection_tasks` | 1 行，`(node_id=1, identity_id=10)` |
| `node_id_reservations` | 1 行，`(node_id=1, identity_id=10)` |

**每个用例只执行一条 REPLACE**（各自库、各自一次）

```sql
-- R10-A1 用（同身份变体）
PRAGMA recursive_triggers = OFF;  PRAGMA foreign_keys = OFF;
INSERT OR REPLACE INTO nodes (airport_id, fingerprint, identity_id, config_version, status, fail_count)
VALUES (1, 'F1', 10, 1, 'available', 0);
```

```sql
-- R10-A2 用（换身份变体）
PRAGMA recursive_triggers = OFF;  PRAGMA foreign_keys = OFF;
INSERT OR REPLACE INTO nodes (airport_id, fingerprint, identity_id, config_version, status, fail_count)
VALUES (1, 'F1', 11, 1, 'available', 0);
```

> 注：A2 的 `identity_id=11` 必须在基线中**存在**（`node_identities(11, airport_id=1)` + `node_config_versions(11,1,'F1')`），否则插入阶段的 `trg_nodes_rel_ins` 会因"identity 不存在"而 ABORT——但那会变成另一个测试（关系校验），不是 REPLACE 破坏实验。基线因此额外预置 identity 11 与版本 `(11,1)`，且**不**让它被任何节点引用。

**验证（每例各自执行，互不共享）**

| 项 | R10-A1 | R10-A2 |
| --- | --- | --- |
| `nodes.id` | 2 | 2 |
| `nodes.identity_id` | 10（新行沿用同值） | 11 |
| 四表行数 | 1/1/1/1 | 1/1/1/1 |
| 四表 `node_id` 集合 | `{1}`（父行已不存在 → 悬空） | `{1}`（同上） |
| 四表 `(node_id, identity_id)` 父键 | 均无匹配（父行 id 已变） | 均无匹配 |
| 结论 | 档案被替换 | 档案被替换且身份被改写 |

**禁止**：两用例共库、按顺序执行、复用上一用例残留；测试报告必须记录"基线复制 → 单次 REPLACE → 五项验证"的完整过程。

### 4.3 测试（FX4，与 v1.8 的 FX1–FX3 不冲突）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| FX4 | 基线副本 | 只做 R10-A1 前置（不执行 REPLACE） | `id=1`；四表各 1 行且 `node_id=1`；`identity 11` 存在但无节点引用 |
| R10-A1 | FX4 状态 | 执行 A1 的 REPLACE 一次 | `id=2`；`identity=10`；四项验证如 §4.2 |
| R10-A2 | **另取一份** FX4 状态 | 执行 A2 的 REPLACE 一次 | `id=2`（不是 3）；`identity=11`；四项验证如 §4.2 |
| R10-A0 | FX4 状态 | 不执行 REPLACE，直接跑七项比较 | 全等（证明比较器本身无噪声） |

---

## 5. 状态机总表（本轮定稿）

| 旧状态 | 新状态 | 触发 | 路径 | 事件类型 | 事件时点 | 失败后果 |
| --- | --- | --- | --- | --- | --- | --- |
| PREPARED | TX_OPEN | BEGIN 成功 | 共用 | tx_local | 事务内 | 日志；不回退 |
| PREPARED | （无转换） | 阶段 A 失败 | 共用 | `migration_abort`（非 phase） | 事务外 | 终止 |
| TX_OPEN | COMMIT_ATTEMPTED | COMMIT 前 | 共用 | tx_local | 事务内 | 日志；继续 COMMIT |
| TX_OPEN | TX_ROLLED_BACK | ROLLBACK 成功 | 共用 | durable | 回滚后 | 事件失败仍终止 |
| COMMIT_ATTEMPTED | COMMITTED | token ∧ `K1_β` ∧ K2 ∧ 事件成功（T4） | **β** | durable | R3 后（β 首个事件） | 不满足 → T4′（停 `COMMIT_ATTEMPTED`） |
| COMMIT_ATTEMPTED | TX_ROLLED_BACK | 无 token ∧ 无对象 ∧ `K1_β` ∧ K2 ∧ 事件成功（T5） | **β** | durable | R3 后（β 首个事件） | 不满足 → T4′；事件失败仍终止 |
| COMMIT_ATTEMPTED | （无转换） | β 门禁不满足（`K1_β` 假 / S5 失败 / 事件失败） | **β** | `migration_note`（仅 `K1_β` 真时） | — | 停 `COMMIT_ATTEMPTED`；保守恢复（T4′） |
| COMMIT_ATTEMPTED | UNKNOWN | COMMIT 抛异常 ∧ **K1 成立**（S5 成功或失败均可）（T6） | **α** | durable | **S5 后（唯一）** | 事件失败 → 非 DB 日志 + 恢复 |
| COMMIT_ATTEMPTED | （无转换） | COMMIT 抛异常 ∧ **K1 不成立**（S5 成功或失败均可）（T6′） | **α** | **无**（`migration-fault.log`） | — | phase 停留 `COMMIT_ATTEMPTED`；maintenance + 保守恢复 / 待人工 |
| COMMIT_ATTEMPTED | （无转换） | T6 证据构造/校验失败（字段缺、`k1_proof` 不全 true、`s5_result=not_run`、**`token_fp` 缺失/非 64 hex/与凭据行不符**） | **α** | **无**（不得写不完整证据） | — | 停 `COMMIT_ATTEMPTED`；文件日志；保守恢复（T6′ 同口径） |
| COMMIT_ATTEMPTED | （无转换） | T6 事件写入失败（`INSERT`/`COMMIT`/唯一约束冲突） | **α** | **无** | — | 停 `COMMIT_ATTEMPTED`；不重试、不补写；文件日志；保守恢复 |
| COMMIT_ATTEMPTED | UNKNOWN（**重查确认已提交**） | T6 事件在 `COMMIT` 抛错后经独立只读重查被确认为已落库（A） | **α** | durable（已存在，不重写） | 重查确认后 | 按成功推进到 `UNKNOWN`；内存 `s5_failed_ever` 取列值；不重复写入 |
| COMMIT_ATTEMPTED | （无转换） | T6 事件结果无法确认（C：重查不可用/字段不一致/链断裂） | **α** | **无新增** | — | 停 `COMMIT_ATTEMPTED`；maintenance；`migration-fault.log`；不重发；待人工 |
| UNKNOWN | COMMITTED（**重查确认已提交**） | T7 事件 `COMMIT` 抛错后重查确认已落库（A） | **α / β′** | durable（已存在） | 重查确认后 | 按成功进入阶段 C；不得再判"事件失败" |
| UNKNOWN | （无转换） | T7/T8 事件结果无法确认（C） | **α / β′** | **无新增** | — | 停 `UNKNOWN`；maintenance；不开放写入；不重发 |
| UNKNOWN | COMMITTED | token 可见 **∧ K1 ∧ S5 成功 ∧ 事件成功**（四条件）（T7）；β′ 另需 E1–E3 ∧ `s5_failed=False` | **α / β′** | durable | 查询后（β′ 在 E1–E3 后） | 任一不满足 → 停留 UNKNOWN + 恢复 |
| UNKNOWN | COMMITTED（S5 曾失败） | **禁止（T7′）** | **α / β′** | — | — | 保持 UNKNOWN；不写 success、不开写入 |
| UNKNOWN | TX_ROLLED_BACK | token 不可见 **∧ 对象不可见 ∧ K1 ∧ S5 成功 ∧ 事件成功**（五条件）（T8）；β′ 另需 E1–E3 ∧ `s5_failed=False` | **α / β′** | durable | 查询后（β′ 在 E1–E3 后） | 任一不满足 → 停留 UNKNOWN + 恢复 |
| UNKNOWN | TX_ROLLED_BACK（S5 曾失败） | **禁止（T8′）** | **α / β′** | — | — | 保持 UNKNOWN；不写 success、不开写入 |
| UNKNOWN | UNKNOWN | — | 共用 | **禁止**（用 `append_reason`） | — | `IllegalTransition` |
| UNKNOWN | （无转换） | β′ E1–E3 任一失败（证据缺失/不全/不符） | **β′** | `migration_note(evidence_unverified)` | E1–E3 后 | 停 `UNKNOWN`；不进阶段 C；无 success；写入关闭 |
| COMMITTED | 任意 | — | 共用 | **禁止回退**（阶段 C 失败用 `migration_rollback` 事件） | — | — |

> **`tx_local` 不进入证据链**：T1/T2 的 `migration_phase` 落在 `migration_tx_notes`（随迁移事务），本表只描述 `system_events` 中的 durable 转换；β′ 绝不读 `migration_tx_notes`。
>
> **β′ 的证据前置**：β′ 的 T7/T8 必须先通过 E1–E3（§1.4），`s5_failed` 只能由持久事件流恢复；`phase=UNKNOWN` 本身不构成任何证明。
>
> **路径不混用**：α 只出 `T6/T6′` 与 `T7/T7′/T8/T8′`；β 只出 `T4/T4′/T5`。表中「路径」列的 `α / β′` 表示两者共用同一转换定义（此时 phase 已是 `UNKNOWN`，终止证据按各自入口解释）。
>
> **"事件失败"仅指 B（确认未提交）与 T6 式证据缺失**：A（重查确认已提交）按成功路径推进；C（无法确认）不推进且停 maintenance——三者不得混同，也不得用异常类型代替重查。
>
> **S2 异常不产生任何转换**：属性读、隔离、回滚三段中的任一抛错，都只写 `migration-fault.log`；`phase` 仍为 `COMMIT_ATTEMPTED`。若隔离确认且关闭成功 → 走 T6 写 `→UNKNOWN`；否则走 T6′（无转换）。

---

## 6. 逐项关闭说明（含实际逻辑）

### 6.1 P0-1 phase 重复

| 要求 | 落实 |
| --- | --- |
| 只有 `set_phase` 能改 phase | §2.1 唯一入口；其他位置置 `commit_raised` 等非 phase 标记 |
| S1 区分进程内标记与状态转换 | §1.1 标记表；S1 不调用 `set_phase` |
| 同一转换不重复 | T6 只在 S5 后执行一次；`set_phase` 内 `LEGAL_TRANSITIONS` 校验，重复即 `IllegalTransition` |
| 路径不混用 | §1.2 路径归属表：α 只 `T6/T7/T8`，β 只 `T4/T5`；β 无 `→UNKNOWN` |
| `UNKNOWN→UNKNOWN` 不伪装 | `append_reason()` 写 `migration_note`，phase 不变 |
| 每个合法转换有定义 | §5 总表十行，各含触发/事件/失败 |
| 文档一致 | §1.2/§1.3/§2.1/§5 四处的转换集合逐字一致（见 §8 复核） |

### 6.2 P0-2 durable 时序

| 要求 | 落实 |
| --- | --- |
| 异常后先记进程内状态 | S1 仅 `commit_raised` |
| 严格 S2–S5 | §1.3 表；S2 三段各自独立 `try`，`close()` 兜底 |
| S2 异常不中断关闭 | §3.1 异常边界表（close 独立 try、必执行） |
| 隔离后再写事件 | `→UNKNOWN` 位于 S6，S5 之后；K1 不成立时 S6 不转换 |
| 首个 durable 事件按路径固定 | §1.3 硬规则 3：α = `→UNKNOWN`；β = `→COMMITTED`/`→TX_ROLLED_BACK` |
| 隔离失败不强写审计 | 规则 1–2：只用 `<data_dir>/migration-fault.log` |
| 所有 durable 时点明确 | §1.3 五类事件表 + 硬规则 3 |
| K1 是写库唯一闸门 | §1.3 硬规则 7 + §3.1 判定表；K1 不成立 → T6′ |
| 测试验证顺序 | MC13/MC14/MC15/MC19/PH6 |

### 6.3 P0-3 事件失败补偿

| 要求 | 落实 |
| --- | --- |
| 两类确认语义 | §2.1 表：durable 失败不改内存；tx_local 改了但非权威 |
| 事件失败不得对外使用新状态 | `set_phase` 返回 False，`rec.phase` 仍旧值 |
| COMMITTED 四条件 | §2.2 门禁（token/终止证据/K2/事件） |
| 门禁编号按 phase 唯一决定 | §2.2 `COMMIT_ATTEMPTED → T4`，`UNKNOWN → T7`，不可互换 |
| 门禁失败不回退到 UNKNOWN | §2.3：`COMMIT_ATTEMPTED→UNKNOWN` 只由 T6 触发 |
| 任一失败不进阶段 C | `to_unknown()` → 保守恢复 |
| T7 四条件（含 S5） | §1.2 T7 + §2.3（S5 曾失败即禁止 `→COMMITTED`） |
| 内存处理明确 | 明确"不推进"，由调用方决定 T6 |
| 补偿转换定义 | §2.3 表（允许 T6 补偿；禁 COMMITTED 回退） |
| 二次补偿失败 | 不推进任何状态；maintenance + 非 DB 日志 + 恢复 |
| PH5 三重断言 | §2.4 表 |
| 不靠"调用了恢复函数"判定 | PH9–PH11 断言内存 phase、事件序列、`enter_phase_c` 调用次数、success 存在性 |
| T7 条件不完整 | MC20：K1 成立、S5 失败、token 可见 → 仍 UNKNOWN |
| T8 条件不完整 | MC21：K1 成立、S5 失败、token 与对象均不可见 → 仍 UNKNOWN |

### 6.4 P1-1 K1 / S5

| 要求 | 落实 |
| --- | --- |
| K1 四条件 | §3.1（隔离、close 成功、句柄不可用、关闭后不读事务属性） |
| S5 独立定义 | §3.2 表（瞬时探测、不得替代 K1、必须关探测连接） |
| S5 后持续封锁 | §3.3 六通道表 + S5′ 复探 |
| close 失败/探测失败/被抢写锁 | §3.3 五种情形表（close 失败停 `COMMIT_ATTEMPTED`，不判 UNKNOWN） |
| 关闭接口统一 | §3.1 对象关系表：迁移流程只调 `conn_wrapper.close()`；底层成功才置 `is_closed` |
| **隔离期禁写数据库** | §3.1 禁令表：S2–S5 未完成前只允许 `migration-fault.log`；ROLLBACK 失败分支也走非 DB 日志 |
| quarantined 与 ROLLBACK 兼容 | §3.1 `rollback_for_migration()` 通道表（只放行 `ROLLBACK`，其他抛 `IllegalRecoverySql`） |
| S2 三段独立异常边界 | §3.1 异常边界表 + 伪代码（属性读/隔离/回滚各自 try，close 兜底） |
| 专门测试 | MC14–MC24（各自独立，非一个通用 UNKNOWN） |

### 6.5 P1-2 独立夹具

| 要求 | 落实 |
| --- | --- |
| 各用独立副本 | §4.2 `cp baseline` 两份 |
| 初始状态相同 | §4.2 固定表（含预置 identity 11） |
| 各执行一条 REPLACE | §4.2 两段 SQL 分属不同库 |
| 各自验证 | §4.2 验证表 |
| 记录初始化 | 报告需含"复制→单次→五项" |
| 不依赖顺序 | FX4 + R10-A0 证明比较器无噪声 |

### 6.6 六次修订 β′ 证据

| 要求 | 落实 |
| --- | --- |
| T6 事件持久化足够证据 | §1.4 必填字段表（`migration_id`/`old_phase`/`new_phase`/`k1_proof`/`s5_result`/`s5_failed_ever`/`seq`/`prev_sha`/`ts`/`token_fp`） |
| β′ 必须校验而非推断 | §1.4 E1–E3；§5 新增 `UNKNOWN →（无转换）` 行 |
| 缺证据不得执行 T7/T8 | §1.4「禁止项」+ §2.2 β′ 分支 `evidence_ok` 前置 |
| S5 失败历史永久可追溯 | 单调 `s5_failed_ever`；禁止清除语义；`EvidenceMonotonicityViolation` 拒写 |
| 不得依赖易失标记 | §3.2「不得依赖易失状态」行；文件日志仅辅助 |
| T6 事件写不进去 | 仍按 §2.1/§2.4：不伪造 UNKNOWN、不开放写入 |
| 不放宽既有条件 | K1/S5/T7/T8 五/四条条件原样保留，β′ 只增加前置校验 |
| `token_fp` 真实持久化 | §2.1 独立列 `token_fp`（CHECK 64）+ 字段来源表 + `required_evidence_missing` |
| `tx_local` 与 DDL 不冲突 | §2.1 `migration_tx_notes` 独立表；与 `system_events` 无共享列语义 |
| 测试 | MC34–MC37（真实进程重启）、MC38（含 `token_fp` 列断言）、MC46 |

### 6.7 七次修订 证据写路径接入

| 要求 | 落实 |
| --- | --- |
| T6 写入前构造并校验完整证据 | §2.1 `set_phase` durable 分支 + `required_evidence_missing()` |
| `k1_proof` 不得伪造 | §2.1 字段来源表：只读 `rec.k1_state`，`set_phase` 不接受该参数 |
| `s5_result` 来自实际执行 | §2.1 字段来源表；T6 禁止 `not_run` |
| `s5_failed_ever = 历史 OR 本次` | §2.1 `write_event` 内计算，写成一等列 |
| `seq`/`prev_sha` 由事务内生成 | §2.1 原子性说明：`BEGIN IMMEDIATE` 内读链头 → `seq+1` → 计算 `prev_sha` |
| 后续事件统一接入 | §1.2 `append_reason` 改用 `write_event`；§1.2「强制约束」表 |
| 单调性违反拒写 | `EvidenceMonotonicityViolation`（写入前 + 事务回滚） |
| 链断裂不重建 | §1.4 三条 note 分支；§2.1「失败语义」 |
| 测试 | MC38–MC43 |

### 6.8 八次修订 证据完整性闭环（四项 P0）

| 要求 | 落实 |
| --- | --- |
| P0-1 `token_fp` 写入与校验 | 唯一来源 = 凭据行（`token_fp_from_credential`）；独立列 + `CHECK(length=64)`；`set_phase`/`emit_event` 不收该参数；`write_event` 落同一条 `INSERT`；β′ 读**列值**比对；缺失/格式错/不符 → T6 拒写、β′ E2 失败 |
| P0-2 `tx_local` 与 DDL 冲突 | 拆表：`migration_tx_notes`（tx_local，迁移事务内，无链列）+ `system_events`（durable，全 NOT NULL）；`emit_event` 一个入口两个后端；tx_local 不进链、β′ 不读、不占 `seq` |
| P0-3 全链验证进事务 | `write_event` 内 `BEGIN IMMEDIATE` 后读全链并跑 C1–C8，通过才分配 `seq`/`prev_sha` 并 `INSERT`；`append_reason` 的事务外 `verify_chain` 降级为诊断；链损坏只写文件日志；写入结果不确定时只读重查、禁止重发 |
| P0-4 α 也受历史失败门禁 | §2.2 `hist_gate = not rec.s5_failed_ever`，在 `set_phase` 之前判定；T7 与 T8 同受约束；`probe_ok` 不得清除；门禁与"写入拒写"分别定义、分别测试 |
| 一致性检查 | §8 新增"DDL / INSERT / tx_local / token_fp / 全链 / 门禁"六项逐条复核 |
| 测试 | MC44–MC47（读真实持久化行） |

---

### 6.9 九次修订 提交结果确认与统一入口（Commit Outcome Reconciliation）

| 要求 | 落实 |
| --- | --- |
| 写入阶段不得统一归类 | §2.1 七态阶段表（`CONN_OPENED` / `TX_OPEN` / `INSERTING` / `INSERTED` / `COMMITTED` / `COMMITTING` / rollback-close）；只有 1–2 态可直接判"未写入" |
| `COMMIT` 抛错后重查 | `write_event` 的 `except` 分支在 `INSERT` 已发出时调用 `settle_uncertain()` → `reconcile_event()` |
| 预期事件完整记录 | `exp` 在 `INSERT` 前构造，含 `event/migration_id/seq/prev_sha/token_fp/s5_failed_ever/detail_json/ts` 8 字段；`ts` 前置固定以保证可比 |
| 逐字段比较 | `row_fields_equal()` 逐项比 8 字段，`detail_json` 按字节比；**不只判断 `seq` 是否存在** |
| 全链重验 | 重查时对实际持久化链重跑 `verify_full_chain`（C1–C8） |
| 三分类 | A 采纳并推进（不重写）；B 返回失败（不推进、不动内存）；C 停 maintenance + 文件日志（不重发、不开放写入） |
| `ROLLBACK`/`close` | 均不参与推断；`close` 抛错不等于未提交；只读连接读取失败不等于"不存在" |
| 内存一致性 | `rec.s5_failed_ever` 仅在 `COMMIT` 返回或 A 后更新；`rec.phase` 仅在 `emit_event==True` 后更新；确认窗口内异常一律 halt |
| 统一入口 | `emit_event()` 成为唯一事件入口；`set_phase`（tx_local 与 durable 两支）与 `append_reason` 都只调 `emit_event`；两个后端函数仅在 `emit_event` 内被引用 |
| 语义不变 | 两种后端的连接、事务、失败与证据链语义一字未改；DDL/`INSERT`/哈希链/单调性/K1/S5/T6/T7/T8 条件未动 |

## 7. 测试矩阵（增量）

| 组 | v1.9 | v1.10 | 变化 |
| --- | --- | --- | --- |
| A | 10 | 10 | — |
| R | 16 | **18** | +R10-A0、R10-A2 改为独立夹具（编号不变，语义收紧） |
| FK | 15 | 15 | — |
| CV | 5 | 5 | — |
| M | 32 | 32 | — |
| BA | 6 | 6 | — |
| RB | 4 | 4 | — |
| RC | 6 | 6 | — |
| CF | 8 | 8 | — |
| AU | 9 | 9 | — |
| MC | 12 | **56** | +MC13–MC18；二次修订 +MC19–MC20；三次修订 +MC21、MC15b/15c/15d、MC13b；四次修订 +MC22–MC24；五次修订 +MC25/MC26/MC26b/MC27/MC27b；六次修订 +MC34–MC37；七次修订 +MC38–MC43；八次修订 +MC44–MC47；九次修订 +MC48–MC56 |
| CR | 5 | 5 | — |
| FX | 3 | **4** | +FX4 |
| PH | 5 | **13** | +PH6–PH11、PH9b、PH10b |

**跨组一致性用例**

| 用例 | 断言 |
| --- | --- |
| PH6 + MC13 | 转换恰好一次，且事件晚于 S5 |
| PH9 + CR1 | 事件失败 → 未进阶段 C → 无 success |
| PH10 + PH11 | 二次补偿失败 → 三重一致（内存 `COMMIT_ATTEMPTED`、无事件、未进 C） |
| MC17 + RC4 | 两道关卡（S5′ 与连接关闭）都能拦下替换 |
| MC19 + §1.3 | 隔离未确认期间 DB 写入次数 0，故障只落文件日志 |
| MC20 + T7′ | K1 成立但 S5 失败 + token 可见 → 仍 `UNKNOWN`，无 `→COMMITTED`、无 success |
| MC21 + T8′ | K1 成立但 S5 失败 + token 与对象均不可见 → 仍 `UNKNOWN`，无 `→TX_ROLLED_BACK` |
| MC22–MC24 + T6′ | S2 任一异常 → close 尝试 ≥1 次、DB 写入 0；隔离失败则 K1=False、phase 停 `COMMIT_ATTEMPTED` |
| MC15 + MC16 | 同一 K1 判定口径：K1 成立才写事件；K1 不成立一律不写（S5 结果不影响） |
| R10-A1 + R10-A2 | 两库各自 `id=2`，互不影响 |

---

## 8. 一致性复核（伪代码 / 状态表 / 测试）

| 复核项 | 伪代码 | 状态表 | 测试 |
| --- | --- | --- | --- |
| S1 不改 phase | `commit_raised` 赋值 | §1.2 无相应行 | MC13/PH6 |
| 单次 `→UNKNOWN` | `to_unknown()` 仅在 S6 调用 | §5 `COMMIT_ATTEMPTED→UNKNOWN` | PH6 |
| `UNKNOWN→UNKNOWN` 禁止 | `LEGAL_TRANSITIONS` 不含该对 | §5 最后两行 | PH7/PH8 |
| durable 事件后于 S5 | §1.3 时序表 | §5 事件时点列 | MC13 |
| 隔离失败不写 DB | 规则 1–2、5、7 | §1.3 硬规则 / §3.1 禁令表 | MC14/MC19 |
| 事件失败不改内存 | `set_phase` 返回 False 分支 | §2.1 表 | PH9 |
| COMMITTED 五条件 | §2.2 门禁（含 `hist_gate`） | §5 `UNKNOWN→COMMITTED` 行 | PH9/PH10/MC44 |
| 补偿合法性 | `to_unknown` | §2.3 表 | PH10/PH10b/PH11 |
| K1 四条件 | §3.1 伪代码 | §3.1 判定表 | MC15 |
| K1 不成立即不写库 | T6′ 分支（无 `set_phase`） | §5 `COMMIT_ATTEMPTED → （无转换）` 行 | MC14/MC15 |
| quarantine 后仍能终止 | `rollback_for_migration()` 只放行 ROLLBACK | §3.1 通道表 | MC15b/MC15c/MC15d |
| S2 不中断关闭 | 三段独立 try + 兜底 close | §3.1 异常边界表 | MC22/MC23/MC24 |
| 路径 α 不套 T4/T5 | S7 只调 T7/T8 | §1.2 路径归属表 | MC25 |
| 路径 β 前置 phase | R1 读持久 `COMMIT_ATTEMPTED` | §5 `COMMIT_ATTEMPTED` 三行 | MC26/MC26b |
| β′ 证据前置 | E1–E3 校验函数 + `evidence_ok` 前置 | §1.4 / §5 `UNKNOWN→（无转换）` | MC34/MC35/MC36 |
| S5 失败历史不可清除 | 单调 `s5_failed_ever` + 拒写清除事件 | §1.4 历史失败标记 / §3.2 | MC37/MC40 |
| 证据随事件构造校验 | `set_phase` durable 分支构造 `k1_proof`/`s5_result` | §2.1 字段来源表 | MC38/MC43 |
| 所有入口统一 | `append_reason` 调用 `write_event` | §1.2 强制约束表 | MC39 |
| 哈希链原子性 | `BEGIN IMMEDIATE` + 两个 UNIQUE 约束 | §2.1 DDL / 原子性说明 | MC41 |
| 链断裂不伪造 | `write_event` 内 `verify_full_chain` 失败即停 | §1.4 三分支 / §2.1 C1–C8 | MC42 |
| 隔离失败仍关闭且 K1=False | `quarantined_ok=False` → `k1=False` | §3.1 判定表 | MC23/MC24 |
| 关闭接口唯一 | `conn_wrapper.close()` 内部调底层 | §3.1 对象关系表 | MC27 |
| `is_closed` 不得伪造 | 底层成功才置 True | §3.1 契约表 | MC27 |
| 关闭后不读事务属性 | `no_tx_read_after_close` | §3.1 契约表 | MC27b |
| S5 独立 | §3.2 | §3.3 | MC16–MC18 |
| T8 五条件 | §1.2 T8 | §5 `UNKNOWN→TX_ROLLED_BACK` 行 | MC18/MC21 |
| T8′ 禁止分支 | 判定处显式 `if s5_failed: stay UNKNOWN` | §1.2 T8′ | MC21 |
| T4/T5 仅路径 β | R1 读持久 phase 后才可调 | §1.2 路径归属 / §5 路径列 | MC26 |
| α 不调 T4/T5 | S7 只调 T7/T8 | §1.3 路径 α 时序 | MC25 |
| 首个 durable 事件按路径 | §1.3 硬规则 3 | §5 事件时点列 | MC25/MC26 |
| 隔离期禁写库 | §3.1 `non_db_log` 分支 | §3.1 禁令表 / §1.3 硬规则 1–2 | MC19 |
| T7 四条件 | §1.2 T7 | §5 `UNKNOWN→COMMITTED` 行 | MC20 |
| T7′ 禁止分支 | `hist_gate` 前置判定（α 与 β′ 共用） | §1.2 T7′ / §2.3 | MC20/MC44/MC46 |
| T8′ 禁止分支（历史门禁） | 同 `hist_gate`，在 `set_phase` 前 | §1.2 T8′ / §2.3 | MC21/MC45/MC46 |
| `token_fp` 真实落库 | `write_event` 的 `INSERT` 含 `token_fp` 列 | §2.1 DDL / 字段来源表 | MC38/MC43 |
| `tx_local` 无 DDL 冲突 | `write_tx_event` 写 `migration_tx_notes`（无链列） | §2.1 两表说明 / 语义对照 | MC39（并集校验）/PH7 |
| 全链验证在写事务内 | `verify_full_chain(rows)` 位于 `BEGIN IMMEDIATE` 之后 | §2.1 C1–C8 表 | MC41/MC42 |
| 写入结果不确定不重发 | 只读重查 + 不重试 | §2.1 `settle_uncertain` / 三结果表 | MC48–MC53 |
| `COMMIT` 抛错后真正重查 | `except` → `exp`(8 字段) → `reconcile_event()` → A/B/C | §2.1 伪代码（不是规则表） | MC48/MC49/MC51 |
| 事件已提交不误判"未提交" | A 路径返回 `True`，`set_phase` 按成功推进 | §2.2 成功/失败语义表 | MC48/MC52/MC53 |
| 事件未提交不推进 phase | B 路径返回 `False`，内存不动 | §2.2 表 / §2.3 | MC49/MC52 |
| 不可读不解释为不存在 | `UNREADABLE` 属 C，停 maintenance | §2.1 三结果表 | MC50 |
| 单一事件入口 | `set_phase` 两支 + `append_reason` 均调 `emit_event` | §2.1 / §1.2 | MC54/MC55/MC56 |
| 独立夹具 | §4.2 | — | FX4/R10-A0/A1/A2 |

**九次修订的八项全篇核对（本轮必须逐条过）**

| # | 核对项 | 结论 |
| --- | --- | --- |
| 1 | DDL 与所有 `INSERT` 字段完全匹配 | `system_events` 8 列 ↔ `write_event` 的 `INSERT` 8 值；`migration_tx_notes` 5 列 ↔ `write_tx_event` 5 值；无表外写入点 |
| 2 | `tx_local` 与 durable 事务边界无冲突 | tx_local 用 `rec.conn`（迁移事务内），durable 用 `audit_conn()`（独立 `BEGIN IMMEDIATE`）；不同表、不同连接 |
| 3 | 所有 durable 事件经统一机制 | T4/T5/T6/T7/T8 与 `migration_note` 均调 `write_event`；T6 走 `set_phase` 的 durable 分支 |
| 4 | T6 的 `token_fp` 真正持久化 | 独立列 + `CHECK(length=64)` + 写入前三重校验（格式/内存值/凭据行） |
| 5 | β′ 从真实记录恢复 `token_fp` | `SELECT token_fp` 取列值比对（E2），不从 `detail_json` 猜、不从 phase 推 |
| 6 | 历史门禁对 α、β′ 均有效 | `hist_gate = not rec.s5_failed_ever`，两条入口共用，且在 `set_phase` 之前 |
| 7 | 不确定结果在伪代码中真实执行 | `write_event` 的 `except` 分支调用 `settle_uncertain`→`reconcile_event`，不是仅存于说明表 |
| 8 | 事件入口单一 | `emit_event` 为唯一入口；`set_phase` 的两个分支都只调它 |

**逐条结论**：伪代码中的每个 `set_phase` 调用都能在 §5 找到唯一一行；§5 每行至少一条测试；未出现"状态表有转换但代码无调用"（`UNKNOWN→COMMITTED`、`UNKNOWN→TX_ROLLED_BACK` 为兜底，代码中有对应分支但正常路径不触发，已注明）；也未出现"代码有转换但状态表未定义"。

---

## 9. C11–C20 确认状态（不变）

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

## 10. 风险（更新）

| # | 风险 | 缓解 | 验证 |
| --- | --- | --- | --- |
| 1 | phase 被多处直写导致错乱 | 唯一入口 + `LEGAL_TRANSITIONS` | PH6–PH8 |
| 2 | 同一转换重复执行 | 单次调用点 + 非法转换抛错 | PH6 |
| 3 | 隔离前抢写审计 → `SQLITE_BUSY` 污染判定 | 事件后置 + 非 DB 日志通道 | MC13/MC14 |
| 4 | 事件失败但内存已改 → 假 COMMITTED | 事件先写、失败不推进 | PH9 |
| 5 | 二次补偿失败仍开放写入 | 不推进 + maintenance + 非零退出 | PH10/PH11 |
| 6 | K1 用关闭后事务属性误判 | 关闭前单次读取，K1 只看四条件 | MC15 |
| 7 | S5 后他进程抢写 | 替换前 S5′ 复探 | MC17 |
| 8 | 两 REPLACE 用例共库导致 `id=3` | 独立副本 + 单次执行 | FX4/R10-A1/A2 |
| 9 | C-2 误停导致迁移中断 | 误停只影响单表 | M30/M32 |
| 10 | 隔离未完成时写库 → `SQLITE_BUSY` 被误读 | §3.1 禁令表：只许 `migration-fault.log` | MC19 |
| 11 | S5 曾失败但 token 事后可见 → 误转 COMMITTED | T7′ 禁止分支；四条件复核 | MC20 |
| 12 | quarantine 语义吞掉 ROLLBACK → 原事务永不终止、K1 恒 False | `rollback_for_migration()` 单点放行（只 ROLLBACK、最多 1 次） | MC15b/MC15c/MC15d |
| 13 | K1 不成立但仍借 S5 成功写库 → 撞锁被误读 | T6′：K1 是唯一写库闸门 | MC14/MC15 |
| 14 | 看不到 token 就当已回滚（T8 条件不全） | T8 五条件 + T8′ 禁止 | MC18/MC21 |
| 15 | S2 属性读/隔离抛错中断流程 → 原连接未隔离、未关闭残留 | 三段独立异常边界 + 兜底 `close()` + K1 严格化 | MC22/MC23/MC24 |
| 16 | 异常路径先落 UNKNOWN 后又套 T4/T5 → 前置状态不成立、状态表自相矛盾 | 路径 α/β 分离；编号按 phase 唯一决定 | MC25/MC26 |
| 17 | 迁移流程直接调 `conn.close()` 而 `is_closed` 仍为 False → K1 误判 | 关闭接口统一走包装层；`is_closed` 只在底层成功后置位 | MC27/MC27b |
| 18 | 重启后凭 `phase=UNKNOWN` 推断"上一进程 K1 成立" | β′ 必须 E1–E3 校验 T6 事件；缺证据即禁止 T7/T8 | MC34/MC36 |
| 19 | S5 失败历史随进程消失 → 重启后误转 COMMITTED/ROLLED_BACK | `s5_failed_ever` 单调持久化，跨重启恢复；成功不得清除 | MC34/MC37 |
| 20 | 证据字段只写在文档、写入路径遗漏 → T6 落库无证明 | §2.1 统一 `write_event` + 字段来源表 + `required_evidence_missing` | MC38/MC43 |
| 21 | 并发追加导致重复 `seq` / 分叉 `prev_sha` / 单调倒退 | `BEGIN IMMEDIATE` + `UNIQUE(migration_id,seq)` + `UNIQUE(migration_id,prev_sha)` | MC40/MC41 |
| 22 | `token_fp` 只在文档里要求、写入路径未落库 → β′ 无据可比 | 独立列 + CHECK + 写入前三重校验 + β′ 读列值 | MC38/MC43/MC46 |
| 23 | `tx_local` 用与 DDL 冲突的 INSERT → 迁移期状态提示写不进去 | 拆表 `migration_tx_notes`；`emit_event` 双后端 | MC39/PH7 |
| 24 | 只验尾行 → 中间被篡改仍记为"链连续" | `verify_full_chain` C1–C8 全链校验（事务内） | MC41/MC42 |
| 25 | 路径 α 凭"后续 S5 成功"进入 T7，绕过历史失败 | `hist_gate` 前置门禁（α/β′ 共用） | MC44/MC45/MC46 |
| 26 | `COMMIT` 抛错即当未提交，实际已落库 → 内存与库分裂、可能重走另一转换 | 七态阶段表 + `reconcile_event` 逐字段比对 + A 路径采纳 | MC48/MC53 |
| 27 | 只读重查失败被当作"事件不存在" → 重复写入 | `UNREADABLE` 归 C：停 maintenance、不重发 | MC50 |
| 28 | `seq` 存在但字段不一致仍被采纳 | 8 字段严格比较（含 `detail_json` 字节与 `ts`）→ `MISMATCH` 归 C | MC51 |
| 29 | 状态机绕过统一入口直连后端写入 | `emit_event` 唯一入口 + 调用计数断言 | MC54/MC56 |

---

**v1.10 到此结束。** 九次修订合计**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据**；九次修订累计只处理"五项 + 两项 + 三项 + S2 异常保护 + 路径与关闭接口一致性 + β′ 跨重启证据 + 证据写入路径 + 证据完整性 + 提交结果确认"的状态机与伪代码矛盾。**C11–C20 全部未确认，C12 仍未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
