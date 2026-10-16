import XCTest
@testable import Wand

final class ChatPresentationTests: XCTestCase {
    func testLiveShellIsNotAnExecutingTurn() {
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: false).stage, .idle)
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: true).label, "正在执行")
    }

    func testTerminalAndArchiveWinOverStaleRunningAndQueueFacts() {
        XCTAssertEqual(ChatRunningPresentation.session(status: "failed", responding: true, permissionBlocked: true, queuedCount: 2).stage, .failed)
        XCTAssertEqual(ChatRunningPresentation.session(status: "stopped", responding: true, queuedCount: 2).label, "已停止")
        XCTAssertEqual(ChatRunningPresentation.session(status: "exited", responding: true).stage, .idle)
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: true, archived: true).stage, .idle)
    }

    func testWaitingAndExecutionTakePriorityOverQueue() {
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: true, permissionBlocked: true, queuedCount: 1).label, "等待你确认操作")
        XCTAssertEqual(ChatRunningPresentation.session(status: "waiting_user", responding: true, queuedCount: 1).label, "等待你的输入")
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: true, queuedCount: 1).stage, .executing)
        XCTAssertEqual(ChatRunningPresentation.session(status: "running", responding: false, queuedCount: 1).stage, .received)
    }

    func testPreviewProjectsItsOwnStatusWithoutMergedTranscript() {
        XCTAssertEqual(ChatRunningPresentation.preview(status: "failed").stage, .failed)
        XCTAssertEqual(ChatRunningPresentation.preview(status: "stopped").stage, .stopped)
        XCTAssertEqual(ChatRunningPresentation.preview(status: "starting").stage, .received)
        XCTAssertEqual(ChatRunningPresentation.preview(status: "unavailable").label, "执行会话暂不可用")
    }

    func testCompletionFoldsUnlessUserAlreadyChoseOtherwise() {
        XCTAssertFalse(ChatDisclosurePresentation.expanded(userChoice: nil, running: false, attention: false))
        XCTAssertTrue(ChatDisclosurePresentation.expanded(userChoice: nil, running: false, attention: true))
        XCTAssertTrue(ChatDisclosurePresentation.expanded(userChoice: true, running: false, attention: false))
        XCTAssertFalse(ChatDisclosurePresentation.expanded(userChoice: false, running: true, attention: true))
    }

    func testActivityFoldOnlyOpensForTheLatestRunningGroup() {
        XCTAssertTrue(ChatDisclosurePresentation.activityExpanded(userChoice: nil, isNewest: true, running: true))
        XCTAssertFalse(ChatDisclosurePresentation.activityExpanded(userChoice: nil, isNewest: false, running: true))
        XCTAssertFalse(ChatDisclosurePresentation.activityExpanded(userChoice: nil, isNewest: true, running: false))
        XCTAssertTrue(ChatDisclosurePresentation.activityExpanded(userChoice: true, isNewest: false, running: false))
        XCTAssertFalse(ChatDisclosurePresentation.activityExpanded(userChoice: false, isNewest: true, running: true))
    }

    func testMissingResultIsNotSuccessAndErrorWins() {
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: false, isError: false, running: false), "未收到结果")
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: true, isError: true, running: true), "失败")
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: true, isError: false, running: true), "完成")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOptionalRuntimeFieldsAndLegacyInitializers() throws {
        let legacy = try decode(StructuredSessionState.self, #"{"inFlight":true}"#)
        XCTAssertNil(legacy.phase)
        XCTAssertNil(legacy.lastActivityAt)
        let oldInit = StructuredSessionState(runner: nil, engine: nil, model: nil, lastError: nil,
                                            inFlight: true, activeRequestId: nil, turnStartedAt: nil)
        XCTAssertNil(oldInit.phase)
        XCTAssertNil(ConversationTurn(role: "user", content: []).requestId)
        let missing = try decode(WsData.self, "{}")
        let cleared = try decode(WsData.self, #"{"structuredState":null,"ptyTurnStartedAt":null}"#)
        XCTAssertFalse(missing.$structuredState.isPresent)
        XCTAssertTrue(cleared.$structuredState.isPresent)
        XCTAssertTrue(cleared.$ptyTurnStartedAt.isPresent)
        XCTAssertNil(cleared.structuredState)
    }

    @MainActor
    func testWebSocketFactsReplaceRequestsAndClearAtEnd() throws {
        let store = ChatStore(sessionId: "s", api: WandAPI(baseURL: URL(string: "http://fixture.example.test")!, token: nil))
        defer { store.shutdown() }
        func receive(_ json: String) throws { store.receiveForTesting(try decode(WsIncoming.self, json)) }
        try receive(#"{"type":"init","data":{"id":"s","status":"running","sessionKind":"structured","structuredState":{"inFlight":true,"activeRequestId":"r1","phase":"background","turnStartedAt":"2026-01-01T00:00:00Z","lastActivityAt":"2026-01-01T00:01:00Z"}}}"#)
        XCTAssertEqual(store.snapshot?.structuredState?.phase, "background")
        try receive(#"{"type":"output","data":{"isResponding":true}}"#)
        XCTAssertEqual(store.snapshot?.structuredState?.activeRequestId, "r1")
        try receive(#"{"type":"status","data":{"structuredState":{"inFlight":true,"activeRequestId":"r2"}}}"#)
        XCTAssertEqual(store.snapshot?.structuredState?.activeRequestId, "r2")
        XCTAssertNil(store.snapshot?.structuredState?.turnStartedAt)
        XCTAssertNil(store.snapshot?.structuredState?.phase)
        try receive(#"{"type":"ended","data":{"status":"failed","structuredState":{"inFlight":true,"activeRequestId":"r2"}}}"#)
        XCTAssertFalse(store.isResponding)
        XCTAssertEqual(store.snapshot?.status, "failed")
        XCTAssertNil(store.snapshot?.structuredState?.activeRequestId)
        try receive(#"{"type":"init","data":{"id":"s","status":"running","sessionKind":"structured"}}"#)
        XCTAssertNil(store.snapshot?.structuredState)
    }

    @MainActor
    func testPtyAnchorsMissingNullAndNewTurnAreDistinct() throws {
        let store = ChatStore(sessionId: "s", api: WandAPI(baseURL: URL(string: "http://fixture.example.test")!, token: nil))
        defer { store.shutdown() }
        func receive(_ json: String) throws { store.receiveForTesting(try decode(WsIncoming.self, json)) }
        try receive(#"{"type":"init","data":{"id":"s","status":"running","sessionKind":"pty","ptyBusy":true,"ptyTurnStartedAt":"2026-01-01T00:00:00Z","ptyLastActivityAt":"2026-01-01T00:01:00Z"}}"#)
        try receive(#"{"type":"output","data":{"chunk":"x"}}"#)
        XCTAssertEqual(store.snapshot?.ptyLastActivityAt, "2026-01-01T00:01:00Z")
        try receive(#"{"type":"status","data":{"ptyTurnStartedAt":"2026-01-01T00:02:00Z"}}"#)
        XCTAssertNil(store.snapshot?.ptyLastActivityAt)
        try receive(#"{"type":"status","data":{"ptyTurnStartedAt":null}}"#)
        XCTAssertNil(store.snapshot?.ptyTurnStartedAt)
        try receive(#"{"type":"status","data":{"ptyBusy":false}}"#)
        try receive(#"{"type":"status","data":{"ptyBusy":true}}"#)
        XCTAssertNil(store.snapshot?.ptyTurnStartedAt)
        try receive(#"{"type":"ended"}"#)
        XCTAssertFalse(store.isResponding)
        XCTAssertEqual(store.snapshot?.ptyBusy, false)
    }

    func testCurrentToolsRetireByIDAndIgnoreForeignSources() throws {
        let snap = try decode(SessionSnapshot.self, #"{"id":"s","sessionKind":"structured","structuredState":{"inFlight":true,"activeRequestId":"r","turnStartedAt":"2026-01-01T00:00:00Z","lastActivityAt":"2026-01-01T00:00:00Z"}}"#)
        let user = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r","content":[{"type":"text","text":"开始"}]}"#)
        let tool = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","content":[{"type":"tool_use","id":"a","name":"bash","input":{"command":"SECRET"}},{"type":"tool_use","id":"b","name":"read","input":{}},{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"failed"}]}"#)
        func project(_ turns: [ConversationTurn]) -> ChatRunningPresentation {
            .live(snapshot: snap, messages: turns, status: "running", responding: true)
        }
        let active = project([user, tool])
        XCTAssertEqual(active.toolID, "a")
        XCTAssertFalse(active.label.contains("SECRET"))
        XCTAssertTrue(active.text(at: ISO8601DateFormatter().date(from: "2026-01-01T00:02:00Z")!).contains("已运行 2 分钟"))
        let result = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r","content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"failed"}]}"#)
        XCTAssertEqual(project([user, tool, result]).stage, .executing)
        let foreign = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","author":{"id":"x","name":"x","sessionId":"other"},"content":[{"type":"thinking","thinking":"x"}]}"#)
        XCTAssertEqual(project([user, foreign]).stage, .executing)
        let child = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","content":[{"type":"tool_use","id":"child","name":"bash","input":{},"__subagent":{"agentId":"child"}}]}"#)
        XCTAssertEqual(project([user, child]).stage, .executing)
        let optimistic = ConversationTurn(role: "user", content: [.text(text: "下一轮", subagent: nil)])
        XCTAssertFalse(project([user, tool, optimistic]).hasClock)
        let newUser = try decode(ConversationTurn.self, #"{"role":"user","requestId":"next","content":[{"type":"text","text":"下一轮"}]}"#)
        XCTAssertFalse(project([user, tool, newUser]).hasClock)
    }

    func testFinishedMessageStreamDoesNotCompleteToolOrQuestion() throws {
        let snap = try decode(SessionSnapshot.self, #"{"id":"s","sessionKind":"structured","structuredState":{"inFlight":true,"activeRequestId":"r","turnStartedAt":"2026-01-01T00:00:00Z"}}"#)
        let user = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r","content":[{"type":"text","text":"开始"}]}"#)
        let tool = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","completedAt":"2026-01-01T00:00:01Z","content":[{"type":"tool_use","id":"a","name":"bash","input":{}}]}"#)
        let question = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","completedAt":"2026-01-01T00:00:01Z","content":[{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{}}]}"#)
        func project(_ turns: [ConversationTurn]) -> ChatRunningPresentation {
            .live(snapshot: snap, messages: turns, status: "running", responding: true)
        }
        XCTAssertEqual(project([user, tool]).stage, .tool)
        XCTAssertEqual(project([user, question]).stage, .waiting)
        let result = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r","content":[{"type":"tool_result","tool_use_id":"q","content":"回答"}]}"#)
        XCTAssertEqual(project([user, question, result]).stage, .executing)
    }

    func testTerminalActivityOnlyAppliesToLatestUnfinishedRequest() throws {
        let user = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r","content":[{"type":"text","text":"开始"}]}"#)
        let current = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"r","content":[{"type":"tool_use","id":"a","name":"bash","input":{}}]}"#)
        let old = try decode(ConversationTurn.self, #"{"role":"assistant","requestId":"old","content":[]}"#)
        XCTAssertEqual(ChatRunningPresentation.activityTerminal(status: "stopped", sessionID: "s", messages: [user, current], index: 1), .stopped)
        XCTAssertNil(ChatRunningPresentation.activityTerminal(status: "failed", sessionID: "s", messages: [user, old], index: 1))
        XCTAssertNil(ChatRunningPresentation.activityTerminal(status: "failed", sessionID: "s", messages: [user, current, user], index: 1))
        XCTAssertEqual(ChatDisclosurePresentation.activityStatus(hasError: false, missingResult: true, running: false, terminal: .failed), "执行失败")
        XCTAssertEqual(ChatDisclosurePresentation.activityStatus(hasError: false, missingResult: true, running: false, terminal: .stopped), "已停止")
        XCTAssertEqual(ChatDisclosurePresentation.activityStatus(hasError: false, missingResult: true, running: false, terminal: nil), "未收到结果")
    }

    func testEmptyWindowDoesNotAdvertiseInvertedRange() {
        XCTAssertEqual(ChatDisclosurePresentation.loadedRange(offset: 0, count: 0, total: 0), "尚未加载消息，共 0 条；仅列用户提问。")
        XCTAssertEqual(ChatDisclosurePresentation.loadedRange(offset: 40, count: 2, total: 42), "已加载消息 41–42，共 42 条；仅列用户提问。")
    }
}
