import XCTest
@testable import Hive

final class HiveOrchestrationTests: XCTestCase {
    // MARK: - Plan parsing

    func testPlanParserAcceptsFencedJSON() {
        let raw = """
        好的，我来拆解：
        ```json
        {"rationale":"两个角度","tasks":[{"agent":"researcher","instruction":"查资料"},{"agent":"writer","instruction":"写稿"}]}
        ```
        """
        let plan = PlanParser.parse(raw)

        XCTAssertEqual(plan?.tasks.count, 2)
        XCTAssertEqual(plan?.tasks[0].id, "task-0")
        XCTAssertEqual(plan?.tasks[0].agentID, "researcher")
        XCTAssertEqual(plan?.tasks[1].agentID, "writer")
        XCTAssertEqual(plan?.rationale, "两个角度")
    }

    func testPlanParserFallsBackForUnknownAgent() {
        let raw = #"{"tasks":[{"agent":"unknown","instruction":"做点事"}]}"#
        let plan = PlanParser.parse(raw)
        XCTAssertEqual(plan?.tasks.first?.agentID, "researcher")
    }

    func testPlanParserAcceptsInstructionAlias() {
        let raw = #"{"tasks":[{"agent":"writer","task":"把这段话改短"}]}"#
        XCTAssertEqual(PlanParser.parse(raw)?.tasks.first?.instruction, "把这段话改短")
    }

    func testPlanParserRejectsUnusableOutput() {
        XCTAssertNil(PlanParser.parse("{}"))
        XCTAssertNil(PlanParser.parse("我不确定该怎么拆"))
        XCTAssertNil(PlanParser.parse(#"{"tasks":[]}"#))
        XCTAssertNil(PlanParser.parse(#"{"tasks":[{"agent":"writer","instruction":"   "}]}"#))
    }

    func testPlanParserCapsAtThreeTasks() {
        let raw = """
        {"tasks":[
          {"agent":"researcher","instruction":"1"},
          {"agent":"writer","instruction":"2"},
          {"agent":"critic","instruction":"3"},
          {"agent":"writer","instruction":"4"}
        ]}
        """
        XCTAssertEqual(PlanParser.parse(raw)?.tasks.count, 3)
    }

    func testPlanParserAssignsStableIDs() {
        let raw = #"{"tasks":[{"agent":"writer","instruction":"a"},{"agent":"critic","instruction":"b"}]}"#
        let first = PlanParser.parse(raw)
        let second = PlanParser.parse(raw)

        XCTAssertEqual(first?.tasks.map(\.id), second?.tasks.map(\.id))
        XCTAssertEqual(first?.tasks.map(\.id), ["task-0", "task-1"])
    }

    // MARK: - Resumable steps

    func testEnsureStepIsIdempotent() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        let first = try store.ensureStep(runID: run.id, seq: 0, kind: .plan, payload: "{}")
        let second = try store.ensureStep(runID: run.id, seq: 0, kind: .plan, payload: "{}")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.steps(runID: run.id).count, 1)
    }

    func testFinishedStepKeepsItsResult() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        let step = try store.ensureStep(runID: run.id, seq: 0, kind: .plan, payload: "{}")
        try store.updateStep(id: step.id, state: .done, result: "cached")

        let reloaded = try store.ensureStep(runID: run.id, seq: 0, kind: .plan, payload: "different")
        XCTAssertEqual(reloaded.state, .done)
        XCTAssertEqual(reloaded.result, "cached")
    }

    // MARK: - Blackboard

    func testBlackboardSnapshotLabelsAuthor() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        try store.blackboardSet(runID: run.id, key: "task-0", value: "甲", author: "研究员")
        try store.blackboardSet(runID: run.id, key: "task-1", value: "乙", author: "写手")

        let snapshot = try store.blackboardSnapshot(runID: run.id)
        XCTAssertTrue(snapshot.contains("task-0 · 研究员"))
        XCTAssertTrue(snapshot.contains("乙"))
    }

    func testBlackboardIsScopedToRun() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let first = AgentRun(sessionID: session.id, goal: "a")
        let second = AgentRun(sessionID: session.id, goal: "b")
        try store.createRun(first)
        try store.createRun(second)

        try store.blackboardSet(runID: first.id, key: "task-0", value: "只属于第一个", author: "研究员")

        XCTAssertEqual(try store.blackboardEntries(runID: second.id).count, 0)
        XCTAssertEqual(try store.blackboardEntries(runID: first.id).count, 1)
    }

    func testBlackboardOverwritesSameKey() throws {
        let database = try Database(path: ":memory:")
        try Migrations.migrate(database)
        let store = Store(db: database)

        let session = try store.createSession(title: "s")
        let run = AgentRun(sessionID: session.id, goal: "g")
        try store.createRun(run)

        try store.blackboardSet(runID: run.id, key: "task-0", value: "旧", author: "研究员")
        try store.blackboardSet(runID: run.id, key: "task-0", value: "新", author: "写手")

        let entries = try store.blackboardEntries(runID: run.id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.value, "新")
    }
}
