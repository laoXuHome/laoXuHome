# NodePoolME P-1.2 定点修正交付材料（Migration Safety Fix）

> 阶段：P-1.2 修正（仅两项，不重写模块、不扩范围）
> 基线 commit：`2890728` → 本次修正 commit：`e572916`
> 性质：**代码施工**。未连接 NAS、未改生产库、未执行迁移、未改 `db.py`/`SCHEMA`/`init_db()`、未进入 P-1.3。
> 日期：2026-11-26

---

## 1. 修正一：已有空迁移表必须拒绝

**原问题**：`ensure_schema_table_transactional()` 无条件执行 `CREATE TABLE IF NOT EXISTS` 后再看行数，等于给"已存在但 0 行"的表补插基线——正是 §2.2 明令禁止的两段式路径。

**修正**（`backend/database/migrate.py`）：

```python
conn.execute("BEGIN IMMEDIATE")
existed = conn.execute(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations'"
).fetchone() is not None
if not existed:
    conn.execute(SCHEMA_MIGRATIONS_DDL)   # 只有原本不存在才建表
    count = 0
else:
    count = _count_rows(conn)
if not existed and count == 0:  # 新库首次登记
    ... 插基线 → count==1 校验 → COMMIT
if existed and count == 0:      # 已存在空表
    raise MigrationStateError("migration_table_empty", ...)
```

- 存在性判断与行数判断都在**同一事务内**，不存在 TOCTOU 窗口；判断顺序是「先看是否存在、再决定是否建表」，不可能"顺手建出来再补写"。
- 空表：抛 `MigrationStateError`，稳定错误码 **`migration_table_empty`**；**不建、不补、不删**，表与 0 行原样保留。
- 原本不存在：仍走「建表 + 登记 + 行数校验 + 提交」。
- 正常幂等（已存在且恰为基线行）：仍返回 `already_present`，不重复插入。
- `preflight()` 语义未变（`empty` ⇒ `allowed=False`），两处判定一致。

---

## 2. 修正二：结构摘要保留列顺序 + 明确登记受支持基准

**原问题**：语义签名对列名排序，等于把列序变化当作合法；而列序影响 `SELECT *` 与省略列名的 `INSERT`。

**修正**：

1. `_table_signature()` 的列改为**按 ordinal（`cid`）原序保留**，并把 `cid` 本身写入签名：

```python
cols = [
    [int(row[0]), row[1], row[2], int(row[3]), row[4], int(row[5])]
    for row in conn.execute(f'PRAGMA table_info("{name}")')
]
```

2. 新增受支持基准登记表（不接受"任意列序都合法"）：

```python
SUPPORTED_STRUCTURE_PROFILES = {
  "alter_history": "798c5d4be3db0885cf75421669d2872d9ec67e426f946ec5cc919f84acc3ca15",
  "fresh_init":    "e9feb0bb5028a38a082f1e2a75105cd15aa963c5562e15217ea80ff70c4eeb71",
}
```

- `alter_history`：历史 `ALTER TABLE` 追加列形成的形态（当前开发实例，与生产同源路径）。
- `fresh_init`：全新 `init_db()` 建出的形态。
- 两者差异**仅来自列声明顺序**（`airports` 的 `filter_keywords`/`created_at`/`updated_at`、`speed_runs` 的 `mb_per_s` 等后加列位置不同），语义相同但物理列序不同，因此**分成两个基准登记**，不是放着不管。

3. `record_baseline()` 用 `structure_profile_for(actual_hash)` 做**白名单匹配**，只接受登记过的摘要；不匹配 → `BaselineRefused("structure_mismatch")`，报错同时给出 `actual` 与全部受支持摘要。匹配时把 `structure_profile` 写进 `detail_json` 与返回值。
4. 删除原 `expected_structure_hash` 外部覆盖参数：不允许调用方传入任意哈希绕过基准登记。

**未做的声明**：生产实际结构**仍未实测**。`alter_history` 只是"最可能的形态"，不是已验证的生产值；若生产摘要与两组都不符（例如更早的 ALTER 顺序差异），登记会拒绝——这是闸门，不是缺陷。生产归属必须等 NAS 侧只读导出 `sqlite_master` 后确认。

---

## 3. 交付文件

| 文件 | 字节 | 行 | blob SHA | commit |
|---|---|---|---|---|
| `backend/database/migrate.py` | 21,085 | 561 | `37d8f35377d6ca94bf8594194e17a9e74b983974` | `e572916` |
| `tests/test_migration_baseline.py` | 20,303 | 507 | `3ce5188cfdca777d6bffd0dd3e089b23fb0b7107` | `e572916` |

commit `e572916`（`fix(P-1.2): 空迁移表拒绝补写 + 结构摘要保留列序（双基准登记）`），已推送 `laoXuHome/NodePoolME` `main`（`2890728..e572916`），远端 blob 已用 contents API 校验一致。

改动面仍仅这两个文件；`db.py`、`SCHEMA`、`init_db()` 零改动。

---

## 4. 测试结果

### 4.1 专项（15 项，全通过）

