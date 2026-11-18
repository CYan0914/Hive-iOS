import Foundation

struct MCPServerConfig: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var url: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }

    private static let storageKey = "hive.mcpServers.v1"

    static func load() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ servers: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

struct MCPRemoteTool {
    let name: String
    let description: String
    let schema: ToolSchema
}

enum MCPError: Error, LocalizedError {
    case invalidURL(String)
    case http(status: Int, body: String)
    case rpc(code: Int, message: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "无效的 MCP 地址：\(raw)"
        case .http(let status, let body):
            let preview = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "MCP HTTP \(status)：\(preview)"
        case .rpc(let code, let message):
            return "MCP 错误 \(code)：\(message)"
        case .malformed(let detail):
            return "MCP 响应异常：\(detail)"
        }
    }
}

/// A JSON-RPC 2.0 envelope. Hand-rolled rather than pulled from a package:
/// the client only needs three methods, and the SDK would add a dependency
/// that has to survive CI on a machine with no Xcode.
struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: [String: Any]

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        // `[String: Any]` needs JSONSerialization; Any is not Encodable.
        let data = try JSONSerialization.data(withJSONObject: params)
        let object = try JSONSerialization.jsonObject(with: data)
        try container.encode(AnyCodable(object), forKey: .params)
    }
}

/// Minimal Encodable wrapper so arbitrary JSON can ride inside a Codable
/// envelope.
struct AnyCodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else {
                try container.encode(number.doubleValue)
            }
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyCodable.init))
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encode(String(describing: value))
        }
    }
}
