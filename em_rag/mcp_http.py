"""远程 MCP 入口：``python -m em_rag.mcp_http``（HTTP + SSE）。"""

from src.mcp_http import main


def run():
    main()


if __name__ == "__main__":
    run()
