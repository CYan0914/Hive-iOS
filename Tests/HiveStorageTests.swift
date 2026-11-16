import XCTest
@testable import Hive

final class HiveStorageTests: XCTestCase {
    private var database: Database!
    private var store: Store!

    override func setUpWithError() throws {
        database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        store = Store(db: database)
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
    }

    func testSessionRoundTrip() throws {
        let session = try store.createSession(title: "测试会话")
        let loaded = try store.sessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, session.id)
        XCTAssertEqual(loaded.first?.title, "测试会话")
    }

    func testMessagesAreOrderedByInsertionTime() throws {
        let session = try store.createSession(title: "s")
        let first = ChatMessage(
            sessionID: session.id,
            role: .user,
            content: "一",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = ChatMessage(
            sessionID: session.id,
            role: .assistant,
            content: "二",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        // Inserted out of order on purpose: the query must order by timestamp.
        try store.insertMessage(second)
        try store.insertMessage(first)

        let loaded = try store.messages(sessionID: session.id)
        XCTAssertEqual(loaded.map(\.content), ["一", "二"])
    }

    func testResumableRunsExcludeTerminal() throws {
        let session = try store.createSession(title: "s")
        let running = AgentRun(sessionID: session.id, goal: "a")
        let finished = AgentRun(sessionID: session.id, goal: "b", state: .completed)

        try store.createRun(running)
        try store.createRun(finished)
        try store.updateRunState(id: running.id, state: .executing)

        let resumable = try store.resumableRuns()
        XCTAssertEqual(resumable.count, 1)
        XCTAssertEqual(resumable.first?.id, running.id)
    }

    func testResetRunningStepsMakesThemReplayable() throws {
        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "a")
        try store.createRun(run)

        let step = AgentStep(
            runID: run.id,
            seq: 0,
            kind: .llm,
            state: .running,
            payload: "{}"
        )
        try store.createStep(step)

        try store.resetRunningSteps()

        let loaded = try store.steps(runID: run.id)
        XCTAssertEqual(loaded.first?.state, .pending)
    }

    func testMemoryStoresAndDecodesEmbedding() throws {
        let session = try store.createSession(title: "s")
        let record = MemoryRecord(layer: .semantic, content: "用户喜欢简短回答")
        try store.insertMemory(record, embedding: [0.1, 0.2], embeddingModel: "test")

        let candidates = try store.memoryCandidates(sessionID: session.id)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.embedding?.count, 2)
        XCTAssertEqual(candidates.first?.record.content, "用户喜欢简短回答")
    }

    func testVectorCodecRoundTrip() {
        let vector: [Float] = [0.1, -2.5, 3.75, 0]
        let decoded = VectorCodec.decode(VectorCodec.encode(vector))

        XCTAssertEqual(decoded.count, vector.count)
        for (index, value) in vector.enumerated() {
            XCTAssertEqual(decoded[index], value, accuracy: 0.0001)
        }
    }

    func testCosineSimilarity() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let c: [Float] = [0, 1, 0]

        XCTAssertEqual(VectorMath.cosine(a, b), 1, accuracy: 0.0001)
        XCTAssertEqual(VectorMath.cosine(a, c), 0, accuracy: 0.0001)
    }

    func testStepPayloadRoundTrip() {
        let payload = StepPayload(userText: "你好", providerID: "p1", model: "m")
        let decoded = StepPayload.decode(payload.json)
        XCTAssertEqual(decoded?.userText, "你好")
        XCTAssertEqual(decoded?.providerID, "p1")
        XCTAssertEqual(decoded?.model, "m")
    }
}
