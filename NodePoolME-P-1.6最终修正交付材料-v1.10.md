# NodePoolME P-1.6 最终修正交付材料（Migration Connection Close Failure）

**阶段**：P-1.6 最终修正（迁移连接关闭失败处理）
**新提交**：`41de972b27f7aa3f097896cc743ca4b360f87b2e`（`41de972`，已推送 `main`）
**上一提交**：`7cf710bbeef0923049f0ca8aa00c68106c9adec0`
**依据**：《新架构总体设计方案 v1.10》《P-1 实施计划 v1.10》（未修改）
**边界**：PT-09b 保持有效、未接入事件链、未执行真实恢复、未进入 P-1.7/P-1.8、未接触 NAS/生产环境。
**停止点**：完成后停止，等待 ChatGPT 最终复审；不自评通过。

---

## 1. 变更清单

本轮 diff：2 files changed, 59 insertions(+), 6 deletions(-)

| 文件 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- |
| `backend/database/migrate.py` | 66,867 B | 1,527 | `4776eab43a20d738685f3beaaca71b8359a8ba7f` |
| `tests/test_migration_state.py` | 40,815 B | 977 | `2c26c90eabea5925b0399489e234ed5327eee0a1` |

`backend/database/cli.py`（6,570 B / 157 行 / `b07d9a906d20ca2106426512cdc45f7b1e4c06b7`）与 `backend/config.py`（7,078 B / 160 行 / `e6dc1aa9dcd5d79c382cbb7f8d00c978ba6317b5`）本轮未改。

---

## 2. 修正内容

两个分支原本在 `_close_migration_connection()` 之后**未检查 `closed`**，现统一把"连接未被确认关闭"提升为最高优先级的故障安全出口：

### 2.1 BEGIN 失败分支

```text
closed=False ⇒ FatalExit("migration_connection_open")（非零退出）
             · 不返回 begin_failed
             · 不写任何 migration status 行（running / failed 均无）
             · 写入封锁保持（pool.ensure_blocked 已在判定前执行）
closed=True  ⇒ 允许返回 begin_failed / no_transaction（phase 保持 PREPARED，epoch 0）
```

### 2.2 回滚成功 + 结构复核通过分支

```text
closed=False ⇒ FatalExit("migration_connection_open")
             · 不调用 _mark_failed()（不打开第二条连接写 failed 行）
             · 不推进 TX_ROLLED_BACK（phase / phase_epoch 保持原值）
             · 不伪造 KNOWN_FAILED
             · 写入封锁保持
closed=True  ⇒ 才进入 KNOWN_FAILED：推进 T3/T5 + 独立短事务写 failed 行
```

判定顺序：`ensure_blocked` → `_safe_log`（记录 begin/rollback/recheck/closed 四事实）→ `if not closed: FatalExit` → 分支处置。`finally` 仍会再尝试 `conn.close()`（已关闭时为幂等 no-op），不影响判定结果。

`FatalExit` 在 CLI 中映射为非零退出（`exc.exit_code`），不会被降级成 `begin_failed` 或 `migration_failed` 之类的普通结果。

---

## 3. 新增测试与结果

```text
$ python3 -m pytest -q tests/test_migration_state.py
44 passed in 87.53s
```

新增 2 项（+ 断言加强）：

| 用例 | 注入 | 断言 |
| --- | --- | --- |
| `test_begin_failure_with_close_failure_is_fatal` | BEGIN 抛错 + `_close_migration_connection → (False, …)` | `FatalExit("migration_connection_open")`、`exit_code != 0`、总行数仍为 1 且全部 `success`（无 running/failed）、`pool.writes_blocked() is True`、fault log 记 `begin_ok=False ∧ connection_closed=False` |
| `test_known_failed_with_close_failure_is_fatal_and_skips_failed_row` | 事务内插入失败（ROLLBACK 与只读复核均真实成功）+ 关闭失败 | `FatalExit("migration_connection_open")`、退出码非零、**`_mark_failed()` 调用次数 = 0**、无 failed 行（行数 1、全 success）、`writes_blocked()` 为 True、fault log 记 `rollback_ok=True ∧ recheck_ok=True ∧ connection_closed=False` |

---

## 4. 回归结果

```text
$ python3 -m pytest -q tests/test_maintenance_lock.py        # P-1.5 专项
63 passed, 1 warning in 2.66s

$ python3 -m pytest -q --ignore=tests/test_migration_baseline.py --ignore=tests/test_migration_state.py
367 passed, 1 skipped, 1 warning in 26.06s

$ python3 -m pytest -q tests/test_migration_baseline.py
15 passed in 14.65s
```

合计：44 + 63 + 367(+1 skipped) + 15 = **489 passed, 1 skipped**。

---

## 5. 声明

* PT-09b 未改动：仍无 `system_events`/`migration_tx_notes`、无哈希链列，`write_event()`/`write_tx_event()`/`emit_event()`/`set_phase()` 仍抛 `NotImplementedError`。
* 未执行真实备份恢复（`rollback_to_snapshot()` 仍只做前置检查 + 只读 `verify_set`，代码零 `restore_set()` 调用）。
* 未进入 P-1.7 / P-1.8；未接触 NAS、生产数据库、生产容器、生产服务；未执行 P-7。
* 未修改两份 v1.10 文档、`db.py`、SCHEMA 与业务表、services/testers/scoring/前端、Compose/镜像/部署配置。
* 本轮不自评验收，等待 ChatGPT 最终复审；完成后停止，不自行进入下一阶段。
