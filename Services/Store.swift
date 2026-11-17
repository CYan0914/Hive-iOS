import Foundation

private let epoch = Date(timeIntervalSince1970: 0)

private func date(_ column: Double) -> Date {
    Date(timeIntervalSince1970: column)
}

private func timestamp(_ date: Date) -> SQLValue {
    .double(date.timeIntervalSince1970)
}

/// All persistence. Every write that must survive a suspension goes through
/// here, so there is exactly one place to audit for durability.
final class Store {
    let db: Database

    init(db: Database) {
        self.db = db
    }

    // MARK: - Sessions

    func createSession(title: String) throws -> ChatSession {
        let session = ChatSession(title: title)
        try db.run(
            "INSERT INTO sessions (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
            [.text(session.id), .text(session.title), timestamp(session.createdAt), timestamp(session.updatedAt)]
        )
        return session
    }

    func sessions() throws -> [ChatSession] {
        try db.query(
            "SELECT id, title, created_at, updated_at FROM sessions ORDER BY updated_at DESC"
        ) { row in
            ChatSession(
                id: row.string(0),
                title: row.string(1),
                createdAt: date(row.double(2)),
                updatedAt: date(row.double(3))
            )
        }
    }

    func touchSession(id: String, title: String? = nil) throws {
        if let title {
            try db.run(
                "UPDATE sessions SET updated_at = ?, title = ? WHERE id = ?",
                [timestamp(Date()), .text(title), .text(id)]
            )
        } else {
            try db.run(
                "UPDATE sessions SET updated_at = ? WHERE id = ?",
                [timestamp(Date()), .text(id)]
            )
        }
    }

    func deleteSession(id: String) throws {
        try db.run("DELETE FROM sessions WHERE id = ?", [.text(id)])
    }

    // MARK: - Messages

    func insertMessage(_ message: ChatMessage) throws {
        try db.run(
            """
            INSERT INTO messages (id, session_id, role, content, status, run_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(message.id),
                .text(message.sessionID),
                .text(message.role.rawValue),
                .text(message.content),
                .text(message.status.rawValue),
                message.runID.map(SQLValue.text) ?? .null,
                timestamp(message.createdAt)
            ]
        )
    }

    func updateMessage(id: String, content: String, status: MessageStatus, runID: String? = nil) throws {
        if let runID {
            try db.run(
                "UPDATE messages SET content = ?, status = ?, run_id = ? WHERE id = ?",
                [.text(content), .text(status.rawValue), .text(runID), .text(id)]
            )
        } else {
            try db.run(
                "UPDATE messages SET content = ?, status = ? WHERE id = ?",
                [.text(content), .text(status.rawValue), .text(id)]
            )
        }
    }

    func messages(sessionID: String, limit: Int = 500) throws -> [ChatMessage] {
        try db.query(
            """
            SELECT id, session_id, role, content, status, run_id, created_at
            FROM messages WHERE session_id = ?
            ORDER BY created_at ASC LIMIT ?
            """,
            [.text(sessionID), .int(limit)]
        ) { row in
            ChatMessage(
                id: row.string(0),
                sessionID: row.string(1),
                role: MessageRole(rawValue: row.string(2)) ?? .user,
                content: row.string(3),
                status: MessageStatus(rawValue: row.string(4)) ?? .complete,
                createdAt: date(row.double(6)),
                runID: row.optionalString(5)
            )
        }
    }

    // MARK: - Providers

    func providers() throws -> [ProviderConfig] {
        try db.query(
            """
            SELECT id, name, kind, base_url, model, temperature, max_tokens
            FROM providers ORDER BY created_at ASC
            """
        ) { row in
            ProviderConfig(
                id: row.string(0),
                name: row.string(1),
                kind: ProviderKind(rawValue: row.string(2)) ?? .openAICompatible,
                baseURL: row.string(3),
                model: row.string(4),
                temperature: row.double(5),
                maxTokens: row.int(6)
            )
        }
    }

    func upsertProvider(_ config: ProviderConfig) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO providers
                (id, name, kind, base_url, model, temperature, max_tokens, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?,
                COALESCE((SELECT created_at FROM providers WHERE id = ?), ?))
            """,
            [
                .text(config.id),
                .text(config.name),
                .text(config.kind.rawValue),
                .text(config.baseURL),
                .text(config.model),
                .double(config.temperature),
                .int(config.maxTokens),
                .text(config.id),
                timestamp(Date())
            ]
        )
    }

