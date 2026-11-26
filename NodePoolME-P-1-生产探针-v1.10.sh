#!/bin/sh
# NodePoolME P-1 生产探针（只读，P-7 除外）
# 用法：
#   1) 在 NAS 宿主机执行：  sh NodePoolME-P-1-生产探针-v1.10.sh | tee p1-probe-$(date +%Y%m%d-%H%M%S).log
#   2) 在容器内执行：       EXEC="" sh NodePoolME-P-1-生产探针-v1.10.sh
# 默认 EXEC="docker exec -i nodepool"（宿主机 → 容器）。
# 除第 5 段（P-7）外全部只读；第 5 段必须显式设置 NODEPOOL_P7_APPROVED=1 才会运行。
set -u
EXEC="${EXEC-docker exec -i nodepool}"
PROBE_MODE="${PROBE_MODE:-host}"   # host | container
P7_APPROVED="${NODEPOOL_P7_APPROVED:-0}"
HEALTHZ="${NODEPOOL_HEALTHZ:-http://127.0.0.1:8080/healthz}"

hr() { echo; echo "===== $* ====="; }

hr "0) 容器 / 镜像 / 挂载（P-10 用）"
if [ "$PROBE_MODE" = "host" ]; then
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i nodepool || echo "no nodepool container"
  docker inspect nodepool --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' 2>/dev/null
  echo "image_tag:"; docker inspect nodepool --format '{{.Config.Image}}' 2>/dev/null
  echo "image_id:";  docker inspect nodepool --format '{{.Image}}' 2>/dev/null
  echo "repo_digests:"; docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$(docker inspect nodepool --format '{{.Config.Image}}' 2>/dev/null)" 2>/dev/null
  echo "env:"; docker inspect nodepool --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E 'NODEPOOL_' || true
  echo "restart_policy:"; docker inspect nodepool --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
  echo "started_at:"; docker inspect nodepool --format '{{.State.StartedAt}}' 2>/dev/null
fi

$EXEC python -c "import backend.config as c;print('app_version', c.VERSION);print('data_dir', c.DATA_DIR);print('db_path', c.DB_PATH);print('backup_dir', c.BACKUP_DIR)" 2>/dev/null

echo "healthz_raw:"; $EXEC python -c "import urllib.request,json;print(urllib.request.urlopen('$HEALTHZ',timeout=5).read().decode())" 2>/dev/null
$EXEC python -c "
import urllib.request,json
try:
    d=json.loads(urllib.request.urlopen('$HEALTHZ',timeout=5).read().decode())
except Exception as e:
    print('healthz_version','UNPARSEABLE',e); raise SystemExit
v=d.get('version') if isinstance(d,dict) else None
print('healthz_version', v if isinstance(v,str) and v else 'ABSENT')
print('healthz_keys', sorted(d.keys()) if isinstance(d,dict) else type(d).__name__)
" 2>/dev/null

hr "1) P-1 / P-3 / P-4：库体量、表行数、WAL、完整性（只读，不 checkpoint）"
$EXEC python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", str(Path(os.getenv("NODEPOOL_DATA_DIR","/data"))/"nodepool.db")))
print("path", p, "exists", p.exists())
print("file_bytes", p.stat().st_size if p.exists() else None)
try:
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
except sqlite3.Error as e:
    print("OPEN_FAILED", type(e).__name__, e)
    print("NOTE: 只读打开失败时不重试 immutable=1（会忽略 WAL，读到过期数据）")
    raise SystemExit
print("sqlite_version", sqlite3.sqlite_version)
for k in ("page_size","page_count","freelist_count","journal_mode","synchronous","wal_autocheckpoint"):
    print(k, c.execute(f"PRAGMA {k}").fetchone())
