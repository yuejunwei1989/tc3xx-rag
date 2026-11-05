# TC397 + iLLD 知识库（em_rag）部署镜像
# 构建:  docker build -t tc397-rag .
# 运行:  docker compose up -d   (MCP stdio 由客户端拉起，容器主要用于索引与检索 CLI)
FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    # HuggingFace 直连被墙时走镜像
    HF_ENDPOINT=https://hf-mirror.com

# p7zip: 解压 iLLD CHM 手册;  curl/git: 拉取数据
RUN apt-get update && apt-get install -y --no-install-recommends \
        p7zip-full curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先装依赖（利用层缓存）
COPY requirements.txt .
RUN pip install -r requirements.txt "mcp>=1,<2"

# 拷贝 em_rag 源码（含本仓库修复补丁）
COPY src/ ./src/
COPY em_rag/ ./em_rag/
COPY scripts/ ./scripts/
COPY config.yaml .
COPY pyproject.toml .
RUN pip install -e .

# 数据获取与索引脚本
COPY deploy/setup_data.sh deploy/rebuild_index.sh ./deploy/
RUN chmod +x deploy/*.sh

# 数据目录（volume 挂载点：模型、索引库、原始数据）
RUN mkdir -p /app/models /app/data /app/.em_rag
VOLUME ["/app/models", "/app/data", "/app/.em_rag"]

# 默认入口：打印帮助；实际用法见 README
# 远程 MCP 模式覆盖 command:
#   command: ["python","-m","em_rag.mcp_http","--host","0.0.0.0","--port","8080"]
CMD ["python", "-m", "em_rag", "--help"]
