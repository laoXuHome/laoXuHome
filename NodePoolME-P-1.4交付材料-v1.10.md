# NodePoolME P-1.4 交付材料（v1.10）｜维护状态文件与 STATE_DIR

实施依据：《NodePoolME-P-1实施计划-v1.10.md》§2.6 / §3.4 / §5（PT-11、PT-14、PT-14b、PT-24），《新架构总体设计方案-v1.10.md》§2.1「maintenance 持久化契约」与三态判定矩阵。以文档为唯一规范，未重新设计、未改动两份 v1.10 文档。
代码仓库：`laoXuHome/NodePoolME`（`main`）
上一提交：`10e03962`（P-1.3 预检修复）
本次提交：`bbb7fc98e47966f6ad9ad428b182d96cd6c58102`

---

## 1. 交付文件

| 文件 | 性质 | 字节 | 行 | blob SHA |
| --- | --- | --- | --- | --- |
| `backend/database/maint.py` | 新增 | 24,896 | 618 | `f597bb3fe5141103a03efb57bd9f6bc4a08c39dc` |
| `backend/config.py` | 修改 | 6,442 | 151 | `2b71da450a98924a4007c29d8e155b48b6504c06` |
| `backend/main.py` | 修改（薄） | 5,644 | 154 | `4a54dbc84b3a2a3216e4ae14e49515dd73fa7abf` |
| `tests/test_maint_state.py` | 新增 | 23,432 | 610 | `6b59dbed42fd77b30ca6bce07bc50a5d2f178f37` |

远端 `contents` API 复核 `size`/`sha` 与上表逐项一致。未修改 `db.py`、`migrate.py`、`routes.py`、Compose/镜像/生产配置；未接线五个业务入口；未进入 P-1.5。

---

## 2. 实现要点

**四态读取（`read_maint_file()`）**：`FileNotFoundError` → `ABSENT`（唯一允许进入 DB 判定的读取结果）；`PermissionError` → `UNREADABLE`；其它 `OSError`（EIO/EBUSY/路径是目录/超时）→ `UNREADABLE`；UTF-8 解码或 JSON 解析失败、顶层非对象 → `CORRUPT`；其余 → `PRESENT`（`blob` 非 None）。损坏与不可读**不会**被当成缺失。

**三态判定（`maintenance_state()`）**：`UNREADABLE`/`CORRUPT` 直接 `RECOVERY_REQUIRED`、**不查库**；`ABSENT` 走 `judge_by_migration_rows()`（查库 1 次）；`PRESENT` 先判 `type(m) is bool`（`"false"`/`"true"`/`0`/`1`/`null`/键缺失一律非法），再过 `maint_fields_sane()`，两步都过才分支：`true` → `ACTIVE`（0 次查库）、`false` → 查库 1 次。

**数值与结构**：`since_sane()` 对 `int` 只判 `> 0`（不调 `math.isfinite`，`10**1000` 不触发 `OverflowError`），对 `float` 要求 `isfinite ∧ > 0`；`maint_fields_sane()` 外层兜 `except → False`，`bool`/`str`/`None`/`0`/负数/`NaN`/`±Inf` 全部非法。

**写库判定**：`migration_incomplete()` 是唯一实现，`mode=ro` 连接，不建库、不产生 `-wal/-shm`、不 checkpoint；表不存在 → `False`；存在 `status <> 'success'` → `True`；查询异常 → `MaintUnverifiable`（上层转 `RECOVERY_REQUIRED`）。

**原子写（`set_maintenance()`）**：`maintenance.json.tmp.<nonce>.<rand>` → `write` → `flush` → **可写 fd** 上 `os.fsync(f.fileno())` → `os.replace` 到目标名 → `fsync(STATE_DIR)`（`O_RDONLY|O_DIRECTORY` 打开目录）→ 回读确认（`maintenance is True ∧ migration_id ∧ phase ∧ nonce`）。内容匹配则跳过写（幂等）。全程不原地改写目标文件；任一步失败抛 `MaintWriteError`（稳定 `reason`），由调用方置 `maintenance_ok=False`。