print("page_bytes", c.execute("PRAGMA page_size").fetchone()[0]*c.execute("PRAGMA page_count").fetchone()[0])
tabs=[(n,c.execute(f'SELECT count(*) FROM "{n}"').fetchone()[0]) for (n,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
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

hr "2) P-4：WAL / SHM 物理实体（只读）"
$EXEC sh -c 'ls -l /data/nodepool.db* 2>/dev/null || echo "no db files"' 

hr "3) P-5：句柄 / 外部持有者（只读；只说明谁打开了文件）"
$EXEC sh -c 'for f in /proc/[0-9]*/fd/*; do t=$(readlink "$f" 2>/dev/null); case "$t" in */nodepool.db*) echo "$f -> $t";; esac; done' | head -30
$EXEC sh -c 'command -v fuser >/dev/null && fuser -v /data/nodepool.db 2>&1 || echo "fuser not installed"'
echo "container_pid:"; [ "$PROBE_MODE" = "host" ] && docker inspect nodepool --format '{{.State.Pid}}' 2>/dev/null
echo "host_lsof:";   [ "$PROBE_MODE" = "host" ] && (command -v lsof >/dev/null && lsof /opt/nodepool/data/nodepool.db* 2>/dev/null | head -10 || echo "lsof not installed on host") || true

hr "3b) P-5：PRAGMA data_version 双读（同一只读连接）"
$EXEC python - <<'PY'
import sqlite3, os, time
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", str(Path(os.getenv("NODEPOOL_DATA_DIR","/data"))/"nodepool.db")))
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
before = c.execute("PRAGMA data_version").fetchone()[0]
time.sleep(2)
after  = c.execute("PRAGMA data_version").fetchone()[0]
print("data_version_before", before)
print("data_version_after ", after)
print("data_version_changed", before != after)
c.close()
PY
echo "NOTE: 只能判断其他连接是否提交过写入；不能证明不存在未提交事务。"

hr "4) P-9：sub_publish 当前配置与最近发布（只读）"
$EXEC python - <<'PY'
import sqlite3, os
from pathlib import Path
p = Path(os.getenv("NODEPOOL_DB", str(Path(os.getenv("NODEPOOL_DATA_DIR","/data"))/"nodepool.db")))
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
cols = [r[1] for r in c.execute("PRAGMA table_info(settings)")]
print("settings_cols", cols)
for k in ("sub_publish_enabled","sub_publish_mode","sub_publish_time","sub_publish_interval_minutes","sub_publish_next_at","sub_publish_last_at"):
    try:
        r = c.execute("SELECT value FROM settings WHERE key=?", (k,)).fetchone()
        print("setting", k, None if r is None else r[0])
    except sqlite3.Error as e:
        print("setting", k, "QUERY_FAILED", e)
lcols=[r[1] for r in c.execute("PRAGMA table_info(logs)")]
print("logs_cols", lcols)
sel=", ".join([x for x in ("id","ts","level","source","message") if x in lcols])
n=0
for r in c.execute(f"SELECT {sel} FROM logs ORDER BY id DESC LIMIT 30"):
    txt=" ".join(str(x) for x in r)
    if any(x in txt for x in ("发布","订阅","publish","sub")):
        print("last_publish_log", tuple(r)); n+=1
        if n>=3: break
if n==0: print("last_publish_log", "NONE_IN_LAST_30")
c.close()
PY

hr "5) P-7【写操作，需审批】在最终 STATE_DIR 上验证原子写全链路"
if [ "$P7_APPROVED" != "1" ]; then
  echo "SKIPPED: 未获批准（需设置 NODEPOOL_P7_APPROVED=1）"
  echo "将创建：<STATE_DIR>/p1probe.<8hex>.tmp、<STATE_DIR>/p1probe.<8hex>.json；随后删除二者"
  echo "若 STATE_DIR 不存在将创建该空目录（结束后若仍为空则删除）"
else
$EXEC python - <<'PY'
import json, os, uuid
from pathlib import Path
DB  = Path(os.getenv("NODEPOOL_DB", str(Path(os.getenv("NODEPOOL_DATA_DIR","/data"))/"nodepool.db")))
SD  = Path(os.getenv("NODEPOOL_STATE_DIR", "/data/state"))
created=False
if not SD.exists():
    SD.mkdir(parents=True); created=True
print("state_dir", SD, "created", created)
dbd, sdd = os.stat(DB).st_dev, os.stat(SD).st_dev
print("db_st_dev", dbd, "state_st_dev", sdd, "same_volume", dbd==sdd)
if dbd != sdd:
    print("VERDICT", "CROSS_DEVICE -> 拒绝迁移（不继续写测试）")
    raise SystemExit(0)
n=uuid.uuid4().hex[:8]; t=SD/f"p1probe.{n}.tmp"; tgt=SD/f"p1probe.{n}.json"
try:
    with open(t,"wb") as f:
        f.write(b'{"probe":true}'); f.flush(); os.fsync(f.fileno())
    print("step write+file_fsync OK")
    os.replace(str(t), str(tgt)); print("step os.replace OK")
    dfd=os.open(str(SD), os.O_RDONLY|os.O_DIRECTORY); os.fsync(dfd); os.close(dfd); print("step dir_fsync OK")
    print("step readback", json.loads(tgt.read_text(encoding="utf-8")))
    tgt.unlink(); dfd=os.open(str(SD), os.O_RDONLY|os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
    print("step unlink+dir_fsync OK")
    print("VERDICT", "ATOMIC_WRITE_SUPPORTED")
finally:
    for q in (t,tgt):
        try: q.unlink()
        except FileNotFoundError: pass
    if created:
        try: SD.rmdir(); print("removed empty STATE_DIR")
        except OSError as e: print("keep STATE_DIR:", e)
PY
fi

hr "6) P-6：备份目录与磁盘余量（只读）"
$EXEC sh -c 'ls -lht /backup 2>/dev/null | head -20; echo "---"; du -sh /backup 2>/dev/null; df -h /backup /data 2>/dev/null'

hr "7) P-8：运行身份与目录权限（只读）"
$EXEC sh -c 'id; ls -ld /data /data/state /backup /config 2>&1'

hr "8) 卷类型（只读）"
$EXEC sh -c 'stat -f -c "data_fs=%T block=%s" /data 2>/dev/null; stat -f -c "backup_fs=%T block=%s" /backup 2>/dev/null; stat -f -c "state_fs=%T block=%s" /data/state 2>/dev/null || true'
if [ "$PROBE_MODE" = "host" ]; then
  echo "host_mounts:"; mount | grep -E " /opt/nodepool| /vol| /mnt" | head -10
fi

hr "DONE"
echo "请把本 log 全文回贴；P-7 未执行属预期，需单独批准后重跑第 5 段。"
