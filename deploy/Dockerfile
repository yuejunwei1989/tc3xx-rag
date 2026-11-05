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
# 默认走腾讯云 Debian 镜像（deb.debian.org 在国内/受限网络下可能极慢，可用 --build-arg 覆盖）
ARG DEBIAN_MIRROR=mirrors.tencent.com
RUN sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
RUN apt-get update && apt-get install -y --no-install-recommends \
        p7zip-full curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先装依赖（利用层缓存）
# pip 默认走官方 PyPI，国内/受限网络下大包（pymupdf 69MB、onnxruntime）
# 经常卡死，默认换腾讯云镜像；海外构建可 --build-arg PIP_INDEX_URL=https://pypi.org/simple
ARG PIP_INDEX_URL=https://mirrors.tencent.com/pypi/simple/
ARG PIP_TRUSTED_HOST=mirrors.tencent.com
COPY requirements.txt .
RUN pip install --index-url "$PIP_INDEX_URL" --trusted-host "$PIP_TRUSTED_HOST" \
        -r requirements.txt "mcp>=1,<2"

# 拷贝 em_rag 源码（含本仓库修复补丁）
COPY src/ ./src/
COPY em_rag/ ./em_rag/
COPY scripts/ ./scripts/
COPY config.yaml .
COPY pyproject.toml .
RUN pip install --index-url "$PIP_INDEX_URL" --trusted-host "$PIP_TRUSTED_HOST" -e .

# 数据获取与索引脚本
COPY deploy/setup_data.sh deploy/rebuild_index.sh deploy/add_docs.sh deploy/add_myicp.sh deploy/download_model.sh ./deploy/
RUN chmod +x deploy/*.sh

# 预下载嵌入模型（90MB）到镜像内。
# 不预置的话，models 卷为空时搜索会直接报 "ONNX 模型未找到"，
# 而 Docker 流程里没有 install.sh 这一步，用户很难定位。
# 下载失败不阻断构建：运行时仍可用 ./deploy/download_model.sh 补下。
RUN ./deploy/download_model.sh /app/models/all-MiniLM-L6-v2 \
    || echo "!! 模型预下载失败，构建后请手动执行 deploy/download_model.sh"

# 数据目录（volume 挂载点：模型、索引库、原始数据）
RUN mkdir -p /app/models /app/data /app/.em_rag
VOLUME ["/app/models", "/app/data", "/app/.em_rag"]

# em_rag 子命令入口。
# 用 ENTRYPOINT 承载解释器，`docker compose run rag search "..."` 时
# docker 会把 search 等参数**追加**到 entrypoint 后面，等价于
# `python -m em_rag search "..."`；若只在 CMD 里写，run 会整段替换 CMD 导致
# 把 search 当可执行文件（实测报 exec: "search": executable file not found）。
# 跑 shell 脚本时用 --entrypoint bash 覆盖。
# 远程 MCP 模式覆盖 command：
#   command: ["mcp_http", "--host", "0.0.0.0", "--port", "8080"]  (见 deploy/README.md)
ENTRYPOINT ["python", "-m", "em_rag"]
CMD ["--help"]
