#!/bin/sh
# NodePoolME P-1 生产探针 v1.10（r5：目标自识别 + fnOS 兼容）
# 只读探针（P-7 写测试单独审批）。核心原则：目标不明确就停止，绝不猜测路径或容器。
#
# 用法（NAS 宿主机，有 docker）：
#   sh NodePoolME-P-1-生产探针-v1.10.sh | tee p1-probe-$(date +%Y%m%d-%H%M%S).log
# 用法（已在容器内）：
#   PROBE_MODE=container sh NodePoolME-P-1-生产探针-v1.10.sh
# P-7（唯一写操作）：NODEPOOL_P7_APPROVED=1 且 STATE_DIR 已确认存在，才会执行
# 其它覆盖：NODEPOOL_CONTAINER=<名>、NODEPOOL_HEALTHZ=<url>、
#           NODEPOOL_DOCKER='sudo docker'（无 docker 组权限时）、NODEPOOL_P7_FAULT=(仅测试用)
set -u

PROBE_MODE="${PROBE_MODE:-host}"
P7_APPROVED="${NODEPOOL_P7_APPROVED:-0}"
HEALTHZ="${NODEPOOL_HEALTHZ:-}"
DOCKER="${NODEPOOL_DOCKER:-docker}"   # 需 sudo 时设 NODEPOOL_DOCKER="sudo docker"
P7_STATE="未执行"
SCRIPT_RC=0

hr()  { echo; echo "===== $* ====="; }
say() { echo "$*"; }
die() {
  echo; echo "!!!!! STOP: $*"
  echo "结论：目标不明确或关键路径无法确认 —— 按设计停止，不猜测、不写入任何文件。"
  exit 2
}

# ---------------------------------------------------------------- 0) 容器识别
hr "0) 容器识别（不假设容器名）"
CNAME=""
if [ "$PROBE_MODE" = "container" ]; then
  CNAME="(in-container)"
  say "PROBE_MODE=container：跳过 docker 侧检查，路径以进程内配置为准"
  say "注意：容器内看不到宿主机↔容器映射，P-7 会被跳过"
else
  command -v "${DOCKER%% *}" >/dev/null 2>&1 || die "宿主机没有 docker CLI，无法定位生产容器"
  if [ -n "${NODEPOOL_CONTAINER:-}" ]; then
    CNAME="${NODEPOOL_CONTAINER}"
    $DOCKER inspect "$CNAME" >/dev/null 2>&1 || die "指定的容器 '$CNAME' 不存在"
  else
    CANDS=$($DOCKER ps --format '{{.Names}}|{{.Image}}' | grep -i 'nodepool' || true)
    N=$(printf '%s\n' "$CANDS" | grep -c . || true)
    [ "${N:-0}" -eq 0 ] && die "docker ps 里没有运行中的 nodepool 容器（容器未运行/未部署）"
    [ "$N" -gt 1 ] && { printf '%s\n' "$CANDS"; die "匹配到 $N 个候选容器，容器不唯一。请用 NODEPOOL_CONTAINER=<name> 指定后重跑"; }
    CNAME=$(printf '%s\n' "$CANDS" | cut -d'|' -f1)
  fi
  say "container_name  $CNAME"
  $DOCKER inspect "$CNAME" --format '{{.State.Status}} started={{.State.StartedAt}} restart={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
  $DOCKER inspect "$CNAME" --format '{{.State.Status}}' 2>/dev/null | grep -q running \
    || die "容器 $CNAME 不在 running 状态，在线探针无法执行"
fi

# ---------------------------------------------------------------- 1) 挂载映射
hr "1) 挂载关系（宿主机 ↔ 容器）"
MOUNTS=""
if [ "$PROBE_MODE" = "host" ]; then
  MOUNTS=$($DOCKER inspect "$CNAME" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}|{{.Type}}{{"\n"}}{{end}}' 2>/dev/null | sed '/^$/d')
  printf '%s\n' "$MOUNTS"
  [ -z "$MOUNTS" ] && die "挂载信息为空，无法建立容器路径 → 宿主机路径映射"
  printf '%s\n' "$MOUNTS" | awk -F'|' '$3!="bind"{print "NON_BIND: "$0}'
fi

