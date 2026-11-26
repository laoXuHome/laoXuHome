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
| T4 | `COMMIT_ATTEMPTED → COMMITTED` | token 可见 ∧ K1 成立 ∧ K2 成立 | 隔离完成后 | 三条件任一不成立 → 见 T6/§2.4 |
| T5 | `COMMIT_ATTEMPTED → TX_ROLLED_BACK` | token 不可见 ∧ 迁移对象不可见 ∧ K1/K2 成立 | 隔离完成后 | 事件失败 → 仍终止 |
| T6 | `COMMIT_ATTEMPTED → UNKNOWN` | COMMIT 抛异常 ∧ **K1 成立**（S5 成功或失败均可） | **S5 之后**（唯一时点） | 事件写失败 → 见 §2.4，仍保守恢复 |
| T6′ | `COMMIT_ATTEMPTED → （无转换）` | COMMIT 抛异常 ∧ **K1 不成立**（无论 S5 是否成功） | — | 不写任何 DB 事件、不调 `set_phase`；phase 停留 `COMMIT_ATTEMPTED`；只写 `migration-fault.log`；maintenance + 保守恢复/待人工 |
| T7 | `UNKNOWN → COMMITTED` | 隔离后 token 可见 **∧ K1 成立 ∧ S5 成功 ∧ `durable` 事件写入成功**（四条件缺一不可） | 隔离完成后 | 任一不满足 → 停留 `UNKNOWN` + 保守恢复 |
| T7′ | `UNKNOWN → COMMITTED`（此前 S5 失败过） | **禁止**——即使后续 token 可见 | — | 保持 `UNKNOWN`，继续保守恢复 |
| T8 | `UNKNOWN → TX_ROLLED_BACK` | token 不可见 **∧ 迁移对象不可见 ∧ K1 成立 ∧ S5 成功 ∧ `durable` 事件写入成功**（五条件缺一不可） | 隔离完成后 | 任一不满足 → 停留 `UNKNOWN` + 保守恢复 |
| T8′ | `UNKNOWN → TX_ROLLED_BACK`（此前 S5 失败过） | **禁止**——即使后续 token 与迁移对象均不可见 | — | 保持 `UNKNOWN`，继续保守恢复；不写 success、不开放业务写入 |
| — | **`UNKNOWN → UNKNOWN` 禁止** | 需要追加新原因 | — | 用 `append_reason()` 写独立事件（`migration_note`），**不改 phase** |

**`append_reason()`（不改变 phase 的唯一合法方式）**

```python
# 伪代码
def append_reason(rec, code, detail):
    """在 phase 不变的前提下追加上下文；不允许伪装成状态转换。"""
    payload = dict(migration_id=MID, phase=rec.phase.name, code=code, detail=detail, ts=now())
    durable_write_event("migration_note", payload)      # 失败只记非数据库日志
```

**为什么必须这样**：`UNKNOWN → UNKNOWN` 在状态机里是无操作，但若写成 `set_phase(UNKNOWN, UNKNOWN)` 会触发旧值断言/守卫（`PhaseMismatch`），把"记录新原因"误当成"状态变化"。记录原因与状态推进是两件事。

### 1.3 durable 事件的确切写入时点（P0-2）

| 事件 | 时点 | 是否允许独立写连接 | 说明 |
| --- | --- | --- | --- |
| `PREPARED→TX_OPEN`、`TX_OPEN→COMMIT_ATTEMPTED` | 事务内即时写 | **否**（写在迁移事务里，`tx_local`） | 随提交或回滚消失，非持久审计 |
| `COMMIT_ATTEMPTED→UNKNOWN` | **S2–S5 全部完成之后，且 K1 成立** | 是（此刻原连接已关闭、S5 已探测） | 唯一允许的时点；K1 不成立则不写（T6′） |
| `COMMIT_ATTEMPTED→COMMITTED` / `→TX_ROLLED_BACK` | 隔离完成后 | 是 | 同上 |
| `TX_OPEN→TX_ROLLED_BACK` | `ROLLBACK` 返回之后 | 是 | 原写事务已结束 |
| 隔离未确认（K1 不成立）时的失败 | **不写数据库事件** | **否** | 只能用非数据库日志（结构化文件/标准错误），因为库上可能仍有写锁 |

