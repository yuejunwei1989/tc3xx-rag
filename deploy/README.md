# TC397 + iLLD 知识库 — 部署指南

本地 RAG 知识库（基于 [em_rag](https://github.com/LeoKemp223/em_rag)，含 2 处修复补丁），
覆盖 AURIX TC397 芯片手册（7006 页）+ **BD-step 勘误表（308 页）** + iLLD 驱动库（1987 个源文件 + 1667 页 API 文档），
通过 MCP 接入 Claude Code / Codex / OpenCode。

## 内容清单

```
deploy/
├── Dockerfile          # 容器镜像（python3.11-slim + p7zip）
├── docker-compose.yml  # volume 持久化 models/data/index
├── install.sh          # 主机部署：venv + 依赖 + 嵌入模型
├── setup_data.sh       # 数据获取：手册PDF + 勘误表 + iLLD + CHM转MD + 大PDF切片
├── rebuild_index.sh    # 索引重建（串行，防并发损坏）
├── add_docs.sh         # 手动添加文档/代码（大 PDF 自动切片，--list/--remove）
├── serve_remote.sh     # 远程 MCP 服务（HTTP+SSE，供其他 Agent 接入）
├── docker-compose.remote.yml  # 远程 MCP 容器（复用同一组 volume）
├── gpu/
│   ├── docker-compose.gpu.yml  # Infinity: bge-m3 + bge-reranker-v2-m3（可选 Qwen2.5-VL-7B）
│   └── setup_gpu.sh            # 一键切换 GPU 路线并全量重索引
└── README.md           # 本文档
```

## GPU 路线（4090 24GB，可选）

CPU 路线部署完成并验证后，一条命令升级：

```bash
cd deploy/gpu && chmod +x setup_gpu.sh && ./setup_gpu.sh
```

脚本自动完成：启动 Infinity（bge-m3 嵌入 + bge-reranker 精排，OpenAI 兼容端口 7997）
→ 切换 `config.yaml`（provider=openai_compatible，chunk 放宽到 2000 token 利用 8k 上下文）
→ 清空并全量重索引（GPU 批量嵌入约 5–10 分钟）。

| 项 | CPU（MiniLM） | GPU（bge-m3 + reranker） |
|---|---|---|
| 中文查询 | 跨语言靠运气 | 原生中英混合 |
| 表格完整性 | 1000 token 截断 | 2000 token，寄存器表整页 |
| 精排 | 无 | bge-reranker-v2-m3（检索代码已内置接线，`retrieval.rerank_url` 配置即启用，服务不可用时静默回退原序） |
| 索引耗时 | 40–60 min | 5–10 min |

回退 CPU 路线：恢复 `config.yaml.cpu.*` 备份后跑 `rebuild_index.sh`。

可选视觉问答（时序图/引脚图精读）：取消 `docker-compose.gpu.yml` 里 `vlm` 段注释
（Qwen2.5-VL-7B，端口 7998），与嵌入模型同卡共占约 21GB。

## 手动添加新文档和代码

三种方式按场景选用：

### 1. 便捷脚本（推荐给人工操作）

```bash
./deploy/add_docs.sh ~/my_notes/register_map.md     # 单文件
./deploy/add_docs.sh ~/sdk/driver_src/              # 整目录（递归）
./deploy/add_docs.sh ~/datasheets/big_manual.pdf    # >400 页自动切片防 OOM
./deploy/add_docs.sh --list                         # 查看已索引
./deploy/add_docs.sh --remove <doc_id>              # 移除
```

支持格式：`.pdf .md .txt .docx .epub` + 代码 `.h .c .hpp .hh .hxx .cpp .cc .cxx .s .asm .inc .i .ino`。

### 2. MCP 工具（Agent 在对话中添加）

Agent 调用 `index_doc` 工具，`path` 可以是**单文件、目录或 URL**：

```json
{"name": "index_doc", "arguments": {"path": "/path/to/new_driver_dir/"}}
```

- 目录：递归展开（跳过 .git/.venv 等），单文件逐个索引并汇报成败，上限 500 个
- 大 PDF（>400 页）：直接拒绝并返回切片命令提示，防止 OOM 假成功
- 已存在同 doc_id 文档：自动替换（先删旧 chunks 再写入）

### 3. CLI

```bash
python -m src.cli add <path>     # 同 add_docs.sh 核心（无切片保护，大 PDF 慎用）
```

> 所有写操作（无论哪条路径）请**串行执行**，不要多进程同时添加——并发写 Chroma 会损坏 HNSW 索引。

## 远程 MCP：让其他 Agent / 其他机器接入

stdio 模式只能本机由客户端拉起进程。要让**别的 Agent、别的机器**访问芯片知识库，用远程模式：

```bash
# 主机方式
./deploy/serve_remote.sh 8080

# 容器方式（复用已建好的索引 volume）
docker compose -f deploy/docker-compose.remote.yml up -d
```

客户端只需一个 URL：

```json
{ "mcpServers": { "tc397-rag": { "url": "http://<服务器IP>:8080/sse" } } }
```

### 三个端点

| 端点 | 用途 |
|---|---|
| `GET /sse` | MCP 传输通道（客户端连这个） |
| `GET /info` | **能力发现**：返回工具清单 + 数据覆盖范围（7006 页手册 / 308 页勘误表 / 1987 文件 SDK / 2842 文档索引），其他 Agent 可先探测再决定是否调用 |
| `GET /health` | 健康检查，供 K8s/负载均衡探活 |
| `GET /.well-known/mcp.json` | MCP 发现入口（部分客户端自动探测） |

`/info` 返回示例：
```json
{"name":"tc397-rag","coverage":{"manuals":"...7006 页","sdk":"...1987 文件",
  "indexed_documents":2842,"indexed_chunks":27172},
 "tools":[{"name":"search_docs"},{"name":"list_docs"},{"name":"index_doc"},{"name":"remove_doc"}]}
```

### 多 Agent 共享注意事项

- **只读共享即可**：`search_docs` / `list_docs` 可安全并发（Chroma 只读查询无锁问题）。
- **写操作要串行**：`index_doc` / `remove_doc` 会写 Chroma，多 Agent 同时调用可能损坏 HNSW 索引（已实测过）。生产环境建议**只对内部可信 Agent 暴露写工具**，或按下方方式关掉。
- 目前无鉴权。跨网段暴露请在前面加 Nginx（basic auth / mTLS）或只监听内网：
  `./deploy/serve_remote.sh` 默认 `0.0.0.0`，内网部署可改为绑 `127.0.0.1` + 反代。

## 方式一：Docker 部署（推荐）

```bash
cd tc397-rag/deploy
docker compose build

# 首次：下载数据 + 建索引（40-60 分钟，只需一次）
docker compose run --rm rag setup          # 见下方"容器内流程"

# 验证
docker compose run --rm rag search "QSPI baud rate configuration"
```

容器内首次流程等价于：
```bash
/app/deploy/setup_data.sh && /app/deploy/rebuild_index.sh
```

### MCP 客户端接入（容器版）

`.mcp.json`（Claude Code 项目级 / OpenCode 通用）：

```json
{
  "mcpServers": {
    "em-rag": {
      "command": "docker",
      "args": ["compose", "-f", "/path/to/deploy/docker-compose.yml",
               "run", "--rm", "rag", "-m", "em_rag.mcp_auto"],
      "cwd": "/path/to/tc397-rag"
    }
  }
}
```

Codex（`~/.codex/config.toml`）：
```toml
[mcp_servers.em-rag]
command = "docker"
args = ["compose", "-f", "/path/to/deploy/docker-compose.yml", "run", "--rm", "rag", "-m", "em_rag.mcp_auto"]
```

## 方式二：主机部署

```bash
# 前提: python3.11, git, curl, 7z (apt install p7zip-full)
./deploy/install.sh ~/tc397-rag
cd ~/tc397-rag
./deploy/setup_data.sh      # 15-30 分钟，取决于网络
./deploy/rebuild_index.sh   # 40-60 分钟
```

## 数据来源（全部公开）

| 数据 | 来源 | 大小 |
|---|---|---|
| AURIX TC39x-B User Manual | infineon.com 官方直链 | 6.4MB / 1159 页 |
| AURIX TC3xx User Manual Part-1/2 | infineon.com 官方直链 | 71MB / 5641 页 |
| TriCore TC1.6.2 Arch Manual Vol.1 | infineon.com 官方直链 | 6.2MB / 206 页 |
| iLLD 源码 | github.com/Infineon/illd_release_tc3x (sparse checkout src/BaseSw/iLLD/TC3xx) | 39MB / 1987 文件 |
| iLLD API 文档 | 同仓库 doc/iLLD-UM-TC3xx.chm → 7z 解压 → BS4 转 MD | 20MB / 1667 文件 |
| 嵌入模型 | sentence-transformers/all-MiniLM-L6-v2 (ONNX)，HF 被墙自动走 hf-mirror | 90MB |

## 已含的修复补丁（相对上游 em_rag）

1. **FTS 得分恒 1.0**（`src/store.py`）：关键词命中原本硬编码 `distance=0.0` 无法排序，
   已改为按 BM25 rank 归一化。
2. **mcp 版本锁定**：`mcp>=1,<2`（mcp 2.x 改名 FastMCP→Server，server 入口会崩）。
3. **大 PDF OOM 规避**（`deploy/setup_data.sh` 第 4 步）：2000+ 页 PDF 用 pdfplumber
   抽表会累积 >12GB 内存被 OOM-kill，且上游 `cmd_add` 静默吞错仍报"成功"。
   方案：300 页切片后分片索引。

## 运维备忘

| 事项 | 操作 |
|---|---|
| 增量加文档 | `python -m src.cli add <path>`（串行！） |
| 删除文档 | `python -m src.cli remove <doc_id>` |
| 环境自检 | `python -m src.cli doctor` |
| Chroma 查询崩溃 | HNSW 段损坏（并发写导致）：删 `.em_rag/chroma_db/<uuid>/` 目录，重启自动从 SQLite 重建 |
| 中文检索 | 建议中英混合（`GTM TOM PWM 频率`），纯中文召回率低 |
| 换嵌入模型 | 改 `config.yaml` embedding 段 + 重新全量索引 |

## 验证清单（部署后逐项跑）

```bash
python -m src.cli doctor            # model.onnx: ok / sqlite.fts5: ok
python -m src.cli list | wc -l      # ~2842 文档
python -m src.cli search "QSPI baud rate configuration"   # 命中 TC39x 手册 p.1032-1035
python -m src.cli search "IfxCan_Can_setBaudrate"         # 命中 iLLD 头文件
python -m src.cli search "GTM TOM PWM 频率"               # 中英混合命中 PWM 驱动
```
