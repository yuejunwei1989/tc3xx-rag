#!/usr/bin/env bash
# =============================================================================
# 导入 myICP 权限文档到知识库（HSM / Safety Manual / MCAL 等）
#
# 为什么需要这个脚本：
#   HSM 技术规范（HSM_TS）、HSM Errata、安全启动应用笔记等不在公开 CDN 上，
#   必须用有 myICP 权限的账号从 myICP 手动下载，无法自动拉取。
#
# 用法:
#   ./add_myicp.sh <目录或文件>...     # 批量导入，自动下载的无关文件会被跳过
#   ./add_myicp.sh --check            # 检查已导入的 myICP 文档
#
# myICP 下载路径参考（需账号）:
#   https://myicp.infineon.com/sites/microcontrollers-aurix_customer_doc
#     AURIX TC3xx/10 AURIX TC3xx HSM/          ← HSM_TS、HSM Errata、AP32373 等
#     AURIX TC3xx/00 AURIX TC3xx General/02 Safety Documentation/  ← Safety Manual
#
# 常见文件名（下载后保持原名即可，doc_id 会自动带上 hsm 前缀便于检索过滤）:
#   HSM_TS_V2.0_Rev2.0.pdf          — HSM 技术规范（核心）
#   AURIX-TC3xx_HSM-ES.pdf          — HSM 勘误表
#   AP32373_HSM_Demo_examples.pdf   — HSM 示例说明
#   AP32391_Secure_Boot_with_HSM.pdf— 安全启动
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PY=./.venv/bin/python
STAGE=data/myicp

case "${1:-}" in
  --check)
    $PY - <<'EOF'
import sqlite3
c = sqlite3.connect('.em_rag/fts.db')
rows = c.execute("""
    select doc_id, count(*) from chunks
    where doc_id like '%hsm%' or doc_id like '%safety%'
    group by doc_id order by doc_id
""").fetchall()
if not rows:
    print("暂无 HSM / Safety 相关文档")
for doc, n in rows:
    print(f"  {doc:50s} {n:5d} chunks")
EOF
    exit 0 ;;
  "")
    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

mkdir -p "$STAGE"
created_stage=0
[ -d "$STAGE" ] && [ -z "$(ls -A "$STAGE" 2>/dev/null)" ] && created_stage=1

for src in "$@"; do
  [ -e "$src" ] || { echo "  跳过（不存在）: $src"; continue; }
  cp -r "$src" "$STAGE"/
done

shopt -s nullglob
PDFS=("$STAGE"/*.pdf "$STAGE"/*.PDF)
if [ ${#PDFS[@]} -eq 0 ]; then
  echo "没有待导入的 PDF。请先把 myICP 文档下载到 $STAGE/ 后再运行。"
  exit 0
fi

echo "==> 待导入 ${#PDFS[@]} 个 PDF"
for f in "${PDFS[@]}"; do
  base=$(basename "$f")
  pages=$($PY -c "import pymupdf,sys;print(pymupdf.open(sys.argv[1]).page_count)" "$f" 2>/dev/null || echo 0)
  echo "--- $base ($pages 页)"
  # >400 页交给 add_docs.sh 的切片逻辑，否则直接索引
  ./deploy/add_docs.sh "$f"
done

echo
echo "==> 验证: $PY -m src.cli search \"HSM secure boot\" --top-k 3"
echo "==> 已导入清单: ./deploy/add_myicp.sh --check"
