import Foundation

// MARK: - Session

struct ChatSession: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Message

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

enum MessageStatus: String, Codable {
    case complete
    case streaming
    case failed
    case interrupted
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let sessionID: String
    var role: MessageRole
    var content: String
    var status: MessageStatus
    let createdAt: Date
    var runID: String?

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        role: MessageRole,
        content: String,
        status: MessageStatus = .complete,
        createdAt: Date = Date(),
        runID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
        self.runID = runID
    }
}

// MARK: - Provider

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-5-5"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    /// Where the key goes. Used by the settings screen to explain the field.
    var keyHint: String {
        switch self {
        case .openAICompatible: return "以 sk- 开头的 Key，或中转站 Key"
        case .anthropic: return "Anthropic Console 的 API Key"
        case .gemini: return "Google AI Studio 的 API Key"
        }
    }
}

struct ProviderConfig: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int

    /// The key itself never lives in SQLite. This is the Keychain item name.
    var keychainKey: String { "hive.provider.\(id)" }

    init(
        id: String = UUID().uuidString,
        name: String = "默认模型",
        kind: ProviderKind = .openAICompatible,
        baseURL: String = ProviderKind.openAICompatible.defaultBaseURL,
        model: String = ProviderKind.openAICompatible.defaultModel,
        temperature: Double = 0.7,
        maxTokens: Int = 2048
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Memory

enum MemoryLayer: String, Codable, CaseIterable, Identifiable {
    /// Shared structured state for the current task. P1 writes here.
    case blackboard
    /// Raw conversation turns, retrieved by similarity.
    case episodic
    /// Distilled facts and preferences. Survives sessions.
    case semantic
    /// Per-agent working notes. Never injected into another agent's context.
    case scratchpad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blackboard: return "黑板"
        case .episodic: return "情节记忆"
        case .semantic: return "语义记忆"
        case .scratchpad: return "草稿区"
        }
    }
}

struct MemoryRecord: Identifiable, Codable, Equatable {
    let id: String
    var layer: MemoryLayer
    var sessionID: String?
    var content: String
    var importance: Double
    var embeddingModel: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        layer: MemoryLayer,
        sessionID: String? = nil,
        content: String,
        importance: Double = 0.5,
        embeddingModel: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.layer = layer
        self.sessionID = sessionID
        self.content = content
        self.importance = importance
        self.embeddingModel = embeddingModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Run / Step (the resumable state machine)

enum RunState: String, Codable {
    case pending
    case executing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    var isResumable: Bool { !isTerminal }

    var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .executing: return "执行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

enum StepKind: String, Codable {
    case llm
    case tool
    case memory
    case finish

    var displayName: String {
        switch self {
        case .llm: return "模型调用"
        case .tool: return "工具调用"
        case .memory: return "记忆写入"
        case .finish: return "结束"
        }
    }
}

enum StepState: String, Codable {
    case pending
    case running
    case done
    case failed

    var displayName: String {
        switch self {
        case .pending: return "待执行"
        case .running: return "执行中"
        case .done: return "完成"
        case .failed: return "失败"
        }
    }
}

struct AgentRun: Identifiable, Codable, Equatable {
    let id: String
    let sessionID: String
    let agentName: String
    var goal: String
    var state: RunState
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        agentName: String = "管家",
        goal: String,
        state: RunState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentName = agentName
        self.goal = goal
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AgentStep: Identifiable, Codable, Equatable {
    let id: String
    let runID: String
    let seq: Int
    var kind: StepKind
    var state: StepState
    /// Request snapshot, JSON. Replayed verbatim when a run is resumed.
    var payload: String
    var result: String?
    var error: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        runID: String,
        seq: Int,
        kind: StepKind,
        state: StepState = .pending,
        payload: String,
        result: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.seq = seq
        self.kind = kind
        self.state = state
        self.payload = payload
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Everything needed to re-run an interrupted LLM step after the app was
/// suspended or killed. Stored as JSON in `steps.payload`.
struct StepPayload: Codable {
    var userText: String
    var providerID: String
    var model: String
    var historyLimit: Int

    init(userText: String, providerID: String, model: String, historyLimit: Int = 20) {
        self.userText = userText
        self.providerID = providerID
        self.model = model
        self.historyLimit = historyLimit
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode(_ raw: String) -> StepPayload? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StepPayload.self, from: data)
    }
}
