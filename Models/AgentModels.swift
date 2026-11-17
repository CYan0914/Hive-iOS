import Foundation

/// A sub-agent. P1 ships three fixed ones; letting users author their own is a
/// P2 feature, and a deliberately late one — an untested custom agent is the
/// single fastest way to turn a working orchestration into a debugging swamp.
struct AgentProfile: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var role: String
    var systemPrompt: String
    var providerID: String?
    var model: String?
    var isBuiltin: Bool
    /// Tool names this agent may use. Empty means "no tools", which is a
    /// permission, not a bug.
    var allowedTools: [String]
}

extension AgentProfile {
    static let supervisor = AgentProfile(
        id: "supervisor",
        name: "管家",
        role: "supervisor",
        systemPrompt: "",
        providerID: nil,
        model: nil,
        isBuiltin: true,
        allowedTools: ["http_request", "extract_text"]
    )

    static let builtins: [AgentProfile] = [
        AgentProfile(
            id: "researcher",
            name: "研究员",
            role: "researcher",
            systemPrompt: """
            你是一名研究员。你的职责是整理与任务相关的事实、线索和已知信息。

            要求：
            - 需要外部信息时使用工具，不要凭记忆编造数据、来源、日期
            - 工具失败或没有信息时，明确说"未能获取"
            - 用紧凑的要点输出，不要写寒暄或过程描述
            """,
            providerID: nil,
            model: nil,
            isBuiltin: true,
            allowedTools: ["http_request", "extract_text"]
        ),
        AgentProfile(
            id: "writer",
            name: "写手",
            role: "writer",
            systemPrompt: """
            你是一名写手。根据收到的指令和共享黑板上的材料，写出清晰、紧凑的成稿。

            要求：
            - 只用给定材料支持的事实，不补充没有依据的细节
            - 先给结果，再给必要的解释
            - 不要提及"黑板""子机器人"或内部流程
            """,
            providerID: nil,
            model: nil,
            isBuiltin: true,
            allowedTools: []
        ),
        AgentProfile(
            id: "critic",
            name: "审稿人",
            role: "critic",
            systemPrompt: """
            你是一名审稿人。检查收到内容的事实错误、逻辑漏洞、表达问题，给出具体、可执行的修改建议。

            要求：
            - 指出问题时说明位置和原因
            - 不要重写全文，只给修改意见
            - 没有问题就直说"没有发现明显问题"
            """,
            providerID: nil,
            model: nil,
            isBuiltin: true,
            allowedTools: []
        )
    ]

    static func find(_ id: String) -> AgentProfile? {
        if id == supervisor.id { return supervisor }
        return builtins.first { $0.id == id }
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