**硬规则**

1. 隔离未确认前，**禁止**用独立连接写任何 `durable` 事件（SQLite 单写者：第二写者会 `SQLITE_BUSY`，且失败会污染恢复判断）；
2. 隔离未确认时，故障记录走**非数据库通道**：`<data_dir>/migration-fault.log`（追加写、含 `migration_id/token/reason/ts`），并在进程退出码中体现；
3. 隔离确认后的第一个 `durable` 事件必须是 `COMMIT_ATTEMPTED→UNKNOWN`（或 `→COMMITTED`/`→TX_ROLLED_BACK`），**不得**在此之前插入其它审计写；
4. 所有 `durable` 写都用短 `busy_timeout`（≤500ms）+ 单次尝试，不重试；
5. **K1 未确认期间的任何异常（含 `rollback_for_migration()` 失败、`close()` 失败）一律只写 `migration-fault.log`**，禁止 `append_reason()` / `durable_write_event()` / 任何 `INSERT`——因为此时原连接可能仍持写锁，写库会 `SQLITE_BUSY` 并把"写不进去"误当成"状态异常"；
6. S7 判定必须**同时**复核 K1、S5 与事件写入成功：走 T7（`UNKNOWN → COMMITTED`）时 S5 曾失败即永久停留 `UNKNOWN`（T7′）；走 T8（`UNKNOWN → TX_ROLLED_BACK`）时 S5 曾失败同样禁止（T8′），即使 token 与对象均不可见；
7. **K1 是"能否写 DB 事件"的唯一闸门**：K1 成立 → `T6/T7/T8` 允许按既定规则写事件（S5 成功或失败都不改变这一点）；K1 不成立 → `T6′`，无论 S5 是否成功，一律不写 DB 事件、不调 `set_phase`，phase 停留 `COMMIT_ATTEMPTED`。

**时序对照（替换 v1.9 §2.2 的 S1–S7 表述）**

| 步 | 动作 | phase | 事件 |
| --- | --- | --- | --- |
| S1 | COMMIT 抛异常 → `commit_raised=True` | 仍 `COMMIT_ATTEMPTED` | 无（仅进程内） |
| S2 | 先读一次 `in_transaction`（属性读，非 SQL，**独立异常边界**，失败记 `UNKNOWN`）→ `quarantine(conn)`（**独立异常边界**，失败仍继续；此后业务 SQL 一律抛 `QuarantinedError`） | 不变 | 无 |
| S3 | `if quarantined_ok and had_tx in (True, UNKNOWN): conn_wrapper.rollback_for_migration()`（仅放行 `ROLLBACK`；隔离未成功则跳过） | 不变 | 无 |
| S4 | `close()`（**兜底必执行**，前序任何异常都不中断） | 不变 | 无 |
| S5 | 探测连接 `BEGIN IMMEDIATE`→`ROLLBACK`→`close()` | 不变 | 无 |
| S6 | K1 成立 → `set_phase(COMMIT_ATTEMPTED → UNKNOWN)`；K1 不成立 → **不转换**（T6′） | `UNKNOWN` / 仍 `COMMIT_ATTEMPTED` | **durable（首个）**；失败 → §2.4；K1 不成立时无事件 |
| S7 | 新连接只读查询 token/对象 → 按 §2.3 判定 | 见 T4/T5/T7/T8 | 对应转换事件 |

> 注意：v1.9 把 S6/S7 的顺序写作"先查询后判定"，本轮明确"先落 UNKNOWN 事件，再查询判定"——因为查询结果决定的是**下一步转换**（T4/T5），而"COMMIT 结果一度未知"这一事实必须在任何结论之前被持久记录。

