"""MCP Server：暴露 RAG 工具给 Claude Code"""

import argparse
import json
import sys
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent


app = Server("em-rag")

_config = None
_classifier = None
_chunker = None
_embedder = None
_vector_store = None
_fts_store = None
_retriever = None
_stores_initialized = False
_pipeline_initialized = False
_config_path = "config.yaml"
_project_root = Path.cwd()


def configure(config_path: str = "config.yaml", project_root: str = None):
    global _config_path, _project_root
    _config_path = config_path
    if project_root:
        _project_root = Path(project_root).expanduser().resolve()
    else:
        _project_root = Path(config_path).expanduser().resolve().parent


def _ensure_stores():
    global _config, _vector_store, _fts_store, _stores_initialized

    if _stores_initialized:
        return

    from src.config import load_config
    from src.store import VectorStore, FTSStore

    _config = load_config(_config_path)
    _vector_store = VectorStore(_config.storage)
    _fts_store = FTSStore(_config.storage)
    _stores_initialized = True


def _ensure_pipeline():
    global _config, _classifier, _chunker, _embedder
    global _vector_store, _fts_store, _retriever, _pipeline_initialized

    if _pipeline_initialized:
        return

    _ensure_stores()

    from src.element_classifier import ElementClassifier
    from src.chunker import Chunker
    from src.embedder import create_embedder
    from src.retriever import Retriever

    _classifier = ElementClassifier()
    _chunker = Chunker(_config.chunking)
    _embedder = create_embedder(_config.embedding)
    _retriever = Retriever(_config.retrieval, _embedder, _vector_store, _fts_store)
    _pipeline_initialized = True


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="search_docs",
            description=(
                "搜索当前工程已索引的嵌入式技术文档。回答芯片、寄存器、"
                "数据手册、SDK API、源码实现或板级行为问题前应优先调用；"
                "支持寄存器名精确查询和语义查询。不要用它索引新文件。"
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "搜索内容，如 'SPI_CR1 寄存器位域' 或 'GPIO 初始化步骤'",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "返回结果数量",
                        "default": 5,
                    },
                    "doc_filter": {
                        "type": "string",
                        "description": "限定搜索的文档 ID（可选）",
                    },
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="list_docs",
            description=(
                "列出当前工程 RAG 中所有已索引文档。若不确定工程是否已有索引，"
                "或需要 doc_filter 的文档 ID，应先调用此工具。"
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="index_doc",
            description=(
                "将用户明确指定的文件、目录或 URL 索引到当前工程 RAG。"
                "只有在用户要求新增、重建、刷新或补充索引时才调用；"
                "普通问答不要自动触发索引。"
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "文档文件路径或 URL",
                    },
                },
                "required": ["path"],
            },
        ),
        Tool(
            name="remove_doc",
            description=(
                "从当前工程 RAG 索引中移除指定文档。此操作会删除该文档的"
                "向量和全文索引；只有在用户明确要求删除时才调用。"
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "doc_id": {
                        "type": "string",
                        "description": "文档 ID",
                    },
                },
                "required": ["doc_id"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "search_docs":
        return await _handle_search(arguments)
    elif name == "list_docs":
        return await _handle_list()
    elif name == "index_doc":
        return await _handle_index(arguments)
    elif name == "remove_doc":
        return await _handle_remove(arguments)
    else:
        return [TextContent(type="text", text=f"未知工具: {name}")]


async def _handle_search(args: dict) -> list[TextContent]:
    _ensure_pipeline()
    query = args["query"]
    top_k = args.get("top_k", 5)
    doc_filter = args.get("doc_filter")

    results = _retriever.search(query, top_k=top_k, doc_filter=doc_filter)

    if not results:
        return [TextContent(type="text", text="未找到相关文档内容。")]

    output_parts = []
    for i, r in enumerate(results, 1):
        header = f"[{i}] {r.context_chain} (p.{r.page + 1}, {r.element_type}, {r.source})"
        image_lines = []
        if r.related_images:
            image_lines.append("\nRelated images:")
            for image in r.related_images:
                asset = image.get("asset_type", "image")
                confidence = image.get("confidence")
                suffix = f" conf={confidence:.2f}" if isinstance(confidence, (int, float)) else ""
                image_lines.append(f"- [{asset}] {image.get('image_path')}{suffix}")
                if image.get("summary"):
                    image_lines.append(f"  summary: {image['summary']}")
        images_text = "\n".join(image_lines)
        expanded_lines = []
        if r.expanded_context:
            expanded_lines.append("\nExpanded context:")
            for ctx in r.expanded_context[:3]:
                preview = ctx["content"]
                if len(preview) > 500:
                    preview = preview[:500] + "\n... (truncated)"
                expanded_lines.append(
                    f"- p.{ctx['page'] + 1} {ctx['element_type']} "
                    f"{ctx['context_chain']}\n{preview}"
                )
        expanded_text = "\n".join(expanded_lines)
        output_parts.append(f"{header}\n{r.content}{images_text}{expanded_text}")

    return [TextContent(type="text", text="\n\n---\n\n".join(output_parts))]


async def _handle_list() -> list[TextContent]:
    _ensure_stores()
    docs = _vector_store.list_docs()
    if not docs:
        return [TextContent(type="text", text="暂无已索引文档。")]
    return [TextContent(type="text", text="已索引文档:\n" + "\n".join(f"  - {d}" for d in docs))]


async def _handle_index(args: dict) -> list[TextContent]:
    _ensure_pipeline()
    path = args["path"]
    is_url = path.startswith(("http://", "https://"))
    resolved_path = path if is_url else _resolve_doc_path(path)

    if not is_url and not Path(resolved_path).exists():
        return [TextContent(type="text", text=f"文件不存在: {path}")]

    # 目录：递归展开为受支持文件后逐个索引（供 Agent 手动添加整目录代码/文档）
    if not is_url and Path(resolved_path).is_dir():
        from src.cli import SUPPORTED_EXTENSIONS
        SKIP_DIRS = {".git", ".venv", ".em_rag", "__pycache__", "node_modules", "data"}
        targets = [
            str(p) for p in sorted(Path(resolved_path).rglob("*"))
            if p.is_file() and p.suffix.lower() in SUPPORTED_EXTENSIONS
            and not (set(p.parts) & SKIP_DIRS)
        ]
        if not targets:
            return [TextContent(type="text", text=f"目录中未找到受支持文件: {path}")]
        if len(targets) > 500:
            return [TextContent(type="text", text=f"目录文件过多({len(targets)})，请分批添加或使用 CLI: python -m em_rag add")]
        results = [f"索引目录 {path}（{len(targets)} 个文件）:"]
        ok = 0
        for t in targets:
            try:
                n = await _index_single_file(t)
                ok += 1
                results.append(f"  OK {Path(t).name} ({n} chunks)")
            except Exception as exc:
                results.append(f"  FAIL {Path(t).name}: {type(exc).__name__}: {exc}")
        results.append(f"完成: 成功 {ok}, 失败 {len(targets) - ok}")
        return [TextContent(type="text", text="\n".join(results))]

    # 单文件（含 URL）：大 PDF 提示切片，避免 OOM
    if not is_url and path.lower().endswith(".pdf"):
        try:
            import fitz
            if fitz.open(resolved_path).page_count > 400:
                return [TextContent(type="text", text=(
                    f"PDF 超过 400 页，直接索引会内存溢出（pdfplumber 逐页抽表约 10MB/页）。\n"
                    f"请先切片: python -c \"import fitz;d0=fitz.open('{resolved_path}');"
                    f"d=fitz.open();d.insert_pdf(d0,from_page=0,to_page=299);d.save('slice1.pdf')\"\n"
                    f"或使用 deploy/setup_data.sh 的切片流程。"))]
        except Exception:
            pass

    try:
        n = await _index_single_file(resolved_path, url=path if is_url else None)
        doc_id = Path(resolved_path).stem.lower().replace(" ", "_") if not is_url else "url_doc"
        return [TextContent(type="text", text=f"索引完成: {path} ({n} chunks, doc_id={doc_id})")]
    except Exception as exc:
        return [TextContent(type="text", text=f"索引失败: {path}\n{type(exc).__name__}: {exc}")]


async def _index_single_file(resolved_path: str, url: str = None) -> int:
    """索引单个文件，返回 chunk 数。供单文件与目录两条路径复用。"""
    is_url = url is not None
    if is_url:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        doc_id = (parsed.netloc + parsed.path).strip("/").replace("/", "_").lower()
    else:
        doc_id = Path(resolved_path).stem.lower().replace(" ", "_")

    from src.parsers import create_parser
    parser = create_parser(resolved_path, _config.parsing, _config.figures)
    elements = parser.parse(resolved_path)
    elements = _classifier.classify(elements)
    chunks = _chunker.chunk(elements)

    from src.embedder import embedding_batch_size

    texts = [c.retrieval_text for c in chunks]
    embeddings = []
    batch_size = embedding_batch_size(_config.embedding)
    for i in range(0, len(texts), batch_size):
        embeddings.extend(_embedder.embed(texts[i:i + batch_size]))

    _vector_store.remove_doc(doc_id)
    _fts_store.remove_doc(doc_id)
    _vector_store.add_chunks(chunks, embeddings, doc_id)
    _fts_store.add_chunks(chunks, doc_id)

    return len(chunks)


async def _handle_remove(args: dict) -> list[TextContent]:
    _ensure_stores()
    doc_id = args["doc_id"]
    _vector_store.remove_doc(doc_id)
    _fts_store.remove_doc(doc_id)
    return [TextContent(type="text", text=f"已移除文档: {doc_id}")]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


def _resolve_doc_path(path: str) -> str:
    doc_path = Path(path).expanduser()
    if doc_path.is_absolute():
        return str(doc_path)
    return str((_project_root / doc_path).resolve())


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="em_rag MCP server")
    parser.add_argument("--config", default="config.yaml", help="配置文件路径")
    parser.add_argument(
        "--project-root",
        help="业务工程根目录；index_doc 的相对路径按该目录解析",
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    import asyncio
    args = parse_args()
    configure(args.config, args.project_root)
    asyncio.run(main())
