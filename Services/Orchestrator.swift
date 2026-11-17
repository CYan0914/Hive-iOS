import Foundation
import Combine

/// The resumable state machine, now with a tool loop.
///
/// A run is:
///
///   plan            supervisor produces a JSON task list
///   task-0..n       one sub-agent per task; each may loop llm -> tool -> llm
///   aggregate       supervisor merges the contributions into an answer
///
/// Every step is a row keyed by its logical name (`task-0/turn-1/tool-0`), not
/// by position: a tool loop changes how many rows a turn produces, so sequence
/// numbers are not stable across a replay. `ensureStep` returns the finished
/// row on resume, and a finished tool step is never executed twice — re-fetching
/// a URL would give the model a different answer than the one it reasoned about.
@MainActor
final class Orchestrator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var streamingText = ""
    @Published private(set) var currentActivity: String?
    @Published private(set) var activeRun: AgentRun?
    @Published private(set) var lastError: String?
    /// Bumped after every persisted change, so views reload on a counter
    /// instead of polling SQLite.
    @Published private(set) var revision = 0

    private let store: Store
    private let memory: MemoryService
    private let resolveProvider: (String) throws -> (LLMProvider, ProviderConfig)
    private var task: Task<Void, Never>?

    private enum StepOutcome {
        case text(String)
        case toolCalls([ToolCall])
        case interrupted
        case failed(String)
    }

    init(
        store: Store,
        memory: MemoryService,
        resolveProvider: @escaping (String) throws -> (LLMProvider, ProviderConfig)
    ) {
        self.store = store
        self.memory = memory
        self.resolveProvider = resolveProvider
    }

    // MARK: - Public entry points

    func send(text: String, sessionID: String, providerID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.performSend(text: trimmed, sessionID: sessionID, providerID: providerID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Re-walks a run that was executing when the app went away. Finished
    /// steps come back from SQLite; only the unfinished tail is re-requested.
    func resumeInterruptedIfNeeded() {
        guard !isRunning else { return }

        let runs = (try? store.resumableRuns()) ?? []
        guard let run = runs.first else { return }
        guard let payload = payloadFor(run: run) else {
            try? store.updateRunState(id: run.id, state: .failed)
            return
        }

        let resolved: (LLMProvider, ProviderConfig)
        do {
            resolved = try resolveProvider(payload.providerID)
        } catch {
            try? store.updateRunState(id: run.id, state: .failed)
            return
        }

        let assistantID = assistantMessageID(for: run)

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.lastError = nil
            self.streamingText = ""
            self.currentActivity = "恢复执行…"
            self.activeRun = run

            try? self.store.resetRunningSteps()
            try? self.store.updateRunState(id: run.id, state: .executing)

            await self.drive(
                run: run,
                sessionID: run.sessionID,
                userText: payload.userText,
                providerID: payload.providerID,
                provider: resolved.0,
                config: resolved.1,
                assistantMessageID: assistantID
            )
        }
    }

    // MARK: - Send

    private func performSend(text: String, sessionID: String, providerID: String) async {
        isRunning = true
        lastError = nil
        streamingText = ""
        currentActivity = "规划中…"

        let provider: LLMProvider
        let config: ProviderConfig
        do {
            (provider, config) = try resolveProvider(providerID)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            currentActivity = nil
            return
        }

        let userMessage = ChatMessage(sessionID: sessionID, role: .user, content: text)
        let run = AgentRun(sessionID: sessionID, goal: text)
        let assistant = ChatMessage(
            sessionID: sessionID,
            role: .assistant,
            content: "",
            status: .streaming,
            runID: run.id
        )

        do {
            try store.insertMessage(userMessage)
            try store.touchSession(id: sessionID)
            try store.createRun(run)
            try store.updateRunState(id: run.id, state: .executing)
            try store.insertMessage(assistant)
        } catch {
            lastError = "保存消息失败：\(error.localizedDescription)"
            isRunning = false
            currentActivity = nil
            return
        }
        revision += 1

        var executing = run
        executing.state = .executing
        activeRun = executing

        await drive(
            run: executing,
            sessionID: sessionID,
            userText: text,
            providerID: providerID,
            provider: provider,
            config: config,
            assistantMessageID: assistant.id
        )
    }

    // MARK: - Pipeline

    private func drive(
        run: AgentRun,
        sessionID: String,
        userText: String,
        providerID: String,
        provider: LLMProvider,
        config: ProviderConfig,
        assistantMessageID: String
    ) async {
        let history = recentHistory(sessionID: sessionID, excluding: assistantMessageID, limit: 12)
        let memoryBlock = await memory.contextBlock(query: userText, sessionID: sessionID)
        let basePayload = StepPayload(userText: userText, providerID: providerID, model: config.model)

        // 1. Plan
        currentActivity = "管家正在拆解任务…"
        let planOutcome = await runStep(
            run: run,
            key: "plan",
            kind: .plan,
            payload: basePayload,
            system: plannerPrompt(),
            messages: history,
            tools: [],
            model: config.model,
            temperature: 0.3,
            maxTokens: 800,
            provider: provider,
            streamToUI: false
        )

        let plan: AgentPlan
        switch planOutcome {
        case .text(let raw):
            plan = PlanParser.parse(raw) ?? AgentPlan(rationale: "", tasks: [])
        case .interrupted:
            finishInterrupted(run: run, assistantMessageID: assistantMessageID, output: streamingText)
            return
        case .failed(let message):
            finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: message)
            return
        case .toolCalls:
            plan = AgentPlan(rationale: "", tasks: [])
        }

        // Unusable plan: answer directly, with the supervisor's own tools.
        if plan.tasks.isEmpty {
            currentActivity = "管家正在回答…"
            let direct = await runAgentLoop(
                run: run,
                keyPrefix: "direct",
                system: supervisorDirectPrompt(memoryBlock: memoryBlock),
                initialMessages: history,
                tools: ToolRegistry.tools(for: AgentProfile.supervisor),
                providerID: providerID,
                provider: provider,
                config: config,
                streamToUI: true,
                maxTurns: 3
            )
            finish(
                direct,
                run: run,
                sessionID: sessionID,
                assistantMessageID: assistantMessageID,
                userText: userText,
                provider: provider,
                config: config
            )
            return
        }

        // 2. Sub-agents, sequential.
        var contributions: [String] = []
        for (index, planned) in plan.tasks.enumerated() {
            if Task.isCancelled {
                finishInterrupted(run: run, assistantMessageID: assistantMessageID, output: streamingText)
                return
            }

            let profile = AgentProfile.find(planned.agentID)
            let name = profile?.name ?? planned.agentID
            currentActivity = "\(name) 正在工作…"

            let blackboard = (try? store.blackboardSnapshot(runID: run.id)) ?? ""
            let taskMemory = await memory.contextBlock(query: planned.instruction, sessionID: sessionID)

            let outcome = await runAgentLoop(
                run: run,
                keyPrefix: "task-\(index)",
                system: agentPrompt(profile: profile, blackboard: blackboard, memoryBlock: taskMemory),
                initialMessages: [LLMMessage(role: .user, content: planned.instruction)],
                tools: ToolRegistry.tools(for: profile),
                providerID: providerID,
                provider: provider,
                config: config,
                streamToUI: false,
                maxTurns: 3
            )

            switch outcome {
            case .text(let output):
                try? store.blackboardSet(runID: run.id, key: planned.id, value: output, author: name)
                contributions.append("[\(planned.id) · \(name)]\n\(output)")
            case .interrupted:
                finishInterrupted(run: run, assistantMessageID: assistantMessageID, output: streamingText)
                return
            case .failed(let message):
                finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: message)
                return
            case .toolCalls:
                // runAgentLoop only returns this if its loop cap was reached in
                // an unexpected state; treat it as a failure rather than
                // silently dropping the turn.
                finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: "子机器人在没有产出结果的情况下停止了")
                return
            }
        }

        // 3. Synthesize
        currentActivity = "管家正在汇总…"
        let synthesis = await runStep(
            run: run,
            key: "aggregate",
            kind: .aggregate,
            payload: basePayload,
            system: synthesisPrompt(userText: userText, contributions: contributions.joined(separator: "\n\n")),
            messages: history,
            tools: [],
            model: config.model,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            provider: provider,
            streamToUI: true
        )

        finish(
            synthesis,
            run: run,
            sessionID: sessionID,
            assistantMessageID: assistantMessageID,
            userText: userText,
            provider: provider,
            config: config
        )
    }

    // MARK: - Agent tool loop

    private func runAgentLoop(
        run: AgentRun,
        keyPrefix: String,
        system: String,
        initialMessages: [LLMMessage],
        tools: [AgentTool],
        providerID: String,
        provider: LLMProvider,
        config: ProviderConfig,
        streamToUI: Bool,
        maxTurns: Int
    ) async -> StepOutcome {
        var conversation = initialMessages
        let definitions = tools.map(\.definition)
        let payload = StepPayload(userText: keyPrefix, providerID: providerID, model: config.model)

        for turn in 0..<maxTurns {
            if Task.isCancelled { return .interrupted }

            let outcome = await runStep(
                run: run,
                key: "\(keyPrefix)/turn-\(turn)",
                kind: .llm,
                payload: payload,
                system: system,
                messages: conversation,
                tools: definitions,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                provider: provider,
                streamToUI: streamToUI
            )

            switch outcome {
            case .text(let text):
                return .text(text)
            case .interrupted:
                return .interrupted
            case .failed(let message):
                return .failed(message)
            case .toolCalls(let calls):
                currentActivity = "执行 \(calls.map(\.name).joined(separator: "、"))…"
                conversation.append(LLMMessage(role: .assistant, content: "", toolCalls: calls))

                for (index, call) in calls.enumerated() {
                    let result = await executeTool(
                        run: run,
                        key: "\(keyPrefix)/turn-\(turn)/tool-\(index)",
                        call: call
                    )
                    conversation.append(LLMMessage(
                        role: .tool,
                        content: result.output,
                        toolCallID: call.id,
                        toolName: call.name
                    ))
                }
            }
        }

        return .failed("工具调用超过 \(maxTurns) 轮，已停止")
    }

    private func executeTool(run: AgentRun, key: String, call: ToolCall) async -> ToolResult {
        let step: AgentStep?
        do {
            step = try store.ensureStep(
                runID: run.id,
                key: key,
                kind: .tool,
                payload: encodeCall(call)
            )
        } catch {
            step = nil
        }

        // Replay path: a finished tool call is not run again. Besides being
        // slow, a second fetch can return different content than the one the
        // model already reasoned about, which makes resume non-deterministic.
        if let step, step.state == .done, let output = step.result {
            return ToolResult(callID: call.id, name: call.name, output: output, isError: false)
        }

        if let step {
            try? store.updateStep(id: step.id, state: .running)
        }

        let tool = ToolRegistry.find(call.name)
        let result: ToolResult
        if let tool {
            result = await tool.execute(call: call)
        } else {
            result = ToolResult(
                callID: call.id,
                name: call.name,
                output: "未知工具：\(call.name)",
                isError: true
            )
        }

        if let step {
            try? store.updateStep(id: step.id, state: .done, result: result.output)
        }
        revision += 1
        return result
    }

    // MARK: - Step execution

    private func runStep(
        run: AgentRun,
        key: String,
        kind: StepKind,
        payload: StepPayload,
        system: String?,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        model: String,
        temperature: Double,
        maxTokens: Int,
        provider: LLMProvider,
        streamToUI: Bool
    ) async -> StepOutcome {
        let step: AgentStep
        do {
            step = try store.ensureStep(runID: run.id, key: key, kind: kind, payload: payload.json)
        } catch {
            return .failed("无法创建步骤：\(error.localizedDescription)")
        }

        if step.state == .done, let result = step.result {
            if let calls = StepPayloadCodec.decodeCalls(result) {
                return .toolCalls(calls)
            }
            return .text(StepPayloadCodec.textOrRaw(result))
        }

        try? store.updateStep(id: step.id, state: .running)

        let request = LLMRequest(
            model: model,
            system: system,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )

        var output = ""
        var collected: [ToolCall] = []
        var lastFlush = Date.distantPast

        do {
            let stream = try await provider.stream(request)
            for try await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .text(let delta):
                    output += delta
                    if streamToUI, Date().timeIntervalSince(lastFlush) > 0.05 {
                        streamingText = output
                        lastFlush = Date()
                    }
                case .toolCalls(let calls):
                    collected.append(contentsOf: calls)
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                try? store.updateStep(id: step.id, state: .pending)
                return .interrupted
            }
            try? store.updateStep(id: step.id, state: .failed, error: error.localizedDescription)
            return .failed(error.localizedDescription)
        }

        if Task.isCancelled {
            try? store.updateStep(id: step.id, state: .pending)
            return .interrupted
        }

        if !collected.isEmpty {
            try? store.updateStep(id: step.id, state: .done, result: StepPayloadCodec.encodeCalls(collected))
            return .toolCalls(collected)
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? store.updateStep(id: step.id, state: .failed, error: "模型返回空内容")
            return .failed("模型返回空内容")
        }

        try? store.updateStep(id: step.id, state: .done, result: StepPayloadCodec.encodeText(trimmed))
        return .text(trimmed)
    }

    private func finish(
        _ outcome: StepOutcome,
        run: AgentRun,
        sessionID: String,
        assistantMessageID: String,
        userText: String,
        provider: LLMProvider,
        config: ProviderConfig
    ) {
        switch outcome {
        case .text(let text):
            complete(
                run: run,
                sessionID: sessionID,
                assistantMessageID: assistantMessageID,
                output: text,
                userText: userText,
                provider: provider,
                config: config
            )
        case .interrupted:
            finishInterrupted(run: run, assistantMessageID: assistantMessageID, output: streamingText)
        case .failed(let message):
            finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: message)
        case .toolCalls:
            finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: "汇总阶段返回了工具调用")
        }
    }

    // MARK: - Terminal states

    private func complete(
        run: AgentRun,
        sessionID: String,
        assistantMessageID: String,
        output: String,
        userText: String,
        provider: LLMProvider,
        config: ProviderConfig
    ) {
        try? store.updateRunState(id: run.id, state: .completed)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .complete)
        try? store.touchSession(id: sessionID)

        revision += 1
        streamingText = ""
        currentActivity = nil
        isRunning = false
        activeRun = nil

        // Memory work is off the critical path: the answer is already on
        // screen. Episodic is the raw turn; semantic is the distilled version
        // that survives across sessions.
        Task { [weak self] in
            guard let self else { return }
            await self.memory.remember(content: userText, layer: .episodic, sessionID: sessionID, importance: 0.4)
            guard !output.isEmpty else { return }
            await self.memory.remember(content: output, layer: .episodic, sessionID: sessionID, importance: 0.4)
            await self.distill(
                userText: userText,
                answer: output,
                provider: provider,
                config: config
            )
        }
    }

    /// Turns one turn into a few durable facts. Deliberately quiet: a failed
    /// distillation leaves the turn's episodic memory intact and never surfaces
    /// an error, because the user already got their answer.
    private func distill(
        userText: String,
        answer: String,
        provider: LLMProvider,
        config: ProviderConfig
    ) async {
        let prompt = """
        从下面这段对话里提炼最多 3 条值得长期记住的事实。

        只保留：用户的稳定偏好、重要背景、明确结论。
        不要保留：问候、过程描述、一次性的临时信息、助手自称做过的事。
        每行一条，不要编号，不要解释。没有值得记住的就只输出：无

        用户：\(userText)
        助手：\(answer)
        """

        let request = LLMRequest(
            model: config.model,
            system: nil,
            messages: [LLMMessage(role: .user, content: prompt)],
            temperature: 0.2,
            maxTokens: 300
        )

        var output = ""
        do {
            let stream = try await provider.stream(request)
            for try await event in stream {
                if case .text(let delta) = event {
                    output += delta
                }
            }
        } catch {
            return
        }

        for line in output.split(separator: "\n") {
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•·0123456789. "))
            guard trimmed.count >= 6, trimmed != "无", !trimmed.hasPrefix("无") else { continue }
            await memory.remember(content: trimmed, layer: .semantic, sessionID: nil, importance: 0.6)
        }
    }

    private func finishInterrupted(run: AgentRun, assistantMessageID: String, output: String) {
        try? store.updateRunState(id: run.id, state: .cancelled)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .interrupted)
        revision += 1
        streamingText = ""
        currentActivity = nil
        isRunning = false
        activeRun = nil
    }

    private func finishFailed(run: AgentRun, assistantMessageID: String, output: String, message: String) {
        try? store.updateRunState(id: run.id, state: .failed)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .failed)
        lastError = message
        revision += 1
        streamingText = ""
        currentActivity = nil
        isRunning = false
        activeRun = nil
    }

    // MARK: - Helpers

    private func encodeCall(_ call: ToolCall) -> String {
        guard let data = try? JSONEncoder().encode(call),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func payloadFor(run: AgentRun) -> StepPayload? {
        let steps = (try? store.steps(runID: run.id)) ?? []
        for step in steps {
            if let payload = StepPayload.decode(step.payload) {
                return payload
            }
        }
        return nil
    }

    private func assistantMessageID(for run: AgentRun) -> String {
        let messages = (try? store.messages(sessionID: run.sessionID)) ?? []
        if let existing = messages.last(where: { $0.runID == run.id && $0.role == .assistant }) {
            try? store.updateMessage(id: existing.id, content: "", status: .streaming)
            return existing.id
        }
        let message = ChatMessage(
            sessionID: run.sessionID,
            role: .assistant,
            content: "",
            status: .streaming,
            runID: run.id
        )
        try? store.insertMessage(message)
        return message.id
    }

    private func recentHistory(sessionID: String, excluding assistantMessageID: String, limit: Int) -> [LLMMessage] {
        let stored = (try? store.messages(sessionID: sessionID)) ?? []
        return Array(
            stored
                .filter { $0.id != assistantMessageID && $0.status != .streaming }
                .suffix(limit)
        ).map { message in
            LLMMessage(
                role: message.role == .assistant ? .assistant : .user,
                content: message.content
            )
        }
    }

    // MARK: - Prompts

    private func plannerPrompt() -> String {
        // Built from the live roster so a user-authored agent is actually
        // selectable, not just visible in settings.
        let roster = AgentProfile.all
            .map { "- \($0.id)：\($0.name)，\($0.summary)" }
            .joined(separator: "\n")

        return """
        你是 Hive 的主管家。把用户请求拆成 1-3 个可以独立执行的子任务。

        可用的子机器人（agent 字段只能填这些 id）：
        \(roster)

        只输出一个 JSON 对象，不要输出任何其他文字：
        {"rationale":"一句话说明为什么这样拆","tasks":[{"agent":"researcher","instruction":"具体指令"}]}

        规则：
        - 简单问题只给 1 个任务
        - 最多 3 个任务
        - instruction 必须能独立执行，不要出现"根据上文""按照刚才"这类指代
        """
    }

    private func agentPrompt(profile: AgentProfile?, blackboard: String, memoryBlock: String) -> String {
        var parts: [String] = [profile?.systemPrompt ?? "你是一个执行具体任务的助手。"]
        if !blackboard.isEmpty {
            parts.append("共享黑板（其他子机器人已经产出的内容，可直接引用）：\n\(blackboard)")
        }
        if !memoryBlock.isEmpty {
            parts.append("相关长期记忆：\n\(memoryBlock)")
        }
        if let tools = profile?.allowedTools, !tools.isEmpty {
            parts.append("你可以使用这些工具：\(tools.joined(separator: "、"))。需要外部信息时先调用工具，不要凭记忆编造。")
        }
        parts.append("只完成分给你的任务，不要复述指令，不要输出 JSON。")
        return parts.joined(separator: "\n\n")
    }

    private func supervisorDirectPrompt(memoryBlock: String) -> String {
        var lines = [
            "你是 Hive 的主管家。",
            "直接、准确地回答用户的问题。",
            "需要外部信息时使用工具，不要编造事实。",
            "不要声称自己执行了没有执行的操作。"
        ]
        if !memoryBlock.isEmpty {
            lines.append("")
            lines.append("相关共享记忆（仅在有用时引用，不要编造）：")
            lines.append(memoryBlock)
        }
        return lines.joined(separator: "\n")
    }

    private func synthesisPrompt(userText: String, contributions: String) -> String {
        """
        你是 Hive 的主管家。下面是你的子机器人对用户问题的产出。请整合成最终回答。

        用户问题：
        \(userText)

        子机器人产出：
        \(contributions)

        要求：
        - 直接回答，不要复述工作过程
        - 不要提到"子机器人""任务""黑板"
        - 产出之间有冲突时，以更可靠的信息为准，并说明不确定的地方
        - 保持简洁
        """
    }
}