### 1.4 测试（MC13–MC13b、MC14、PH6–PH8）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC13 | COMMIT 抛异常，K1 成立，S5 成功 | 观察事件写入序 | DB 事件中**不存在**早于 S5 的 `→UNKNOWN`；`COMMIT_ATTEMPTED→UNKNOWN` 出现在 S5 之后；S5 前只有进程内标记 |
| MC13b | 同上，但 K1 成立、S5 失败 | 观察 | 仍有 `COMMIT_ATTEMPTED→UNKNOWN`（S5 失败不影响 K1 闸门）；无 `→COMMITTED`/`→TX_ROLLED_BACK` |
| MC14 | 同上，但 `close()` 失败（K1 不成立），探测亦失败 | 观察 | **无任何 DB 事件**；`migration-fault.log` 有记录；phase 停留 `COMMIT_ATTEMPTED`（T6′，未被伪装成 UNKNOWN）；进入保守恢复；写入保持关闭；无 success |
| PH6 | COMMIT 抛异常（K1 成立） | 全程记录转换 | `COMMIT_ATTEMPTED→UNKNOWN` **恰好 1 次**；无 `UNKNOWN→UNKNOWN`；无 `PhaseMismatch`；后续每条结论分支（T7/T8）也各至多 1 次 |
| PH7 | 已处 `UNKNOWN`，再记录一条新原因 | `append_reason("probe_retry_failed", ...)` | 产生 `migration_note` 事件；phase 不变；无异常 |
| PH8 | 构造非法转换（如 `TX_ROLLED_BACK→COMMITTED`） | `set_phase` | 抛 `IllegalTransition`；状态不变；不写事件 |

---

## 2. P0-3：`set_phase()` 的事件失败补偿

### 2.1 事件先写、状态后改（唯一顺序）

```python
# 伪代码
def set_phase(rec, new, reason):
    old = rec.phase
    if (old, new) not in LEGAL_TRANSITIONS:              # 见 §1.2 表
        raise IllegalTransition(old, new)
    payload = dict(migration_id=MID, old_phase=old.name, new_phase=new.name, reason=reason, ts=now())
    durability = DURABILITY[(old, new)]                   # tx_local | durable

    if durability == "durable":
        ok = durable_write_event("migration_phase", payload)
        if not ok:
            # 状态不推进：old 仍是唯一可对外使用的状态
            return False                                  # 由调用方决定补偿/恢复
    else:
        try:
            rec.conn.execute("INSERT INTO system_events(event,detail_json,ts) VALUES ('migration_phase',?,?)",
                             (json.dumps(payload), payload["ts"]))
        except Exception as e:
            log_error("phase_event_tx_local_failed", e)    # 非权威，失败仅日志

    rec.phase = new                                       # 只有事件成功后才改内存
    return True
```

**语义对照**

| 类型 | 事件失败时 | 内存 phase | 可否对外作为"已确认状态" |
| --- | --- | --- | --- |
| `tx_local` | 记日志 | **已改为新值** | **不可**（事件在事务内，可能随回滚消失；只作运行期提示） |
| `durable` | 返回 `False`，**不改** | 仍为旧值 | 旧值仍是唯一确认状态 |

### 2.2 `COMMITTED` 的四条件门禁

进入阶段 C 前必须**同时**满足：

1. token 已确认可见（新连接只读查询成功）；
2. K1 成立（§3.1）；
3. K2 成立（§3.2）；
4. `T4 COMMIT_ATTEMPTED→COMMITTED` 的 `durable` 事件写入成功（`set_phase` 返回 `True` 且 `rec.phase == COMMITTED`）。

```python
# 伪代码
if not (token_visible and k1 and k2):
    to_unknown(rec, "commit_gate_failed"); handle_post_commit_failure(...)
elif not set_phase(rec, Phase.COMMITTED, "token_visible_and_isolated"):
    # 事件写失败：不得进入阶段 C
    to_unknown(rec, "committed_event_failed")       # 补偿转换（见 §2.3）
    handle_post_commit_failure(...)
else:
    enter_phase_c(rec)                              # 唯一的阶段 C 入口
```

### 2.3 补偿转换的合法性（明确定义）

