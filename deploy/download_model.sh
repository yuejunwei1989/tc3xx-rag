#!/usr/bin/env bash
# =============================================================================
# 下载 ONNX 嵌入模型 all-MiniLM-L6-v2（90MB）
# 主机和容器都适用：容器内没有 venv 也能跑，只依赖 curl。
# 用法: ./download_model.sh [目标目录，默认 models/all-MiniLM-L6-v2]
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-models/all-MiniLM-L6-v2}"
mkdir -p "$DEST"

# 已存在且大小正常则跳过（model.onnx 约 90MB）
if [ -f "$DEST/model.onnx" ] && [ "$(stat -c%s "$DEST/model.onnx")" -gt 80000000 ]; then
  echo "  模型已存在: $DEST ($(du -h "$DEST/model.onnx" | cut -f1))"
  exit 0
fi

HF="https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main"
MIRROR="https://hf-mirror.com/sentence-transformers/all-MiniLM-L6-v2/resolve/main"

# 优先 hf-mirror（国内直连 HuggingFace 通常超时才失败，白等 5 分钟/文件）；
# 设置 HF_DIRECT=1 可强制先试直连
if [ "${HF_DIRECT:-0}" = "1" ]; then
  BASES=("$HF" "$MIRROR")
else
  BASES=("$MIRROR" "$HF")
fi

dl() { # dl <相对路径> <输出名>
  local rel="$1" out="$2"
  for base in "${BASES[@]}"; do
    if curl -sSL --retry 2 --max-time 600 -o "$DEST/$out" "$base/$rel" 2>/dev/null \
       && [ -s "$DEST/$out" ]; then
      echo "  OK  $out ($(du -h "$DEST/$out" | cut -f1))  <- ${base%%/sentence*}"
      return 0
    fi
  done
  echo "  FAIL $out（直连与 hf-mirror 均失败，请手动下载）"
  return 1
}

echo "==> 下载嵌入模型到 $DEST"
rc=0
dl "onnx/model.onnx"        "model.onnx"          || rc=1
dl "tokenizer.json"         "tokenizer.json"      || rc=1
dl "tokenizer_config.json"  "tokenizer_config.json" || rc=1

# 校验主模型文件大小，防止下到错误页面（HTML 报错页只有几 KB）
sz=$(stat -c%s "$DEST/model.onnx" 2>/dev/null || echo 0)
if [ "$sz" -lt 80000000 ]; then
  echo "  !! model.onnx 只有 $sz 字节，疑似下载不完整"
  echo "     手动下载: $MIRROR/onnx/model.onnx"
  exit 1
fi

echo "==> 完成: $DEST"
exit $rc
