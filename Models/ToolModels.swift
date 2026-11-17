import Foundation

// MARK: - Declarations

struct ToolProperty: Codable, Equatable {
    var type: String
    var description: String
}

/// JSON Schema subset. Only flat string arguments are needed by the P2 tools;
/// nested objects would add a schema walker to every provider adapter for no
/// benefit yet.
struct ToolSchema: Codable, Equatable {
    var type: String
    var properties: [String: ToolProperty]
    var required: [String]

    static func strings(_ properties: [String: String], required: [String] = []) -> ToolSchema {
        var mapped: [String: ToolProperty] = [:]
        for (key, description) in properties {
            mapped[key] = ToolProperty(type: "string", description: description)
        }
        return ToolSchema(type: "object", properties: mapped, required: required)
    }
}

struct ToolDefinition: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let schema: ToolSchema
}

// MARK: - Calls and results

struct ToolCall: Codable, Equatable {
    let id: String
    let name: String
    /// Flattened to strings on purpose: both P2 tools take one URL. A model
    /// that sends a number gets `String(describing:)`, not a decode failure.
    let arguments: [String: String]
}

struct ToolResult: Equatable {
    let callID: String
    let name: String
    let output: String
    let isError: Bool
}

// MARK: - Persistence envelope

/// How a step result is stored. P1 wrote raw text; anything without the
/// envelope decodes as text, so old rows keep working.
enum StepPayloadCodec {
    private struct Envelope: Codable {
        struct Call: Codable {
            var id: String
            var name: String
            var arguments: [String: String]
        }

        var kind: String
        var text: String?
        var calls: [Call]?
    }

    static func encodeText(_ text: String) -> String {
        encode(Envelope(kind: "text", text: text, calls: nil)) ?? text
    }

    static func encodeCalls(_ calls: [ToolCall]) -> String {
        let mapped = calls.map { Envelope.Call(id: $0.id, name: $0.name, arguments: $0.arguments) }
        return encode(Envelope(kind: "toolCalls", text: nil, calls: mapped)) ?? "{}"
    }

    static func decodeCalls(_ raw: String) -> [ToolCall]? {
        guard let envelope = decode(raw), envelope.kind == "toolCalls",
              let calls = envelope.calls else { return nil }
        return calls.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
    }

    static func decodeText(_ raw: String) -> String? {
        guard let envelope = decode(raw), envelope.kind == "text" else { return nil }
        return envelope.text
    }

    /// A row that is not an envelope is P1 text (or a plan's JSON), so return
    /// it unchanged rather than swallowing it.
    static func textOrRaw(_ raw: String) -> String {
        decodeText(raw) ?? raw
    }

    private static func encode(_ envelope: Envelope) -> String? {
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ raw: String) -> Envelope? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}
