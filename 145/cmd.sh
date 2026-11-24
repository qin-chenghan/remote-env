#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：从 145 ssh 到 198，详查今天两次 py312 运行（100823 / 094434），并搜索 100323 痕迹。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

REMOTE=root@90.91.147.198
PROBE=/tmp/probe198.sh

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench
echo "### 198 $(uname -m) nproc=$(nproc)"

echo "== 0. 全盘搜 100323 =="
docker exec $C bash -lc "find /home /tmp /root /vllmBench -maxdepth 9 -name '*100323*' 2>/dev/null | head -10"
echo "(以上为空即 198 上不存在)"

echo "== 1. 100823 =="
docker exec $C bash -lc "
  D=$VB/py312_litehost_gap_20261124_100823
  stat -c 'mtime=%y ctime=%z' \$D
  echo '-- tree'; find \$D -maxdepth 3 | sed 's|^|  |' | head -30
  echo '-- config.txt'; cat \$D/config.txt 2>/dev/null | head -20
  echo '-- summary.csv'; head -4 \$D/summary.csv 2>/dev/null
  echo '-- server.log 关键行'
  grep -nE 'loading took|Capturing|startup complete|pinned to cpu|Compiling|died unexpectedly|Engine core|Traceback|Error' \$D/logs/server.log 2>/dev/null | head -25
  echo '-- server.log 尾部'
  tail -25 \$D/logs/server.log 2>/dev/null
" 2>&1 | head -110

echo "== 2. 094434 =="
docker exec $C bash -lc "
  D=$VB/py312_litehost_gap_20261124_094434
  stat -c 'mtime=%y ctime=%z' \$D
  echo '-- tree'; find \$D -maxdepth 3 | sed 's|^|  |' | head -20
  echo '-- config.txt'; cat \$D/config.txt 2>/dev/null | head -20
  echo '-- summary.csv'; head -4 \$D/summary.csv 2>/dev/null
  echo '-- server.log 关键行'
  grep -nE 'loading took|Capturing|startup complete|pinned to cpu|Compiling|died unexpectedly|Engine core|Traceback|Error' \$D/logs/server.log 2>/dev/null | head -25
  echo '-- server.log 尾部'
  tail -20 \$D/logs/server.log 2>/dev/null
" 2>&1 | head -95

echo "== 3. 今天 09:00 之后容器里所有新文件（找 harness 输出）=="
docker exec $C bash -lc "find /tmp /root /home/huawei_ts_program -maxdepth 3 -newermt '2026-11-24 09:00' -type f 2>/dev/null | grep -vE 'inductor_cache|/proc/' | head -25"

echo "== 4. 容器 shell 历史（看测试者的实际命令）=="
docker exec $C bash -lc "tail -40 /root/.bash_history 2>/dev/null; ls -l /root/.bash_history 2>/dev/null"

echo "== 5. 现状 =="
docker exec $C bash -lc "ps -eo pid,pcpu,nlwp,args | grep -E 'vllm|python' | grep -v grep | cut -c1-120 | head -10"

PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -260

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