# 容器路径 → 宿主机路径（最长目标前缀匹配；未命中返回空）
map_host() {
  printf '%s\n' "$MOUNTS" | awk -F'|' -v p="$1" '
    { if ($2=="") next;
      if (p==$2 || index(p, $2"/")==1) { if (length($2)>best) { best=length($2); src=$1; dst=$2 } } }
    END { if (best>0) { rest=substr(p, best+1); print src rest } }'
}


# ---------------------------------------------------------------- 2) 容器内真实路径
hr "2) 容器内真实路径与版本（只取运行中的配置）"
if [ "$PROBE_MODE" = "host" ]; then
  RUN() { $DOCKER exec -i "$CNAME" "$@"; }
else
  RUN() { "$@"; }
fi

# 2.1 导入前先查"会不会被建目录"（config.py 导入时对 5 个目录做 mkdir exist_ok）
PRE=$(RUN python -c "
import json,os
from pathlib import Path
data=str(Path(os.getenv('NODEPOOL_DATA_DIR','./data')).resolve())
def p(v): return str(Path(v).resolve())
pre={'DATA_DIR':data,
     'CONFIG_DIR':p(os.getenv('NODEPOOL_CONFIG_DIR') or (Path(data)/'config')),
     'LOG_DIR':p(os.getenv('NODEPOOL_LOG_DIR') or (Path(data)/'logs')),
     'BACKUP_DIR':p(os.getenv('NODEPOOL_BACKUP_DIR') or (Path(data)/'backup')),
     'SUB_DIR':p(str(Path(data)/'sub')),
     'DB_PATH':p(os.getenv('NODEPOOL_DB') or (Path(data)/'nodepool.db')),
     'STATE_DIR':p(os.getenv('NODEPOOL_STATE_DIR') or (Path(data)/'state'))}
mk=['DATA_DIR','CONFIG_DIR','LOG_DIR','BACKUP_DIR','SUB_DIR']
missing=[k for k in mk if not Path(pre[k]).exists()]
print(json.dumps({'pre':pre,'missing':missing,'mkdir_dirs':mk}))
" 2>&1) || true

PREJ=$(printf '%s\n' "$PRE" | tail -1)
MISSING=$(printf '%s' "$PREJ" | sed -n 's/.*"missing": *\[\([^]]*\)\].*/\1/p')
if [ -z "$PREJ" ]; then die "导入前目录检查失败：没有拿到路径 JSON"; fi
if [ -n "$MISSING" ]; then
  printf '%s\n' "将被 config 导入自动创建、当前不存在的目录：$MISSING"
  say "pre_json：$PREJ"
  die "存在会被 backend.config 导入自动 mkdir 的目录（$MISSING）。按设计停止：不导入、不创建任何目录。请先确认这些挂载/目录是否正常，再重跑。"
fi
say "pre_import_dirs OK（DATA_DIR/CONFIG_DIR/LOG_DIR/BACKUP_DIR/SUB_DIR 均存在，导入不会产生目录副作用）"

# 2.2 导入 config 取权威路径
PATHS=$(RUN python -c "
import json,os
from pathlib import Path
import backend.config as c
d={'app_version':c.VERSION,'data_dir':str(c.DATA_DIR),'config_dir':str(c.CONFIG_DIR),
   'db_path':str(c.DB_PATH),'backup_dir':str(c.BACKUP_DIR),'log_dir':str(c.LOG_DIR),
   'sub_dir':str(c.SUB_DIR),'state_dir_env':os.getenv('NODEPOOL_STATE_DIR','')}
d['state_dir']=d['state_dir_env'] or str(Path(d['data_dir'])/'state')
print('PATHS_JSON '+json.dumps(d))
" 2>&1) || true

PJ=$(printf '%s\n' "$PATHS" | grep '^PATHS_JSON ' | sed 's/^PATHS_JSON //')
printf '%s\n' "$PATHS" | grep -v '^PATHS_JSON ' | grep . | sed 's/^/[config] /'
if [ -z "$PJ" ]; then die "容器内 import backend.config 失败：拿不到权威路径（见上面 [config] 输出）"; fi

getjson() { printf '%s' "$PJ" | sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p"; }
CFG=$(getjson config_dir); CDATA=$(getjson data_dir); CDB=$(getjson db_path)
CBK=$(getjson backup_dir); CST=$(getjson state_dir); AVER=$(getjson app_version)
CLOG=$(getjson log_dir); CSUB=$(getjson sub_dir); SENV=$(getjson state_dir_env)
[ -n "$CDB" ] && [ -n "$CBK" ] && [ -n "$CST" ] && [ -n "$CDATA" ] || die "关键路径解析不完整（db='$CDB' backup='$CBK' state='$CST' data='$CDATA'）"

# 2.3 导入值 vs 预检查值：五个会被 config 自动 mkdir 的目录逐个核对，缺一即停
PRE_JSON=$(printf '%s' "$PREJ")
for k in DATA_DIR CONFIG_DIR LOG_DIR BACKUP_DIR SUB_DIR; do
  case "$k" in
    DATA_DIR)   actual="$CDATA" ;;
    CONFIG_DIR) actual="$CFG" ;;
    LOG_DIR)    actual="$CLOG" ;;
    BACKUP_DIR) actual="$CBK" ;;
    SUB_DIR)    actual="$CSUB" ;;
    *)          actual="" ;;
  esac
  [ -n "$actual" ] || die "无法取得导入后的实际 $k（值为空），按设计停止，不跳过核对"
  pv=$(printf '%s' "$PRE_JSON" | sed -n "s/.*\"$k\": \"\([^\"]*\)\".*/\1/p")
  [ -n "$pv" ] || die "预检查结果缺少 $k，无法核对，按设计停止"
  [ "$pv" = "$actual" ] || die "路径不一致：$k 预检查=$pv 导入=$actual（停止，不继续）"
  say "path_check $k OK  $actual"
