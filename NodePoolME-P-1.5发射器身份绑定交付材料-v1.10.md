# NodePoolME P-1.5 最后一项修复交付材料（v1.10）｜发射器对象身份绑定

阶段：P-1.5（五入口与二次封锁机制接线，PT-15 / PT-16 / PT-23）
上一提交（复审确认提交原子性通过）：`ce68612d3037d7f247ec5024d829d9ebb77e2b6b`
本提交：`3fb7c515f894569e231d687f228df7ad3d8dac5b`（已推送 `main`，`git ls-remote` 回读一致）
状态：**完成，停止等待复审。不自行宣布 P-1.5 通过，不进入 P-1.6/P-1.7。**

---

## 1. 变更清单与 blob SHA

| 文件 | 字节 | 行 | blob SHA | 本轮 |
| --- | --- | --- | --- | --- |
| `backend/database/pool.py` | 20,018 | 448 | `42aeb8134013213f6590acfad72450b21aa867ce` | 修改 |
| `tests/test_maintenance_lock.py` | 49,845 | 1,160 | `c8e2aa2b2fe13cd01724ad5359fa973847943a90` | 修改 |
| `backend/database/db.py` | 32,405 | 833 | `a423dd315da41b43565e878260753717f85552c2` | **未改动**（blob 与 `ce68612` 一致） |

差异：2 files changed, 193 insertions(+), 17 deletions(-)。

`db.py` 的提交原子性实现一行未动（本轮身份绑定不需要它提供任何新接口）；`gate.py`、`migrate.py`、SCHEMA、业务表、services/testers/scoring/前端、Compose/镜像/部署配置均未改动。

---

## 2. 发射器对象身份绑定实现

### 2.1 登记项结构

```python
@dataclass(frozen=True)
class _IssuerRecord:
    token: object            # 签发令牌本体（不是 id 影子）
    issuer: str              # "backend.database.migrate:halt_migration"（仅作标识，不作信任依据）
    function: Any            # 实际发射器函数对象（强引用）
    registered_at: float
```

`function` 是**强引用**：函数对象在整个注册存活期内不会被回收，`id()` 复用也就无从发生；所有比对一律 `is`。

### 2.2 注册

`register_confirmation_issuer(issue)`：

1. 必须是 `types.FunctionType`；
2. `sys.modules["backend.database.migrate"]` 存在且 `issue.__module__` 相符（否则 `untrusted_issuer_module`）；
3. `issue.__globals__ is module.__dict__`（否则 `untrusted_issuer_identity`；`__globals__` 只读，改字符串冒充不了）；
4. `issue.__name__ == "halt_migration"`（否则 `untrusted_issuer_identity`）；
5. 锁内比对登记项：
   - `record.issuer == _ISSUER_ID` 且 **`record.function is issue`** → 返回 `record.token`（幂等，同一对象永远同一令牌）；
   - `record.issuer == _ISSUER_ID` 但 `record.function is not issue` → `issuer_identity_conflict`，**拒绝注册、不交出原令牌**；
   - 否则创建令牌并登记 `{token, issuer, function, registered_at}`。

即：身份串相同 ≠ 可信。必须"同一身份 + 同一函数对象"才拿得到令牌。

### 2.3 绑定存活校验（签发与确认共用）

```python
def _record_binding_live(record) -> bool:
    module = sys.modules.get(_TRUSTED_ISSUER_MODULE)
    current = getattr(module, _TRUSTED_ISSUER_FUNC, None)
    return isinstance(record.function, types.FunctionType) and current is record.function
```

要求登记项里的函数对象**就是模块当前绑定的那个对象**。

- `mint_confirmation()`：令牌命中 → 绑定存活校验，不通过即 `issuer_replaced`（在维护态/封锁字段校验之前），不签发；
- `MaintConfirmation.is_confirmed()`：哨兵 → 令牌对象同一 → 身份串一致 → **绑定存活**，任一不成立即 `False`。

因此四种替换/混淆全部失败：

| 场景 | 结果 |
| --- | --- |
| 同身份串，传入另一个函数对象 | 注册 `issuer_identity_conflict` |
| 已注册后，模块里同名函数被替换 | 旧令牌 `mint_confirmation` → `issuer_replaced`；新函数 → 拿不到原令牌 |
| 登记项 `function` 被改写成别的函数对象 | `issuer_replaced` / `is_confirmed()=False` |
| 模块属性换成别的对象、登记项仍指原对象 | `issuer_replaced` / `is_confirmed()=False` |

### 2.4 仍然失败关闭

