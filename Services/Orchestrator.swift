import Foundation
import Combine

/// The resumable state machine, now multi-step.
///
/// A run is a fixed sequence of steps:
///
///   seq 0        plan        supervisor produces a JSON task list
///   seq 1..n     llm         one sub-agent per task, output goes to the blackboard
///   seq n+1      aggregate   supervisor merges the contributions into an answer
///
/// Every step is a row written before it executes and updated when it finishes.
/// Resume replays the same sequence and `ensureStep` hands back finished rows,
/// so a run interrupted at step 2 picks up at step 2 — not from the beginning,
/// and not with a duplicate model call for steps 0 and 1.
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

    /// Called once at launch. Re-walks a run that was executing when the app
    /// went away; finished steps are replayed from SQLite, not re-requested.
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
            // The provider may have been deleted. Mark it failed rather than
            // leaving a run that never clears.
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
            seq: 0,
            kind: .plan,
            payload: basePayload,
            system: plannerPrompt(),
            messages: history,
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
        }

        // Unusable plan (or a model that cannot produce JSON): answer directly.
        // This is the P0 path, kept as the fallback rather than an error state.
        if plan.tasks.isEmpty {
            currentActivity = "管家正在回答…"
            let direct = await runStep(
                run: run,
                seq: 1,
                kind: .aggregate,
                payload: basePayload,
                system: supervisorDirectPrompt(memoryBlock: memoryBlock),
                messages: history,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                provider: provider,
                streamToUI: true
            )
            finish(direct, run: run, sessionID: sessionID, assistantMessageID: assistantMessageID, userText: userText)
            return
        }

        // 2. Sub-agents, sequential. Sequential on purpose: iOS gives no
        // background guarantee, and three parallel streams on a suspended app
        // is three partial outputs that all have to be reconciled on resume.
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

            let outcome = await runStep(
                run: run,
                seq: index + 1,
                kind: .llm,
                payload: StepPayload(
                    userText: planned.instruction,
                    providerID: providerID,
                    model: config.model
                ),
                system: agentPrompt(profile: profile, blackboard: blackboard, memoryBlock: taskMemory),
                messages: [LLMMessage(role: .user, content: planned.instruction)],
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                provider: provider,
                streamToUI: false
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
            }
        }

        // 3. Synthesize
        currentActivity = "管家正在汇总…"
        let synthesis = await runStep(
            run: run,
            seq: plan.tasks.count + 1,
            kind: .aggregate,
            payload: basePayload,
            system: synthesisPrompt(userText: userText, contributions: contributions.joined(separator: "\n\n")),
            messages: history,
            model: config.model,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            provider: provider,
            streamToUI: true
        )

        finish(synthesis, run: run, sessionID: sessionID, assistantMessageID: assistantMessageID, userText: userText)
    }

    private func finish(
        _ outcome: StepOutcome,
        run: AgentRun,
        sessionID: String,
        assistantMessageID: String,
        userText: String
    ) {
        switch outcome {
        case .text(let text):
            complete(run: run, sessionID: sessionID, assistantMessageID: assistantMessageID, output: text, userText: userText)
        case .interrupted:
            finishInterrupted(run: run, assistantMessageID: assistantMessageID, output: streamingText)
        case .failed(let message):
            finishFailed(run: run, assistantMessageID: assistantMessageID, output: streamingText, message: message)
        }
    }

    // MARK: - Step execution

    private func runStep(
        run: AgentRun,
        seq: Int,
        kind: StepKind,
        payload: StepPayload,
        system: String?,
        messages: [LLMMessage],
        model: String,
        temperature: Double,
        maxTokens: Int,
        provider: LLMProvider,
        streamToUI: Bool
    ) async -> StepOutcome {
        let step: AgentStep
        do {
            step = try store.ensureStep(runID: run.id, seq: seq, kind: kind, payload: payload.json)
        } catch {
            return .failed("无法创建步骤：\(error.localizedDescription)")
        }

        // Resume fast path: this step already produced its output.
        if step.state == .done, let result = step.result {
            return .text(result)
        }

        // Written before the call starts. A crash here leaves a `running` row
        // that launch recovery resets to `pending`.
        try? store.updateStep(id: step.id, state: .running)

        let request = LLMRequest(
            model: model,
            system: system,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens
        )

        var output = ""
        var lastFlush = Date.distantPast

        do {
            let stream = try await provider.stream(request)
            for try await event in stream {
                guard !Task.isCancelled else { break }
                if case .text(let delta) = event {
                    output += delta
                    if streamToUI, Date().timeIntervalSince(lastFlush) > 0.05 {
                        streamingText = output
                        lastFlush = Date()
                    }
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

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? store.updateStep(id: step.id, state: .failed, error: "模型返回空内容")
            return .failed("模型返回空内容")
        }

        try? store.updateStep(id: step.id, state: .done, result: trimmed)
        return .text(trimmed)
    }

    // MARK: - Terminal states

    private func complete(
        run: AgentRun,
        sessionID: String,
        assistantMessageID: String,
        output: String,
        userText: String
    ) {
        try? store.updateRunState(id: run.id, state: .completed)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .complete)
        try? store.touchSession(id: sessionID)

        revision += 1
        streamingText = ""
        currentActivity = nil
        isRunning = false
        activeRun = nil

        // Memory writes are not on the critical path; the answer is already on
        // screen by the time this runs.
        Task { [weak self] in
            guard let self else { return }
            await self.memory.remember(content: userText, layer: .episodic, sessionID: sessionID, importance: 0.4)
            if !output.isEmpty {
                await self.memory.remember(content: output, layer: .episodic, sessionID: sessionID, importance: 0.4)
            }
        }
    }

    private func finishInterrupted(run: AgentRun, assistantMessageID: String, output: String) {
        // The run goes terminal so a deliberate cancel is not resurrected at
        // next launch. The step itself stays pending and replayable.
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
        """
        你是 Hive 的主管家。把用户请求拆成 1-3 个可以独立执行的子任务。

        可用的子机器人（agent 字段只能填这些 id）：
        - researcher：整理事实和信息
        - writer：撰写和改写文字
        - critic：挑错和给修改建议

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
        parts.append("只完成分给你的任务，不要复述指令，不要输出 JSON。")
        return parts.joined(separator: "\n\n")
    }

    private func supervisorDirectPrompt(memoryBlock: String) -> String {
        var lines = [
            "你是 Hive 的主管家。",
            "直接、准确地回答用户的问题。",
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
