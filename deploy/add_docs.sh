#!/usr/bin/env bash
# =============================================================================
# 手动添加文档/代码到知识库（自动处理大 PDF 切片）
# 用法:
#   ./add_docs.sh <文件或目录>          # 索引并立即可检索
#   ./add_docs.sh --list               # 查看已索引文档
#   ./add_docs.sh --remove <doc_id>    # 移除文档
# 支持: .pdf .md .txt .docx .epub .h .c .hpp .cpp .cc .cxx .s .asm .inc .i .ino
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PY=./.venv/bin/python

case "${1:-}" in
  --list)   exec $PY -m src.cli list ;;
  --remove) [ -n "${2:-}" ] || { echo "用法: $0 --remove <doc_id>（doc_id 见 --list）"; exit 1; }
            exec $PY -m src.cli remove "$2" ;;
  "")       grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

TARGET="$1"
[ -e "$TARGET" ] || { echo "不存在: $TARGET"; exit 1; }

# 大 PDF 自动切片到 data/documents/slices/
if [ -f "$TARGET" ] && [ "${TARGET##*.}" = "pdf" ]; then
  PAGES=$($PY -c "import fitz;print(fitz.open('$TARGET').page_count)" 2>/dev/null || echo 0)
  if [ "$PAGES" -gt 400 ]; then
    echo "==> PDF 共 $PAGES 页（>400 页直接索引会 OOM），自动切片中..."
    OUT=data/documents/slices
    mkdir -p "$OUT"
    $PY - "$TARGET" "$OUT" <<'EOF'
import sys, os, fitz
src, out = sys.argv[1], sys.argv[2]
name = os.path.splitext(os.path.basename(src))[0]
d0 = fitz.open(src); n = d0.page_count; d0.close()
step = 300
for i in range(0, n, step):
    end = min(i + step, n)
    f = f"{out}/{name}-p{i+1:04d}-{end:04d}.pdf"
    if os.path.exists(f): continue
    s = fitz.open(src); d = fitz.open(); d.insert_pdf(s, from_page=i, to_page=end-1); d.save(f); d.close()
    print("  切片:", f)
EOF
    echo "==> 索引切片"
    for f in "$OUT"/"$(basename "${TARGET%.pdf}")"-p*.pdf; do
      $PY -m src.cli add "$f" 2>&1 | grep -E "索引完成|索引失败" || true
    done
    echo "==> 完成。原始 PDF 保留在原位置，可删除切片: rm -rf $OUT"
    exit 0
  fi
fi

echo "==> 索引 $TARGET"
$PY -m src.cli add "$TARGET"

echo "==> 验证:"
$PY - <<'EOF'
import sqlite3
c = sqlite3.connect('.em_rag/fts.db')
docs = c.execute("SELECT COUNT(DISTINCT doc_id) FROM chunks").fetchone()[0]
chunks = c.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
print(f"  当前知识库: {docs} 个文档 / {chunks} 个 chunks")
EOF
echo "  测试检索: ./.venv/bin/python -m em_rag search '<新文档中的关键词>'"