**写入确认（`confirm_maint_write(rec)`）**：只做回读（`maintenance is True ∧ migration_id == rec.migration_id ∧ phase == rec.phase.name ∧ since 非空 ∧ nonce == rec.maint_nonce`），**不推导维护态**。

**启动自检（`selfcheck_state_dir()`）**：每次启动一次、结果缓存。序列 = 目录合法性（`STATE_DIR != DATA_DIR`）→ 建目录 → 同卷判定 → 写探针 → 文件 fsync → 原子 rename → 目录 fsync → 回读比对 → 删除 → 再目录 fsync。任一步失败记 `maint_fs_unsupported` 并附 errno（回读不一致用 `EIO`，路径非目录用 `ENOTDIR`）；跨卷记 `state_dir_cross_device`；`STATE_DIR == DATA_DIR` 记 `state_dir_equals_data_dir`。探针文件 `finally` 清理，绝不触碰 `nodepool.db*`。

**同卷判定的边界处理（不改变语义）**：计划原文为 `os.stat(DB_PATH).st_dev == os.stat(STATE_DIR).st_dev`。实现按此比较；仅在两种可判定情形下退回「库所在目录」的 `st_dev` 作为同一挂载锚点：(a) 库文件尚未创建（首次部署），(b) 文件与所在目录 `st_dev` 不一致的 overlay/沙箱（此时文件值不代表挂载归属）。正常文件系统上两者相等，比较对象就是计划原文的库文件本身；`test_pt14_same_device_check_uses_db_path_st_dev` 对该分支逐项断言。

**config.py**：`STATE_DIR = Path(env("NODEPOOL_STATE_DIR", DATA_DIR/"state")).resolve()`；`STATE_DIR_CONFIG_ERROR` 在 `== DATA_DIR` 时为 `state_dir_equals_data_dir`；合法配置在导入时创建空目录（不写任何业务文件），非法配置**不建目录**，交由启动自检拦下。

**main.py**：`lifespan` 首步（先于 `db.init_db()`）调用自检，结果存 `app.state.state_dir_check`；失败只 `log.warning(code, detail)` 并禁用迁移入口，不抛异常、不 503、不迁移、不改库。自检自身异常同样只降级。

---

## 3. 测试逐项输出

### PT-11（文件四态 + 三态矩阵 + 查库次数）：48 passed

```
test_pt11_present_true_is_active_without_db_query                        PASSED  ACTIVE / 查库 0
test_pt11_present_false_defers_to_db                                     PASSED  INACTIVE / 1；有 running 行 → RECOVERY_REQUIRED / 1
test_pt11_present_false_with_failed_row_is_recovery                      PASSED  RECOVERY_REQUIRED / 1
test_pt11_non_boolean_maintenance_is_recovery_without_query[7 参数]      PASSED  均 RECOVERY_REQUIRED / 0
test_pt11_structure_violation_blocks_both_branches[true|false × 10 字段] PASSED  均 RECOVERY_REQUIRED / 0（两套取值结果相同）
test_pt11_non_finite_since_is_recovery[NaN/Inf/-Inf × true|false]        PASSED  RECOVERY_REQUIRED / 0
test_pt11_huge_int_since_is_structurally_valid                           PASSED  10**1000 结构合法：true→ACTIVE/0；false→INACTIVE/1；false+非法 migration_id→RECOVERY_REQUIRED/不再查库
test_pt11_corrupt_is_recovery_without_query[截断/非UTF8/[]/"x"/42/null]  PASSED  status=CORRUPT（非 ABSENT）/ RECOVERY_REQUIRED / 0
test_pt11_permission_error_is_unreadable_not_absent                       PASSED  status=UNREADABLE / RECOVERY_REQUIRED / 0
test_pt11_is_a_directory_is_unreadable                                   PASSED  status=UNREADABLE / RECOVERY_REQUIRED / 0
test_pt11_absent_requires_db_evidence                                    PASSED  缺失+全 success→INACTIVE/1；+running→RECOVERY_REQUIRED/1；库打不开→RECOVERY_REQUIRED/1 且 migration_incomplete 抛 MaintUnverifiable
test_pt11_absent_with_table_missing_is_inactive                          PASSED  表不存在→False→INACTIVE
test_pt11_phase_names_match_design                                       PASSED  PHASE_NAMES 与设计六个 phase 一致
```

