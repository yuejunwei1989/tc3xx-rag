#!/usr/bin/env bash
# =============================================================================
# 重建索引：手册 PDF 分片 + iLLD 源码 + iLLD API 文档 → Chroma + FTS5
# 用法:  ./rebuild_index.sh   （在工程根目录执行；首次约 40-60 分钟）
# 注意:  串行执行！多进程并发写 Chroma 会损坏 HNSW 索引（已踩坑验证）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PY=./.venv/bin/python

echo "==> 初始化工程配置"
[ -f .em_rag/config.yaml ] || $PY -m em_rag init

echo "==> 索引手册 PDF（每片约 45 秒）"
for f in data/documents/*.pdf; do
  $PY -m em_rag add "$f" 2>&1 | grep -E "索引完成|索引失败" || true
done

echo "==> 索引 iLLD 源码 (1987 个 .c/.h)"
$PY -m em_rag add data/illd 2>&1 | grep -E "批量索引完成" || true

echo "==> 索引 iLLD API 文档 (1667 个 .md)"
[ -d data/illd_api ] && $PY -m em_rag add data/illd_api 2>&1 | grep -E "批量索引完成" || true

echo "==> 生成/刷新 MCP 配置"
$PY -m em_rag mcp || true

echo "==> 完成。统计:"
$PY - <<'EOF'
import sqlite3
c=sqlite3.connect('.em_rag/fts.db')
print(f"  文档数: {c.execute('select count(distinct doc_id) from chunks').fetchone()[0]}")
print(f"  chunk数: {c.execute('select count(*) from chunks').fetchone()[0]}")
EOF
echo "验证: $PY -m em_rag search 'QSPI baud rate configuration'"
