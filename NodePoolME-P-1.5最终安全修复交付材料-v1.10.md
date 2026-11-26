# NodePoolME P-1.5 最终安全修复交付材料（v1.10）

阶段：P-1.5（五入口与二次封锁机制接线，PT-15 / PT-16 / PT-23）
基线：`85cc85a3d7e7fa4349c7a3f00a50025e714fc27d`
本提交：`ce68612d3037d7f247ec5024d829d9ebb77e2b6b`（已推送 `main`，`git ls-remote` 回读一致）
状态：**完成，停止等待负责人验收。不自行宣布 P-1.5 通过，不进入 P-1.6。**

---

## 1. 提交与修改文件

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/pool.py` | 17,742 | 409 | `d43851ae62d05ee6011973cf8edb2521e4c0ae55` |
| `backend/database/db.py` | 32,405 | 833 | `a423dd315da41b43565e878260753717f85552c2` |
| `tests/test_maintenance_lock.py` | 42,893 | 1,023 | `eb0affee1b4e08a7409703340e5f4de6189c01af` |

未改动（blob 与基线一致，可核对）：

- `backend/database/gate.py` `ba7fb8bff939cc70e487629d20e12542f0f1c316`（本轮确无必要）
- `backend/database/migrate.py` `37d8f35377d6ca94bf8594194e17a9e74b983974`
- 其余 `main.py` / `manager.py` / `routes.py` / `cli.py` / `conftest.py` / SCHEMA / 业务表 / Compose 全部未动。

差异：3 files changed, 494 insertions(+), 55 deletions(-)。

---

## 2. 问题一：提交复核与 `conn.commit()` 的原子性

### 2.1 原缺陷

```
_assert_txn_committable(entry)     # 复核通过
        ← 这里可以插入 block_writes()
conn.commit()                      # 仍然把写入落库
```

复核通过后、真正提交前存在竞争窗口；靠"封锁会关连接"兜底并不成立——`close()` 只是把句柄关掉，在提交已经跨过复核的瞬间无法撤回。

### 2.2 修法（三层，缺一不可）

**(a) 提交临界区与封锁同锁。** 新增 `pool.commit_slot()`，与 `write_slot()`、`block_writes()` 共用同一把可重入的 `_blocking_lock`：

```python
@contextmanager
def commit_slot():
    with _blocking_lock:
        if _blocked_reason is not None or _block_intent:
            raise WriteRefused("writes_blocked")
        yield
```

`db.transaction()` 现在是：

```python
with gate.write_guard() as conn:
    entry = None
    try:
        with pool.commit_slot():          # 登记与封锁互斥
            entry = _register_txn(conn)
        conn.execute("BEGIN IMMEDIATE")
        yield conn
        with pool.commit_slot():          # 复核 + commit 原子化
            _assert_txn_committable(entry)
            conn.commit()
    except Exception:
        try: conn.rollback()
        except Exception: pass
        raise
    finally:
        if entry is not None: _unregister_txn(entry)
