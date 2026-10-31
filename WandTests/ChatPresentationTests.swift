import XCTest
import AppKit
import SwiftUI
@testable import Wand

final class ChatPresentationTests: XCTestCase {
    /// 补更早历史时必须恢复阅读锚点：prepend 会把整列往下推，
    /// 不恢复锚点就等于把读者正在读的内容扫走（与 iOS earlierLoadAnchorID、Web pendingAnchor 同一语义）。
    func testEarlierLoadRestoresTheReadingAnchor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Wand/ChatView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("private func loadEarlierKeepingAnchor()"), "Mac 侧补更早历史必须先记锚点再 prepend")
        XCTAssertTrue(source.contains("earlierLoadAnchorID = groupedMessageItems.first.map"), "锚点取当前窗口第一条消息的绝对 turn id")
        XCTAssertTrue(source.contains("private func restoreEarlierLoadAnchor(_ proxy: ScrollViewProxy)"), "prepend 完成后必须按锚点复位")
        XCTAssertTrue(source.contains("restoreEarlierLoadAnchor(proxy)"), "loadedOffset 变化时必须触发锚点复位")
        XCTAssertTrue(source.contains("if !loadingEarlier, earlierLoadAnchorID != nil"), "空页或请求失败不能让过期锚点误作用于之后的推送")
        XCTAssertTrue(source.contains("followsLatest = false\n        store.loadEarlier()"), "补历史期间不贴尾，否则会把读者拽回最新一条")
    }

    func testSessionSubtasksKeepStableIdentityAcrossTurnsAndIgnoreParentClaims() {
        let a = SubagentMeta(taskId: "child-a", agentType: "general", taskDescription: "检查 A")
        let b = SubagentMeta(taskId: "child-b", agentType: "general", taskDescription: "检查 B")
        let turns = [
            ConversationTurn(role: "assistant", content: [
                .toolUse(id: "child-a", name: "Task", description: nil, input: ["prompt": .string("完整任务说明 A")], subagent: a),
                .toolUse(id: "child-b", name: "Task", description: nil, input: [:], subagent: b),
            ]),
            ConversationTurn(role: "user", content: [
                .toolResult(toolUseId: "child-a", text: "Async agent launched successfully.\nagentId: native-a\noutput_file: /tmp/child.txt", isError: false, truncated: false, images: [], subagent: nil),
            ]),
            ConversationTurn(role: "assistant", content: [.text(text: "两个任务都已成功完成", subagent: nil)]),
        ]
        let tasks = collectNativeChatSubtasks(turns)
        XCTAssertEqual(tasks.map(\.id), ["child-a", "child-b"])
        XCTAssertEqual(tasks[0].instruction, "完整任务说明 A")
        XCTAssertEqual(tasks[0].status(running: false), "运行状态未知")
        XCTAssertNil(tasks[0].finalResult)
        XCTAssertTrue(tasks[0].diagnostics.contains("/tmp/child.txt"))
        XCTAssertTrue(tasks[0].process.isEmpty)
        let terminal = ConversationTurn(role: "user", content: [
            .toolResult(toolUseId: "child-a", text: "# 完整结果\n\n保留换行", isError: false, truncated: false, images: [], subagent: a),
        ])
        let updated = collectNativeChatSubtasks(turns + [terminal])
        XCTAssertEqual(updated.map(\.id), tasks.map(\.id))
        XCTAssertEqual(updated[0].finalResult, "# 完整结果\n\n保留换行")
        XCTAssertEqual(updated[0].status(running: true), "已完成")
        XCTAssertEqual(updated[1].status(running: false), "运行状态未知")
    }

    @MainActor
    func testNativeSubtaskPanelRendersIndependentlyAtWideAndNarrowWidths() throws {
        let meta = SubagentMeta(taskId: "child", agentType: "general", taskDescription: "原生子任务")
        let tasks = collectNativeChatSubtasks([ConversationTurn(role: "assistant", content: [
            .toolUse(id: "child", name: "Task", description: nil, input: ["prompt": .string("任务说明")], subagent: meta),
            .toolResult(toolUseId: "child", text: "# 原生结果\n\n已返回的内容", isError: false, truncated: false, images: [], subagent: nil),
        ])])
        for width in [CGFloat(420), CGFloat(900)] {
            let view = NativeChatSubtaskPanel(tasks: tasks, selectedID: .constant("child"),
                baseURL: URL(string: "http://127.0.0.1")!, running: false, onClose: {})
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let output = root.appendingPathComponent("output/architecture-stage2/task-70/native")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appendingPathComponent("panel-\(Int(width)).png"))
        }
    }

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

    func testQoderChildReceiptAndNativeTerminalAreIndependentOfParentStatus() {
        let receipt = ContentBlock.toolResult(toolUseId: "a", text: "Async agent launched successfully.\nagentId: native-a", isError: false, truncated: false, images: [], subagent: nil)
        for running in [false, true] {
            XCTAssertEqual(ChatDisclosurePresentation.subagentStatus(blocks: [receipt], taskID: "a", running: running), "运行状态未知")
        }
        let done = ContentBlock.toolResult(toolUseId: "a", text: "原生子任务通知：已完成。", isError: false, truncated: false, images: [], subagent: nil)
        XCTAssertEqual(ChatDisclosurePresentation.subagentStatus(blocks: [receipt, done], taskID: "a", running: true), "已完成")
        let failed = ContentBlock.toolResult(toolUseId: "a", text: "原生子任务通知：执行失败。", isError: true, truncated: false, images: [], subagent: nil)
        XCTAssertEqual(ChatDisclosurePresentation.subagentStatus(blocks: [receipt, failed], taskID: "a", running: false), "执行失败")
        XCTAssertEqual(ChatDisclosurePresentation.subagentStatus(blocks: [done], taskID: "other", running: false), "运行状态未知")
    }

    func testMissingResultIsNotSuccessAndErrorWins() {
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: false, isError: false, running: false), "未收到结果")
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: true, isError: true, running: true), "失败")
        XCTAssertEqual(ChatDisclosurePresentation.toolStatus(hasResult: true, isError: false, running: true), "完成")
    }

    @MainActor
    func testTodoLifecycleUsesTranscriptSourceAndObservedTerminalEvidence() throws {
        let store = ChatStore(sessionId: "todo", api: WandAPI(baseURL: URL(string: "http://fixture.example.test")!, token: nil))
        defer { store.shutdown() }
        let messages: [[String: Any]] = [
            ["role": "user", "requestId": "r1", "content": [["type": "text", "text": "相同输入"]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "list", "name": "TodoWrite", "input": ["todos": [["content": "已完成", "status": "completed"], ["content": "最后记录", "status": "in_progress"]]]]]],
        ]
        func receive(_ type: String, _ extra: [String: Any]) throws {
            var data: [String: Any] = ["id": "todo", "sessionKind": "structured", "messages": messages, "messageTotal": messages.count, "messageOffset": 0]
            data.merge(extra) { _, new in new }
            let raw = try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": "todo", "data": data])
            store.receiveForTesting(try JSONDecoder().decode(WsIncoming.self, from: raw))
        }
        let active: [String: Any] = ["status": "running", "structuredState": ["inFlight": true, "activeRequestId": "r1"]]
        let idle: [String: Any] = ["status": "idle", "structuredState": ["inFlight": false]]
        try receive("init", active)
        XCTAssertEqual(store.todoProgress?.context.kind, .running)
        try receive("output", idle)
        XCTAssertEqual(store.todoProgress?.context.kind, .unknown, "idle is not a stop receipt")
        try receive("ended", idle.merging(["turnOutcome": "stopped"]) { _, new in new })
        XCTAssertEqual(store.todoProgress?.context.kind, .stopped)
        XCTAssertEqual(store.todoProgress?.todos.filter { $0.status == "completed" }.count, 1)
        XCTAssertEqual(store.todoProgress?.todos.last?.status, "in_progress", "history must not rewrite Todo state")
        try receive("init", idle)
        XCTAssertEqual(store.todoProgress?.context.kind, .unknown, "reconnect cannot reconstruct a missed reason")
        try receive("output", ["status": "running", "structuredState": ["inFlight": true, "activeRequestId": "r2"]])
        XCTAssertNil(store.todoProgress, "accepted new request retires old Todo even before its user message arrives")
        let next = messages + [["role": "user", "requestId": "r2", "content": [["type": "text", "text": "相同输入"]]]]
        try receive("output", ["messages": next, "messageTotal": next.count, "status": "running", "structuredState": ["inFlight": true, "activeRequestId": "r2"]])
        XCTAssertNil(store.todoProgress, "new round without Todo cannot reuse the old list")
    }

    func testTodoToolResultsKeepLogicalSourceAndPartialLegacySourcesAreConservative() throws {
        let first = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r1","content":[{"type":"text","text":"开始"}]}"#)
        let task = try decode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_use","id":"todo","name":"TodoWrite","input":{"todos":[{"content":"A","status":"in_progress"}]}}]}"#)
        let answer = try decode(ConversationTurn.self, #"{"role":"user","requestId":"r2","content":[{"type":"tool_result","tool_use_id":"q","content":"是"}]}"#)
        let old = try XCTUnwrap(TodoTurnSource.find(sessionID: "s", messages: [first, task], offset: 10))
        let source = try XCTUnwrap(TodoTurnSource.find(sessionID: "s", messages: [first, task, answer], offset: 10, activeRequestID: "r2"))
        XCTAssertEqual(source.key, old.key)
        XCTAssertEqual(source.requestID, "r2")
        XCTAssertEqual(TodoItem.currentTodos(in: [first, task, answer], startIndex: source.startIndex).count, 1)
        XCTAssertNil(TodoTurnSource.find(sessionID: "s", messages: [first, task], offset: 10, leadingBlockOffset: 1))
        XCTAssertNil(TodoTurnSource.find(sessionID: "s", messages: [task], offset: 10))
        XCTAssertNil(TodoTurnSource.find(sessionID: "s", messages: [ConversationTurn(role: "user", content: [.text(text: "旧记录", subagent: nil)]), task], offset: 0))
    }

    func testTodoWaitingFailureCompletionAndEvidenceConflictRemainDistinct() throws {
        let messages = try decode([ConversationTurn].self, #"[{"role":"user","requestId":"r","content":[{"type":"text","text":"开始"}]},{"role":"assistant","content":[{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[]}}]}]"#)
        let source = try XCTUnwrap(TodoTurnSource.find(sessionID: "s", messages: messages, offset: 0))
        func view(_ status: String, active: Bool = false, permission: Bool = false, connected: Bool = true, outcome: String? = nil) -> TodoExecutionPresentation {
            .make(source: source, status: status, active: active, permission: permission, archived: false, connected: connected,
                  evidence: outcome.map { TodoTurnEvidence(sourceKey: source.key, requestID: "r", outcome: $0) })
        }
        XCTAssertEqual(view("running").kind, .waiting)
        XCTAssertEqual(view("idle").kind, .unknown)
        XCTAssertEqual(view("running", active: true).kind, .running)
        XCTAssertEqual(view("running", permission: true).kind, .permission)
        XCTAssertEqual(view("failed").kind, .failed)
        XCTAssertEqual(view("idle", outcome: "done").kind, .ended)
        XCTAssertEqual(view("idle", outcome: "stopped").kind, .stopped)
        XCTAssertEqual(view("running", active: true, outcome: "stopped").kind, .unknown)
        XCTAssertEqual(view("idle", connected: false, outcome: "stopped").kind, .unknown)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOptionalRuntimeFieldsAndLegacyInitializers() throws {
        let legacy = try decode(StructuredSessionState.self, #"{"inFlight":true}"#)
        XCTAssertNil(legacy.phase)
        XCTAssertNil(legacy.lastActivityAt)
        XCTAssertNil(legacy.inputMode)
        let steering = try decode(StructuredSessionState.self, #"{"engine":"cli","inFlight":true,"inputMode":"steer"}"#)
        XCTAssertEqual(steering.inputMode, "steer")
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

final class NativeSubtaskLiveTests: XCTestCase {
    @MainActor
    func testInstalledQoderConversationSubtaskSplitPreservesDraftAndReading() async throws {
        guard ProcessInfo.processInfo.environment["WAND_SUBTASK_LIVE"] == "1" else {
            throw XCTSkip("Installed Qoder native acceptance is opt-in and read-only")
        }
        XCTAssertTrue(NativeAcceptance.enabled)
        let storage = NativeAcceptance.defaults
        defer { NativeAcceptance.cleanup() }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(storage.string(forKey: "wand.serverURL"))))
        let token = try XCTUnwrap(storage.string(forKey: "wand.token"))
        let api = WandAPI(baseURL: origin, token: token)
        let sessionID = "3ae04c2f-c3c9-43e5-8f72-1ab5aeaeabf6"
        let snapshot = try await api.getSession(id: sessionID)
        let tasks = collectNativeChatSubtasks(snapshot.messages ?? [])
        XCTAssertEqual(tasks.count, 2, "Use the existing Qoder pair; never manufacture server data")
        let host = NSHostingView(rootView: ChatView(sessionId: sessionID, api: api, gitStatusStore: GitStatusStore()).defaultAppStorage(storage))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        if let appearance = ProcessInfo.processInfo.environment["WAND_SUBTASK_APPEARANCE"] {
            window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func marker(_ id: String) throws -> NSView { try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id }, "Missing rendered marker: \(id)") }
        func settle() async throws { try await Task.sleep(nanoseconds: 500_000_000); host.layoutSubtreeIfNeeded() }
        func click(_ id: String) async throws {
            let view = try marker(id), rect = view.convert(view.bounds, to: nil)
            // AppKit may track mouse-down synchronously; queue mouse-up first.
            let clickTime = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                    timestamp: clickTime + (type == .leftMouseUp ? 0.01 : 0), windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) }
                else { window.sendEvent(event) }
            }
            try await settle()
        }
        func capture(_ name: String) throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let output = ProcessInfo.processInfo.environment["WAND_SUBTASK_VISUAL_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? root.appendingPathComponent("output/architecture-stage2/task-70/native")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(nanoseconds: 2_000_000_000); host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .wandDesktopCommand, object: DesktopCommand.focusComposer)
        try await settle()
        let input = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        input.insertText("TASK-70 本机验收草稿，不发送", replacementRange: NSRange(location: 0, length: 0))
        try await settle()
        let draft = input.string
        let trigger = try marker("subtasks-trigger"), triggerFrame = trigger.convert(trigger.bounds, to: host)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first {
            !($0.documentView is NSTextView) && $0.convert($0.bounds, to: host).height > 300
                && $0.convert($0.bounds, to: host).minX < 1440
        })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height - 160)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin.y
        try await click("subtasks-trigger")
        XCTAssertEqual(try marker("subtasks-main").bounds.width, 1440 * 0.62, accuracy: 2)
        XCTAssertTrue(descendants(host).contains { $0 === input })
        XCTAssertEqual(input.string, draft)
        XCTAssertEqual(trigger.convert(trigger.bounds, to: host), triggerFrame)
        let mainFrame = try marker("subtasks-main").convert(marker("subtasks-main").bounds, to: host)
        let detailFrame = try marker("subtasks-panel").convert(marker("subtasks-panel").bounds, to: host)
        XCTAssertLessThanOrEqual(mainFrame.maxX, detailFrame.minX + 1, "Native main and details must be separate layout columns")
        XCTAssertEqual(detailFrame.maxX, host.bounds.maxX, accuracy: 2)
        XCTAssertLessThanOrEqual(scroll.documentView!.bounds.width, scroll.contentView.bounds.width + 1,
            "Native message content must reflow inside the main viewport")
        XCTAssertLessThanOrEqual(input.convert(input.bounds, to: host).maxX, mainFrame.maxX + 1,
            "Composer must stay within the main conversation column, not cross under the inspector")
        _ = try marker("subtask-instruction-closed-" + tasks[0].id)
        _ = try marker("subtask-instruction-closed-" + tasks[1].id)
        try capture("default-wide")
        try await click("subtask-instruction-" + tasks[0].id)
        _ = try marker("subtask-instruction-open-" + tasks[0].id)
        let detailScrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
            let rect = $0.convert($0.bounds, to: host)
            return rect.minX >= 890 && rect.minX < 1440 && rect.height > 300 && !($0.documentView is NSTextView)
        }
        XCTAssertEqual(detailScrolls.count, 2)
        let firstDetail = try XCTUnwrap(detailScrolls.first)
        firstDetail.contentView.scroll(to: NSPoint(x: 0, y: 80))
        firstDetail.reflectScrolledClipView(firstDetail.contentView)
        let firstPosition = firstDetail.contentView.bounds.origin.y
        try await click("subtask-row-" + tasks[1].id)
        _ = try marker("subtask-selected-" + tasks[1].id)
        _ = try marker("subtask-instruction-closed-" + tasks[1].id)
        try capture("default-second")
        try await click("subtask-instruction-" + tasks[1].id)
        _ = try marker("subtask-instruction-open-" + tasks[1].id)
        let secondDetail = try XCTUnwrap(detailScrolls.last)
        secondDetail.contentView.scroll(to: NSPoint(x: 0, y: 50))
        secondDetail.reflectScrolledClipView(secondDetail.contentView)
        let secondPosition = secondDetail.contentView.bounds.origin.y
        try capture("installed-wide")
        try await click("subtasks-close")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, position, accuracy: 2)
        try await click("subtasks-trigger")
        _ = try marker("subtask-selected-" + tasks[1].id)
        XCTAssertEqual(firstDetail.contentView.bounds.origin.y, firstPosition, accuracy: 2)
        XCTAssertEqual(secondDetail.contentView.bounds.origin.y, secondPosition, accuracy: 2)
        _ = try marker("subtask-instruction-open-" + tasks[1].id)
        XCTAssertEqual(input.string, draft)
        window.makeFirstResponder(input)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        try await settle()
        XCTAssertEqual(try marker("subtasks-main").bounds.width, 1440, accuracy: 2)
        XCTAssertEqual(input.string, draft)
        host.frame.size.width = 900; window.setContentSize(NSSize(width: 900, height: 900))
        try await settle(); try await click("subtasks-trigger")
        XCTAssertEqual(try marker("subtasks-panel").bounds.width, 900, accuracy: 2)
        try await click("subtask-instruction-" + tasks[1].id)
        _ = try marker("subtask-instruction-closed-" + tasks[1].id)
        try capture("installed-900px")
        try await click("subtasks-trigger")
        XCTAssertEqual(input.string, draft)
    }

}