| 补偿 | 允许 | 说明 | 失败行为 |
| --- | --- | --- | --- |
| `COMMIT_ATTEMPTED → UNKNOWN`（因 `→COMMITTED` 事件失败） | **允许**（T6 的另一触发条件） | 状态未曾进入 COMMITTED，故不需要"降级"语义 | 该事件也失败 → 见下 |
| `UNKNOWN → COMMITTED` 失败后停留 UNKNOWN | 允许（不转换） | 停留即安全 | 走保守恢复 |
| `UNKNOWN → COMMITTED` 但 **S5 曾失败** | **不允许** | S5 失败意味着"探测时刻存在写者"，token 可见也不足以证明外部世界已稳定 | 保持 `UNKNOWN`，继续保守恢复；不写 success、不开放写入 |
| `UNKNOWN → TX_ROLLED_BACK` 但 **S5 曾失败** | **不允许**（T8′） | 同源理由：看不到 token 也不能证明外部写者已消失 | 保持 `UNKNOWN`，继续保守恢复 |
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

### 2.5 测试（PH9–PH11 + MC19–MC21）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| PH9 | token 可见、K1/K2 成立，`→COMMITTED` 事件写失败 | 注入写失败 | `set_phase` 返回 False；内存仍 `COMMIT_ATTEMPTED`；随后 T6 转 `UNKNOWN`；**未进入阶段 C**；无 success；写入关闭 |
| PH10 | 同上，且 T6 事件也失败 | 注入两次失败 | 无任何 `migration_phase` 事件；内存停留 `COMMIT_ATTEMPTED`；maintenance 保持；非数据库日志有两条；保守恢复执行；退出码非零 |
| PH11 | 同 PH10 | 检查写入入口与 success | 写入 503；`schema_migrations` 中该 mid 无 `success`；三重一致性断言全过 |
| MC19 | COMMIT 抛异常，且 `rollback_for_migration()` 抛错（如 `SQLITE_BUSY`） | 注入回滚失败；统计 S4/S5 完成前的数据库写入 | S4（close）与 S5（探测）**完成之前**，`system_events` 写入次数 == **0**；回滚失败只出现在 `migration-fault.log`；`close()` 成功则 K1 成立 → S5 后可写 `→UNKNOWN`；`close()` 也失败则按 MC14 走 T6′（停 `COMMIT_ATTEMPTED`）；两种情形均无 success |
| MC20 | `UNKNOWN` 态；K1 成立、S5 曾失败、新连接 token 可见 | 走 T7 判定 | **仍为 `UNKNOWN`**（T7′ 禁止）；不进入阶段 C；无 `→COMMITTED` 事件；无 success；保守恢复；写入关闭 |

---

## 3. P1-1：K1 与 S5 的职责分离

### 3.1 K1（原连接终止证明）——只看四件事

| 条件 | 检查方式 | 禁止 |
| --- | --- | --- |
| 已隔离 | 连接包装对象 `quarantined == True`，其 `execute()` 一律抛 `QuarantinedError` | — |
| `close()` 成功 | `close()` 返回无异常 | — |
| 句柄不再可用 | 包装对象 `is_closed == True`；`close()` 后任何方法抛 `ConnectionClosed` | — |
| **不在关闭后读取事务属性** | — | **禁止** `conn.in_transaction`（对象已关闭，该属性无定义/无意义） |

`in_transaction` 只在 **quarantine 之前**读取一次（属性读，不执行 SQL），用于决定是否需要尝试回滚；读取本身有独立异常边界（见下），读取失败记 `had_tx = UNKNOWN`。读取发生在关闭之前，属"终止尝试"的一部分，**不作为 K1 的组成条件**。

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
| ④ `conn.close()` | 独立 `try`，**兜底必执行**（等价于 `finally` 语义） | `close_ok = False`，`non_db_log("conn_close_failed")` | — |

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

try:                                                  # ④ 兜底关闭，必执行
    conn.close()
    close_ok = True
except Exception as e:
    close_ok = False
    non_db_log("conn_close_failed", e)

