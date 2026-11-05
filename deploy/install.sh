#!/usr/bin/env bash
# =============================================================================
# TC397 + iLLD 知识库 — 主机部署脚本（无 Docker 场景）
# 用法:  ./install.sh [目标目录，默认 ./tc397-rag]
# 前提:  python3.11+, git, curl, 7z(CHM转换用, apt install p7zip-full)
# =============================================================================
set -euo pipefail

TARGET="${1:-./tc397-rag}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # 部署包根目录（含 src/em_rag）

echo "==> 目标目录: $TARGET"
mkdir -p "$TARGET"
cd "$TARGET"

# 目标就是源码目录本身（clone 后直接 install .）时跳过拷贝，避免 cp 到自身
if [ "$(pwd -P)" = "$SRC_DIR" ]; then
  echo "  (目标即项目根目录，跳过源码拷贝)"
else
  # 1. 拷贝源码
  echo "==> 拷贝 em_rag 源码（含修复补丁）"
  cp -r "$SRC_DIR/src" "$SRC_DIR/em_rag" "$SRC_DIR/scripts" .
  cp "$SRC_DIR/config.yaml" "$SRC_DIR/pyproject.toml" "$SRC_DIR/requirements.txt" .
  mkdir -p deploy
  cp -r "$SRC_DIR/deploy/." ./deploy/
fi

# 2. 虚拟环境 + 依赖
echo "==> 创建 venv 并安装依赖"
python3.11 -m venv .venv
./.venv/bin/python -m pip install -q --upgrade pip
./.venv/bin/python -m pip install -q -r requirements.txt "mcp>=1,<2"
./.venv/bin/python -m pip install -q -e .

# 3. 下载嵌入模型（复用 download_model.sh：HF 直连失败自动走 hf-mirror）
echo "==> 下载 ONNX 嵌入模型 all-MiniLM-L6-v2"
./deploy/download_model.sh models/all-MiniLM-L6-v2 || echo "  !! 模型下载失败，可稍后重跑 ./deploy/download_model.sh"

echo "==> 完成。下一步: ./deploy/setup_data.sh   （下载手册与 iLLD，约 80MB PDF + 32MB 源码）"
