#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
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
  # 第九批：正确的联网探测（带 -i 喂 stdin），三套代理配置各测一次。
  # 只读 + 只拉元数据，不安装。

  CON=corex5-py311
  BASE=/opt/corex311

  echo "== A. TCP 可达性（容器内，host 网络）=="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import socket
for host, port in (("141.1.61.31", 3129), ("141.4.2.160", 8888)):
    s = socket.socket()
    s.settimeout(5)
    try:
        s.connect((host, port))
        print(f"{host}:{port} TCP OK")
    except Exception as e:
        print(f"{host}:{port} FAIL {type(e).__name__} {e}")
    finally:
        s.close()
PY

  echo "== B. HTTPS 探测：无代理 =="
  docker exec -i -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import urllib.request
try:
    with urllib.request.urlopen("https://mirrors.aliyun.com/pypi/simple/six/", timeout=12) as r:
        print("OK", r.status, len(r.read(200)))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:150])
PY

  echo "== C. HTTPS 探测：set_proxy 小写那套 141.1.61.31:3129 =="
  docker exec -i -e http_proxy=http://141.1.61.31:3129 -e https_proxy=http://141.1.61.31:3129 \
    -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import urllib.request
try:
    with urllib.request.urlopen("https://mirrors.aliyun.com/pypi/simple/six/", timeout=12) as r:
        print("OK", r.status, len(r.read(200)))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:150])
PY

  echo "== D. HTTPS 探测：继承的大写那套 141.4.2.160:8888 =="
  docker exec -i -e HTTP_PROXY=http://141.4.2.160:8888 -e HTTPS_PROXY=http://141.4.2.160:8888 \
    -e PYTHONPATH= -e PYTHONHOME= "$CON" "$BASE/bin/python" - <<'PY'
import urllib.request
try:
    with urllib.request.urlopen("https://mirrors.aliyun.com/pypi/simple/six/", timeout=12) as r:
        print("OK", r.status, len(r.read(200)))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:150])
PY

  echo "== E. pip dry-run：小写代理 + 未安装版本（必须联网解析）=="
  docker exec -e http_proxy=http://141.1.61.31:3129 -e https_proxy=http://141.1.61.31:3129 \
    -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$BASE/bin/python" -m pip install --dry-run --ignore-installed \
    --no-cache-dir --no-deps --only-binary=:all: six==1.16.0 2>&1 | tail -6

  echo "== F. pip dry-run：代表性 pin（transformers + tokenizers），小写代理 =="
  docker exec -e http_proxy=http://141.1.61.31:3129 -e https_proxy=http://141.1.61.31:3129 \
    -e PYTHONPATH= -e PYTHONHOME= -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CON" "$BASE/bin/python" -m pip install --dry-run --ignore-installed \
    --no-cache-dir --no-deps --only-binary=:all: transformers==5.5.3 tokenizers==0.22.2 2>&1 | tail -6

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
