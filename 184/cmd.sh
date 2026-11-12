#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 查 corex5-py311 里 /usr/local/corex-5.0.0/vllmBench 是否落在 host 上，以及实际路径。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

{
  echo "### server: $SERVER"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----
  C=corex5-py311
  P=/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257

  echo "== 1. 容器的挂载表 =="
  docker inspect "$C" --format '{{range .Mounts}}{{.Type}}  {{.Source}} -> {{.Destination}}  (rw={{.RW}}){{println}}{{end}}'
  echo "-- /usr/local 是否被单独挂载 --"
  docker inspect "$C" --format '{{range .Mounts}}{{if eq .Destination "/usr/local"}}{{.Source}} -> /usr/local{{end}}{{end}}'

  echo "== 2. 容器的存储驱动与可写层 =="
  docker inspect "$C" --format 'driver={{.GraphDriver.Name}}{{println}}{{range $k,$v := .GraphDriver.Data}}{{$k}}={{$v}}{{println}}{{end}}'
  UP=$(docker inspect "$C" --format '{{.GraphDriver.Data.UpperDir}}')
  echo "UPPERDIR=$UP"

  echo "== 3. host 上可写层里的实际路径 =="
  ls -ld "$UP/usr/local/corex-5.0.0" "$UP/usr/local/corex-5.0.0/vllmBench" "$UP/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257" 2>&1
  du -sh "$UP/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257" 2>&1
  echo "-- 从 host 直接看文件数 --"
  find "$UP/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257" -type f 2>/dev/null | wc -l
  echo "-- 从 host 直接读 summary.csv --"
  head -3 "$UP/usr/local/corex-5.0.0/vllmBench/litehost_gap_20261112_150257/summary.csv" 2>&1

  echo "== 4. host 上是否还有别的同名副本 =="
  find /var/lib/docker /home /usr/local /data /opt -maxdepth 8 -name 'litehost_gap_20261112_150257' 2>/dev/null | head -10

  echo "== 5. 挂载点列表（确认 /home 是哪个 bind）=="
  findmnt -T /home/qch -o TARGET,SOURCE,FSTYPE 2>/dev/null
  findmnt -T /usr/local -o TARGET,SOURCE,FSTYPE 2>/dev/null

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
