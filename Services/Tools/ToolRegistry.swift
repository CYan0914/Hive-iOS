import Foundation

protocol AgentTool {
    var definition: ToolDefinition { get }
    func execute(call: ToolCall) async -> ToolResult
}

enum ToolRegistry {
    static let builtins: [AgentTool] = [HTTPRequestTool(), WebTextTool()]

    /// Filled by AppEnvironment after it connects to the configured MCP
    /// servers. Empty until then, which is also the correct default when the
    /// user has configured none.
    static var mcp: [AgentTool] = []

    static var all: [AgentTool] { builtins + mcp }

    /// Permission is per-agent and lives on the profile. An agent with an empty
    /// list simply never sees the tools, which is the cheapest possible
    /// sandbox: the model cannot ask for what it does not know about.
    static func tools(for profile: AgentProfile?) -> [AgentTool] {
        guard let profile else { return [] }
        return all.filter { profile.allowedTools.contains($0.definition.name) }
    }

    static func find(_ name: String) -> AgentTool? {
        all.first { $0.definition.name == name }
    }

    /// Provider function names allow only `[A-Za-z0-9_-]` and are capped at 64
    /// characters; a server whose name contains spaces must not produce a name
    /// the API rejects at request time.
    static func mcpToolName(server: MCPServerConfig, tool: String) -> String {
        let raw = "mcp_\(server.name)_\(tool)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = String(raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return String(sanitized.prefix(64))
    }
}

// MARK: - Networking

enum ToolNetworking {
    struct Response {
        var status: Int
        var contentType: String
        var body: String
    }

    static func fetch(_ raw: String) async throws -> Response {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw ToolError.invalidURL(raw)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Hive/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/json,text/plain;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await HTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "unknown"

        // decoding:as: tolerates a truncated multi-byte sequence, which
        // `String(data:encoding:)` would refuse and turn into "no output".
        let body = String(decoding: data, as: UTF8.self)
        return Response(status: status, contentType: contentType, body: body)
    }
}

enum ToolError: Error, LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "无效的 URL：\(raw.isEmpty ? "(空)" : raw)"
        }
    }
}

// MARK: - http_request

struct HTTPRequestTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "http_request",
            description: "用 GET 请求一个 URL，返回状态码、Content-Type 和正文（最多 8000 字符）。适合调用 JSON API 或读取原始响应。",
            schema: .strings(
                ["url": "完整 URL，必须带 http:// 或 https://"],
                required: ["url"]
            )
        )
    }

    func execute(call: ToolCall) async -> ToolResult {
        let raw = call.arguments["url"] ?? ""
        do {
            let response = try await ToolNetworking.fetch(raw)
            let body = String(response.body.prefix(8000))
            return ToolResult(
                callID: call.id,
                name: call.name,
                output: "HTTP \(response.status)\nContent-Type: \(response.contentType)\n\n\(body)",
                isError: !(200..<300).contains(response.status)
            )
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

// MARK: - extract_text

struct WebTextTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "extract_text",
            description: "抓取网页并去掉 HTML 标签，返回可读正文（最多 8000 字符）。适合读文章、文档、说明页。",
            schema: .strings(
                ["url": "完整 URL，必须带 http:// 或 https://"],
                required: ["url"]
            )
        )
    }

    func execute(call: ToolCall) async -> ToolResult {
        let raw = call.arguments["url"] ?? ""
        do {
            let response = try await ToolNetworking.fetch(raw)
            let text = HTMLText.extract(response.body)
            let clipped = String(text.prefix(8000))
            return ToolResult(
                callID: call.id,
                name: call.name,
                output: "HTTP \(response.status)\n\n\(clipped.isEmpty ? "(没有提取到正文)" : clipped)",
                isError: !(200..<300).contains(response.status) || text.isEmpty
            )
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

// MARK: - HTML to text

enum HTMLText {
    static func extract(_ html: String) -> String {
        // Cap before running regexes. A multi-megabyte page with pathological
        // nesting is a main-thread hang, and this runs on the main actor.
        var text = String(html.prefix(200_000))

        text = text.replacingOccurrences(
            of: "(?is)<script[^>]*>.*?</script>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<style[^>]*>.*?</style>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<head[^>]*>.*?</head>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?s)<[^>]+>",
            with: "\n",
            options: .regularExpression
        )

        text = decodeEntities(text)

        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ]
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
