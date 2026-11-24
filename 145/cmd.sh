#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
# 本次：198 上核对 mock 代码版本、worker 死亡判定、PCH 落盘逻辑、core。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"
REMOTE=root@90.91.147.198
PROBE=/tmp/probe198d.sh

{
  echo "### server: 145 -> 198"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
C=vllm
VB=/home/huawei_ts_program/litehost_perf_opt/vllmBench

echo "== 1. mock 源码版本（sitecustomize 打印的 id = 源码哈希）=="
docker exec $C bash -lc "for d in py312_litehost_gap_20261123_155113 py312_litehost_gap_20261123_155940 py312_litehost_gap_20261124_100823; do echo -n \"\$d: \"; grep -h 'mock_gpu] activated' $VB/\$d/logs/preflight.log 2>/dev/null | tail -1; done"
docker exec $C bash -lc "ls -l /home/qch/mock_vllm/mock_gpu/*.py | head -12"
docker exec $C bash -lc "md5sum /home/qch/mock_vllm/mock_gpu/worker_patch.py /home/qch/mock_vllm/mock_gpu/fake_graph.py /home/qch/mock_vllm/sitecustomize.py 2>/dev/null"

echo "== 2. worker 死亡判定（multiproc_executor.py:270-300）=="
docker exec $C bash -lc "sed -n '255,300p' /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py"
docker exec $C bash -lc "grep -n 'died unexpectedly\|monitor_workers\|def _monitor\|_check_worker\|is_alive' /usr/local/lib/python3.12/site-packages/vllm/v1/executor/multiproc_executor.py | head -12"

echo "== 3. PCH 目录选择逻辑（是否与 CACHE_DIR 无关）=="
docker exec $C bash -lc "grep -n 'precompiled_headers\|system_temp\|gettempdir' /usr/local/lib/python3.12/site-packages/torch/_inductor/codecache.py | head -12"

echo "== 4. 今天 100823 里 rank2 的日志与任何 stderr =="
docker exec $C bash -lc "grep -n 'pid=1810' $VB/py312_litehost_gap_20261124_100823/logs/server.log | cut -c1-190 | head -20"

echo "== 5. core dump =="
ls -lt /tmp/core* /var/crash 2>/dev/null | head -5
docker exec $C bash -lc "ls -lt /tmp/core* 2>/dev/null | head -5; cat /proc/sys/kernel/core_pattern"

echo "== 6. 100823 的 preflight 尾部（会话建立后有无异常）=="
docker exec $C bash -lc "tail -12 $VB/py312_litehost_gap_20261124_100823/logs/preflight.log"

echo "== 7. litehost 会话目录残留 =="
docker exec $C bash -lc "ls -ld /tmp/lhc-* 2>/dev/null | head; du -sh /tmp/lhc-* 2>/dev/null | head"
PROBE_EOF

  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'bash -s' < "$PROBE" 2>&1 | head -200

  set +x
} 2>&1 | tee "$OUT"

printf '\n### exit: %s\n' "${PIPESTATUS[0]}" | tee -a "$OUT"
echo "结果已写入: $OUT"