done

say "app_version       $AVER"
say "container_data    $CDATA"
say "container_db      $CDB"
say "container_backup  $CBK"
say "container_state   $CST   (来源：${SENV:+env NODEPOOL_STATE_DIR}${SENV:-默认 <DATA_DIR>/state})"

HDB=""; HBK=""; HST=""; HSTATE="unknown"; HSTATE_EXISTS="unknown"
if [ "$PROBE_MODE" = "host" ]; then
  HDB=$(map_host "$CDB"); HBK=$(map_host "$CBK"); HST=$(map_host "$CST")
  say "host_db           ${HDB:-<未映射>}"
  say "host_backup       ${HBK:-<未映射>}"
  say "host_state        ${HST:-<未映射>}"
  [ -z "$HDB" ] && die "数据库路径映射不到宿主机（$CDB）"
  [ -z "$HBK" ] && die "备份目录映射不到宿主机（$CBK）"
  [ -f "$HDB" ] || die "宿主机上不存在 $HDB（映射与文件不一致）"
  if [ -n "$HST" ]; then
    if [ -e "$HST" ]; then HSTATE_EXISTS="yes"; else HSTATE_EXISTS="no"; fi
  else
    HSTATE_EXISTS="unmapped"
  fi
  say "host_state_exists $HSTATE_EXISTS（本脚本不会创建它）"
fi

# ---------------------------------------------------------------- 3) P-10
hr "3) P-10：镜像 ID / RepoDigests / 版本（四值核对）"
if [ "$PROBE_MODE" = "host" ]; then
  ITAG=$($DOCKER inspect "$CNAME" --format '{{.Config.Image}}' 2>/dev/null)
  IID=$($DOCKER inspect "$CNAME" --format '{{.Image}}' 2>/dev/null)
  say "image_ref(Config.Image) $ITAG"
  say "image_id(running)       $IID"
  [ -n "$IID" ] || die "取不到运行容器的 .Image（不可变 image ID）"
  TAGID=$($DOCKER image inspect "$ITAG" --format '{{.Id}}' 2>/dev/null || true)
  say "image_id(tag_now)       ${TAGID:-<unresolved>}"
  if [ -n "$TAGID" ] && [ "$TAGID" != "$IID" ]; then
    say "TAG_DRIFT: 标签当前指向 ${TAGID}，运行中的是 $IID（判定以 image_id 为准）"
  fi
  say "--- RepoDigests（按 image_id 查询）---"
  $DOCKER image inspect "$IID" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | sed '/^$/d' | sed 's/^/  digest  /'
  REPO=$(printf '%s' "$ITAG" | sed 's/:.*$//')
  ND=$($DOCKER image inspect "$IID" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | grep -c "^${REPO}@" || true)
  say "digests_for_repo($REPO) ${ND:-0}"
  case "${ND:-0}" in
    0) say "VERDICT_digest ABSENT：镜像为本地构建/未推送，基线不可溯源 ⇒ 禁止登记基线";;
    1) say "VERDICT_digest OK：可溯源";;
    *) say "VERDICT_digest AMBIGUOUS：同一 repo 多条 digest，需人工确认";;
  esac
  say "container_id     $CNAME"
