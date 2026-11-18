import Foundation

enum Router {
    static func handle(
        _ request: HTTPRequest,
        store: Store,
        orchestrator: Orchestrator
    ) -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        switch (request.method, path) {
        case ("GET", "/health"):
            return json(200, ["status": "ok"])

        case ("GET", "/v1/sessions"):
            let sessions = (try? store.sessions()) ?? []
            return json(200, [
                "sessions": sessions.map { session in
                    ["id": session.id, "title": session.title]
                }
            ])

        case ("POST", "/v1/message"):
            return handleMessage(request.body, store: store, orchestrator: orchestrator)

        case ("GET", "/v1/runs/latest"):
            let runs = (try? store.runs(limit: 1)) ?? []
            guard let run = runs.first else {
                return json(404, ["error": "还没有任何运行记录"])
            }
            let steps = (try? store.steps(runID: run.id)) ?? []
            return json(200, runPayload(run, steps: steps))

        default:
            return json(404, ["error": "未知路径：\(request.method) \(path)"])
        }
    }

    private static func handleMessage(
        _ body: Data,
        store: Store,
        orchestrator: Orchestrator
    ) -> HTTPResponse {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let text = object["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return json(400, ["error": "body 需要 {\"text\": \"...\"}"])
        }

        let sessionID: String
        if let supplied = object["sessionID"] as? String, !supplied.isEmpty {
            sessionID = supplied
        } else if let existing = (try? store.sessions())?.first {
            sessionID = existing.id
        } else if let created = try? store.createSession(title: "服务端会话") {
            sessionID = created.id
        } else {
            return json(500, ["error": "无法创建会话"])
        }

        let providerID: String
        if let supplied = object["providerID"] as? String, !supplied.isEmpty {
            providerID = supplied
        } else if let first = (try? store.providers())?.first {
            providerID = first.id
        } else {
            return json(400, ["error": "还没有配置模型，先在 App 的设置页添加一个"])
        }

        // The orchestrator is main-actor isolated; the HTTP handler is not.
        // Dispatch and answer immediately — the client polls /v1/runs/latest.
        DispatchQueue.main.async {
            Task { @MainActor in
                orchestrator.send(text: text, sessionID: sessionID, providerID: providerID)
            }
        }

        return json(202, ["accepted": true, "sessionID": sessionID])
    }

    private static func runPayload(_ run: AgentRun, steps: [AgentStep]) -> [String: Any] {
        [
            "id": run.id,
            "sessionID": run.sessionID,
            "goal": run.goal,
            "state": run.state.rawValue,
            "steps": steps.map { step in
                [
                    "seq": step.seq,
                    "key": step.stepKey,
                    "kind": step.kind.rawValue,
                    "state": step.state.rawValue,
                    "result": step.result ?? "",
                    "error": step.error ?? ""
                ]
            }
        ]
    }

    private static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }
}
