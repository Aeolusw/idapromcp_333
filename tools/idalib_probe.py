from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import Any

from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def _get_attr(obj: Any, *names: str) -> Any:
    for name in names:
        if hasattr(obj, name):
            return getattr(obj, name)
    return None


def _extract_metadata(call_result: Any) -> dict[str, Any]:
    structured = _get_attr(call_result, "structuredContent", "structured_content")
    if isinstance(structured, dict):
        return structured

    for item in _get_attr(call_result, "content") or []:
        text = getattr(item, "text", None)
        if not text:
            continue
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed

    return {}


async def _probe(url: str, timeout_seconds: float) -> dict[str, Any]:
    async with streamablehttp_client(
        url,
        timeout=timeout_seconds,
        sse_read_timeout=timeout_seconds,
    ) as (read_stream, write_stream, get_session_id):
        async with ClientSession(read_stream, write_stream) as session:
            initialize_result = await session.initialize()
            tools_result = await session.list_tools()
            metadata_result = await session.call_tool("get_metadata")
            metadata = _extract_metadata(metadata_result)

            return {
                "ok": not bool(_get_attr(metadata_result, "isError", "is_error")),
                "url": url,
                "session_id": get_session_id(),
                "server_name": _get_attr(
                    _get_attr(initialize_result, "serverInfo", "server_info"),
                    "name",
                ),
                "server_version": _get_attr(
                    _get_attr(initialize_result, "serverInfo", "server_info"),
                    "version",
                ),
                "protocol_version": _get_attr(
                    initialize_result,
                    "protocolVersion",
                    "protocol_version",
                ),
                "tool_count": len(_get_attr(tools_result, "tools") or []),
                "module": metadata.get("module"),
                "path": metadata.get("path"),
                "metadata": metadata,
            }


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe a streamable-http idalib MCP server")
    parser.add_argument("--url", required=True, help="Full MCP endpoint URL, for example http://127.0.0.1:8746/mcp")
    parser.add_argument("--timeout-seconds", type=float, default=30.0, help="Per-request timeout in seconds")
    args = parser.parse_args()

    try:
        result = asyncio.run(_probe(args.url, args.timeout_seconds))
    except Exception as exc:  # pragma: no cover - best effort diagnostics for shell usage
        result = {
            "ok": False,
            "url": args.url,
            "error": f"{type(exc).__name__}: {exc}",
        }
        print(json.dumps(result, ensure_ascii=False))
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
