import Foundation

// MARK: - OpenAI-compatible

final class OpenAICompatibleProvider: LLMProvider {
    let config: ProviderConfig
    let apiKey: String

    init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var displayName: String { config.name }

    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        let url = try ProviderSupport.openAIChatURL(base: config.baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var messages: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in request.messages {
            let role = message.role == .assistant ? "assistant" : (message.role == .system ? "system" : "user")
            messages.append(["role": role, "content": message.content])
        }

        let body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in SSE.events(from: bytes) {
                        if event.data == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard
                            let data = event.data.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let choices = object["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String,
                           !text.isEmpty {
                            continuation.yield(.text(text))
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

// MARK: - Anthropic

final class AnthropicProvider: LLMProvider {
    let config: ProviderConfig
    let apiKey: String

    init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var displayName: String { config.name }

    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        let url = try ProviderSupport.anthropicURL(base: config.baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Anthropic takes system out of the messages array and has no `system`
        // role inside it.
        let messages: [[String: Any]] = request.messages
            .filter { $0.role != .system }
            .map { ["role": $0.role == .assistant ? "assistant" : "user", "content": $0.content] }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "stream": true
        ]
        if let system = request.system, !system.isEmpty {
            body["system"] = system
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in SSE.events(from: bytes) {
                        if event.name == "message_stop" {
                            continuation.finish()
                            return
                        }
                        guard
                            let data = event.data.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let type = object["type"] as? String,
                           type == "content_block_delta",
                           let delta = object["delta"] as? [String: Any],
                           let text = delta["text"] as? String,
                           !text.isEmpty {
                            continuation.yield(.text(text))
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

// MARK: - Gemini

final class GeminiProvider: LLMProvider {
    let config: ProviderConfig
    let apiKey: String

    init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var displayName: String { config.name }

    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        let model = ProviderSupport.geminiModelName(request.model)
        guard !model.isEmpty else {
            throw LLMError.invalidConfiguration("Gemini 模型名不能为空")
        }
        let base = ProviderSupport.stripTrailingSlash(config.baseURL)
        let root = base.hasSuffix("/v1beta") || base.hasSuffix("/v1") ? base : base + "/v1beta"
        guard let url = URL(string: "\(root)/models/\(model):streamGenerateContent?alt=sse") else {
            throw LLMError.invalidConfiguration("Base URL 无法解析：\(config.baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than ?key= so the key never lands in a URL log.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var contents: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            contents.append([
                "role": message.role == .assistant ? "model" : "user",
                "parts": [["text": message.content]]
            ])
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": request.temperature,
                "maxOutputTokens": request.maxTokens
            ]
        ]
        if let system = request.system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in SSE.events(from: bytes) {
                        guard
                            let data = event.data.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        guard
                            let candidates = object["candidates"] as? [[String: Any]],
                            let content = candidates.first?["content"] as? [String: Any],
                            let parts = content["parts"] as? [[String: Any]]
                        else { continue }

                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
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

// MARK: - Factory

enum ProviderFactory {
    static func make(config: ProviderConfig, apiKey: String) -> LLMProvider {
        switch config.kind {
        case .openAICompatible:
            return OpenAICompatibleProvider(config: config, apiKey: apiKey)
        case .anthropic:
            return AnthropicProvider(config: config, apiKey: apiKey)
        case .gemini:
            return GeminiProvider(config: config, apiKey: apiKey)
        }
    }
}

// MARK: - Connectivity check

enum ProviderHealth {
    /// Sends the smallest possible streaming request and stops at the first
    /// token. Using `stream` rather than a non-streaming ping means the check
    /// exercises exactly the code path a real message takes.
    static func check(config: ProviderConfig, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidConfiguration("Key 为空")
        }
        let provider = ProviderFactory.make(config: config, apiKey: apiKey)
        let request = LLMRequest(
            model: config.model,
            system: nil,
            messages: [LLMMessage(role: .user, content: "ping")],
            temperature: 0,
            maxTokens: 8
        )
        let stream = try await provider.stream(request)
        var output = ""
        for try await event in stream {
            if case .text(let text) = event {
                output += text
            }
            if output.count >= 4 { break }
        }
        return output.isEmpty ? "连接成功（模型未返回文本）" : "连接成功：\(output)"
    }
}
