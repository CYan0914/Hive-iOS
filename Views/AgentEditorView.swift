import SwiftUI

struct AgentEditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var profile: AgentProfile

    init(profile: AgentProfile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $profile.name)
                    TextField("一句话描述", text: $profile.summary)
                } header: {
                    Text("身份")
                } footer: {
                    Text("这句描述会出现在管家的规划提示里，写清楚它能干什么、什么时候该用它。")
                }

                Section("职责") {
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 160)
                }

                Section {
                    ForEach(ToolRegistry.all, id: \.definition.name) { tool in
                        Toggle(tool.definition.name, isOn: binding(for: tool.definition.name))
                    }
                } header: {
                    Text("工具权限")
                } footer: {
                    Text("关闭的工具不会出现在这个子机器人的提示里，模型不会尝试调用。")
                }
            }
            .navigationTitle(profile.name.isEmpty ? "子机器人" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !profile.summary.trimmingCharacters(in: .whitespaces).isEmpty
            && !profile.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func binding(for toolName: String) -> Binding<Bool> {
        Binding(
            get: { profile.allowedTools.contains(toolName) },
            set: { isOn in
                if isOn {
                    if !profile.allowedTools.contains(toolName) {
                        profile.allowedTools.append(toolName)
                    }
                } else {
                    profile.allowedTools.removeAll { $0 == toolName }
                }
            }
        )
    }

    private func save() {
        var agents = env.customAgents
        if let index = agents.firstIndex(where: { $0.id == profile.id }) {
            agents[index] = profile
        } else {
            agents.append(profile)
        }
        env.saveCustomAgents(agents)
        dismiss()
    }
}