P-1.5 不注册任何发射器，`_ISSUERS` 为空 ⇒ `halt_tail()` 一律 `no_trusted_issuer`（本轮新增用例再次固化该断言，含"已封锁"与"未封锁"两种前置）。

---

## 3. 新增反向测试（5 项，全部真实构造函数对象）

| 用例 | 断言要点 | 结果 |
| --- | --- | --- |
| `test_same_function_object_registration_is_idempotent` | 同一对象两次注册 → 同一令牌、`len(_ISSUERS)==1`、`record.function is issuer` | 通过 |
| `test_same_module_and_name_but_different_function_object_is_rejected` | `_replace_module_halt_migration()` 重新 `exec` 出**另一个**函数对象（同日模块同名），注册 → `issuer_identity_conflict`；原登记项未被改写 | 通过 |
| `test_replaced_module_function_breaks_token_and_confirmation` | 替换后：新函数注册被拒；新函数无令牌 → `untrusted_issuer`；旧令牌 → `issuer_replaced`；替换前签发的凭据 → `halt_tail` 报 `unconfirmed` | 通过 |
| `test_record_binding_replacement_is_rejected` | 登记项 `function` 换成别的对象（模块侧保持原对象）→ `issuer_replaced` + `halt_tail` 失败；反向（登记项原对象、模块属性被换）→ 同样失败，`_record_binding_live()` 为 False | 通过 |
| `test_no_issuer_registered_keeps_halt_tail_fail_closed` | `_ISSUERS == {}` 时，直接实例化/鸭子对象/dict 全部拒绝；封锁态下 `no_trusted_issuer` | 通过 |

测试辅助：`_fake_halt_migration()` 用 `exec(compile(...), module.__dict__)` 在 migrate 模块命名空间内定义 `halt_migration`（复刻 P-1.6 的真实事实），并复用已存在的可信定义；`_replace_module_halt_migration()` 每次都产生**新对象**并覆盖模块属性。两者都不是"改 `__module__` 字符串"的假替代。

---

## 4. 测试结果

```
$ python3 -m pytest -q tests/test_maintenance_lock.py
63 passed, 1 warning in 2.64s          # 原 58 项全部保留 + 新增 5 项
                    （连跑 5 次：63 passed × 5，无抖动）

$ python3 -m pytest -q --ignore=tests/test_migration_baseline.py
367 passed, 1 skipped, 1 warning in 24.32s

$ python3 -m pytest -q tests/test_migration_baseline.py
15 passed in 13.33s
```

合计 **382 passed + 1 skipped, 0 failed**（上一提交为 377：362+15）。

---

## 5. P-1.6 注册接口兼容性

接口签名、调用方式与上一轮契约完全一致，只是**校验更严**：

```python
# migrate.py（P-1.6 施工时）
from backend.database import pool

def halt_migration(reason: str) -> dict:
    pool.block_writes(reason or "maintenance")                  # 1. 置位写入闸
    ...                                                          # 2. 回读维护文件 → maintenance_ok
    writes_blocked = pool.confirm_writes_blocked()[0]            # 3. 实证封锁成立
    rec = pool.mint_confirmation(_TOKEN, migration_id,
                                 maintenance_ok, writes_blocked)
    return {"halt_tail": pool.halt_tail(rec), ...}

_TOKEN = pool.register_confirmation_issuer(halt_migration)       # 模块级，导入时执行一次
```

- 与上一轮的差异：注册会额外要求"同一身份下是同一函数对象"。P-1.6 只注册一次、后续不再重定义 `halt_migration`，因此天然满足；
- `importlib.reload(migrate)` 或运行期重定义 `halt_migration` 会使旧令牌失效（`issuer_replaced`）——这是设计意图：新进程/新定义必须重走"置位 → 回读 → 实证 → 签发"，不复用旧凭据；
- `mint_confirmation` / `halt_tail` / `confirm_writes_blocked` / `register_confirmation_issuer` 签名与返回类型均未变，P-1.6 可直接按上述片段接线，无需适配。

---

## 6. 边界声明

- 未修改两份已批准的 v1.10 文档；未修改 `migrate.py`；未实现 P-1.6 状态机；未进入 P-1.7；未执行 P-7；
- 未接触 NAS、生产数据库、生产容器、生产服务；
- 提交原子性部分（`db.py` / `pool.commit_slot` / 封锁意图）本轮零改动；
- 测试标准未降低：原 58 项全部保留（两条手工构造登记项的用例仅同步了新增 `function` 字段，拒绝语义未放宽），新增 5 项。
- Python 模块不是安全沙箱：本次加固的是接口层身份绑定（同名不同对象、id 复用、属性替换），不防御拥有任意代码执行能力的攻击者。
