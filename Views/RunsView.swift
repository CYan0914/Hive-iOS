import SwiftUI

struct RunsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var runs: [AgentRun] = []

    var body: some View {
        List {
            if runs.isEmpty {
                Text("还没有任务记录。发一条消息就会生成一条，每次模型调用都是一个可恢复的步骤。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(runs) { run in
                NavigationLink {
                    RunDetailView(run: run)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.goal)
                            .font(.system(size: 15))
                            .lineLimit(2)
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 8) {
                            Text(run.state.displayName)
                                .font(.caption2)
                                .foregroundStyle(stateColor(run.state))
                            Text(run.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("任务")
        .onAppear(perform: reload)
        .onChange(of: env.orchestrator.revision) { _, _ in reload() }
    }

    private func reload() {
        runs = (try? env.store.runs()) ?? []
    }

    private func stateColor(_ state: RunState) -> Color {
        switch state {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .pending, .executing: return Theme.accent
        case .cancelled: return Theme.textSecondary
        }
    }
}

struct RunDetailView: View {
    let run: AgentRun
    @EnvironmentObject private var env: AppEnvironment
    @State private var steps: [AgentStep] = []

    var body: some View {
        List {
            Section("目标") {
                Text(run.goal)
                    .font(.system(size: 15))
            }

            Section("状态") {
                Text(run.state.displayName)
                    .foregroundStyle(stateColor)
            }

            Section("步骤") {
                if steps.isEmpty {
                    Text("没有步骤记录")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(step.seq + 1) · \(step.kind.displayName)")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(step.state.displayName)
                                .font(.caption2)
                                .foregroundStyle(step.state == .failed ? Theme.danger : Theme.textSecondary)
                        }
                        if step.kind == .tool, let summary = toolSummary(step.payload) {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let error = step.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.danger)
                        }
                        if let result = step.result, !result.isEmpty {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(8)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: env.orchestrator.revision) { _, _ in reload() }
    }

    private var stateColor: Color {
        switch run.state {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .pending, .executing: return Theme.accent
        case .cancelled: return Theme.textSecondary
        }
    }

    private func reload() {
        steps = (try? env.store.steps(runID: run.id)) ?? []
    }

    private func toolSummary(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let call = try? JSONDecoder().decode(ToolCall.self, from: data) else {
            return nil
        }
        let argument = call.arguments["url"] ?? call.arguments.values.first ?? ""
        return argument.isEmpty ? call.name : "\(call.name) · \(argument)"
    }
}
