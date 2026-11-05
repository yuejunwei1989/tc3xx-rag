"""远程 MCP 服务：通过 HTTP + SSE 暴露同一套芯片知识库工具。

用途：让**其他机器/其他 Agent** 通过 URL 接入，而不是 stdio 拉起本地进程。
与 stdio 版共用 app 实例和全部工具实现（见 src/mcp_server.py）。

启动：
    python -m em_rag.mcp_http --host 0.0.0.0 --port 8080

客户端（远程 Agent）配置：
    {
      "mcpServers": {
        "tc397-rag": { "url": "http://<服务器IP>:8080/sse" }
      }
    }

端点：
    GET  /sse         SSE 流（MCP 传输通道）
    POST /messages/  客户端回传 JSON-RPC
    GET  /health     健康检查
    GET  /info       服务元信息 + 工具清单（给 Agent 做能力发现）
    GET  /.well-known/mcp.json   MCP 发现入口（部分客户端会自动探测）
"""

from __future__ import annotations

import argparse
import json
import sys

import uvicorn
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from mcp.server.sse import SseServerTransport

from src import mcp_server as core


def build_app() -> Starlette:
    """把 core.app（FastMCP/低层 Server）挂到 Starlette 的 SSE 传输上。"""
    sse = SseServerTransport("/messages/")

    async def handle_sse(request):
        async with sse.connect_sse(
            request.scope, request.receive, request._send
        ) as (read_stream, write_stream):
            await core.app.run(
                read_stream, write_stream, core.app.create_initialization_options()
            )

    async def health(request):
        return JSONResponse({"status": "ok", "server": "tc397-rag-mcp"})

    async def info(request):
        """能力发现：返回工具清单与数据覆盖范围，供其他 Agent 决定是否调用。"""
        try:
            # 低层 Server 通过 request_handlers 暴露真实处理函数；
            # app.list_tools() 本身是装饰器，不能直接调用。
            from mcp.types import ListToolsRequest
            handler = core.app.request_handlers.get(ListToolsRequest)
            res = await handler(ListToolsRequest(method="tools/list"))
            tools = [
                {
                    "name": t.name,
                    "description": t.description,
                    "inputSchema": t.inputSchema,
                }
                for t in res.root.tools
            ]
        except Exception as exc:  # 发现接口不应让服务不可用
            tools = [{"error": f"{type(exc).__name__}: {exc}"}]
        try:
            stats = _index_stats()
        except Exception:
            stats = {}
        return JSONResponse({
            "name": "tc397-rag",
            "version": "1.0",
            "description": "AURIX TC397 芯片手册 + iLLD 驱动库知识库（本地 RAG）",
            "coverage": {
                "manuals": "TC39x-B / TC3xx Part1-2 / TriCore TC1.6.2 架构，共 7006 页",
                "sdk": "iLLD TC3xx 源码 1987 文件 + API 文档 1667 页",
                **stats,
            },
            "transport": {"type": "sse", "endpoint": "/sse", "messages": "/messages/"},
            "tools": tools,
        })

    async def well_known(request):
        return JSONResponse({
            "name": "tc397-rag",
            "description": "AURIX TC397 芯片手册与 iLLD 库检索",
            "transport": {"type": "sse", "url": "/sse"},
        })

    routes = [
        Route("/health", health),
        Route("/info", info),
        # MCP 发现入口：部分客户端按惯例探测此路径
        Route("/.well-known/mcp.json", well_known),
        Route("/sse", handle_sse),
        Mount("/messages/", app=sse.handle_post_message),
    ]
    return Starlette(routes=routes)


def _index_stats() -> dict:
    import sqlite3
    from src.config import load_config

    cfg = core._config or load_config(core._config_path)
    con = sqlite3.connect(cfg.storage.fts_path)
    try:
        docs = con.execute("SELECT COUNT(DISTINCT doc_id) FROM chunks").fetchone()[0]
        chunks = con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    finally:
        con.close()
    return {"indexed_documents": docs, "indexed_chunks": chunks}


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="em_rag 远程 MCP 服务 (HTTP/SSE)")
    p.add_argument("--config", default=None, help="配置文件路径（默认自动发现 .em_rag/config.yaml）")
    p.add_argument("--project-root", default=None)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    # 复用 stdio 版的配置发现逻辑（.em_rag/config.yaml 向上查找）
    from src.mcp_auto import find_project_config, repo_default_config

    if args.config:
        from pathlib import Path
        cfg_path = Path(args.config).expanduser().resolve()
        root = Path(args.project_root).expanduser().resolve() if args.project_root else cfg_path.parent.parent
    else:
        found_cfg, found_root = find_project_config(args.project_root)
        cfg_path, root = (found_cfg, found_root) if found_cfg else (repo_default_config(), None)

    core.configure(str(cfg_path), str(root) if root else None)
    core._ensure_stores()
    app = build_app()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
