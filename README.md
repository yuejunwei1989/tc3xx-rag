# TC397 + iLLD 知识库（em_rag）

本地 RAG，覆盖 AURIX TC397 芯片手册与 iLLD 驱动库，通过 MCP 接入 Claude Code / Codex / OpenCode。

## 已索引内容

| 数据源 | 规模 | chunk 数 | 说明 |
|---|---|---|---|
| AURIX TC39x-B User Manual | 1159 页 | 2802 | TC397 器件专用附录（寄存器、外设差异） |
| AURIX TC3xx User Manual Part-1 | 2080 页 | 约 9800 | 平台通用：CPU、存储器、总线、DMA |
| AURIX TC3xx User Manual Part-2 | 3561 页 | 约 14400 | 平台通用：GTM、ADC、CAN、QSPI 等外设 |
| TriCore TC1.6.2 Core Architecture Vol.1 | 206 页 | 439 | 指令集、寄存器模型、寻址方式 |
| **TC39x BD-step Errata Sheet (v2.7)** | **308 页** | **465** | **硅片已知偏差清单：功能缺陷 / 应用提示 + Workaround** |
| **TC3xx HSM Quick Training** | **11 页** | **6** | **HSM 硬件能力概览（AES128/TRNG/PKC/HASH、独立 DFlash 密钥存储）** |
| iLLD 源码（TC3xx） | 1987 个 .c/.h | 1987 | 官方低层驱动库源码 |
| iLLD API 文档（CHM → MD） | 1667 个页面 | 1667 | Doxygen 生成的函数/结构体说明 |

**合计 2843 个文档、27178 个 chunk。** 手册总页数 7325 页（含勘误表与 HSM 培训）。

## 部署

### 环境要求

| 项目 | 最低 | 推荐 |
|---|---|---|
| CPU | 4 核 | 8 核 |
| 内存 | 8GB（索引手册时峰值约 3GB/进程） | 16GB |
| 磁盘 | 12GB | 20GB |
| Python | 3.11+ | 3.11 |
| 其他 | `git` `curl` `p7zip-full`（CHM 转换用） | — |

GPU 可选：有 4090 走 bge-m3 + reranker 路线，见 `deploy/gpu/`。

### 方式一：主机部署（不用 Docker）

```bash
git clone https://github.com/yuejunwei1989/tc3xx-rag.git
cd tc3xx-rag

# 1. 建 venv、装依赖、下载 ONNX 嵌入模型（~90MB）
#    传 "." 表示装在当前目录；不传会新建 ./tc397-rag 子目录
./deploy/install.sh .

# 2. 下载数据：5 份手册 PDF + iLLD 源码 + iLLD API 文档（~100MB、15-30 分钟）
./deploy/setup_data.sh

# 3. 建索引：手册分片 + iLLD 源码 + API 文档（首次 40-60 分钟）
./deploy/rebuild_index.sh

# 4. 验证
./.venv/bin/python -m src.cli search "QSPI baud rate configuration"
```

> 嵌入模型下载走 `deploy/download_model.sh`（优先 hf-mirror，避免直连超时白等）。单独重跑：`./deploy/download_model.sh models/all-MiniLM-L6-v2`
> **索引必须串行**：`rebuild_index.sh` 已按串行写，不要自己并发跑多个 `add`。

### 方式二：Docker

```bash
cd tc3xx-rag/deploy
docker compose build

# 首次初始化：下载数据 + 建索引（脚本用 --entrypoint bash 跑）
docker compose run --rm --entrypoint bash rag deploy/setup_data.sh
docker compose run --rm --entrypoint bash rag deploy/rebuild_index.sh

# 日常检索（参数直接跟在 rag 后面）
docker compose run --rm rag search "QSPI baud rate configuration"
docker compose run --rm rag list
docker compose run --rm rag remove <doc_id>
```

`docker-compose.yml` 挂了三个 volume（`rag_models` / `rag_data` / `rag_index`），容器重建不丢数据。
远程 MCP 模式用 `docker-compose.remote.yml`，复用同一批 volume，只暴露 HTTP 端口：

```bash
# 前置：先创建 volume（remote.yml 用的是 external volume，未创建会报 not found）
docker compose create rag

docker compose -f docker-compose.remote.yml up -d
curl http://localhost:8080/info     # 能力发现
```

> **构建加速**：Dockerfile 默认把 apt 和 pip 都指向腾讯云镜像（`DEBIAN_MIRROR` / `PIP_INDEX_URL` build-arg 可覆盖）。
> 不改这两项时，pymupdf（69MB）、onnxruntime 这些大包在受限网络下会卡住，实测 40 分钟仍无进展；换镜像后约 2 分钟完成。
>
> **模型已打进镜像**（90MB ONNX，构建时经 hf-mirror 下载）。所以 `docker compose run` 首次检索就能用，不需要额外跑 `install.sh`。
> 若构建时下载失败，容器启动后补执行：`docker compose run --rm --entrypoint bash rag deploy/download_model.sh`