    func deleteProvider(id: String) throws {
        try db.run("DELETE FROM providers WHERE id = ?", [.text(id)])
    }

    // MARK: - Memory

    func insertMemory(_ record: MemoryRecord, embedding: [Float]?, embeddingModel: String?) throws {
        try db.run(
            """
            INSERT INTO memory
                (id, layer, session_id, content, importance, embedding_model, embedding, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(record.id),
                .text(record.layer.rawValue),
                record.sessionID.map(SQLValue.text) ?? .null,
                .text(record.content),
                .double(record.importance),
                embeddingModel.map(SQLValue.text) ?? .null,
                embedding.map { .blob(VectorCodec.encode($0)) } ?? .null,
                timestamp(record.createdAt),
                timestamp(record.updatedAt)
            ]
        )
    }

    func updateMemoryEmbedding(id: String, embedding: [Float], model: String) throws {
        try db.run(
            "UPDATE memory SET embedding = ?, embedding_model = ?, updated_at = ? WHERE id = ?",
            [.blob(VectorCodec.encode(embedding)), .text(model), timestamp(Date()), .text(id)]
        )
    }

    func deleteMemory(id: String) throws {
        try db.run("DELETE FROM memory WHERE id = ?", [.text(id)])
    }

    struct MemoryCandidate {
        let record: MemoryRecord
        let embedding: [Float]?
    }

    /// Semantic memory is global; episodic memory is scoped to the session.
    /// Scratchpad is deliberately excluded: it belongs to one agent.
    func memoryCandidates(sessionID: String?, limit: Int = 400) throws -> [MemoryCandidate] {
        try db.query(
            """
            SELECT id, layer, session_id, content, importance, embedding_model,
                   embedding, created_at, updated_at
            FROM memory
            WHERE layer IN ('semantic', 'episodic', 'blackboard')
              AND (session_id IS NULL OR session_id = ?)
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            [sessionID.map(SQLValue.text) ?? .null, .int(limit)]
        ) { row in
            let record = MemoryRecord(
                id: row.string(0),
                layer: MemoryLayer(rawValue: row.string(1)) ?? .episodic,
                sessionID: row.optionalString(2),
                content: row.string(3),
                importance: row.double(4),
                embeddingModel: row.optionalString(5),
                createdAt: date(row.double(7)),
                updatedAt: date(row.double(8))
            )
            let raw = row.data(6)
            return MemoryCandidate(record: record, embedding: raw.map(VectorCodec.decode))
        }
    }

    func keywordMemorySearch(sessionID: String?, keyword: String, limit: Int = 8) throws -> [MemoryRecord] {
        let pattern = "%\(keyword)%"
        return try db.query(
            """
            SELECT id, layer, session_id, content, importance, embedding_model, created_at, updated_at
            FROM memory
            WHERE content LIKE ?
              AND layer IN ('semantic', 'episodic', 'blackboard')
              AND (session_id IS NULL OR session_id = ?)
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            [.text(pattern), sessionID.map(SQLValue.text) ?? .null, .int(limit)]
        ) { row in
            MemoryRecord(
                id: row.string(0),
                layer: MemoryLayer(rawValue: row.string(1)) ?? .episodic,
                sessionID: row.optionalString(2),
                content: row.string(3),
                importance: row.double(4),
                embeddingModel: row.optionalString(5),
                createdAt: date(row.double(6)),
                updatedAt: date(row.double(7))
            )
        }
    }

    // MARK: - Runs

    func createRun(_ run: AgentRun) throws {
        try db.run(
            """
            INSERT INTO runs (id, session_id, agent_name, goal, state, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(run.id),
                .text(run.sessionID),
                .text(run.agentName),
                .text(run.goal),
                .text(run.state.rawValue),
                timestamp(run.createdAt),
                timestamp(run.updatedAt)
            ]
        )
    }