```

于是"复核"与"`commit()`"之间不存在任何可以被封锁穿插的点——这一步不是靠约定，而是靠锁结构保证。

**(b) 封锁意图（`_block_intent`）。** `block_writes()` 在**取锁之前**先置位意图标记，再取锁完成"中止在途事务 + 关闭写连接"。含义是：如果封锁请求在提交临界区执行期间到达，临界区内的复核会直接看到意图并拒绝提交，而不是"等封锁释放锁之后再把写入落库"。这是把 (a) 从"互斥"升级为"封锁请求优先于尚未落库的提交"。

**(c) 登记也进临界区。** `_register_txn()` 在 `commit_slot()` 内调用，并在函数内部对 `block_pending()` 做兜底拒绝。防止"封锁已中止并关闭连接 → 又冒出一条新的、未被中止的在途登记"（那会让 `active_write_transactions()` 在封锁后瞬时非零，破坏排空判据）。

### 2.3 保证与锁序

`block_writes()` 返回时同时满足：闸门已置位、业务写连接 0 条、可提交在途事务 0 条（`confirm_writes_blocked()` 的四个判据）。可达的三种交错只有两种结局：

| 交错 | 结果 |
| --- | --- |
| 提交临界区先取得锁 | 提交先落库，封锁**必须等** `commit()` 返回才能返回 ⇒ 封锁返回即静默点 |
| 封锁先完成 | `commit_slot()` 入口即 `WriteRefused("writes_blocked")` |
| 封锁请求落在临界区内部 | 意图已置位 ⇒ 复核拒绝提交；封锁仍要等临界区退出才返回 |

不存在第四种（复核通过后提交、而封锁同时返回）。

锁获取顺序固定并写入模块 docstring：`_blocking_lock`（可重入）→ `_INFLIGHT_LOCK` / `_ISSUER_LOCK`；持有后两者时不申请前者。提交临界区只做"复核 + commit"，不等待其它连接的 SQLite 锁（写锁已在 `BEGIN IMMEDIATE` 阶段取得），因此不存在锁反转；`block_writes()` 在锁内只做"标记中止 + `close()`"，不等待任何 SQLite 事务结束。实测两轮并发用例各 15 次重复执行无挂起、无超时（见 §5.2）。

`reset_for_tests()` 同步清理意图标记与注册表。

---

## 3. 问题二：可信令牌的对象身份绑定

### 3.1 原缺陷

- 信任依据是 `issue.__module__` 字符串——普通调用方 `f.__module__ = "backend.database.migrate"` 即可冒充；
- `_ISSUERS` 只存 `id(token) -> 模块名`，令牌对象本身随手丢弃 ⇒ 对象回收后 id 复用会让"另一个对象"通过校验；
- 凭据只校验 `_issuer` 字符串"出现在注册表里"，没有绑定具体发射器实例。

### 3.2 修法

**身份绑定改为模块命名空间的真实绑定。** `register_confirmation_issuer()` 依次校验：

1. 必须是 `types.FunctionType`（内建、实例、lambda 以外的东西直接拒）；
2. `sys.modules["backend.database.migrate"]` 必须已存在，且 `issue.__module__` 与之相符（不符 → `untrusted_issuer_module`，保留既有错误码）；
3. **`issue.__globals__ is module.__dict__`**（不符 → `untrusted_issuer_identity`）。函数的 `__globals__` 是只读属性，普通调用方无法把它指到别处，因此"改 `__module__` 字符串"这条路被彻底堵死；
4. `issue.__name__ == "halt_migration"`（否则 `untrusted_issuer_identity`）——凭据绑定的是**具体发射器**，不是"某个函数"。

**注册表保留令牌对象本身。** 登记项改为不可变记录：

```python
@dataclass(frozen=True)
class _IssuerRecord:
    token: object            # 令牌对象本体（不是 id 的影子）
    issuer: str              # "backend.database.migrate:halt_migration"
    registered_at: float

_ISSUERS: dict[int, _IssuerRecord] = {}   # id(token) -> record
```

`_lookup_token()` 的校验是 `record.token is token`——id 相符但引用不同（对象被替换 / id 复用）一律视为未注册。同一发射器重复注册是幂等的：返回**同一个**令牌对象，注册表不会出现第二个可用令牌。

**签发绑定到发射器实例。** 凭据现在携带三个不可伪造要素：

| 字段 | 含义 | 伪造难度 |
| --- | --- | --- |
| `_token` | 模块私有哨兵 `_ISSUER_TOKEN` | 直接实例化/复制字段/子类都拿不到 |
| `_issuer_token` | **注册表中那个令牌对象** | 只能由 `mint_confirmation()` 从登记项取出 |
| `_issuer` | `模块:函数` 身份串 | 必须与登记项一致 |

`is_confirmed()` 的要求：哨兵命中 → `_lookup_token(_issuer_token)` 命中且 `record.issuer == _issuer` → 再校验 `source` / 非空 `migration_id` / 两个严格 `True` / 数值 `confirmed_at`。

没有公开的无验证工厂：`new_confirmation()` 仍不存在；唯一签发入口 `mint_confirmation()` 要求已注册令牌对象，且在签发时刻当场 `confirm_writes_blocked()` 为真。

**P-1.5 仍失败关闭。** 本阶段不注册任何发射器，`halt_tail()` 一律 `no_trusted_issuer`；注册表被清空后同样如此。

---

## 4. P-1.6 可信发射器接入契约（接口已就位，状态机未实现）

`backend/database/migrate.py` 内（P-1.6 施工时写）：

```python
from backend.database import pool

