import Foundation
import Combine

/// The resumable state machine.
///
/// Every model call is a `step` row written *before* the call starts and
/// updated when it finishes. iOS can suspend the app between any two awaits,
/// so "in memory only" would mean a suspended run is a lost run. The rules:
///
///  - a step set to `running` that is still `running` at launch means the
///    process died mid-call; it is reset to `pending` and replayed
///  - a user cancellation writes `cancelled`, which is terminal and is never
///    auto-resumed
///  - a network or provider error writes `failed`, which is also terminal
@MainActor
final class Orchestrator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var streamingText = ""
    @Published private(set) var activeRun: AgentRun?
    @Published private(set) var lastError: String?
    /// Bumped after every persisted change, so views reload on a counter
    /// instead of polling SQLite.
    @Published private(set) var revision = 0

    private let store: Store
    private let memory: MemoryService
    private let resolveProvider: (String) throws -> (LLMProvider, ProviderConfig)
    private var task: Task<Void, Never>?

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

    /// Called once at launch. Picks up a run that was executing when the app
    /// went away and replays its unfinished step.
    func resumeInterruptedIfNeeded() {
        guard !isRunning else { return }

        let runs = (try? store.resumableRuns()) ?? []
        guard let run = runs.first else { return }

        let steps = (try? store.steps(runID: run.id)) ?? []
        guard let step = steps.last else { return }

        if step.state == .done {
            try? store.updateRunState(id: run.id, state: .completed)
            return
        }
        guard let payload = StepPayload.decode(step.payload) else { return }

        let resolved: (LLMProvider, ProviderConfig)
        do {
            resolved = try resolveProvider(payload.providerID)
        } catch {
            // The provider may have been deleted. Mark it failed rather than
            // leaving a run that never clears.
            try? store.updateRunState(id: run.id, state: .failed)
            return
        }

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.lastError = nil
            self.streamingText = ""
            self.activeRun = run

            try? self.store.updateStep(id: step.id, state: .pending)
            try? self.store.updateRunState(id: run.id, state: .executing)

            let assistantID = self.assistantMessageID(for: run)
            await self.execute(
                step: step,
                run: run,
                config: resolved.1,
                provider: resolved.0,
                assistantMessageID: assistantID,
                sessionID: run.sessionID
            )
        }
    }

    // MARK: - Send

    private func performSend(text: String, sessionID: String, providerID: String) async {
        isRunning = true
        lastError = nil
        streamingText = ""

        let provider: LLMProvider
        let config: ProviderConfig
        do {
            (provider, config) = try resolveProvider(providerID)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            return
        }

        let userMessage = ChatMessage(sessionID: sessionID, role: .user, content: text)
        let run = AgentRun(sessionID: sessionID, goal: text)
        let payload = StepPayload(userText: text, providerID: providerID, model: config.model)
        let step = AgentStep(runID: run.id, seq: 0, kind: .llm, payload: payload.json)
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
            try store.createStep(step)
            try store.updateRunState(id: run.id, state: .executing)
            try store.insertMessage(assistant)
        } catch {
            lastError = "保存消息失败：\(error.localizedDescription)"
            isRunning = false
            return
        }
        revision += 1

        var executing = run
        executing.state = .executing
        activeRun = executing

        await execute(
            step: step,
            run: executing,
            config: config,
            provider: provider,
            assistantMessageID: assistant.id,
            sessionID: sessionID
        )
    }

    // MARK: - Step execution

    private func execute(
        step: AgentStep,
        run: AgentRun,
        config: ProviderConfig,
        provider: LLMProvider,
        assistantMessageID: String,
        sessionID: String
    ) async {
        // Write "running" before the call. If the app dies right here, launch
        // recovery finds this row and knows a replay is needed.
        try? store.updateStep(id: step.id, state: .running)

        let payload = StepPayload.decode(step.payload)
        let userText = payload?.userText ?? run.goal

        let stored = (try? store.messages(sessionID: sessionID)) ?? []
        let history = Array(
            stored
                .filter { $0.id != assistantMessageID && $0.status != .streaming }
                .suffix(payload?.historyLimit ?? 20)
        ).map { message in
            LLMMessage(
                role: message.role == .assistant ? .assistant : .user,
                content: message.content
            )
        }

        let memoryBlock = await memory.contextBlock(query: userText, sessionID: sessionID)
        let request = LLMRequest(
            model: config.model,
            system: supervisorPrompt(memoryBlock: memoryBlock),
            messages: history,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )

        var output = ""
        var lastFlush = Date.distantPast

        do {
            let stream = try await provider.stream(request)
            for try await event in stream {
                guard !Task.isCancelled else { break }
                if case .text(let delta) = event {
                    output += delta
                    // Republishing on every token stutters the list; 20fps is
                    // indistinguishable and much cheaper.
                    if Date().timeIntervalSince(lastFlush) > 0.05 {
                        streamingText = output
                        lastFlush = Date()
                    }
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                finishInterrupted(step: step, run: run, assistantMessageID: assistantMessageID, output: output)
            } else {
                finishFailed(step: step, run: run, assistantMessageID: assistantMessageID, output: output, error: error)
            }
            return
        }

        if Task.isCancelled {
            finishInterrupted(step: step, run: run, assistantMessageID: assistantMessageID, output: output)
            return
        }

        try? store.updateStep(id: step.id, state: .done, result: output)
        try? store.updateRunState(id: run.id, state: .completed)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .complete)
        try? store.touchSession(id: sessionID)

        // Episodic memory is written after the turn settles, not per token.
        await memory.remember(content: userText, layer: .episodic, sessionID: sessionID, importance: 0.4)
        if !output.isEmpty {
            await memory.remember(content: output, layer: .episodic, sessionID: sessionID, importance: 0.4)
        }

        revision += 1
        streamingText = ""
        isRunning = false
        activeRun = nil
    }

    private func finishInterrupted(
        step: AgentStep,
        run: AgentRun,
        assistantMessageID: String,
        output: String
    ) {
        // Pending, not failed: a cancellation is the user's choice, and the row
        // must stay replayable. The run itself goes terminal so a deliberate
        // cancel is not resurrected at next launch.
        try? store.updateStep(id: step.id, state: .pending)
        try? store.updateRunState(id: run.id, state: .cancelled)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .interrupted)
        revision += 1
        streamingText = ""
        isRunning = false
        activeRun = nil
    }

    private func finishFailed(
        step: AgentStep,
        run: AgentRun,
        assistantMessageID: String,
        output: String,
        error: Error
    ) {
        try? store.updateStep(id: step.id, state: .failed, error: error.localizedDescription)
        try? store.updateRunState(id: run.id, state: .failed)
        try? store.updateMessage(id: assistantMessageID, content: output, status: .failed)
        lastError = error.localizedDescription
        revision += 1
        streamingText = ""
        isRunning = false
        activeRun = nil
    }

    // MARK: - Helpers

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

    private func supervisorPrompt(memoryBlock: String) -> String {
        var lines = [
            "你是 Hive 的主管家。",
            "你的职责是理解用户意图并给出简短、准确的回答。",
            "后续版本中你会把任务拆给子机器人；现在由你直接完成全部工作。",
            "不要声称自己执行了没有执行的操作。"
        ]
        if !memoryBlock.isEmpty {
            lines.append("")
            lines.append("下面是与当前问题可能相关的共享记忆。仅在确实相关时引用，不要编造记忆里没有的内容：")
            lines.append(memoryBlock)
        }
        return lines.joined(separator: "\n")
    }
}
