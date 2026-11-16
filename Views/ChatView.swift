import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var orchestrator: Orchestrator { env.orchestrator }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider().overlay(Theme.border)
            composer
        }
        .background(Theme.background)
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    env.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .onAppear {
            env.ensureSession()
            reload()
        }
        .onChange(of: env.currentSessionID) { _, _ in reload() }
        .onChange(of: orchestrator.revision) { _, _ in reload() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !orchestrator.isRunning {
                        emptyState
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if orchestrator.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(orchestrator.currentActivity ?? "执行中…")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.leading, 4)

                            StreamingBubble(text: orchestrator.streamingText)
                        }
                        .id("streaming")
                    }

                    if let error = orchestrator.lastError, !orchestrator.isRunning {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: orchestrator.isRunning) { _, _ in scrollToBottom(proxy) }
            .onChange(of: orchestrator.streamingText) { _, _ in
                guard orchestrator.isRunning else { return }
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hive")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("先发一条消息试试。记忆会在后台按相似度检索，模型可以在设置里随时替换。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 40)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("说点什么…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .foregroundStyle(Theme.textPrimary)
                .disabled(orchestrator.isRunning)

            Button {
                if orchestrator.isRunning {
                    orchestrator.cancel()
                } else {
                    send()
                }
            } label: {
                Image(systemName: orchestrator.isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(!orchestrator.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(!orchestrator.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    // MARK: - Actions

    private var sessionTitle: String {
        guard let id = env.currentSessionID else { return "对话" }
        return env.sessions.first(where: { $0.id == id })?.title ?? "对话"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let sessionID = env.ensureSession(),
              let provider = env.activeProvider else { return }

        draft = ""
        orchestrator.send(text: text, sessionID: sessionID, providerID: provider.id)
    }

    private func reload() {
        guard let sessionID = env.currentSessionID else {
            messages = []
            return
        }
        messages = (try? env.store.messages(sessionID: sessionID)) ?? []
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            if orchestrator.isRunning {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Bubbles

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(message.content.isEmpty ? " " : message.content)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == .user ? Theme.background : Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user ? Theme.accent : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                if message.status == .failed {
                    Label("失败", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                } else if message.status == .interrupted {
                    Label("已中断", systemImage: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if message.role != .user {
                Spacer(minLength: 44)
            }
        }
    }
}

struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    TypingIndicator()
                } else {
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            Spacer(minLength: 44)
        }
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.35 + 0.65 * pulse(index))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func pulse(_ index: Int) -> Double {
        let offset = Double(index) * 0.25
        let value = (phase + offset).truncatingRemainder(dividingBy: 1)
        return value < 0.5 ? value * 2 : (1 - value) * 2
    }
}