（查库次数通过包装 `migration_incomplete()` 计数；断言值即上表「/N」。）

### PT-14（文件系统能力）：9 passed

```
test_pt14_selfcheck_full_chain                    PASSED  八步全 true；探针无残留
test_pt14_selfcheck_cached_once                   PASSED  同一对象返回（每次启动只跑一次）
test_pt14_cross_device_rename_reports_exdev       PASSED  跨设备 rename errno=18(EXDEV)，源文件仍在；同目录 rename 成功
test_pt14_selfcheck_rename_failure_reports_errno  PASSED  code=maint_fs_unsupported, errno=22；write/file_fsync=true、rename=false；目录空
test_pt14_selfcheck_dir_fsync_failure_reports_errno PASSED code=maint_fs_unsupported, errno=22；dir_fsync=false；目录空
test_pt14_selfcheck_readback_mismatch             PASSED  code=maint_fs_unsupported, errno=5(EIO)，detail 含 readback
test_pt14_selfcheck_mkdir_failure_reports_errno   PASSED  code=maint_fs_unsupported，errno 非空；mkdir=false
test_pt14_selfcheck_on_real_state_dir             PASSED  在真实配置 STATE_DIR 上八步全通过、db_dev==state_dev、无残留
test_pt14_same_device_check_uses_db_path_st_dev   PASSED  同卷判定与 os.stat(DB_PATH).st_dev 一致（overlay 退回目录锚点）
```

### PT-14b（同卷校验与非法配置）：6 passed

```
test_pt14b_cross_device_state_dir_is_refused        PASSED  code=state_dir_cross_device；db_dev≠state_dev；探针未启动（write=false）；/dev/shm 目录为空
test_pt14b_cross_device_keeps_business_ok           PASSED  自检失败时 /healthz 200、登录 200、/api/nodes 200（业务不 503）
test_pt14b_state_dir_equal_data_dir_is_refused      PASSED  code=state_dir_equals_data_dir；mkdir=false；DATA_DIR 下未生成 maintenance.json
test_pt14b_config_creates_state_dir_when_override_missing  PASSED  NODEPOOL_STATE_DIR 覆盖到不存在路径 ⇒ 创建空目录、CONFIG_ERROR=None
test_pt14b_config_default_state_dir_is_data_state   PASSED  默认 = <DATA_DIR>/state
test_pt14b_config_flags_state_dir_equal_data_dir    PASSED  覆盖为 DATA_DIR ⇒ state_dir_equals_data_dir
```

### PT-24（探针副作用审计）：2 passed

```
test_pt24_probe_never_touches_database              PASSED  WAL 库（未 checkpoint，6 行可读）：自检 + maintenance_state + set_maintenance + confirm 前后 db sha256、-wal 大小与 mtime、-shm 存在性、目录条目集合完全不变；STATE_DIR 内只有 maintenance.json，无探针残留
test_pt24_selfcheck_failure_creates_no_database_files PASSED 自检失败路径不建库、不建表、不写 STATE_DIR
```

### 反向验证（证明测试能识别缺陷）

把 `maintenance_state()` 的 `CORRUPT` 分支改成「当作缺失去查库」后：

```
6 failed  tests/test_maint_state.py::test_pt11_corrupt_is_recovery_without_query[6 组夹具]
```

修复前代码无法通过；说明「损坏 ≠ 缺失」被测试真正钉住。验证后已恢复实现（工作树与提交一致）。

---

## 4. 全量回归

```
tests/test_maint_state.py            65 passed
其余全部模块（--ignore=tests/test_migration_baseline.py）  298 passed
tests/test_migration_baseline.py     15 passed
合计 313 passed / 0 failed
```

