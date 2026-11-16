import Foundation

// MARK: - Request / event types

struct LLMMessage: Codable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

struct LLMRequest {
    var model: String
    var system: String?
    var messages: [LLMMessage]
    var temperature: Double = 0.7
    var maxTokens: Int = 2048
}

enum LLMEvent {
    case text(String)
}

enum LLMError: Error, LocalizedError {
    case invalidConfiguration(String)
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return "HTTP \(status)：\(preview.isEmpty ? "(空响应)" : preview)"
        case .decoding(let message):
            return "响应解析失败：\(message)"
        }
    }
}

protocol LLMProvider {
    var displayName: String { get }
    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error>
}

// MARK: - Transport

enum HTTPClient {
    /// One shared session. `waitsForConnectivity` is off on purpose: a LAN
    /// orchestration server that is not running should fail in seconds, not
    /// hang until the resource timeout.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip"]
        return URLSession(configuration: configuration)
    }()
}

// MARK: - SSE

enum SSE {
    struct Event {
        var name: String?
        var data: String
    }

    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pendingName: String?
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            pendingName = nil
                            continue
                        }
                        if line.hasPrefix(":") {
                            continue
                        }
                        if line.hasPrefix("event:") {
                            pendingName = String(line.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let data = String(line.dropFirst(5))
                                .trimmingCharacters(in: .whitespaces)
                            continuation.yield(Event(name: pendingName, data: data))
                            pendingName = nil
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared request helpers

enum ProviderSupport {
    static func stripTrailingSlash(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    static func url(_ raw: String, suffix: String) throws -> URL {
        let base = stripTrailingSlash(raw)
        guard !base.isEmpty else {
            throw LLMError.invalidConfiguration("Base URL 不能为空")
        }
        guard let url = URL(string: base + suffix) else {
            throw LLMError.invalidConfiguration("Base URL 无法解析：\(raw)")
        }
        return url
    }

    static func openAIChatURL(base: String) throws -> URL {
        let cleaned = stripTrailingSlash(base)
        if cleaned.hasSuffix("/chat/completions") {
            guard let url = URL(string: cleaned) else {
                throw LLMError.invalidConfiguration("Base URL 无法解析：\(base)")
            }
            return url
        }
        return try url(cleaned, suffix: "/chat/completions")
    }

    static func openAIEmbeddingURL(base: String) throws -> URL {
        let cleaned = stripTrailingSlash(base)
        if cleaned.hasSuffix("/embeddings") {
            guard let url = URL(string: cleaned) else {
                throw LLMError.invalidConfiguration("Base URL 无法解析：\(base)")
            }
            return url
        }
        if cleaned.hasSuffix("/chat/completions") {
            let trimmed = String(cleaned.dropLast("/chat/completions".count))
            return try url(trimmed, suffix: "/embeddings")
        }
        return try url(cleaned, suffix: "/embeddings")
    }

    static func anthropicURL(base: String) throws -> URL {
        let cleaned = stripTrailingSlash(base)
        if cleaned.hasSuffix("/messages") {
            guard let url = URL(string: cleaned) else {
                throw LLMError.invalidConfiguration("Base URL 无法解析：\(base)")
            }
            return url
        }
        if cleaned.hasSuffix("/v1") {
            return try url(cleaned, suffix: "/messages")
        }
        return try url(cleaned, suffix: "/v1/messages")
    }

    static func geminiModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
    }

    static func validate(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidConfiguration("收到非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            do {
                for try await line in bytes.lines {
                    body += line
                    if body.count > 4000 { break }
                }
            } catch {
                // The status code is the useful part; a broken body is not.
            }
            throw LLMError.http(status: http.statusCode, body: body)
        }
    }
}
