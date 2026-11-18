import Foundation

/// MCP over Streamable HTTP (2025-03-26).
///
/// Only the three methods the app needs: initialize, tools/list, tools/call.
/// The stdio transport is deliberately absent — iOS cannot spawn a child
/// process, so a stdio-only server is simply not connectable from this client.
final class MCPClient {
    let config: MCPServerConfig
    private var sessionID: String?
    private var nextID = 0

    init(config: MCPServerConfig) {
        self.config = config
    }

    private var endpoint: URL? {
        let raw = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    // MARK: - Protocol

    func initialize() async throws {
        _ = try await send(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Hive", "version": "0.1.0"]
            ],
            captureSession: true
        )
        try await notify(method: "notifications/initialized")
    }

    func listTools() async throws -> [MCPRemoteTool] {
        let result = try await send(method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }

        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            return MCPRemoteTool(
                name: name,
                description: tool["description"] as? String ?? "",
                schema: Self.flattenSchema(tool["inputSchema"] as? [String: Any])
            )
        }
    }

    func callTool(name: String, arguments: [String: String]) async throws -> String {
        let result = try await send(
            method: "tools/call",
            params: ["name": name, "arguments": arguments]
        )
        return Self.text(from: result)
    }

    // MARK: - Transport

    private func send(
        method: String,
        params: [String: Any],
        captureSession: Bool = false
    ) async throws -> [String: Any] {
        guard let endpoint else { throw MCPError.invalidURL(config.url) }

        nextID += 1
        let request = JSONRPCRequest(id: nextID, method: method, params: params)
        let body = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await HTTPClient.session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.malformed("非 HTTP 响应")
        }
        if captureSession, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let payload = try Self.jsonPayload(from: data, contentType: contentType)
        guard let object = payload as? [String: Any] else {
            throw MCPError.malformed("响应不是 JSON 对象")
        }
        if let error = object["error"] as? [String: Any] {
            throw MCPError.rpc(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "unknown"
            )
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func notify(method: String) async throws {
        guard let endpoint else { throw MCPError.invalidURL(config.url) }

        let request = JSONRPCRequest(id: nil, method: method, params: [:])
        let body = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        _ = try? await HTTPClient.session.data(for: urlRequest)
    }

    // MARK: - Parsing

    private static func jsonPayload(from data: Data, contentType: String) throws -> Any {
        if contentType.contains("text/event-stream") {
            // A Streamable HTTP reply may be one SSE frame carrying the
            // JSON-RPC response. Take the last frame that parses.
            let text = String(decoding: data, as: UTF8.self)
            var last: Any?
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let lineData = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) else {
                    continue
                }
                last = object
            }
            guard let last else { throw MCPError.malformed("SSE 里没有 JSON 数据") }
            return last
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw MCPError.malformed("无法解析 JSON")
        }
        return object
    }

    /// The app's schema model carries flat string arguments only. A nested MCP
    /// schema would need a recursive walker in all three provider adapters for
    /// very little gain, so non-string properties are dropped here and the
    /// model is told about the ones that survive.
    private static func flattenSchema(_ raw: [String: Any]?) -> ToolSchema {
        guard let raw, let properties = raw["properties"] as? [String: Any] else {
            return ToolSchema(type: "object", properties: [:], required: [])
        }

        var mapped: [String: ToolProperty] = [:]
        for (key, value) in properties {
            guard let property = value as? [String: Any],
                  property["type"] as? String == "string" else { continue }
            mapped[key] = ToolProperty(
                type: "string",
                description: property["description"] as? String ?? ""
            )
        }

        let required = (raw["required"] as? [String] ?? []).filter { mapped[$0] != nil }
        return ToolSchema(type: "object", properties: mapped, required: required)
    }

    private static func text(from result: [String: Any]) -> String {
        if let content = result["content"] as? [[String: Any]] {
            let parts = content.compactMap { item -> String? in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }

        if let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return "（工具没有返回文本内容）"
    }
}

// MARK: - Tool adapter

struct MCPToolAdapter: AgentTool {
    let definition: ToolDefinition
    let client: MCPClient
    let remoteName: String

    func execute(call: ToolCall) async -> ToolResult {
        do {
            let output = try await client.callTool(name: remoteName, arguments: call.arguments)
            return ToolResult(callID: call.id, name: call.name, output: output, isError: false)
        } catch {
            return ToolResult(
                callID: call.id,
                name: call.name,
                output: error.localizedDescription,
                isError: true
            )
        }
    }
}
