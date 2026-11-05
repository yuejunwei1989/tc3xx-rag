# TC397 + iLLD 知识库（em_rag）

本地 RAG，覆盖 AURIX TC397 芯片手册与 iLLD 驱动库，通过 MCP 接入 Claude Code / Codex / OpenCode。

## 已索引内容

| 数据源 | 规模 | chunk 数 | 说明 |
|---|---|---|---|
| AURIX TC39x-B User Manual | 1159 页 | 2802 | TC397 器件专用附录（寄存器、外设差异） |
| AURIX TC3xx User Manual Part-1 | 2080 页 | 约 9800 | 平台通用：CPU、存储器、总线、DMA |
| AURIX TC3xx User Manual Part-2 | 3561 页 | 约 14400 | 平台通用：GTM、ADC、CAN、QSPI 等外设 |
| TriCore TC1.6.2 Core Architecture Vol.1 | 206 页 | 439 | 指令集、寄存器模型、寻址方式 |
| iLLD 源码（TC3xx） | 1987 个 .c/.h | 1987 | 官方低层驱动库源码 |
| iLLD API 文档（CHM → MD） | 1667 个页面 | 1667 | Doxygen 生成的函数/结构体说明 |

**合计 2840 个文档、26707 个 chunk。** 手册总页数 7006 页。

## 目录结构

```
/workspace/tc397-rag/
├── .venv/                       # Python 3.11 虚拟环境（已装好依赖）
├── .em_rag/
│   ├── config.yaml              # 工程配置（PDF 后端 / 分块 / 存储路径）
│   ├── chroma_db/               # 向量库（26707 条）
│   ├── fts.db                   # SQLite FTS5 全文索引
│   └── figures/                 # 手册页面截图（时序图/波形页）
├── models/all-MiniLM-L6-v2/     # ONNX 嵌入模型（384 维，本地推理）
├── data/
│   ├── documents/               # 手册 PDF（Part1/Part2 已按 300 页切片）
│   ├── illd/                    # iLLD 源码
│   └── illd_api/                # iLLD API 文档（Markdown）
├── .mcp.json                    # MCP 配置（agent 直接读这个）
└── src/                         # em_rag 源码（已修复 2 处缺陷）
```

## 使用方法

### 命令行检索

```bash
cd /workspace/tc397-rag
./.venv/bin/python -m em_rag search "QSPI baud rate configuration"
./.venv/bin/python -m em_rag search "IfxCan_Can_setBaudrate"     # 代码符号精确查
./.venv/bin/python -m em_rag list                                # 已索引文档列表
./.venv/bin/python -m em_rag add <文件或目录>                     # 增量索引
```

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

## 本次部署中修复的两个缺陷

1. **关键词检索得分恒为 1.0**（`src/store.py`）
   FTS 结果硬编码 `"distance": 0.0`，导致所有关键词命中并列第一、无法排序。已改为按 FTS5 BM25 rank 归一化到 `[0,1]`，现在得分能正确递减（0.696 → 0.663 → 0.651）。

2. **超大 PDF 索引静默失败**（OOM, EXIT=137）
   `_extract_tables` 用 pdfplumber 逐页抽取，2000+ 页时累积内存超 12GB 被系统杀死，且 `cmd_add` 捕获异常后仍计为成功。解决：把 Part1/Part2 按 300 页切片后分别索引（峰值内存降到 3GB）。

> 第 2 点只是绕过，根本修法是把 `pdfplumber.open` 移到循环外 + 流式处理。已在 `data/documents/` 保留切片版本作为稳定方案。

## 注意事项

- **中文提问建议带英文关键词**。手册是英文的，纯中文查询靠嵌入模型跨语言匹配，召回率不如中英混合。
- **PPT/PDF 手册更新后需重建索引**：`remove` 旧文档再 `add` 新文件。
- **向量库不要多进程并发写**。本次部署中曾因并发写入导致 HNSW 索引损坏（查询时进程崩溃）；修复方式是删除 `chroma_db/<segment-id>/` 目录让 Chroma 从 SQLite 重建。增量索引请串行执行。
- 首次查询需加载 ONNX 模型和向量索引，约 3–5 秒；之后常驻内存。
