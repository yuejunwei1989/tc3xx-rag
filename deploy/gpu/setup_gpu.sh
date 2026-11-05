#!/usr/bin/env bash
# =============================================================================
# GPU 路线切换：启动 Infinity 推理服务 → 改写 config.yaml → 全量重索引
# 用法:  ./setup_gpu.sh   （在工程根目录执行；需 docker + nvidia-container-toolkit）
# 注意:  换嵌入模型后必须全量重索引，新旧向量不可混用
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1/4] 启动 Infinity (bge-m3 + bge-reranker-v2-m3)"
docker compose -f deploy/gpu/docker-compose.gpu.yml up -d infinity

echo "==> [2/4] 等待服务就绪"
for i in $(seq 1 60); do
  if curl -s http://localhost:7997/v1/models | grep -q bge-m3; then echo "  就绪"; break; fi
  [ "$i" = 60 ] && { echo "  超时：检查 docker logs tc397-rag-infinity"; exit 1; }
  sleep 5
done

echo "==> [3/4] 备份并切换 config.yaml 到 GPU embedding"
cp .em_rag/config.yaml .em_rag/config.yaml.cpu.$(date +%s)
cat > .em_rag/config.yaml <<'EOF'
embedding:
  provider: "openai_compatible"
  openai_base_url: "http://localhost:7997/v1"
  openai_model: "BAAI/bge-m3"
  batch_size: 64

parsing:
  table_strategy: "pdfplumber"
  use_bookmarks: true
  fallback_to_markdown_headings: true

chunking:
  max_tokens: 2000          # bge-m3 上下文 8192，放宽分块让寄存器表整页完整
  overlap_tokens: 200
  keep_tables_intact: true
  split_at_semantic_boundary: true

storage:
  chroma_path: "./.em_rag/chroma_db"
  fts_path: "./.em_rag/fts.db"

figures:
  enabled: true
  mode: "timing_related"
  detection: "hybrid"       # GPU 场景建议 hybrid：规则召回 + LLM 精判
  save_full_page: true
  save_crops: true
  render_dpi: 180
  output_dir: "./.em_rag/figures"

documents:
  source_dir: "./data/documents"

retrieval:
  top_k: 5
  keyword_priority: true
  context_expand: true
  rerank_url: "http://localhost:7997/rerank"   # bge-reranker 精排
  rerank_candidates: 20
EOF

echo "==> [4/4] 清空旧索引并全量重建（GPU 嵌入，预计 5-10 分钟）"
rm -rf .em_rag/chroma_db .em_rag/fts.db
./deploy/rebuild_index.sh

echo "==> 完成。验证:"
echo "  ./.venv/bin/python -m em_rag search 'CAN 波特率如何计算'   # 纯中文现在应能命中"
echo "  回退 CPU 路线: 恢复 .em_rag/config.yaml.cpu.* 后重建索引即可"