else
  say "image_ref/image_id/digest 需在宿主机执行，本模式跳过"
fi

if [ -z "$HEALTHZ" ]; then
  HEALTHZ=$(RUN python -c "import os;print('http://127.0.0.1:%s/healthz'%os.getenv('NODEPOOL_PORT','8080'))" 2>/dev/null)
  [ -n "$HEALTHZ" ] || HEALTHZ="http://127.0.0.1:8080/healthz"
fi
say "healthz_url      $HEALTHZ"
RUN python -c "
import urllib.request,json
try: raw=urllib.request.urlopen('$HEALTHZ',timeout=5).read().decode()
except Exception as e:
    print('healthz_raw','UNREACHABLE',e); raise SystemExit
print('healthz_raw', raw)
try: d=json.loads(raw)
except Exception as e:
    print('healthz_version','UNPARSEABLE',e); raise SystemExit
v=d.get('version') if isinstance(d,dict) else None
print('healthz_version', v if isinstance(v,str) and v else 'ABSENT')
print('healthz_keys', sorted(d.keys()) if isinstance(d,dict) else type(d).__name__)
" 2>/dev/null

# ---------------------------------------------------------------- 4) P-1/P-3/P-4
hr "4) P-1 / P-3 / P-4：体量、表行数、WAL、完整性（只读，不 checkpoint）"
RUN env NP_DB="$CDB" python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.environ["NP_DB"])
print("path", p, "exists", p.exists())
print("file_bytes", p.stat().st_size if p.exists() else None)
try:
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
except sqlite3.Error as e:
    print("OPEN_FAILED", type(e).__name__, e)
    print("NOTE: 只读打开失败时不改用 immutable=1（会忽略 WAL，读到过期数据），先查 -shm 权限")
    raise SystemExit
print("sqlite_version", sqlite3.sqlite_version)
ps = c.execute("PRAGMA page_size").fetchone()[0]
pc = c.execute("PRAGMA page_count").fetchone()[0]
for k in ("page_size","page_count","freelist_count","journal_mode","synchronous","wal_autocheckpoint"):
    print(k, c.execute(f"PRAGMA {k}").fetchone())
