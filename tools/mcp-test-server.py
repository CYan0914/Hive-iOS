#!/usr/bin/env python3
"""Minimal MCP server over Streamable HTTP, for testing the Hive client.

No dependencies. Run it on the same LAN as the phone:

    python tools/mcp-test-server.py --port 8765

Then add http://<your-lan-ip>:8765/mcp in Hive settings and press 测试连接.
It exposes two tools: echo and add.

This exists because the client cannot be exercised without a server, and a
real MCP server may need credentials, a Mac, or a container. This one needs
nothing but Python.
"""

import argparse
import json
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-03-26"

TOOLS = [
    {
        "name": "echo",
        "description": "原样返回你输入的文本",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "要回显的文本"}
            },
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": "把两个整数相加",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "string", "description": "第一个整数"},
                "b": {"type": "string", "description": "第二个整数"},
            },
            "required": ["a", "b"],
        },
    },
]


def call_tool(name, arguments):
    if name == "echo":
        return [{"type": "text", "text": str(arguments.get("text", ""))}]
    if name == "add":
        try:
            total = int(arguments.get("a", 0)) + int(arguments.get("b", 0))
        except (TypeError, ValueError):
            return [{"type": "text", "text": "参数不是整数"}]
        return [{"type": "text", "text": str(total)}]
    return [{"type": "text", "text": f"未知工具：{name}"}]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[mcp]", fmt % args)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return

        method = message.get("method")
        message_id = message.get("id")

        # Notifications carry no id and expect no body.
        if message_id is None and method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if method == "initialize":
            session = uuid.uuid4().hex
            self.respond(
                {
                    "jsonrpc": "2.0",
                    "id": message_id,
                    "result": {
                        "protocolVersion": PROTOCOL_VERSION,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "hive-test-server", "version": "0.1.0"},
                    },
                },
                session=session,
            )
            return

        if method == "tools/list":
            self.respond({"jsonrpc": "2.0", "id": message_id, "result": {"tools": TOOLS}})
            return

        if method == "tools/call":
            params = message.get("params") or {}
            content = call_tool(params.get("name", ""), params.get("arguments") or {})
            self.respond(
                {"jsonrpc": "2.0", "id": message_id, "result": {"content": content}}
            )
            return

        if method == "ping":
            self.respond({"jsonrpc": "2.0", "id": message_id, "result": {}})
            return

        self.respond(
            {
                "jsonrpc": "2.0",
                "id": message_id,
                "error": {"code": -32601, "message": f"method not found: {method}"},
            }
        )

    def respond(self, payload, session=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if session:
            self.send_header("Mcp-Session-Id", session)
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"MCP test server on http://127.0.0.1:{args.port}/mcp")
    server.serve_forever()


if __name__ == "__main__":
    main()