### 部署耗时参考（实测）

| 步骤 | 耗时 | 说明 |
|---|---|---|
| `install.sh` | 3-5 分钟 | 主要耗在下载 ONNX 模型 |
| `setup_data.sh` | 15-30 分钟 | 取决于网络；CHM 70MB 最容易卡住 |
| `rebuild_index.sh` | 40-60 分钟 | 手册 PDF 占大头，每 300 页片约 45 秒 |

### 部署后接入 MCP

见下方[接入 Claude Code / Codex / OpenCode](#接入-claude-code--codex--opencode)，或 `deploy/serve_remote.sh` 起远程 SSE 服务供其他机器调用。

完整部署文档（GPU 路线、多 Agent 共享、镜像加速细节）：[`deploy/README.md`](deploy/README.md)

## 目录结构

```
/workspace/tc397-rag/
├── .venv/                       # Python 3.11 虚拟环境（已装好依赖）
├── .em_rag/
│   ├── config.yaml              # 工程配置（PDF 后端 / 分块 / 存储路径）
│   ├── chroma_db/               # 向量库（27178 条）
│   ├── fts.db                   # SQLite FTS5 全文索引
│   └── figures/                 # 手册页面截图（时序图/波形页）
├── models/all-MiniLM-L6-v2/     # ONNX 嵌入模型（384 维，本地推理）
├── data/
│   ├── documents/               # 手册 PDF + 勘误表（Part1/Part2/Errata 已按页切片）
│   ├── illd/                    # iLLD 源码
│   └── illd_api/                # iLLD API 文档（Markdown）
├── .mcp.json                    # MCP 配置（agent 直接读这个）
└── src/                         # em_rag 源码（已修复 2 处缺陷）
```

## 使用方法

### 命令行检索

```bash
cd /workspace/tc397-rag
./.venv/bin/python -m src.cli search "QSPI baud rate configuration"
./.venv/bin/python -m src.cli search "IfxQspi_SpiMaster_initModule"   # 代码符号精确查
./.venv/bin/python -m src.cli list                                # 已索引文档列表
./.venv/bin/python -m src.cli add <文件或目录>                     # 增量索引
```

### 删除文档

先查 `doc_id`（文件名去掉扩展名，空格转下划线），再按 `doc_id` 删除：

```bash
./.venv/bin/python -m src.cli list                       # 查 doc_id
./.venv/bin/python -m src.cli remove <doc_id>            # 删除
```

等价的便捷写法：

```bash
./deploy/add_docs.sh --remove <doc_id>
```

Agent 在对话中调用 MCP 工具 `remove_doc`，参数 `{"doc_id": "..."}`。

**删除会清掉什么：**

| 位置 | 操作 |
|---|---|
| Chroma 向量库 | 删除该 `doc_id` 的全部向量 |
| SQLite FTS5 | 删除对应 chunk 记录 |
| `data/documents/` 源 PDF | **保留**，需自行 `rm` |

**批量删除**（例：清掉所有勘误表切片）：

```bash
for d in $(./.venv/bin/python -m src.cli list | grep errata | awk '{print $2}'); do
  ./.venv/bin/python -m src.cli remove "$d"
done
```

删除后验证：

```bash
./.venv/bin/python -m src.cli list | wc -l                       # 文档数应减少
./.venv/bin/python -m src.cli search "<被删文档的关键词>" --top-k 3   # 应查不到
```

> ⚠️ **必须串行执行**，不要与其他 `add`/`remove` 并发——多进程写 Chroma 会损坏 HNSW 索引（查询时进程崩溃）。
> 删除不可撤销，恢复只能重新 `add` 一次（源 PDF 在即可）。
> 索引损坏时：`python -m src.cli doctor` 检查、`repair` 修复；严重时删掉 `chroma_db/<uuid>/` 目录让 Chroma 从 SQLite 重建。

### 接入 Claude Code / Codex / OpenCode

`.mcp.json` 内容（三个客户端通用格式）：

```json
{
  "mcpServers": {
    "em-rag": {
      "command": "/workspace/tc397-rag/.venv/bin/python",
      "args": ["-m", "em_rag.mcp_auto"],
      "cwd": "/workspace/tc397-rag"
    }
  }
}
```

- **Claude Code**：放在项目根目录，或用 `claude mcp add` 注册
- **Codex**：`~/.codex/config.toml` 加 `[mcp_servers.em-rag]`
- **OpenCode**：`~/.config/opencode/opencode.json` 的 `mcp` 段

暴露 4 个工具：`search_docs`（检索）、`list_docs`、`index_doc`、`remove_doc`。

## 实测检索效果

| 提问 | 命中文档 | 结果 |
|---|---|---|
| `QSPI baud rate configuration` | TC39x 手册 p.1032–1035 | 寄存器块 + 页面截图 |
| `CAN baud rate calculation prescaler` | iLLD CAN API | IfxCan_Can 初始化函数 |
| `GTM TOM PWM 频率` | iLLD PWM 驱动 | Pwm Functions / DataStructures / 用法 |
| `IfxCan_Can_setBaudrate` | iLLD 头文件 | 结构体定义（得分 1.0 → 0.83 递减） |
| `FlexRay_AI.103 Received messages not stored ...` | 勘误表 p.46 | 正文条目首位命中（编号加权生效） |
| `DMA_TC.067 double buffering buffer overflow workaround` | 勘误表 p.33 | Description / Workaround 全文 |
| `ADC_TC.086` | 勘误表 p.22 | 正文条目首位命中 |

### 查勘误表（硅片已知问题）

勘误表每条目结构固定为 **Description / Scope / Effects / Workaround**，概述表（第 4–18 页）列出全部编号。
检索时**带上编号或症状关键词**效果最好：

```bash
python -m src.cli search "DMA_TC.067 double buffering buffer overflow workaround"
python -m src.cli search "GETH_AI.001 errata"
python -m src.cli search "HSPDM 通信失败 勘误"   # 中文需配英文寄存器/模块名
```

编号命名规则：`模块_类别.序号`，类别 `TC`=功能缺陷（Functional deviation）、`AI`=应用提示（Application hint）、`H`/`P`=应用/参数偏差。
例：`DMA_TC.067`、`FlexRay_AI.103`、`GETH_TC.H003`。

### 关于 HSM 文档（重要限制）

**已覆盖**（可直接检索）：

| 来源 | 内容 | 规模 |
|---|---|---|
| TC3xx User Manual Part1 §6.5 | HSM Suspend、UCB_HSMCFG / UCB_HSM Interface Protection、HSM 相关 Flash 保护、UCB 配置序列 | 手册内 368 个 chunk 提到 HSM，其中 `UCB_HSMCFG` 32 处 |
| TC3xx HSM Quick Training（公开） | HSM 硬件能力：AES128、TRNG、PKC、SHA-224/256、独立 DFlash 密钥存储 | 11 页 |

**未覆盖**（需 myICP 权限，无法自动下载）：

- `HSM_TS_V2.0_Rev2.0` — **HSM 技术规范**（寄存器、指令集、服务调用接口，最核心）
- `AURIX-TC3xx_HSM-ES` — HSM 勘误表
- `AP32373` — HSM Demo 示例说明
- `AP32391` — 使用 HSM 实现安全启动
- HSM 相关 UCB 编程细节、HSM 固件升级流程

> HSM 在 myICP 上是**独立授权**（与 TC3xx 普通文档权限不同），需要单独申请。
> 申请入口：<https://www.infineon.com/cms/en/product/promopage/MyICP-platform-for-Microcontroller/>
> 审批通过后访问：`AURIX TC3xx/10 AURIX TC3xx HSM/`

**补齐方法**：拿到权限后下载 PDF，一条命令导入：

```bash
./deploy/add_myicp.sh ~/Downloads/HSM_TS_V2.0_Rev2.0.pdf
./deploy/add_myicp.sh --check      # 查看已导入的 HSM/Safety 文档
```

脚本会自动处理大 PDF 切片，导入后立即可被 MCP 客户端检索。

## 本次部署中修复的两个缺陷

1. **关键词检索得分恒为 1.0**（`src/store.py`）
   FTS 结果硬编码 `"distance": 0.0`，导致所有关键词命中并列第一、无法排序。已改为按 FTS5 BM25 rank 归一化到 `[0,1]`，现在得分能正确递减（0.696 → 0.663 → 0.651）。

2. **超大 PDF 索引静默失败**（OOM, EXIT=137）
   `_extract_tables` 用 pdfplumber 逐页抽取，2000+ 页时累积内存超 12GB 被系统杀死，且 `cmd_add` 捕获异常后仍计为成功。解决：把 Part1/Part2 按 300 页切片后分别索引（峰值内存降到 3GB）。

> 第 2 点只是绕过，根本修法是把 `pdfplumber.open` 移到循环外 + 流式处理。已在 `data/documents/` 保留切片版本作为稳定方案。

## 注意事项

- **中文提问建议带英文关键词**。手册是英文的，纯中文查询靠嵌入模型跨语言匹配，召回率不如中英混合。
- **手册更新后按“先删后加”处理**：`remove` 旧文档再 `add` 新文件（见[删除文档](#删除文档)）。
- **向量库不要多进程并发写**。本次部署中曾因并发写入导致 HNSW 索引损坏（查询时进程崩溃）；修复方式是删除 `chroma_db/<segment-id>/` 目录让 Chroma 从 SQLite 重建。增删操作请串行执行。
- 首次查询需加载 ONNX 模型和向量索引，约 3–5 秒；之后常驻内存。
