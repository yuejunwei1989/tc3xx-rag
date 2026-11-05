#!/usr/bin/env bash
# =============================================================================
# 远程 MCP 服务：让其他机器/Agent 通过 HTTP+SSE 访问芯片知识库
# 用法:  ./serve_remote.sh [端口，默认 8080]
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8080}"

# 首次运行确保索引存在
if [ ! -s .em_rag/fts.db ]; then
  echo "!! 未发现索引，请先执行 ./deploy/setup_data.sh && ./deploy/rebuild_index.sh"
  exit 1
fi

echo "启动远程 MCP: http://0.0.0.0:$PORT/sse"
echo "  能力发现:    curl http://<本机IP>:$PORT/info"
echo "  健康检查:    curl http://<本机IP>:$PORT/health"
echo "  客户端配置:  {\"mcpServers\":{\"tc397-rag\":{\"url\":\"http://<本机IP>:$PORT/sse\"}}}"
exec ./.venv/bin/python -m em_rag.mcp_http --host 0.0.0.0 --port "$PORT"
