import Foundation

struct AgentProfile: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var role: String
    /// One line the planner reads. The full system prompt is far too long to
    /// put in the roster.
    var summary: String
    var systemPrompt: String
    var providerID: String?
    var model: String?
    var isBuiltin: Bool
    /// Tool names this agent may use. Empty means "no tools", which is a
    /// permission, not a bug.
    var allowedTools: [String]

    init(
        id: String,
        name: String,
        role: String,
        summary: String,
        systemPrompt: String,
        providerID: String? = nil,
        model: String? = nil,
        isBuiltin: Bool,
        allowedTools: [String]
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.summary = summary
        self.systemPrompt = systemPrompt
        self.providerID = providerID
        self.model = model
        self.isBuiltin = isBuiltin
        self.allowedTools = allowedTools
    }
}

extension AgentProfile {
    static let supervisor = AgentProfile(
        id: "supervisor",
        name: "管家",
        role: "supervisor",
        summary: "总管，负责拆解任务、派活和汇总",
        systemPrompt: "",
        isBuiltin: true,
        allowedTools: ["http_request", "extract_text"]
    )

    static let builtins: [AgentProfile] = [
        AgentProfile(
            id: "researcher",
            name: "研究员",
            role: "researcher",
            summary: "整理事实和信息，可以联网查资料",
            systemPrompt: """
            你是一名研究员。你的职责是整理与任务相关的事实、线索和已知信息。

            要求：
            - 需要外部信息时使用工具，不要凭记忆编造数据、来源、日期
            - 工具失败或没有信息时，明确说"未能获取"
            - 用紧凑的要点输出，不要写寒暄或过程描述
            """,
            isBuiltin: true,
            allowedTools: ["http_request", "extract_text"]
        ),
        AgentProfile(
            id: "writer",
            name: "写手",
            role: "writer",
            summary: "撰写和改写文字",
            systemPrompt: """
            你是一名写手。根据收到的指令和共享黑板上的材料，写出清晰、紧凑的成稿。

            要求：
            - 只用给定材料支持的事实，不补充没有依据的细节
            - 先给结果，再给必要的解释
            - 不要提及"黑板""子机器人"或内部流程
            """,
            isBuiltin: true,
            allowedTools: []
        ),
        AgentProfile(
            id: "critic",
            name: "审稿人",
            role: "critic",
            summary: "挑错和给修改建议",
            systemPrompt: """
            你是一名审稿人。检查收到内容的事实错误、逻辑漏洞、表达问题，给出具体、可执行的修改建议。

            要求：
            - 指出问题时说明位置和原因
            - 不要重写全文，只给修改意见
            - 没有问题就直说"没有发现明显问题"
            """,
            isBuiltin: true,
            allowedTools: []
        )
    ]

    // MARK: - Custom agents

    private static let customStorageKey = "hive.customAgents.v1"

    /// Loaded once at launch by AppEnvironment. Kept as a static so the
    /// planner and the parser see the same roster without threading a store
    /// through every call site.
    static var custom: [AgentProfile] = []

    static var all: [AgentProfile] { builtins + custom }

    static func find(_ id: String) -> AgentProfile? {
        if id == supervisor.id { return supervisor }
        return all.first { $0.id == id }
    }

    static func loadCustom() -> [AgentProfile] {
        guard let data = UserDefaults.standard.data(forKey: customStorageKey),
              let decoded = try? JSONDecoder().decode([AgentProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    static func saveCustom(_ agents: [AgentProfile]) {
        custom = agents
        guard let data = try? JSONEncoder().encode(agents) else { return }
        UserDefaults.standard.set(data, forKey: customStorageKey)
    }
}

/// One unit of work handed to one sub-agent. `id` is assigned by the parser
/// (`task-0`, `task-1`, …) rather than by the model, so it is stable across a
/// resume — the model may reword, the index will not.
struct PlannedTask: Identifiable, Codable, Equatable {
    let id: String
    var agentID: String
    var instruction: String
}

struct AgentPlan: Equatable {
    var rationale: String
    var tasks: [PlannedTask]
}

struct BlackboardEntry: Equatable {
    let key: String
    let value: String
    let author: String
    let updatedAt: Date
}