print("page_bytes", ps*pc, "equals_file_bytes", ps*pc == p.stat().st_size)
tabs=[(n, c.execute(f'SELECT count(*) FROM "{n}"').fetchone()[0]) for (n,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
print("table_count", len(tabs))
for n,rc in tabs: print("  table", n, rc)
print("views", [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='view'")])
print("indexes", len([1 for r in c.execute("SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL")]))
print("triggers", [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='trigger'")])
print("integrity", c.execute("PRAGMA integrity_check").fetchone()[0])
print("fk_violations", len(c.execute("PRAGMA foreign_key_check").fetchall()))
print("data_version_single", c.execute("PRAGMA data_version").fetchone()[0])
c.close()
PY

hr "4b) P-4：WAL / SHM 物理实体（只读）"
RUN sh -c 'ls -l "$0" "$0-wal" "$0-shm" 2>/dev/null || echo "no db/wal/shm files"' "$CDB"

# ---------------------------------------------------------------- 5) P-5
hr "5) P-5：句柄 / 外部持有者（只读；只回答"谁打开了文件"）"
RUN sh -c 'for f in /proc/[0-9]*/fd/*; do t=$(readlink "$f" 2>/dev/null); case "$t" in *nodepool.db*) echo "$f -> $t";; esac; done' | head -30
RUN sh -c 'command -v fuser >/dev/null && fuser -v "$0" 2>&1 || echo "fuser not installed"' "$CDB"
if [ "$PROBE_MODE" = "host" ] && [ -n "$HDB" ]; then
  say "host_holders:"
  if command -v lsof >/dev/null 2>&1; then lsof "$HDB"* 2>/dev/null | head -10; else say "  lsof not installed on host"; fi
fi

hr "5b) P-5：PRAGMA data_version 双读（同一只读连接）"
RUN env NP_DB="$CDB" python - <<'PY'
import sqlite3, os, time
from pathlib import Path
p = Path(os.environ["NP_DB"])
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
before = c.execute("PRAGMA data_version").fetchone()[0]
time.sleep(2)
after  = c.execute("PRAGMA data_version").fetchone()[0]
print("data_version_before", before)
print("data_version_after ", after)
print("data_version_changed", before != after)
c.close()
PY
say "NOTE: 只能判断其他连接是否提交过写入；不能证明不存在未提交事务。"

# ---------------------------------------------------------------- 6) P-9
hr "6) P-9：sub_publish 当前配置与最近发布（只读）"
RUN env NP_DB="$CDB" python - <<'PY'
import sqlite3, os
from pathlib import Path
c = sqlite3.connect(f"file:{os.environ['NP_DB']}?mode=ro", uri=True)
print("settings_cols", [r[1] for r in c.execute("PRAGMA table_info(settings)")])
for k in ("sub_publish_enabled","sub_publish_mode","sub_publish_time",
          "sub_publish_interval_minutes","sub_publish_next_at","sub_publish_last_at"):
    r = c.execute("SELECT value FROM settings WHERE key=?", (k,)).fetchone()
    print("setting", k, None if r is None else r[0])
lcols=[r[1] for r in c.execute("PRAGMA table_info(logs)")]
print("logs_cols", lcols)
sel=", ".join([x for x in ("id","ts","level","source","message") if x in lcols])
n=0
for r in c.execute(f"SELECT {sel} FROM logs ORDER BY id DESC LIMIT 30"):
    txt=" ".join(str(x) for x in r)
    if any(x in txt for x in ("发布","订阅","publish","sub_publish")):
        print("last_publish_log", r); n+=1
        if n>=3: break
if n==0: print("last_publish_log", "NONE_IN_LAST_30")
c.close()
PY

# ---------------------------------------------------------------- 7) P-7
hr "7) P-7【写操作，需审批 + 路径已确认】"
say "host_state        ${HST:-<未映射/本模式不可用>}"
say "container_state   $CST"
say "state_exists_host $HSTATE_EXISTS"
if [ "$P7_APPROVED" != "1" ]; then
  P7_STATE="未执行（等待批准）"
  say "SKIPPED: $P7_STATE（设置 NODEPOOL_P7_APPROVED=1 后重跑本段）"
  say "将创建：$CST/p1probe.<8hex>.tmp、$CST/p1probe.<8hex>.json，随后删除二者；不会创建目录"
  say "影响：仅 2 个 13 字节文件新增/删除；不触碰 $CDB、-wal、-shm、config、backup、logs；不重启服务"
elif [ "$PROBE_MODE" != "host" ]; then
  P7_STATE="未执行（容器内模式无法确认宿主机路径）"; say "SKIPPED: $P7_STATE"
elif [ -z "$HST" ]; then
  P7_STATE="未执行（STATE_DIR 无宿主机映射）"; say "SKIPPED: $P7_STATE"
elif [ "$HSTATE_EXISTS" != "yes" ]; then
  P7_STATE="未执行（STATE_DIR 未确认/不存在，按设计不创建目录）"; say "SKIPPED: $P7_STATE"
  say "如确认可创建：先手工 mkdir -p $HST，再重跑本段"
else
  P7_STATE="已执行（进行中）"
  P7_OUT=$(RUN env NP_STATE="$CST" NP_FAULT="${NODEPOOL_P7_FAULT:-}" python - <<'PY'
import json, os, uuid
from pathlib import Path
SD = Path(os.environ["NP_STATE"])
FAULT = os.environ.get("NP_FAULT") or ""
print("state_dir", SD, "exists", SD.exists(), "os_access_W", os.access(SD, os.W_OK))
if not SD.exists():
    print("VERDICT", "FAILED STATE_DIR_MISSING")
    raise SystemExit(3)
n = uuid.uuid4().hex[:8]
t   = SD / f"p1probe.{n}.tmp"
tgt = SD / f"p1probe.{n}.json"
steps = {}
cur = "init"
try:
    cur = "write_tmp_flush_fsync"
    if FAULT == "write": raise OSError("injected_fault:write")
    with open(t, "wb") as f:
        f.write(b'{"probe":true}')
        f.flush()
        os.fsync(f.fileno())
    steps[cur] = True; print("step1 write+flush+file_fsync OK")

    cur = "os_replace"
    if FAULT == "replace": raise OSError("injected_fault:replace")
    os.replace(str(t), str(tgt))
    steps[cur] = True; print("step2 os.replace OK")

    cur = "dir_fsync"
    if FAULT == "dirfsync": raise OSError("injected_fault:dirfsync")
    dfd = os.open(str(SD), os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dfd); os.close(dfd)
    steps[cur] = True; print("step3 dir_fsync OK")

    cur = "readback"
    if FAULT == "readback": raise ValueError("injected_fault:readback")
    data = json.loads(tgt.read_text(encoding="utf-8"))
    if data != {"probe": True}: raise ValueError("readback_mismatch %r" % (data,))
    steps[cur] = True; print("step4 readback OK", data)

    cur = "unlink_testfile"
    if FAULT == "unlink": raise OSError("injected_fault:unlink")
    tgt.unlink()
    steps[cur] = True; print("step5 unlink OK")

    cur = "dir_fsync_after_unlink"
    if FAULT == "dirfsync2": raise OSError("injected_fault:dirfsync2")
    dfd = os.open(str(SD), os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dfd); os.close(dfd)
    steps[cur] = True; print("step6 dir_fsync(after unlink) OK")
except Exception as e:
    print("STEP_FAILED", cur, type(e).__name__, e)
finally:
    # 只清理本次创建的两个文件（名字含本次 uuid），绝不碰其他文件
    for q in (t, tgt):
        try:
            if q.exists():
                q.unlink(); print("cleanup removed", q.name)
        except OSError as e:
            print("cleanup_failed", q.name, type(e).__name__, e)
ok = len(steps) == 6 and not FAULT
print("steps_completed", len(steps), sorted(steps))
print("VERDICT", "ATOMIC_WRITE_SUPPORTED" if ok else "FAILED")
raise SystemExit(0 if ok else 3)
PY
)
  P7_RC=$?
  printf '%s\n' "$P7_OUT" | sed 's/^/  /'
  if [ "$P7_RC" -eq 0 ] && printf '%s\n' "$P7_OUT" | grep -q 'VERDICT ATOMIC_WRITE_SUPPORTED'; then
    P7_STATE="已执行（通过：ATOMIC_WRITE_SUPPORTED）"
  else
    P7_STATE="已执行（失败：rc=$P7_RC，见 STEP_FAILED/VERDICT）"
    SCRIPT_RC=3
  fi
fi

# ---------------------------------------------------------------- 8) P-6 / P-8 / 卷
hr "8) P-6：备份目录与余量（只读）"
RUN sh -c 'ls -lht "$0" 2>/dev/null | head -20; echo "---"; du -sh "$0" 2>/dev/null; df -h "$0" "$1" 2>/dev/null' "$CBK" "$CDATA"

hr "9) P-8：运行身份与目录权限（只读）"
RUN sh -c 'id; ls -ld "$0" "$1" "$2" "$3" 2>&1' "$CDATA" "$CST" "$CBK" "$CFG"

hr "10) 卷类型（只读）"
RUN sh -c 'stat -f -c "data_fs=%T block=%s" "$0" 2>/dev/null; stat -f -c "backup_fs=%T block=%s" "$1" 2>/dev/null; stat -f -c "state_fs=%T block=%s" "$2" 2>/dev/null || echo "state dir absent: skip"' "$CDATA" "$CBK" "$CST"
if [ "$PROBE_MODE" = "host" ] && [ -n "$HDB" ]; then
  say "host_fs_for_db:"
  stat -f -c '  %T block=%s' "$(dirname "$HDB")" 2>/dev/null || say "  stat -f 不可用（非 GNU coreutils）"
fi

hr "DONE"
say "P-7 状态：$P7_STATE"
say "脚本退出码：$SCRIPT_RC（0=全部只读探针完成；2=目标不明已停止；3=P-7 执行失败）"
say "请回贴本 log 全文；未确认项保持为空，不做估算。"
exit "$SCRIPT_RC"