```
test_pt06_baseline_idempotent_and_business_tables_unchanged          PASSED
test_pt06b_version_ordering_uses_seq_not_string                      PASSED
test_pt06c_create_and_insert_are_atomic_on_insert_failure            PASSED
test_pt06c_count_verification_failure_rolls_back                     PASSED
test_pt06d_tasks_absent_and_empty_present_share_same_hash            PASSED
test_pt06d_tasks_present_but_not_empty_is_refused                    PASSED
test_pt06d_structure_drift_is_refused                                PASSED
test_pt06d_missing_base_table_is_refused                             PASSED
test_pt06d_two_structure_profiles_are_registered_and_distinct        PASSED
test_pt06d_column_order_drift_is_refused                             PASSED
test_pt06e_init_db_never_creates_schema_migrations                   PASSED
test_pt06f_existing_empty_table_is_refused_not_repaired              PASSED
test_pt06f_new_database_first_registration_still_works               PASSED
test_preflight_matrix_empty_incomplete_and_mismatch                  PASSED
test_preflight_and_record_baseline_refuse_on_version_mismatch        PASSED

15 passed in 13.18s
```

### 4.2 新增/改写的验收点

| 测试 | 验证内容 |
|---|---|
| `test_pt06f_existing_empty_table_is_refused_not_repaired` | 手工建空表 → `record_baseline()` 抛 `migration_table_empty`；表**仍存在且仍 0 行**（未补写、未删除）；`current_version()=None`；`preflight()` 判 `empty`；直接调 `ensure_schema_table_transactional()` 同样拒绝 |
| `test_pt06f_new_database_first_registration_still_works` | 全新库首次登记 → `created` + `structure_profile=fresh_init`；再次调用 → `already_present`，仍 1 行 |
| `test_pt06d_two_structure_profiles_are_registered_and_distinct` | `alter_history` 与 `fresh_init` 两个摘要**不相等**且各自在册；两条库分别登记成功并写入对应 `structure_profile`；`detail_json` 同步记录 |
| `test_pt06d_column_order_drift_is_refused` | 在 `run_events`（无索引无触发器）重建并交换列序：列集合不变、仅顺序变 → 摘要改变、`structure_profile_for()` 返回 `None`、`record_baseline()` 抛 `structure_mismatch` 且不建表 |
| `test_pt06c_count_verification_failure_rolls_back`（改写） | 注入 `_count_rows` 恒返回 0 → 登记后校验失败抛 `baseline_count_mismatch`，`schema_migrations` 随建表一起回滚 |

### 4.3 回归与不变量

```
python3 -m pytest -q   （在副本库上执行）
218 passed, 1 warning in 6.88s
```

218 = 既有 203 + 本阶段 15；**通过 218 / 失败 0 / 跳过 0**，原有用例无退化。

17 张业务表与 `tasks` 复核（`sqlite3.backup()` 副本 + 2 行哨兵数据，登记前后各测一次）：

```
structure_hash(before) = 798c5d4be3db0885cf75421669d2872d9ec67e426f946ec5cc919f84acc3ca15
structure_hash(after)  = 798c5d4be3db0885cf75421669d2872d9ec67e426f946ec5cc919f84acc3ca15
same_structure: True    table_diffs: []
schema_migrations rows: 1 | seq: 1 | version: 1.8.7-baseline | status: success
detail.structure_profile: alter_history
detail.tasks_present: True rows: 0 | tables_count: 17
integrity: ok | fk_violations: 0 | tasks rows still: 0
```

---

## 5. 严格边界声明

1. 未修改生产数据库；未连 NAS；未执行任何生产迁移；生产 `schema_migrations` 仍不存在。
2. 未改 `db.py`、通用 `SCHEMA`、`init_db()`；`schema_migrations` 仍只由迁移器入口事务创建。
3. 未进入 P-1.3；未改 v1.10 总体设计与 P-1 实施计划。
4. 未删/未改 `tasks`、`sqlite_sequence` 或任何业务数据（测试均在副本上，`tasks` 非空拒绝用例也只在副本内注入一行）。
5. 仓库内 `data/nodepool.db` 是 gitignored 的开发实例（非生产），其业务表会被既有 `tests/conftest.py` 清空；全部迁移测试使用副本，证据不依赖该实例。

---

## 6. 剩余问题（不阻断本次验收）

| 项 | 说明 | 判定 |
|---|---|---|
| 生产结构归属未确定 | 生产库不可达，`alter_history`/`fresh_init` 均属代码侧登记值 | 需 NAS 只读实测 `sqlite_master` 后确认；不影响本阶段代码正确性 |
| 生产摘要可能落空 | 若两组都匹配不上，登记会拒绝并输出 `actual` 与受支持列表 | 设计意图就是"不匹配就停"，不是缺陷 |
| `tasks_hash` 仍取 DDL 文本 | 仅记账展示，不参与放行 | 不影响 |
| R1（生产备份陈旧） | 本阶段未触碰生产 | 生产写窗口前必须先有 `pre-migrate` 备份 |

---

*本阶段到此停止，等待最终验收与 P-1.3 指令。*