def halt_migration(reason: str) -> dict:
    pool.block_writes(reason or "maintenance")            # 1. 置位写入闸（A 类已给结论，B 类执行）
    state, _ = ...                                         # 2. 回读维护文件（A 类判定，B 类不做）
    maintenance_ok = state is MaintState.ACTIVE and fields_ok
    writes_blocked = pool.confirm_writes_blocked()[0]      # 3. 用实证而不是自称
    rec = pool.mint_confirmation(_TOKEN, migration_id,
                                 maintenance_ok, writes_blocked)
    return {"halt_tail": pool.halt_tail(rec), ...}

_TOKEN = pool.register_confirmation_issuer(halt_migration)  # 模块级、只执行一次
```

契约要点：

1. `register_confirmation_issuer()` 只接受"定义在 `backend.database.migrate` 里、名为 `halt_migration` 的函数"；返回的令牌由 `migrate.py` 以**模块私有变量**持有，不对外导出、不写进配置或事件记录。
2. `mint_confirmation()` 的 `writes_blocked` 必须是 `confirm_writes_blocked()` 的实证结果（闸门置位 + 写连接 0 + 可提交在途事务 0 + 只读 `query_only=1`），不接受调用方自填 `True`。
3. 只有完成"置位 → 回读维护文件 → 实证封锁"三步之后签发的凭据才能通过 `halt_tail()`；缺任一步在 `halt_tail()` 或 `mint_confirmation()` 处失败关闭。
4. 排空失败路径：`gate.assert_drain_ok(result)` 抛 `DrainFailed`，或在 `except DrainFailed` 内 `halt_migration(exc.code)`；`DrainResult.continue_allowed` 恒为 `False`，`halt_code="drain_failed"`。
5. 重启后注册表为空 ⇒ 旧凭据（进程内对象）不可复用，必须重新走一遍上述流程——这是设计意图，不是缺陷。

`gate.py` 本轮无需改动：排空下限、失败保持封锁、`assert_drain_ok` 契约在上一轮已成立并通过测试。

---

## 5. 测试

### 5.1 专项测试

`python3 -m pytest -q tests/test_maintenance_lock.py` → **58 passed**（原 50 项全部保留，新增 8 项）。

新增用例：

| 用例 | 覆盖 |
| --- | --- |
| `test_block_cannot_interleave_between_commit_check_and_commit` | 在途事务已在提交临界区、`commit()` 未执行 → 封锁无法插入 → 复核拒绝（问题一主用例） |
| `test_commit_inside_critical_section_serializes_before_block_return` | 提交先到（复核已过）→ 封锁等 commit 落库才返回；封锁返回即静默点 |
| `test_inflight_registration_cannot_slip_past_block` | 封锁后 `commit_slot()` 拒绝、`_register_txn()` 拒绝，在途计数恒 0 |
| `test_forged_module_attribute_cannot_register_issuer` | 伪造 `__module__` / 同名空间不同函数名 / 非函数，一律拒绝 |
| `test_registry_stores_token_object_identity` | 登记项保留令牌对象；重复注册幂等返回同一对象 |
| `test_unregistered_and_replaced_token_cannot_mint` | 未注册令牌、同 id 换对象、清表后占位，均拒绝 |
| `test_confirmation_is_bound_to_issuer_token_not_issuer_string` | 光有哨兵+身份串无效；换令牌对象旧凭据失效；冒用他令牌身份被拒 |
| `test_p16_issuer_handoff_contract` | P-1.6 交接全链路：未封锁不得签发 → 封锁后实证签发 → `halt_tail` 通过 |

### 5.2 关键竞争窗口时序与结果

**用例 A（封锁请求落在提交临界区内）**

```
T0 会话1: transaction() → write_guard → write_slot 取写连接 → commit_slot 登记
         → BEGIN IMMEDIATE → INSERT → 进入提交 commit_slot（持锁）
         暂停点 P：复核前（in_critical.set(); resume.wait()）
T1 主线程: in_critical 已置位；active_write_transactions()==1（在途，未提交）
T2 会话2: pool.block_writes() → 先置意图(不取锁) → 抢锁（被 T0 挡住）
T3 主线程: blocked_done 0.3s 内未置位（封锁没有返回）
           block_pending()==True（意图在）  writes_blocked()==False（闸门未落）
T4 resume.set() → 会话1 复核读到意图 → WriteRefused("writes_blocked")
           → rollback → 注销登记 → 释放临界区