    func updateRunState(id: String, state: RunState) throws {
        try db.run(
            "UPDATE runs SET state = ?, updated_at = ? WHERE id = ?",
            [.text(state.rawValue), timestamp(Date()), .text(id)]
        )
    }

    func runs(sessionID: String? = nil, limit: Int = 100) throws -> [AgentRun] {
        let sql: String
        let values: [SQLValue]
        if let sessionID {
            sql = """
            SELECT id, session_id, agent_name, goal, state, created_at, updated_at
            FROM runs WHERE session_id = ? ORDER BY created_at DESC LIMIT ?
            """
            values = [.text(sessionID), .int(limit)]
        } else {
            sql = """
            SELECT id, session_id, agent_name, goal, state, created_at, updated_at
            FROM runs ORDER BY created_at DESC LIMIT ?
            """
            values = [.int(limit)]
        }
        return try db.query(sql, values) { row in
            AgentRun(
                id: row.string(0),
                sessionID: row.string(1),
                agentName: row.string(2),
                goal: row.string(3),
                state: RunState(rawValue: row.string(4)) ?? .failed,
                createdAt: date(row.double(5)),
                updatedAt: date(row.double(6))
            )
        }
    }

    /// Runs that were mid-flight when the app went away.
    func resumableRuns() throws -> [AgentRun] {
        try db.query(
            """
            SELECT id, session_id, agent_name, goal, state, created_at, updated_at
            FROM runs WHERE state IN ('pending', 'executing')
            ORDER BY updated_at ASC
            """
        ) { row in
            AgentRun(
                id: row.string(0),
                sessionID: row.string(1),
                agentName: row.string(2),
                goal: row.string(3),
                state: RunState(rawValue: row.string(4)) ?? .pending,
                createdAt: date(row.double(5)),
                updatedAt: date(row.double(6))
            )
        }
    }

    // MARK: - Steps

