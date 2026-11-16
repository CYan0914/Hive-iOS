import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editing: ProviderConfig?

    var body: some View {
        List {
            Section {
                ForEach(env.providers) { provider in
                    Button {
                        env.setActiveProvider(provider.id)
                        editing = provider
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(provider.kind.displayName) · \(provider.model)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                if !env.hasKey(for: provider) {
                                    Text("未保存 Key")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.danger)
                                }
                            }
                            Spacer()
                            if env.activeProviderID == provider.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            env.deleteProvider(provider)
                        }
                    }
                }

                Button {
                    editing = ProviderConfig(name: "新模型")
                } label: {
                    Label("添加模型", systemImage: "plus")
                }
                .listRowBackground(Theme.surface)
            } header: {
                Text("模型")
            } footer: {
                Text("点一行打开配置并设为当前模型。Key 存在 Keychain，不写进数据库。")
            }

            Section {
                HStack {
                    Text("向量检索")
                    Spacer()
                    Text(embeddingStatus)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            } header: {
                Text("记忆")
            } footer: {
                Text("优先用远程 embedding；不可用时退回 Apple 端上模型；都不行就只做关键词匹配。")
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("所有数据都存在本机。只有你输入的内容会发给你自己配置的模型服务商。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("设置")
        .sheet(item: $editing, onDismiss: { editing = nil }) { config in
            ProviderEditorView(config: config)
                .environmentObject(env)
        }
    }

    private var embeddingStatus: String {
        guard env.memory.embedder.isAvailable else { return "关键词" }
        return env.memory.embedder.activeIdentifier ?? "可用"
    }
}

// MARK: - Editor

struct ProviderEditorView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var config: ProviderConfig
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?

    init(config: ProviderConfig) {
        _config = State(initialValue: config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("显示名称", text: $config.name)
                }

                Section("协议") {
                    Picker("类型", selection: $config.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: config.kind) { oldKind, newKind in
                        if config.baseURL == oldKind.defaultBaseURL {
                            config.baseURL = newKind.defaultBaseURL
                        }
                        if config.model == oldKind.defaultModel {
                            config.model = newKind.defaultModel
                        }
                    }
                }

                Section {
                    TextField("Base URL", text: $config.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型 ID", text: $config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(config.kind.keyHint, text: $apiKey)
                } header: {
                    Text("连接")
                } footer: {
                    Text(env.hasKey(for: config) ? "已经保存过 Key，留空则保持不变。" : "Key 只写入 Keychain。")
                }

                Section("参数") {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", config.temperature))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Slider(value: $config.temperature, in: 0...2, step: 0.1)
                    Stepper("最大输出 \(config.maxTokens)", value: $config.maxTokens, in: 256...32000, step: 256)
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text(testing ? "测试中…" : "测试连接")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("连接成功") ? Theme.success : Theme.danger)
                    }
                }
            }
            .navigationTitle(config.name.isEmpty ? "模型配置" : config.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.saveProvider(config, apiKey: apiKey)
                        dismiss()
                    }
                    .disabled(config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func testConnection() {
        guard !testing else { return }
        testing = true
        testResult = nil

        let key = apiKey.isEmpty ? (Keychain.get(config.keychainKey) ?? "") : apiKey
        Task {
            do {
                testResult = try await ProviderHealth.check(config: config, apiKey: key)
            } catch {
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}