T5 会话2: 取得锁 → abort inflight → close write conns → 返回
```

结果：`outcome["commit"] == "WriteRefused"`；`blocked_done` 置位；`open_write_connections()==0`；`active_write_transactions()==0`；`confirm_writes_blocked()` 为 True；新会话 `db.connect()` 抛 `PoolClosed`；只读 `SELECT 1` 正常；**DB 终态 `logs` 中 `message='t'` 计数 = 0**；封锁后新事务仍被拒，计数保持 0。

**用例 B（提交先取得临界区）**

```
T0 会话1: 同上，但暂停点在复核**之后**（checked.set(); resume.wait()）
T1 主线程: checked 已置位；active_write_transactions()==1
T2 会话2: block_writes() → 意图置位 → 等锁
T3 主线程: blocked_done 0.3s 内未置位（封锁被提交临界区挡住，抢不进去）
T4 resume → conn.commit() 落库 → 释放临界区
T5 会话2 取得锁 → 中止/关闭 → 返回
```

结果：`outcome["commit"] == "ok"`，且这一行是**封锁返回之前**落库的（封锁在 T3 已被证明无法返回）；封锁返回后 `confirm_writes_blocked()` 为 True、在途 0、新连接被拒、只读正常、新事务被拒，**DB 终态计数 = 1 且此后不再变化**。

两组用例各重复执行 15 次：`5 passed` × 15，无挂起、无超时、无抖动。

### 5.3 令牌伪造测试结果

| 攻击 | 结果 |
| --- | --- |
| 测试模块函数 + `__module__ = "backend.database.migrate"` | `untrusted_issuer_identity`（`__globals__` 不符） |
| 在 migrate 命名空间内定义 `run()` 后注册 | `untrusted_issuer_identity`（函数名不符） |
| `len` / 实例 / 字符串 当发射器 | `untrusted_issuer_identity` |
| `object()` 冒充令牌调用 `mint_confirmation` | `untrusted_issuer` |
| 同 id 位置换成另一令牌对象 | `untrusted_issuer`（`is` 比对失败） |
| 直接实例化凭据（含子类） | `unconfirmed` |
| 字段全 True + 哨兵，但 `_issuer_token` 是陌生对象 | `unconfirmed` |
| 有效凭据 + 注册表换成同身份不同令牌 | `unconfirmed`（旧凭据立即失效） |
| 冒用他令牌身份串 | `unconfirmed` |
| P-1.5（无发射器） | `no_trusted_issuer` |

### 5.4 全量测试（按既定分批）

```
$ python3 -m pytest -q --ignore=tests/test_migration_baseline.py
362 passed, 1 skipped, 1 warning in 24.09s

$ python3 -m pytest -q tests/test_migration_baseline.py
15 passed in 13.13s
```

合计 **377 passed + 1 skipped, 0 failed**（上一轮为 369：354+15）。分批原因不变：`test_migration_baseline.py` 的 PT-06 系列要求"仓库开发库 = alter_history 形态"，而部分业务模块在导入期用 `NODEPOOL_DATA_DIR` 指向全新临时库（fresh_init），单进程混跑必失败。

---

## 6. 边界声明

- 未修改两份 v1.10 批准文档、`migrate.py`、SCHEMA、业务表、`services`/`testers`/`scoring`/前端、Compose/镜像/部署配置。
- 未实现 P-1.6 状态机（无迁移事件链、无 phase 推进），未实现 P-1.7 演练，未执行 P-7。
- 未接触 NAS 生产数据库、生产容器、生产服务。
- 未降低测试标准：原 50 项全部保留（其中两项按新凭据模型调整了构造方式与身份串断言，拒绝语义未放宽），新增 8 项。
- Python 模块不是安全沙箱：本轮消除的是**接口层**的伪造与身份混淆（改属性冒充、id 复用、字符串身份比对），不防御"拥有任意代码执行能力"的攻击者。

## 7. 仍待负责人裁定（沿用前轮，未新增）

1. 维护期 `/api/login`（POST）是否也应 503（当前按"所有业务写接口"字面拦截）。
2. CLI 形态（现为 `python -m backend.database.cli`）与 `halt_tail()` 的最终归属模块（现暂在 `pool.py`）。
3. 跨进程真实排空（独立进程持库）与多实例闸门当前未覆盖（本阶段为单进程内存态）。