final class NativeQueueDensityTests: XCTestCase {
    @MainActor
    func testQueueDensityUsesActualOverflowAndNativeActions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("output/architecture-stage2/qoderwake-p2-previews/TASK-159/implementation/native")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let long = String(repeating: "完整正文保留换行与路径。\n", count: 12) + "全文末尾不可丢失"
        var heights: [String: CGFloat] = [:]
        for width in [CGFloat(536), CGFloat(264)] {
            for (name, text) in [("short", "先检查桌面。"), ("long", long)] {
                let row = QueueItemRow(index: 0, text: text, onPromote: {}, onDelete: {}, onRetrieve: {}, onMove: { _ in }, canRetrieve: true, canDelete: true, count: 2)
                let host = NSHostingView(rootView: row.frame(width: width).padding(8).background(Theme.surface).transaction { $0.animation = nil; $0.disablesAnimations = true })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 16, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host; window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil }
                host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
                heights["\(Int(width))-\(name)"] = host.fittingSize.height
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 17)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("queue-\(Int(width))-\(name).png"))
            }
        }
        XCTAssertLessThan(try XCTUnwrap(heights["536-short"]), 80)
        XCTAssertGreaterThan(try XCTUnwrap(heights["264-short"]), try XCTUnwrap(heights["536-short"]))
    }

    @MainActor
    func testQueueFullTextAndRetrieveUseRealNativeButtons() async throws {
        var retrieved = 0
        let long = String(repeating: "长文完整内容不可丢失。\n", count: 12) + "全文末尾"
        let row = QueueItemRow(index: 0, text: long, onPromote: {}, onDelete: {}, onRetrieve: { retrieved += 1 }, onMove: { _ in }, canRetrieve: true, canDelete: true, count: 2)
        let host = NSHostingView(rootView: row.frame(width: 536).padding(8).background(Theme.surface).transaction { $0.animation = nil; $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 552, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 120_000_000)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func press(_ id: String) throws {
            let node = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id }, "Missing native queue control: \(id)")
            let rect = node.convert(node.bounds, to: nil)
            window.makeKeyAndOrderFront(nil)
            // AppKit may track mouse-down synchronously; queue mouse-up first.
            let clickTime = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [], timestamp: clickTime + (type == .leftMouseUp ? 0.01 : 0), windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) }
                else { window.sendEvent(event) }
            }
        }
        let collapsed = host.fittingSize.height
        try press("queue-expand-0"); try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, collapsed + 80)
        try press("queue-expand-0"); try await Task.sleep(nanoseconds: 120_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 1)
        try press("queue-retrieve-0"); XCTAssertEqual(retrieved, 1)
    }

}