    func createStep(_ step: AgentStep) throws {
        try db.run(
            """
            INSERT INTO steps
                (id, run_id, seq, step_key, kind, state, payload, result, error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(step.id),
                .text(step.runID),
                .int(step.seq),
                step.stepKey.isEmpty ? .null : .text(step.stepKey),
                .text(step.kind.rawValue),
                .text(step.state.rawValue),
                .text(step.payload),
                step.result.map(SQLValue.text) ?? .null,
                step.error.map(SQLValue.text) ?? .null,
                timestamp(step.createdAt),
                timestamp(step.updatedAt)
            ]
        )
    }

    func updateStep(
        id: String,
        state: StepState,
        result: String? = nil,
        error: String? = nil
    ) throws {
        try db.run(
            "UPDATE steps SET state = ?, result = ?, error = ?, updated_at = ? WHERE id = ?",
            [
                .text(state.rawValue),
                result.map(SQLValue.text) ?? .null,
                error.map(SQLValue.text) ?? .null,
                timestamp(Date()),
                .text(id)
            ]
        )
    }

    func steps(runID: String) throws -> [AgentStep] {
        try db.query(
            """
            SELECT id, run_id, seq, step_key, kind, state, payload, result, error, created_at, updated_at
            FROM steps WHERE run_id = ? ORDER BY seq ASC
            """,
            [.text(runID)]
        ) { row in
            AgentStep(
                id: row.string(0),
                runID: row.string(1),
                seq: row.int(2),
                stepKey: row.optionalString(3) ?? "",
                kind: StepKind(rawValue: row.string(4)) ?? .llm,
                state: StepState(rawValue: row.string(5)) ?? .pending,
                payload: row.string(6),
                result: row.optionalString(7),
                error: row.optionalString(8),
                createdAt: date(row.double(9)),
                updatedAt: date(row.double(10))
            )
        }
    }

    func lastStep(runID: String) throws -> AgentStep? {
        try steps(runID: runID).last
    }

    func step(runID: String, seq: Int) throws -> AgentStep? {
        try db.query(
            """
            SELECT id, run_id, seq, step_key, kind, state, payload, result, error, created_at, updated_at
            FROM steps WHERE run_id = ? AND seq = ? LIMIT 1
            """,
            [.text(runID), .int(seq)]
        ) { row in
            AgentStep(
                id: row.string(0),
                runID: row.string(1),
                seq: row.int(2),
                stepKey: row.optionalString(3) ?? "",
                kind: StepKind(rawValue: row.string(4)) ?? .llm,
                state: StepState(rawValue: row.string(5)) ?? .pending,
                payload: row.string(6),
                result: row.optionalString(7),
                error: row.optionalString(8),
                createdAt: date(row.double(9)),
                updatedAt: date(row.double(10))
            )
        }.first
    }

    func step(runID: String, key: String) throws -> AgentStep? {
        try db.query(
            """
            SELECT id, run_id, seq, step_key, kind, state, payload, result, error, created_at, updated_at
            FROM steps WHERE run_id = ? AND step_key = ? LIMIT 1
            """,
            [.text(runID), .text(key)]
        ) { row in
            AgentStep(
                id: row.string(0),
                runID: row.string(1),
                seq: row.int(2),
                stepKey: row.optionalString(3) ?? "",
                kind: StepKind(rawValue: row.string(4)) ?? .llm,
                state: StepState(rawValue: row.string(5)) ?? .pending,
                payload: row.string(6),
                result: row.optionalString(7),
                error: row.optionalString(8),
                createdAt: date(row.double(9)),
                updatedAt: date(row.double(10))
            )
        }.first
    }

    func nextStepSeq(runID: String) throws -> Int {
        let maximum = try db.query(
            "SELECT COALESCE(MAX(seq), -1) FROM steps WHERE run_id = ?",
            [.text(runID)]
        ) { $0.int(0) }.first ?? -1
        return maximum + 1
    }

    /// Returns the existing row for `(runID, seq)` or creates it. This is what
    /// makes resume cheap: a replayed run re-walks the same sequence and every
    /// finished step is handed back instead of re-executed.
    func ensureStep(runID: String, seq: Int, kind: StepKind, payload: String) throws -> AgentStep {
        if let existing = try step(runID: runID, seq: seq) {
            return existing
        }
        let created = AgentStep(runID: runID, seq: seq, kind: kind, payload: payload)
        try createStep(created)
        return created
    }

    /// P2 resume path. Keyed lookup, fresh sequence number on first create —
    /// a replay finds the row regardless of where the tool loop put it.
    func ensureStep(runID: String, key: String, kind: StepKind, payload: String) throws -> AgentStep {
        if let existing = try step(runID: runID, key: key) {
            return existing
        }
        let seq = try nextStepSeq(runID: runID)
        let created = AgentStep(runID: runID, seq: seq, stepKey: key, kind: kind, payload: payload)
        try createStep(created)
        return created
    }

    // MARK: - Blackboard

    func blackboardSet(runID: String, key: String, value: String, author: String) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO blackboard (run_id, key, value, author, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(runID), .text(key), .text(value), .text(author), timestamp(Date())]
        )
    }

    func blackboardEntries(runID: String) throws -> [BlackboardEntry] {
        try db.query(
            "SELECT key, value, author, updated_at FROM blackboard WHERE run_id = ? ORDER BY updated_at ASC",
            [.text(runID)]
        ) { row in
            BlackboardEntry(
                key: row.string(0),
                value: row.string(1),
                author: row.string(2),
                updatedAt: date(row.double(3))
            )
        }
    }

    func blackboardSnapshot(runID: String) throws -> String {
        let entries = try blackboardEntries(runID: runID)
        guard !entries.isEmpty else { return "" }
        return entries
            .map { "[\($0.key) · \($0.author)]\n\($0.value)" }
            .joined(separator: "\n\n")
    }

    /// A step left in `running` means the process died mid-call. Nothing can be
    /// trusted about it, so it is reset and replayed.
    func resetRunningSteps() throws {
        try db.run(
            "UPDATE steps SET state = 'pending', updated_at = ? WHERE state = 'running'",
            [timestamp(Date())]
        )
    }
}

// MARK: - Vector codec

enum VectorCodec {
    /// Float32, little endian. Dimension is implied by byte count, which is why
    /// `embedding_model` is stored alongside: swapping models means rebuilding.
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { buffer in
            for index in 0..<count {
                let bits = buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                output[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return output
    }
}

enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dot / denominator : 0
    }
}

extension Date {
    var hiveEpoch: TimeInterval { timeIntervalSince(epoch) }
}
