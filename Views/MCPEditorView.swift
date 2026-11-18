import SwiftUI

struct MCPEditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var config: MCPServerConfig
    @State private var testing = false
    @State private var testResult: String?

    init(config: MCPServerConfig) {
        _config = State(initialValue: config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $config.name)
                    TextField("地址", text: $config.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("启用", isOn: $config.isEnabled)
                } header: {
                    Text("连接")
                } footer: {
                    Text("填 MCP 服务的 Streamable HTTP 端点，例如 http://192.168.1.10:3000/mcp。stdio 类型的服务 iOS 连不了。")
                }

                Section {
                    Button(testing ? "测试中…" : "测试连接") {
                        test()
                    }
                    .disabled(testing || config.url.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("连接成功") ? Theme.success : Theme.danger)
                    }
                }
            }
            .navigationTitle(config.name.isEmpty ? "MCP 服务" : config.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || config.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func test() {
        guard !testing else { return }
        testing = true
        testResult = nil

        Task {
            let client = MCPClient(config: config)
            do {
                try await client.initialize()
                let tools = try await client.listTools()
                testResult = "连接成功，\(tools.count) 个工具"
            } catch {
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func save() {
        var servers = env.mcpServers
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
        } else {
            servers.append(config)
        }
        env.saveMCPServers(servers)
        dismiss()
    }
}
