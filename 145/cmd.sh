#!/usr/bin/env bash
# Agent: 每次覆盖本文件，命令写进下方的标记区间。
# 标记区间内所有 stdout/stderr 都会写入 tmp/<timestamp>.log。
#
# 天数 mock 环境部署，**分阶段执行**，一次只跑一步：
#   STAGE=1 bash 145/cmd.sh   # 校验 + 解压（9G -> 27G tar）
#   STAGE=2 bash 145/cmd.sh   # docker load
#   STAGE=3 bash 145/cmd.sh   # 起容器 + 容器内自检
#   STAGE=4 bash 145/cmd.sh   # mock 激活冒烟
# 不带 STAGE 时只打印用法，不做任何事。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(basename "$DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/tmp/$TS.log"
mkdir -p "$DIR/tmp"

IMG=/home/qch/transfer/corex5-py311-py3116-20261029.tar.zst
TAR=/home/qch/transfer/corex5-py311-py3116-20261029.tar
EXPECT_ZST=dc479721103811984b4f08a397da6f78825a5457a8773f35995b44a80e29f5ff
IMAGE_TAG=corex5-py311:py3116-20261029

STAGE="${STAGE:-}"

{
  echo "### server: $SERVER  stage=${STAGE:-none}"
  echo "### host:   $(hostname)"
  echo "### time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  set -x

  # ---- 命令开始 ----

  case "$STAGE" in
  1)
    echo "== STAGE 1：校验 + 解压 =="
    ls -lh "$IMG" 2>/dev/null || { echo "!! 缺 $IMG，先拷文件到 /home/qch/transfer/"; exit 3; }
    ACTUAL=$(sha256sum "$IMG" | cut -d' ' -f1)
    echo "actual=$ACTUAL"
    echo "expect=$EXPECT_ZST"
    [ "$ACTUAL" = "$EXPECT_ZST" ] || { echo "!! sha256 不一致，停止（不 load 半个镜像）"; exit 4; }
    df -h /home | tail -1
    if [ -f "$TAR" ]; then
      echo "== tar 已存在，跳过解压 =="
    else
      if command -v zstd >/dev/null 2>&1; then
        zstd -d "$IMG" -o "$TAR" || exit 1
      else
        echo "宿主无 zstd，用 zstd:latest 镜像解压"
        docker run --rm --security-opt label=disable -v /home:/home zstd:latest \
          zstd -d "$IMG" -o "$TAR" || exit 1
      fi
    fi
    ls -lh "$TAR"
    df -h /home | tail -1
    echo "== STAGE 1 完成，检查上面 sha256 一致、tar 27G 左右，再跑 STAGE=2 =="
    ;;

  2)
    echo "== STAGE 2：docker load =="
    [ -f "$TAR" ] || { echo "!! 缺 $TAR，先跑 STAGE=1"; exit 3; }
    df -h /home | tail -1
    docker load -i "$TAR" || exit 1
    docker images | grep -E "corex5-py311|REPOSITORY" | head -5
    df -h /home | tail -1
    echo "== STAGE 2 完成：镜像已载入，再跑 STAGE=3 =="
    ;;

  3)
    echo "== STAGE 3：起容器 + 自检 =="
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || { echo "!! 镜像未载入，先跑 STAGE=2"; exit 3; }
    if ss -ltn 2>/dev/null | grep -q ':8948 '; then
      echo "!! 8948 已被占用，不启动容器；先确认是谁在用"
      ss -ltnp 2>/dev/null | grep ':8948 ' | head -2
      exit 5
    fi
    docker rm -f corex5-py311-mock 2>/dev/null
    docker run -d --name corex5-py311-mock --network host \
      --security-opt label=disable -v /home:/home \
      "$IMAGE_TAG" sleep infinity || exit 1
    sleep 3
    docker ps --filter name=corex5-py311-mock --format '{{.Names}} {{.Status}}'
    echo "-- 容器内自检 --"
    docker exec corex5-py311-mock bash -lc '
      uname -m
      /opt/corex311/bin/python3 -V
      ls -l /usr/local/corex/lib64/libcuda.so.1
      /opt/corex311/bin/python3 -c "import torch; print(torch.__version__)"
      ls -d /dev/iluvatar* 2>/dev/null || echo "no device (expected)"
    ' 2>&1 | tail -8
    echo "== STAGE 3 完成：aarch64 / py3.11 / libcuda / torch 都正常，再跑 STAGE=4 =="
    ;;

  4)
    echo "== STAGE 4：mock 激活冒烟 =="
    if [ ! -d /home/qch/mock_vllm/mock_gpu ] && [ -d /home/qch/tools/remote-env/mock_vllm/mock_gpu ]; then
      ln -sfn /home/qch/tools/remote-env/mock_vllm /home/qch/mock_vllm
      echo "已软链 /home/qch/mock_vllm -> remote-env/mock_vllm"
    fi
    [ -d /home/qch/mock_vllm/mock_gpu ] || { echo "!! 缺 mock_vllm：先 cd /home/qch/tools/remote-env && git pull"; exit 3; }
    docker exec corex5-py311-mock bash -lc '
      PYTHONPATH=/home/qch/mock_vllm /opt/corex311/bin/python3 -c "import mock_gpu.autoload" 2>&1 | tail -4
    '
    echo "== STAGE 4 完成：出现 [mock_gpu] activated ... (id=...) 即部署成功 =="
    ;;

  *)
    echo "用法：STAGE=1|2|3|4 bash 145/cmd.sh"
    echo "  1 = 校验 sha256 + 解压（需 27G 空闲，当前）"
    echo "  2 = docker load（再占约 28G）"
    echo "  3 = 起容器 + 自检"
    echo "  4 = mock 激活冒烟"
    echo
    echo "当前状态："
    ls -lh "$IMG" "$TAR" 2>/dev/null || echo "  镜像文件尚未就位"
    docker images 2>/dev/null | grep -E "$IMAGE_TAG" || echo "  镜像尚未载入"
    docker ps -a --filter name=corex5-py311-mock --format '  容器: {{.Names}} {{.Status}}' 2>/dev/null
    df -h /home | tail -1
    ;;
  esac

  # ---- 命令结束 ----

  set +x
} 2>&1 | tee "$OUT"

STATUS=${PIPESTATUS[0]}
printf '\n### exit: %s\n' "$STATUS" | tee -a "$OUT"
echo "结果已写入: $OUT"
