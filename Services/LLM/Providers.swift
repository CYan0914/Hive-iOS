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

    // MARK: - Encoding

    private func encodedMessages(_ request: LLMRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }

        for message in request.messages {
            switch message.role {
            case .tool:
                messages.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "content": message.content
                ])
            case .assistant where !message.toolCalls.isEmpty:
                messages.append([
                    "role": "assistant",
                    "content": message.content,
                    "tool_calls": message.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": OpenAICompatibleProvider.argumentsJSON(call.arguments)
                            ]
                        ] as [String: Any]
                    }
                ])
            default:
                let role: String
                switch message.role {
                case .system: role = "system"
                case .assistant: role = "assistant"
                default: role = "user"
                }
                messages.append(["role": role, "content": message.content])
            }
        }
        return messages
    }

    private static func toolPayload(_ tool: ToolDefinition) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, value) in tool.schema.properties {
            properties[key] = ["type": value.type, "description": value.description]
        }
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": tool.schema.type,
                    "properties": properties,
                    "required": tool.schema.required
                ]
            ]
        ]
    }

    private static func argumentsJSON(_ arguments: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func parseArguments(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    func stream(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        let url = try ProviderSupport.openAIChatURL(base: config.baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let messages = encodedMessages(request)
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { OpenAICompatibleProvider.toolPayload($0) }
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Tool call fragments arrive across chunks: id and name
                    // once, arguments in pieces. Keyed by `index` because more
                    // than one call can be in flight.
                    var toolAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

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
                           let delta = choices.first?["delta"] as? [String: Any] {
                            if let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                                for fragment in fragments {
                                    let index = fragment["index"] as? Int ?? 0
                                    var accumulator = toolAccumulators[index] ?? (id: "", name: "", arguments: "")
                                    if let id = fragment["id"] as? String, !id.isEmpty {
                                        accumulator.id = id
                                    }
                                    if let function = fragment["function"] as? [String: Any] {
                                        if let name = function["name"] as? String, !name.isEmpty {
                                            accumulator.name = name
                                        }
                                        if let arguments = function["arguments"] as? String {
                                            accumulator.arguments += arguments
                                        }
                                    }
                                    toolAccumulators[index] = accumulator
                                }
                            }
                        }
                    }

                    let calls = toolAccumulators.keys.sorted().compactMap { index -> ToolCall? in
                        guard let accumulator = toolAccumulators[index],
                              !accumulator.name.isEmpty else { return nil }
                        return ToolCall(
                            id: accumulator.id.isEmpty ? UUID().uuidString : accumulator.id,
                            name: accumulator.name,
                            arguments: OpenAICompatibleProvider.parseArguments(accumulator.arguments)
                        )
                    }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls))
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

    // MARK: - Encoding

    /// Anthropic expresses tool use as content blocks, not as a parallel
    /// `tool_calls` field, and it rejects two consecutive user turns — so
    /// several tool results have to be folded into one user message.
    private static func encodedMessages(_ request: LLMRequest) -> [[String: Any]] {
        var result: [[String: Any]] = []
        let messages = request.messages
        var index = 0

        while index < messages.count {
            let message = messages[index]

            if message.role == .tool {
                var blocks: [[String: Any]] = []
                while index < messages.count, messages[index].role == .tool {
                    let toolMessage = messages[index]
                    blocks.append([
                        "type": "tool_result",
                        "tool_use_id": toolMessage.toolCallID ?? "",
                        "content": toolMessage.content
                    ])
                    index += 1
                }
                result.append(["role": "user", "content": blocks])
                continue
            }

            if message.role == .assistant, !message.toolCalls.isEmpty {
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty {
                    blocks.append(["type": "text", "text": message.content])
                }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments
                    ])
                }
                result.append(["role": "assistant", "content": blocks])
                index += 1
                continue
            }

            if message.role != .system {
                result.append([
                    "role": message.role == .assistant ? "assistant" : "user",
                    "content": message.content
                ])
            }
            index += 1
        }

        return result
    }

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
        let messages = AnthropicProvider.encodedMessages(request)

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
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": ProviderSupport.schemaDictionary(tool.schema)
                ] as [String: Any]
            }
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Tool use streams as: content_block_start (id + name),
                    // input_json_delta fragments, content_block_stop.
                    var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]

                    for try await event in SSE.events(from: bytes) {
                        if event.name == "message_stop" { break }
                        guard
                            let data = event.data.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            let type = object["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_start":
                            let blockIndex = object["index"] as? Int ?? 0
                            if let block = object["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use" {
                                toolBlocks[blockIndex] = (
                                    id: block["id"] as? String ?? "",
                                    name: block["name"] as? String ?? "",
                                    json: ""
                                )
                            }
                        case "content_block_delta":
                            guard let delta = object["delta"] as? [String: Any] else { continue }
                            if let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if delta["type"] as? String == "input_json_delta",
                               let partial = delta["partial_json"] as? String {
                                let blockIndex = object["index"] as? Int ?? 0
                                if var block = toolBlocks[blockIndex] {
                                    block.json += partial
                                    toolBlocks[blockIndex] = block
                                }
                            }
                        default:
                            break
                        }
                    }

                    let calls = toolBlocks.keys.sorted().compactMap { key -> ToolCall? in
                        guard let block = toolBlocks[key], !block.name.isEmpty else { return nil }
                        return ToolCall(
                            id: block.id.isEmpty ? UUID().uuidString : block.id,
                            name: block.name,
                            arguments: ProviderSupport.parseArguments(block.json)
                        )
                    }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls))
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

    // MARK: - Encoding

    private static func encodedContents(_ request: LLMRequest) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in request.messages where message.role != .system {
            if message.role == .tool {
                // Gemini keys the response by function name, which is why
                // LLMMessage carries `toolName` separately from `toolCallID`.
                result.append([
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "name": message.toolName ?? "",
                            "response": ["result": message.content]
                        ]
                    ]]
                ])
                continue
            }

            if message.role == .assistant, !message.toolCalls.isEmpty {
                var parts: [[String: Any]] = []
                if !message.content.isEmpty {
                    parts.append(["text": message.content])
                }
                for call in message.toolCalls {
                    parts.append([
                        "functionCall": [
                            "name": call.name,
                            "args": call.arguments
                        ]
                    ])
                }
                result.append(["role": "model", "parts": parts])
                continue
            }

            result.append([
                "role": message.role == .assistant ? "model" : "user",
                "parts": [["text": message.content]]
            ])
        }

        return result
    }

    private static func schemaDictionary(_ schema: ToolSchema) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, value) in schema.properties {
            properties[key] = [
                "type": value.type.uppercased(),
                "description": value.description
            ]
        }
        return [
            "type": schema.type.uppercased(),
            "properties": properties,
            "required": schema.required
        ]
    }

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

        let contents = GeminiProvider.encodedContents(request)

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
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": GeminiProvider.schemaDictionary(tool.schema)
                    ] as [String: Any]
                }
            ]]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await HTTPClient.session.bytes(for: urlRequest)
        try await ProviderSupport.validate(response: response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var collectedCalls: [ToolCall] = []

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
                            if let functionCall = part["functionCall"] as? [String: Any],
                               let name = functionCall["name"] as? String, !name.isEmpty {
                                let rawArguments = functionCall["args"] as? [String: Any] ?? [:]
                                var arguments: [String: String] = [:]
                                for (key, value) in rawArguments {
                                    arguments[key] = value as? String ?? String(describing: value)
                                }
                                collectedCalls.append(ToolCall(
                                    id: UUID().uuidString,
                                    name: name,
                                    arguments: arguments
                                ))
                            }
                        }
                    }
                    if !collectedCalls.isEmpty {
                        continuation.yield(.toolCalls(collectedCalls))
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