# ⑤ 关闭之后再判定：只读包装对象标志，绝不读 conn.in_transaction
k1 = quarantined_ok and close_ok and conn_wrapper.is_closed and conn_wrapper.no_tx_read_after_close
```

**K1 判定的唯一口径**

| K1 | 条件组合 | 允许写 DB 事件 | phase 去向 |
| --- | --- | --- | --- |
| **成立** | 已隔离 ∧ `close()` 成功 ∧ 句柄不可用 ∧ 关闭后未读事务属性 | **允许**（S5 成功或失败都允许） | T6 → `UNKNOWN`；S7 再按 T4/T7/T8 判定 |
| **不成立** | 上述任一缺失（隔离未置位或隔离抛错 / `close()` 抛错 / 句柄仍可用 / 关闭后读过事务属性） | **禁止**，无论 S5 是否成功 | **不转换**，停留 `COMMIT_ATTEMPTED`（T6′）；maintenance + 保守恢复或待人工 |

> `had_tx = UNKNOWN` 本身**不**使 K1 为 False（它不是 K1 的条件）；但"隔离抛错"必然使 K1 为 False，"关闭抛错"也必然使 K1 为 False。

**隔离期的写入禁令（本轮新增，硬性）**

| 阶段 | 允许的记录通道 | 禁止 |
| --- | --- | --- |
| S2–S5 未完成（K1 未确认，或 K1 已确认但 S5 未完成） | `<data_dir>/migration-fault.log`（追加写，含 `migration_id/token/reason/ts`）、标准错误 | `append_reason()`、`durable_write_event()`、`set_phase()`、任何 `INSERT/UPDATE` |
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
| S5 失败但 K1 成立 | 仍 `UNKNOWN`（K2 不成立，故不得判 `COMMITTED`/`TX_ROLLED_BACK`）；**允许**写 `→UNKNOWN` 事件（原连接已关，不存在写锁）；随后保守恢复 |
| K1、S5 均失败 | 无 DB 事件、仅文件日志、phase 停留 `COMMIT_ATTEMPTED`、保守恢复 |
| 他进程重新取得写锁且拒绝释放 | 不重试、不杀进程；`abort_recovery`，人工介入 |

### 3.4 测试（MC14–MC24）

| # | 初始 | 步骤 | 预期 |
| --- | --- | --- | --- |
| MC14 | COMMIT 抛异常；`close()` 失败；探测也失败 | 判定 | **无任何 DB 事件**；`migration-fault.log` 有记录；phase 停留 `COMMIT_ATTEMPTED`（T6′）；保守恢复；写入关闭；无 success |
| MC15 | COMMIT 抛异常；`close()` 抛错，**S5 成功** | 判定 | K1=False → **仍停留 `COMMIT_ATTEMPTED`**；`system_events` 写入次数 0；无 `→UNKNOWN`；无 success；写入关闭；只写文件日志 |
| MC15b | `rollback_for_migration()` 抛 `SQLITE_BUSY` | 继续 S4/S5 | 只写 `migration-fault.log`；S4–S5 完成前 DB 写入 0；close 成功则 K1 成立、可写 `→UNKNOWN` |
| MC15c | 隔离后调用 `conn.execute("ROLLBACK")` | 观察 | 抛 `QuarantinedError`；DB 无写入；K1 不受影响（不影响判定） |
| MC15d | 隔离后调用 `rollback_for_migration("UPDATE ...")` | 观察 | 抛 `IllegalRecoverySql`；DB 无写入；恢复路径继续按既有规则 |
| MC16 | 探测连接被外部持有写锁 | S5 失败，K1 成立 | 判 `UNKNOWN`；有 `→UNKNOWN` 事件；保守恢复；写入关闭 |
| MC17 | S5 成功，随后注入他进程写锁 | 替换前 S5′ | 检出 → `abort_recovery`（码 4）；文件未替换；备份 sha256 不变 |
| MC18 | K1 成立、S5 成立、token 不可见、对象不可见 | 判定（分别从 `COMMIT_ATTEMPTED` 与 `UNKNOWN` 两态各跑一次） | `COMMIT_ATTEMPTED → TX_ROLLED_BACK`（T5）/ `UNKNOWN → TX_ROLLED_BACK`（T8）；终止；无 success |
| MC21 | K1 成立、**S5 曾失败**、token 不可见、对象不可见 | 判定 | **仍 `UNKNOWN`**（T8′ 禁止）；无 `→TX_ROLLED_BACK` 事件；不写 success；不开写入；保守恢复 |
| MC22 | `conn.in_transaction` 属性读取抛异常 | 观察调用序列 | 仍执行 `quarantine()` 与 `close()`（close 尝试次数 = 1）；`had_tx=UNKNOWN` 只用于决定回滚尝试，**不进 K1**；若隔离与关闭均成功则 K1 可成立，否则 K1=False |
| MC23 | `quarantine(conn)` 抛异常 | 观察 | 仍执行 `close()`（尝试次数 = 1）；**不调用** `conn.execute` / `rollback_for_migration()`；K1 = **False**；DB 写入次数 = 0；phase 保持 `COMMIT_ATTEMPTED`；maintenance = 开 |
| MC24 | 属性读与 `quarantine` 均抛异常 | 观察 | 仍执行 `close()`（尝试次数 = 1）；K1 = **False**；DB 写入次数 = 0；phase 保持 `COMMIT_ATTEMPTED`；maintenance = 开；仅 `migration-fault.log`（两条记录、无 success） |

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

| 旧状态 | 新状态 | 触发 | 事件类型 | 事件时点 | 失败后果 |
| --- | --- | --- | --- | --- | --- |
| PREPARED | TX_OPEN | BEGIN 成功 | tx_local | 事务内 | 日志；不回退 |
| PREPARED | （无转换） | 阶段 A 失败 | `migration_abort`（非 phase） | 事务外 | 终止 |
| TX_OPEN | COMMIT_ATTEMPTED | COMMIT 前 | tx_local | 事务内 | 日志；继续 COMMIT |
| TX_OPEN | TX_ROLLED_BACK | ROLLBACK 成功 | durable | 回滚后 | 事件失败仍终止 |
| COMMIT_ATTEMPTED | COMMITTED | token ∧ K1 ∧ K2 ∧ 事件成功 | durable | S5 后 | 事件失败 → T6 |
| COMMIT_ATTEMPTED | TX_ROLLED_BACK | 无 token ∧ 无对象 ∧ K1/K2 | durable | S5 后 | 事件失败仍终止 |
| COMMIT_ATTEMPTED | UNKNOWN | COMMIT 抛异常 ∧ **K1 成立**（S5 成功或失败均可） | durable | **S5 后（唯一）** | 事件失败 → 非 DB 日志 + 恢复 |
| COMMIT_ATTEMPTED | （无转换） | COMMIT 抛异常 ∧ **K1 不成立**（S5 成功或失败均可） | **无**（`migration-fault.log`） | — | phase 停留 `COMMIT_ATTEMPTED`；maintenance + 保守恢复 / 待人工（T6′） |
| UNKNOWN | COMMITTED | token 可见 **∧ K1 ∧ S5 成功 ∧ 事件成功**（四条件） | durable | 查询后 | 任一不满足 → 停留 UNKNOWN + 恢复 |
| UNKNOWN | COMMITTED（S5 曾失败） | **禁止（T7′）** | — | — | 保持 UNKNOWN；不写 success、不开写入 |
| UNKNOWN | TX_ROLLED_BACK | token 不可见 **∧ 对象不可见 ∧ K1 ∧ S5 成功 ∧ 事件成功**（五条件） | durable | 查询后 | 任一不满足 → 停留 UNKNOWN + 恢复 |
| UNKNOWN | TX_ROLLED_BACK（S5 曾失败） | **禁止（T8′）** | — | — | 保持 UNKNOWN；不写 success、不开写入 |
| UNKNOWN | UNKNOWN | — | **禁止**（用 `append_reason`） | — | `IllegalTransition` |
| COMMITTED | 任意 | — | **禁止回退**（阶段 C 失败用 `migration_rollback` 事件） | — | — |

> **S2 异常不产生任何转换**：属性读、隔离、回滚三段中的任一抛错，都只写 `migration-fault.log`；`phase` 仍为 `COMMIT_ATTEMPTED`。若隔离确认且关闭成功 → 走 T6 写 `→UNKNOWN`；否则走 T6′（无转换）。

---

## 6. 逐项关闭说明（含实际逻辑）

### 6.1 P0-1 phase 重复

| 要求 | 落实 |
| --- | --- |
| 只有 `set_phase` 能改 phase | §2.1 唯一入口；其他位置置 `commit_raised` 等非 phase 标记 |
| S1 区分进程内标记与状态转换 | §1.1 标记表；S1 不调用 `set_phase` |
| 同一转换不重复 | T6 只在 S5 后执行一次；`set_phase` 内 `LEGAL_TRANSITIONS` 校验，重复即 `IllegalTransition` |
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
| 隔离失败不强写审计 | 规则 1–2：只用 `<data_dir>/migration-fault.log` |
| 所有 durable 时点明确 | §1.3 五类事件表 + 硬规则 3 |
| K1 是写库唯一闸门 | §1.3 硬规则 7 + §3.1 判定表；K1 不成立 → T6′ |
| 测试验证顺序 | MC13/MC14/MC15/MC19/PH6 |

### 6.3 P0-3 事件失败补偿

| 要求 | 落实 |
| --- | --- |
| 两类确认语义 | §2.1 表：durable 失败不改内存；tx_local 改了但非权威 |
| 事件失败不得对外使用新状态 | `set_phase` 返回 False，`rec.phase` 仍旧值 |
| COMMITTED 四条件 | §2.2 门禁（token/K1/K2/事件） |
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

---

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
| MC | 12 | **28** | +MC13–MC18；二次修订 +MC19–MC20；三次修订 +MC21、MC15b/15c/15d、MC13b；四次修订 +MC22–MC24 |
| CR | 5 | 5 | — |
| FX | 3 | **4** | +FX4 |
| PH | 5 | **11** | +PH6–PH11 |

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
| COMMITTED 四条件 | §2.2 门禁 | §5 第一行 | PH9/PH10 |
| 补偿合法性 | `to_unknown` | §2.3 表 | PH10/PH11 |
| K1 四条件 | §3.1 伪代码 | §3.1 判定表 | MC15 |
| K1 不成立即不写库 | T6′ 分支（无 `set_phase`） | §5 `COMMIT_ATTEMPTED → （无转换）` 行 | MC14/MC15 |
| quarantine 后仍能终止 | `rollback_for_migration()` 只放行 ROLLBACK | §3.1 通道表 | MC15b/MC15c/MC15d |
| S2 不中断关闭 | 三段独立 try + 兜底 close | §3.1 异常边界表 | MC22/MC23/MC24 |
| 隔离失败仍关闭且 K1=False | `quarantined_ok=False` → `k1=False` | §3.1 判定表 | MC23/MC24 |
| S5 独立 | §3.2 | §3.3 | MC16–MC18 |
| T8 五条件 | §1.2 T8 | §5 `UNKNOWN→TX_ROLLED_BACK` 行 | MC18/MC21 |
| T8′ 禁止分支 | 判定处显式 `if s5_failed: stay UNKNOWN` | §1.2 T8′ | MC21 |
| 隔离期禁写库 | §3.1 `non_db_log` 分支 | §3.1 禁令表 / §1.3 硬规则 1–2 | MC19 |
| T7 四条件 | §1.2 T7 | §5 `UNKNOWN→COMMITTED` 行 | MC20 |
| T7′ 禁止分支 | 判定处显式 `if s5_failed: stay UNKNOWN` | §1.2 T7′ / §2.3 | MC20 |
| 独立夹具 | §4.2 | — | FX4/R10-A0/A1/A2 |

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

---

**v1.10 到此结束。** 四次修订合计**未编写代码、未执行迁移、未修改数据库、未修改生产配置或生产数据**；四次修订累计只处理"五项 + 两项 + 三项 + S2 异常保护"的状态机与伪代码矛盾。**C11–C20 全部未确认，C12 仍未被本轮视为已批准。** 文档交回总体设计最终审查；未获批准前不提交 P-1 实施计划、不进入任何实施阶段。
