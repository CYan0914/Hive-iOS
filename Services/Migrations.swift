import Foundation

enum Migrations {
    static let currentVersion = 2

    static func migrate(_ database: Database) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        let stored = try database
            .query("SELECT value FROM meta WHERE key = 'schema_version'") { $0.string(0) }
            .first
        let version = Int(stored ?? "0") ?? 0

        if version < 1 {
            try applyVersion1(database)
        }
        if version < 2 {
            try applyVersion2(database)
        }

        try database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)",
            [.text(String(currentVersion))]
        )
    }

    private static func applyVersion1(_ database: Database) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            status TEXT NOT NULL,
            run_id TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, created_at);

        CREATE TABLE IF NOT EXISTS providers (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            base_url TEXT NOT NULL,
            model TEXT NOT NULL,
            temperature REAL NOT NULL,
            max_tokens INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory (
            id TEXT PRIMARY KEY,
            layer TEXT NOT NULL,
            session_id TEXT,
            content TEXT NOT NULL,
            importance REAL NOT NULL,
            embedding_model TEXT,
            embedding BLOB,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_memory_layer ON memory(layer, updated_at);

        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            agent_name TEXT NOT NULL,
            goal TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state);

        CREATE TABLE IF NOT EXISTS steps (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            payload TEXT NOT NULL,
            result TEXT,
            error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_steps_run ON steps(run_id, seq);
        """)
    }

    /// P1: the shared blackboard. Structured, keyed, scoped to one run — as
    /// opposed to `memory`, which is a similarity-searched pile of prose.
    private static func applyVersion2(_ database: Database) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS blackboard (
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            author TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (run_id, key)
        );
        """)
    }
}
