import Foundation
import Combine

/// Wires the object graph together and owns the user-visible configuration:
/// which providers exist, which one is active, and which key goes with each.
@MainActor
final class AppEnvironment: ObservableObject {
    let store: Store
    let memory: MemoryService
    let orchestrator: Orchestrator

    @Published var providers: [ProviderConfig] = []
    @Published var activeProviderID: String?
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: String?
    @Published var startupError: String?

    private let defaults = UserDefaults.standard
    private let activeProviderKey = "hive.activeProviderID"

    init() {
        let (database, error) = Self.openDatabase()
        let store = Store(db: database)
        let memory = MemoryService(store: store)

        // The closure captures `store` directly, not `self`: it is handed to
        // Orchestrator before AppEnvironment finishes initializing.
        let resolve: (String) throws -> (LLMProvider, ProviderConfig) = { providerID in
            let all = (try? store.providers()) ?? []
            guard let config = all.first(where: { $0.id == providerID }) ?? all.first else {
                throw LLMError.invalidConfiguration("还没有配置任何模型，先去设置页添加一个")
            }
            guard let key = Keychain.get(config.keychainKey),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMError.invalidConfiguration("「\(config.name)」还没有保存 API Key")
            }
            return (ProviderFactory.make(config: config, apiKey: key), config)
        }

        self.store = store
        self.memory = memory
        self.orchestrator = Orchestrator(store: store, memory: memory, resolveProvider: resolve)
        self.startupError = error

        loadProviders()
        loadSessions()
        refreshEmbedder()
    }

    // MARK: - Lifecycle

    func bootstrap() {
        loadProviders()
        loadSessions()
        refreshEmbedder()
        orchestrator.resumeInterruptedIfNeeded()
    }

    // MARK: - Providers

    var activeProvider: ProviderConfig? {
        if let id = activeProviderID,
           let match = providers.first(where: { $0.id == id }) {
            return match
        }
        return providers.first
    }

    func hasKey(for config: ProviderConfig) -> Bool {
        Keychain.exists(config.keychainKey)
    }

    func loadProviders() {
        var loaded = (try? store.providers()) ?? []
        if loaded.isEmpty {
            let seed = ProviderConfig()
            try? store.upsertProvider(seed)
            loaded = [seed]
        }
        providers = loaded

        if let stored = defaults.string(forKey: activeProviderKey),
           loaded.contains(where: { $0.id == stored }) {
            activeProviderID = stored
        } else {
            activeProviderID = loaded.first?.id
            defaults.set(activeProviderID, forKey: activeProviderKey)
        }
    }

    func saveProvider(_ config: ProviderConfig, apiKey: String) {
        try? store.upsertProvider(config)
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? Keychain.set(trimmed, for: config.keychainKey)
        }
        loadProviders()
        if activeProviderID == nil {
            setActiveProvider(config.id)
        }
        refreshEmbedder()
    }

    func deleteProvider(_ config: ProviderConfig) {
        Keychain.delete(config.keychainKey)
        try? store.deleteProvider(id: config.id)
        loadProviders()
        if activeProviderID == config.id {
            activeProviderID = providers.first?.id
            defaults.set(activeProviderID, forKey: activeProviderKey)
        }
        refreshEmbedder()
    }

    func setActiveProvider(_ id: String) {
        activeProviderID = id
        defaults.set(id, forKey: activeProviderKey)
        refreshEmbedder()
    }

    // MARK: - Embedding

    /// Rebuilt whenever the active provider changes. Remote first, then Apple's
    /// on-device sentence model, then (implicitly) keyword search.
    func refreshEmbedder() {
        var candidates: [EmbeddingProvider] = []

        if let config = activeProvider,
           config.kind == .openAICompatible,
           let key = Keychain.get(config.keychainKey),
           !key.isEmpty {
            candidates.append(RemoteEmbedding(
                config: config,
                apiKey: key,
                model: "text-embedding-3-small"
            ))
        }
        if let chinese = AppleSentenceEmbedding(language: .simplifiedChinese) {
            candidates.append(chinese)
        }
        if let english = AppleSentenceEmbedding(language: .english) {
            candidates.append(english)
        }

        memory.embedder = HybridEmbedder(providers: candidates)
    }

    // MARK: - Sessions

    func loadSessions() {
        sessions = (try? store.sessions()) ?? []
        if let current = currentSessionID,
           sessions.contains(where: { $0.id == current }) {
            return
        }
        currentSessionID = sessions.first?.id
    }

    @discardableResult
    func newSession(title: String = "新对话") -> ChatSession? {
        guard let session = try? store.createSession(title: title) else { return nil }
        sessions = (try? store.sessions()) ?? []
        currentSessionID = session.id
        return session
    }

    @discardableResult
    func ensureSession() -> String? {
        if let id = currentSessionID { return id }
        return newSession()?.id
    }

    func deleteSession(_ session: ChatSession) {
        try? store.deleteSession(id: session.id)
        loadSessions()
    }

    // MARK: - Database location

    private static func openDatabase() -> (Database, String?) {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Hive", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("hive.sqlite")

        do {
            let database = try Database(path: url.path)
            try Migrations.migrate(database)
            return (database, nil)
        } catch {
            // Better a session that forgets than a launch that white-screens.
            if let fallback = try? Database(path: ":memory:") {
                try? Migrations.migrate(fallback)
                return (fallback, "数据库打开失败，本次运行不会保存数据：\(error.localizedDescription)")
            }
            let lastResort = try! Database(path: ":memory:")
            return (lastResort, "数据库不可用：\(error.localizedDescription)")
        }
    }
}
