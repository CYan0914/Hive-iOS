import Foundation

/// Models emit plans in whatever shape they feel like. This accepts the common
/// variants (`agent` vs `agentID`, `instruction` vs `task`), strips markdown
/// fences, and refuses to invent a plan out of an empty object — a nil return
/// means "fall back to answering directly", not "retry forever".
enum PlanParser {
    private struct RawPlan: Decodable {
        struct RawTask: Decodable {
            var agent: String?
            var agentID: String?
            var instruction: String?
            var task: String?
        }

        var rationale: String?
        var tasks: [RawTask]?
    }

    static func parse(_ raw: String) -> AgentPlan? {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawPlan.self, from: data),
              let rawTasks = decoded.tasks else {
            return nil
        }

        let known = Set(AgentProfile.builtins.map(\.id))
        var tasks: [PlannedTask] = []

        for item in rawTasks {
            let instruction = (item.instruction ?? item.task ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { continue }

            var agentID = item.agent ?? item.agentID ?? "researcher"
            if !known.contains(agentID) {
                agentID = "researcher"
            }

            tasks.append(PlannedTask(
                id: "task-\(tasks.count)",
                agentID: agentID,
                instruction: instruction
            ))

            if tasks.count >= 3 { break }
        }

        guard !tasks.isEmpty else { return nil }
        return AgentPlan(rationale: decoded.rationale ?? "", tasks: tasks)
    }

    /// First `{` to last `}`. Cheap, but it survives ```json fences and a
    /// trailing sentence, which is what actually shows up.
    private static func extractJSONObject(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(raw[start...end])
    }
}