说明（必须如实记录）：`tests/test_migration_baseline.py` 的 PT-06 系列在**单进程混跑**时会失败 4 项（`307 passed / 4 failed`），原因是该文件把 `config.DB_PATH` 当作「仓库开发实例」并要求其为历史 ALTER 形态，而多个业务测试模块在导入时把 `NODEPOOL_DATA_DIR` 改指各自的临时目录（`tempfile.mkdtemp`），config 的首次导入因此绑定到全新临时库（`fresh_init` 形态）。该现象在本阶段改动**之前**即可复现：`git stash` 后在未修改的 `10e03962` 上单进程混跑 = `244 passed / 4 failed`，失败项完全相同。本阶段未修改 `migrate.py`、未修改该测试文件，故按「其余模块 + PT-06 文件独占进程」分两次执行，合计 313 项全通过。

---

## 5. 关键异常场景与降级行为

| 场景 | 行为 | 依据 |
| --- | --- | --- |
| maintenance.json 不存在 | 不直接判正常，必须查库；查库全 `success`/表不存在才 `INACTIVE` | 矩阵 ABSENT 两行 |
| 文件损坏（截断/非 UTF-8/顶层非对象） | `CORRUPT` → `RECOVERY_REQUIRED`，**不查库** | 矩阵 CORRUPT 行 |
| 权限错误 / EIO / 路径是目录 | `UNREADABLE` → `RECOVERY_REQUIRED`，**不查库**，不当缺失 | 矩阵 UNREADABLE 行 |
| `maintenance` 非真布尔 | `RECOVERY_REQUIRED`，不查库 | 严格布尔约定 |
| 结构不自洽（id/since/phase），true 与 false 皆然 | `RECOVERY_REQUIRED`，不查库 | 五条不得违反① |
| `since = 10**1000` | 结构合法（只判 `>0`），无 `OverflowError` | 十九次修订 (p) |
| 库打不开 / 查询抛错 | `MaintUnverifiable` → `RECOVERY_REQUIRED`（无法确认 ≠ 正常） | 矩阵末行 |
| 写临时文件 / fsync / replace / 目录 fsync 失败 | `MaintWriteError`，调用方置 `maintenance_ok=False` → 继续封锁 → `fatal_exit("maintenance_unconfirmed")`（本阶段不实现 halt，仅提供异常契约） | §2.1 失败语义 |
| 回读不一致 | `maint_write_unconfirmed`，不认「调用过就算成功」 | 写入确认契约 |
| STATE_DIR 跨卷 | `state_dir_cross_device`：只禁用迁移入口，业务照常（`/healthz` 200） | §2.6 第 1 条 / PT-14b |
| STATE_DIR == DATA_DIR | `state_dir_equals_data_dir`：拒绝通过启动检查，不建目录 | §2.6 第 1 条 |
| 自检链路任一步失败 | `maint_fs_unsupported` + errno；只禁用迁移，业务启动与接口不受影响 | §2.6 第 4 条 |
| 自检自身抛异常 | `main.py` 捕获并降级（`state_dir_check=None`），不阻断启动 | 本阶段约束 |

未实现（明确留待后续阶段）：`start_migration()` 的门禁消费（`state_dir_ok=false` 的对外暴露走 `/api/system/migration/status`，属 P-1.5 路由）、五入口接线、halt 链路、连接池 `dead`。本阶段只产出「自检结论 + 唯一判定入口 + 原子写/回读」这三块可被后续阶段直接消费的件。

---

## 6. 边界声明

- 未接触生产数据库，未在 NAS 生产容器上运行启动自检，未执行 P-7。
- 所有文件系统故障注入均在临时目录 / `/dev/shm` / 测试环境完成；唯一在「真实配置 STATE_DIR」上的一次探针来自仓库开发实例（`data/state`），探针自删、无残留，不涉及生产。
- 未修改 v1.10 总体设计与 P-1 实施计划；未修改 `db.py` 通用 SCHEMA、`migrate.py` 状态机、`routes.py`；未接线五个业务入口。
- 生产 `structure_hash` 归属仍未确认，本材料不作「生产结构已验证」表述。

已停止在本阶段，等待验收；未进入 P-1.5。
