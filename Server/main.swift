import Foundation

// Entry point for the local orchestration server.
//
// It reuses the same Store, MemoryService, Orchestrator and provider adapters
// as the app — one engine, two surfaces. The only thing it does not reuse is
// the UI layer, which is why it links Models/Services/Keychain directly.

let port = UInt16(ProcessInfo.processInfo.environment["HIVE_PORT"] ?? "") ?? 8787

// stdout is line-buffered when attached to a pipe, which makes a hung server
// look like a server that printed nothing.
setvbuf(stdout, nil, _IONBF, 0)

let state = MainActor.assumeIsolated { ServerState(port: port) }

do {
    try state.start()
    print("Hive server listening on http://127.0.0.1:\(port)")
    print("  GET  /health")
    print("  GET  /v1/sessions")
    print("  POST /v1/message   {\"text\":\"...\",\"sessionID\":\"...\",\"providerID\":\"...\"}")
    print("  GET  /v1/runs/latest")
} catch {
    FileHandle.standardError.write(Data("启动失败：\(error)\n".utf8))
    exit(1)
}

RunLoop.main.run()

// MARK: - Wiring

@MainActor
final class ServerState {
    let store: Store
    let memory: MemoryService
    let orchestrator: Orchestrator
    private let server: HTTPServer

    init(port: UInt16) {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Hive", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let databaseURL = folder.appendingPathComponent("hive.sqlite")

        let database: Database
        do {
            database = try Database(path: databaseURL.path)
            try Migrations.migrate(database)
        } catch {
            FileHandle.standardError.write(Data("数据库不可用：\(error)\n".utf8))
            exit(1)
        }

        let store = Store(db: database)
        let memory = MemoryService(store: store)

        let resolve: (String) throws -> (LLMProvider, ProviderConfig) = { providerID in
            let all = (try? store.providers()) ?? []
            guard let config = all.first(where: { $0.id == providerID }) ?? all.first else {
                throw LLMError.invalidConfiguration("还没有配置模型")
            }
            guard let key = Keychain.get(config.keychainKey), !key.isEmpty else {
                throw LLMError.invalidConfiguration("「\(config.name)」没有保存 API Key")
            }
            return (ProviderFactory.make(config: config, apiKey: key), config)
        }

        let orchestrator = Orchestrator(store: store, memory: memory, resolveProvider: resolve)

        self.store = store
        self.memory = memory
        self.orchestrator = orchestrator
        self.server = HTTPServer(port: port) { request in
            Router.handle(request, store: store, orchestrator: orchestrator)
        }
    }

    func start() throws {
        try server.start()
    }
}
