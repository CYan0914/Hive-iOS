import XCTest
@testable import Hive

final class HiveToolTests: XCTestCase {
    // MARK: - HTML extraction

    func testHTMLTextStripsMarkupScriptsAndStyles() {
        let html = """
        <html><head><style>body{color:red}</style></head>
        <body><h1>标题</h1><script>alert('x')</script><p>正文 &amp; 更多</p></body></html>
        """
        let text = HTMLText.extract(html)

        XCTAssertTrue(text.contains("标题"))
        XCTAssertTrue(text.contains("正文 & 更多"))
        XCTAssertFalse(text.contains("<h1>"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color:red"))
    }

    func testHTMLTextCollapsesBlankLines() {
        let text = HTMLText.extract("<div>a</div><div>b</div>")
        XCTAssertFalse(text.contains("\n\n\n"))
    }

    // MARK: - Step result envelope

    func testTextEnvelopeRoundTrip() {
        let encoded = StepPayloadCodec.encodeText("hello")
        XCTAssertEqual(StepPayloadCodec.decodeText(encoded), "hello")
        XCTAssertNil(StepPayloadCodec.decodeCalls(encoded))
    }

    func testToolCallEnvelopeRoundTrip() {
        let calls = [
            ToolCall(id: "c1", name: "http_request", arguments: ["url": "https://example.com"])
        ]
        let encoded = StepPayloadCodec.encodeCalls(calls)
        let decoded = StepPayloadCodec.decodeCalls(encoded)

        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.name, "http_request")
        XCTAssertEqual(decoded?.first?.arguments["url"], "https://example.com")
    }

    func testLegacyRawTextIsNotSwallowed() {
        // P1 rows were written as raw model output, not envelopes.
        XCTAssertEqual(StepPayloadCodec.textOrRaw(#"{"tasks":[]}"#), #"{"tasks":[]}"#)
        XCTAssertEqual(StepPayloadCodec.textOrRaw("plain"), "plain")
    }

    // MARK: - Permissions

    func testToolPermissionsFollowProfile() {
        let researcher = AgentProfile.find("researcher")
        let writer = AgentProfile.find("writer")

        XCTAssertEqual(ToolRegistry.tools(for: researcher).map(\.definition.name).sorted(),
                       ["extract_text", "http_request"])
        XCTAssertTrue(ToolRegistry.tools(for: writer).isEmpty)
        XCTAssertTrue(ToolRegistry.tools(for: nil).isEmpty)
    }

    func testSupervisorCanUseTools() {
        XCTAssertEqual(ToolRegistry.tools(for: AgentProfile.supervisor).count, 2)
    }

    // MARK: - Stable step keys

    func testEnsureStepByKeyIsIdempotent() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        let first = try store.ensureStep(runID: run.id, key: "task-0/turn-0", kind: .llm, payload: "{}")
        let second = try store.ensureStep(runID: run.id, key: "task-0/turn-0", kind: .llm, payload: "{}")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.steps(runID: run.id).count, 1)
    }

    func testStepsGetIncreasingSequenceNumbers() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        let llm = try store.ensureStep(runID: run.id, key: "task-0/turn-0", kind: .llm, payload: "{}")
        let tool = try store.ensureStep(runID: run.id, key: "task-0/turn-0/tool-0", kind: .tool, payload: "{}")

        XCTAssertLessThan(llm.seq, tool.seq)
        XCTAssertEqual(tool.stepKey, "task-0/turn-0/tool-0")
    }

    func testFinishedToolStepKeepsOutput() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        let step = try store.ensureStep(runID: run.id, key: "tool-0", kind: .tool, payload: "{}")
        try store.updateStep(id: step.id, state: .done, result: "HTTP 200")

        let reloaded = try store.step(runID: run.id, key: "tool-0")
        XCTAssertEqual(reloaded?.state, .done)
        XCTAssertEqual(reloaded?.result, "HTTP 200")
    }
}
