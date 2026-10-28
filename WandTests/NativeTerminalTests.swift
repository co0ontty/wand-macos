import AppKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class NativeTerminalTests: XCTestCase {
    private let api = WandAPI(baseURL: URL(string: "https://terminal.example.test")!, token: nil)

    private func event(_ type: String, seq: Int? = nil, data: [String: Any] = [:],
                       id: String = "pty-1", bytes: Int? = nil) throws -> WsIncoming {
        var json: [String: Any] = ["type": type, "sessionId": id, "data": data]
        if let seq { json["seq"] = seq }
        if let bytes { json["ptyBytes"] = bytes }
        return try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func store(_ socket: RecordingTerminalSocket) -> PtyTerminalStore {
        let defaults = UserDefaults(suiteName: "WandTerminalTests.\(UUID().uuidString)")!
        return PtyTerminalStore(sessionId: "pty-1", api: api, socket: socket, defaults: defaults)
    }

    private func visibleText(_ view: NativeTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
        }.joined(separator: "\n")
    }

    func testCheckpointReplaysGeometryInOrderAndPreservesModes() throws {
        let view = NativeTerminalView()
        var replies: [String] = []
        var sizes: [String] = []
        view.onInput = { text, _ in replies.append(text) }
        view.onSizeChange = { sizes.append("\($0)x\($1)") }
        let data = try XCTUnwrap(event("init", data: [
            "output": "THIS MUST NOT BE REPLAYED",
            "terminalState": [
                "version": 1, "cols": 8, "rows": 4,
                "data": "\u{1B}[?1049h\u{1B}[?2004h\u{1B}[H1234567\u{1B}[6n",
                "pending": [
                    ["type": "resize", "cols": 12, "rows": 4],
                    ["type": "data", "data": "XY"],
                ],
            ],
        ]).data)
        view.restore(data)
        XCTAssertTrue(visibleText(view).hasPrefix("1234567XY"))
        XCTAssertFalse(visibleText(view).contains("THIS MUST"))
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode, "Fitting must not soft-reset ANSI modes")
        XCTAssertTrue(replies.isEmpty, "Historical terminal queries must not be sent to the live process")
        XCTAssertEqual(sizes.count, 1, "Only the final native geometry may be sent to the server")
        XCTAssertEqual(view.nativeBackgroundColor, NativeTerminalView.canvasColor)
    }

    func testLegacyAndUnknownVersionRestoreReplaceRatherThanAppend() throws {
        let view = NativeTerminalView()
        view.feedOutput("OLD CONTENT")
        let data = try XCTUnwrap(event("init", data: [
            "output": "NEW CONTENT", "ptyCols": 80, "ptyRows": 24,
            "terminalState": ["version": 2, "cols": 80, "rows": 24, "data": "INVALID", "pending": []],
        ]).data)
        view.restore(data)
        view.restore(data)
        XCTAssertTrue(visibleText(view).hasPrefix("NEW CONTENT"))
        XCTAssertFalse(visibleText(view).contains("OLD CONTENT"))
        XCTAssertFalse(visibleText(view).contains("INVALID"))
        XCTAssertEqual(visibleText(view).components(separatedBy: "NEW CONTENT").count, 2)
    }

    func testLiveDeviceRepliesAreNotUserInput() {
        let view = NativeTerminalView()
        var replies: [(String, Bool)] = []
        view.onInput = { replies.append(($0, $1)) }
        view.feedOutput("\u{1B}[6n")
        XCTAssertEqual(replies.count, 1)
        XCTAssertFalse(replies[0].1)
        XCTAssertTrue(replies[0].0.hasPrefix("\u{1B}["))
    }

    func testIMEPreeditDoesNotSendAndAttributedCommitStaysSeparateFromReturn() {
        let view = NativeTerminalView()
        var inputs: [String] = []
        view.onInput = { text, _ in inputs.append(text) }
        view.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(inputs.isEmpty)
        view.insertText(NSAttributedString(string: "中文输入"),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(inputs, ["中文输入"])
        view.send(txt: "\r")
        XCTAssertEqual(inputs, ["中文输入", "\r"])
    }

    func testStreamingShellOutputKeepsManualSelectionAndScrollPosition() {
        let view = NativeTerminalView()
        view.feedOutput((0..<100).map { "line-\($0)\r\n" }.joined())
        view.scroll(toPosition: 0)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        let selected = view.selection.getSelectedText()
        let firstLine = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        XCTAssertEqual(selected, "line-0")
        view.feedOutput("more output\r\n")
        XCTAssertTrue(view.selection.active, "Streaming output must not cancel a user's copy selection")
        XCTAssertEqual(view.selection.getSelectedText(), selected)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), firstLine)
        XCTAssertTrue(view.allowMouseReporting, "Keeping a selection must not disable TUI mouse support")
    }

    func testFreshCheckpointAndLiveOutputFollowTailUntilUserScrollsUp() throws {
        let view = NativeTerminalView()
        let history = (0..<120).map { "line-\($0)\r\n" }.joined()
        let data = try XCTUnwrap(event("init", data: ["output": history]).data)
        // A new terminal has scrollPosition == 0 even though nobody scrolled up.
        XCTAssertEqual(view.scrollPosition, 0)
        view.restore(data)
        XCTAssertEqual(view.scrollPosition, 1, "Initial history must open at the newest output")
        view.feedOutput("newest\r\n")
        XCTAssertEqual(view.scrollPosition, 1, "Streaming output must continue to follow")
        XCTAssertTrue(visibleText(view).contains("newest"))

        view.scroll(toPosition: 0)
        let firstLine = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        view.feedOutput("later\r\n")
        XCTAssertEqual(view.scrollPosition, 0, "Reading history must pause auto-follow")
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), firstLine)

        view.scroll(toPosition: 1)
        view.feedOutput("resumed\r\n")
        XCTAssertEqual(view.scrollPosition, 1, "Returning to the tail must resume auto-follow")
        XCTAssertTrue(visibleText(view).contains("resumed"))
    }

    func testResyncPreservesScrollbackButFollowsWhenAtTail() throws {
        let view = NativeTerminalView()
        let data = try XCTUnwrap(event("init", data: [
            "output": (0..<120).map { "line-\($0)\r\n" }.joined(),
        ]).data)
        view.restore(data)
        view.scroll(toPosition: 0)
        view.restore(data)
        XCTAssertEqual(view.scrollPosition, 0)
        view.scroll(toPosition: 1)
        view.restore(data)
        XCTAssertEqual(view.scrollPosition, 1)
    }

    func testCheckpointInvalidatesSelectionsFromTheOldScreen() throws {
        let view = NativeTerminalView()
        view.feedOutput("old screen")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        view.restore(try XCTUnwrap(event("init", data: ["output": "new screen"]).data))
        XCTAssertFalse(view.selection.active)
    }

    func testMouseTrackingTUIStillClearsStaleSelectionsOnRepaint() {
        let view = NativeTerminalView()
        view.feedOutput("\u{1B}[?1049h\u{1B}[?1000hTUI screen")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        XCTAssertTrue(view.selection.active)
        view.feedOutput("\u{1B}[Hnew screen")
        XCTAssertFalse(view.selection.active)
        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertEqual(view.getTerminal().mouseMode, .vt200)
    }

    func testIMEConfirmationDoesNotSendKittyReturnOrItsKeyRelease() throws {
        let view = NativeTerminalView()
        var inputs: [String] = []
        view.onInput = { text, _ in inputs.append(text) }
        view.feedOutput("\u{1B}[>31u")
        XCTAssertFalse(view.getTerminal().keyboardEnhancementFlags.isEmpty)
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if let event = view.handleCompositionEvent(down) { view.keyDown(with: event) }
        XCTAssertTrue(inputs.isEmpty, "Candidate confirmation must not reach the remote application")
        // Some input methods clear marked text before the matching key-up is delivered.
        view.unmarkText()
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if let event = view.handleCompositionEvent(up) { view.keyUp(with: event) }
        XCTAssertTrue(inputs.isEmpty, "An IME-owned key release must not leak into Kitty reports")
        if let event = view.handleCompositionEvent(down) { view.keyDown(with: event) }
        XCTAssertFalse(inputs.isEmpty, "A later non-composing Return must still reach the TUI")
    }

    func testIMEFilteringKeepsAppShortcutsAndCatchesInitialCompositionKeyRelease() throws {
        let view = NativeTerminalView()
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let commandF = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(view.handleCompositionEvent(commandF) === commandF)
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertNil(view.handleCompositionEvent(release), "The first phonetic key was routed before marked text existed")
        view.unmarkText()
        XCTAssertTrue(view.handleCompositionEvent(release) === release)
    }

    func testIMECommitStaysLiteralTextWithEnhancedKeyboardProtocol() {
        let view = NativeTerminalView()
        var inputs: [String] = []
        view.onInput = { text, _ in inputs.append(text) }
        view.feedOutput("\u{1B}[>31u")
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(inputs.isEmpty, "Candidate navigation cannot become remote cursor movement")
        view.insertText(NSAttributedString(string: "中"),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(inputs, ["中"])
        XCTAssertFalse(view.hasMarkedText())
    }

    func testNativePastePreservesBracketedPasteAndDoesNotSubmit() {
        let view = NativeTerminalView()
        var inputs: [String] = []
        view.onInput = { text, _ in inputs.append(text) }
        view.feedOutput("\u{1B}[?2004h")
        view.pasteText("  中文\nsecond line")
        XCTAssertEqual(inputs, ["\u{1B}[200~", "  中文\nsecond line", "\u{1B}[201~"])
        XCTAssertFalse(inputs.contains("\r"))
        view.pasteText("")
        XCTAssertEqual(inputs.count, 3, "An unavailable or empty clipboard must not emit paste delimiters")
    }

    func testNativeControlKeysAndReturnKeepTerminalSemantics() throws {
        let view = NativeTerminalView()
        var inputs: [String] = []
        view.onInput = { text, _ in inputs.append(text) }
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        let controlC = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        view.keyDown(with: controlC)
        XCTAssertEqual(inputs, ["\r", "\u{1B}[A", "\u{03}"])
    }

    func testInputChunkingPreservesUnicodeWhitespaceAndControlBytes() {
        let input = String(repeating: "  中文🙂\t\n", count: 8000) + "\r\u{1B}[A"
        let chunks = PtyTerminalInput.chunks(input)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), input)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 16 * 1024 })
        XCTAssertEqual(PtyTerminalInput.chunks("\r"), ["\r"])
        XCTAssertEqual(PtyTerminalInput.chunks(""), [])
    }

    func testOSC52CannotReadClipboardAndClearDoesNotSendToShell() {
        let view = NativeTerminalView()
        var sent: [String] = []
        view.onInput = { text, _ in sent.append(text) }
        XCTAssertNil(view.clipboardRead(source: view))
        view.feedOutput("hello\r\nworld")
        view.clearScrollback()
        XCTAssertTrue(sent.isEmpty)
    }

    func testOutputIsConsumedBeforeACKAndMetadataDoesNotRepaint() throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        defer { store.shutdown() }
        store.start()
        socket.onEvent?(try event("init", data: ["status": "running", "output": "hello"]))
        XCTAssertTrue(store.ready)
        var consumedBeforeAck = false
        socket.onAck = { _ in consumedBeforeAck = self.visibleText(store.terminal).contains("hello中文") }
        socket.onEvent?(try event("output", data: ["chunk": "中文", "incremental": true], bytes: 6))
        XCTAssertTrue(consumedBeforeAck)
        XCTAssertEqual(socket.acks, [6])
        socket.onEvent?(try event("output", data: ["title": "metadata", "output": "STALE RAW HISTORY"]))
        XCTAssertTrue(visibleText(store.terminal).contains("hello中文"))
        XCTAssertFalse(visibleText(store.terminal).contains("STALE"))
    }

    func testDisconnectResyncAndEndedStatesBlockInputWithoutQueuingIt() throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        defer { store.shutdown() }
        store.start()
        store.sendInput("before-init")
        XCTAssertTrue(socket.inputs.isEmpty)
        socket.onEvent?(try event("init", data: ["status": "running"]))
        store.sendInput("echo native")
        store.sendInput("\r")
        XCTAssertEqual(socket.inputs.map(\.0), ["echo native", "\r"])
        socket.onConnectionChange?(false)
        store.sendInput("offline")
        socket.onEvent?(try event("init", data: ["status": "running"]))
        XCTAssertEqual(socket.inputs.count, 2)
        socket.onResync?()
        store.sendInput("during-resync")
        XCTAssertEqual(socket.inputs.count, 2)
        socket.onEvent?(try event("init", data: ["status": "exited"]))
        store.sendInput("after-exit")
        XCTAssertEqual(socket.inputs.count, 2)
    }

    func testPtyWriteErrorRequiresResyncBeforeFurtherInput() throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        defer { store.shutdown() }
        store.start()
        socket.onEvent?(try event("init", data: ["status": "running", "output": "ready"]))
        XCTAssertTrue(store.ready)

        socket.onEvent?(try event("pty_error"))
        XCTAssertFalse(store.ready)
        XCTAssertTrue(store.loadError?.contains("未确认") == true)
        store.sendInput("should-not-repeat")
        XCTAssertTrue(socket.inputs.isEmpty)

        socket.onEvent?(try event("init", data: ["status": "running", "output": "ready"]))
        XCTAssertTrue(store.ready)
        XCTAssertNil(store.loadError)
    }

    func testLifecycleDoesNotDuplicateSubscriptionsOrApplyLateEvents() throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        store.start()
        store.start()
        XCTAssertEqual(socket.connects, 1)
        XCTAssertEqual(socket.subscriptions, ["pty-1:true"])
        socket.onEvent?(try event("init", data: ["output": "other"], id: "another-session"))
        XCTAssertFalse(store.ready)
        store.shutdown()
        socket.onEvent?(try event("init", data: ["output": "late"]))
        XCTAssertFalse(store.ready)
        XCTAssertFalse(visibleText(store.terminal).contains("late"))
        store.start()
        XCTAssertEqual(socket.connects, 2)
        store.shutdown()
    }

    func testResizeDebouncesAndStoppedViewsSendNothing() async throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        store.start()
        socket.onEvent?(try event("init", data: ["status": "running"]))
        store.terminal.setFrameSize(NSSize(width: 700, height: 400))
        store.terminal.setFrameSize(NSSize(width: 900, height: 500))
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(socket.sizes.last?.0, store.terminal.getTerminal().cols)
        XCTAssertEqual(socket.sizes.last?.1, store.terminal.getTerminal().rows)
        let count = socket.sizes.count
        store.terminal.setFrameSize(NSSize(width: 600, height: 300))
        store.shutdown()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(socket.sizes.count, count)
    }

    func testQuickTerminalDockPreferenceIsClientAndServerScoped() {
        let name = "QuickTerminalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = QuickTerminalModel(api: api, defaults: defaults)
        XCTAssertEqual(model.dock, .right)
        model.setDock(.bottom)
        XCTAssertEqual(QuickTerminalModel(api: api, defaults: defaults).dock, .bottom)
        let another = WandAPI(baseURL: URL(string: "https://another.example.test")!, token: nil)
        XCTAssertEqual(QuickTerminalModel(api: another, defaults: defaults).dock, .right)
        XCTAssertEqual(QuickTerminalDock(stored: "bad-value"), .right)
    }

    func testQuickTerminalReopenRestoresInputAndKeepsTheSameShellAcrossDocks() async throws {
        let host = "quick-terminal-\(UUID().uuidString).example.test"
        var requests: [String] = []
        CommunicationsContractURLProtocol.register(host: host) { request in
            requests.append(request.httpMethod ?? "GET")
            return Data(#"{"id":"pty-1","sessionKind":"pty","sessionSource":"quick-terminal","cwd":"/worktree","status":"running"}"#.utf8)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommunicationsContractURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = WandAPI(baseURL: URL(string: "https://\(host)")!, token: nil, session: session)
        let name = "QuickTerminalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let socket = RecordingTerminalSocket()
        let model = QuickTerminalModel(api: api, defaults: defaults) { id, api in
            PtyTerminalStore(sessionId: id, api: api, socket: socket, defaults: defaults)
        }
        defer {
            model.terminal?.shutdown()
            session.invalidateAndCancel()
            CommunicationsContractURLProtocol.unregister(host: host)
            defaults.removePersistentDomain(forName: name)
        }
        model.open(cwd: "/worktree")
        try await waitUntil { !model.busy }
        let store = try XCTUnwrap(model.terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = store.terminal
        defer { window.close() }
        socket.onEvent?(try event("init", data: ["status": "running", "output": "KEEP_OUTPUT"]))
        model.setDock(.bottom)
        model.close()
        XCTAssertFalse(store.terminal.inputEnabled)
        model.open(cwd: "/different-workspace")
        XCTAssertTrue(store.terminal.inputEnabled, "Explicit reopen must enable input before requesting AppKit focus")
        XCTAssertTrue(window.firstResponder === store.terminal)
        XCTAssertTrue(model.terminal === store)
        XCTAssertTrue(visibleText(store.terminal).contains("KEEP_OUTPUT"))
        XCTAssertEqual(model.dock, .bottom)
        model.setDock(.right)
        XCTAssertTrue(model.terminal === store)
        XCTAssertEqual(QuickTerminalModel(api: api, defaults: defaults).dock, .right)
        XCTAssertEqual(socket.connects, 1)
        XCTAssertEqual(requests, ["POST"], "Docking/reopen must not create or reconnect a shell")
        let restoredSocket = RecordingTerminalSocket()
        let restored = QuickTerminalModel(api: api, defaults: defaults) { id, api in
            PtyTerminalStore(sessionId: id, api: api, socket: restoredSocket, defaults: defaults)
        }
        defer { restored.terminal?.shutdown() }
        XCTAssertEqual(restored.dock, .right)
        restored.open(cwd: "/different-workspace")
        try await waitUntil { !restored.busy }
        XCTAssertNotNil(restored.terminal)
        XCTAssertEqual(restoredSocket.subscriptions, ["pty-1:true"])
        XCTAssertEqual(requests, ["POST", "GET"], "A fresh client model reads the saved shell instead of creating another")
        if let directory = ProcessInfo.processInfo.environment["WAND_TERMINAL_SCREENSHOT_DIR"] {
            try await captureQuickTerminal(model: model, directory: directory)
        }
        socket.onConnectionChange?(false)
        model.close()
        model.open(cwd: nil)
        XCTAssertFalse(store.terminal.inputEnabled, "Reopening a disconnected shell cannot enable input")
        socket.onEvent?(try event("init", data: ["status": "exited"]))
        model.close()
        model.open(cwd: nil)
        XCTAssertFalse(store.terminal.inputEnabled, "An ended shell stays read-only when reopened")
    }

    func testQuickTerminalMissingReferenceRequiresExplicitReplacement() async throws {
        for status in [404, 410] {
            let fixture = QuickTerminalRecoveryFixture()
            defer { fixture.close() }
            fixture.getStatus = status
            let model = fixture.model()
            model.open(cwd: "/new-worktree")
            try await waitUntil { !model.busy }
            XCTAssertTrue(model.canCreateTerminal)
            XCTAssertTrue(model.recoveryMessage?.contains("已不存在") == true)
            XCTAssertEqual(fixture.methods, ["GET"])
            model.close()
            model.open(cwd: "/new-worktree")
            try await waitUntil { !model.busy }
            XCTAssertEqual(fixture.methods, ["GET", "GET"], "Reopening cannot silently create a process")
            model.createNewTerminal()
            model.createNewTerminal()
            try await waitUntil { !model.busy }
            XCTAssertNotNil(model.terminal)
            XCTAssertEqual(fixture.methods, ["GET", "GET", "POST"])
            XCTAssertEqual(fixture.defaults.string(forKey: fixture.key + ".session"), "pty-new")
            XCTAssertFalse(fixture.defaults.bool(forKey: fixture.key + ".creating"))
            XCTAssertFalse(model.canCreateTerminal)
        }
    }

    func testQuickTerminalTransientFailuresKeepOriginalReference() async throws {
        for status in [401, 403, 500, 503, -1] {
            let fixture = QuickTerminalRecoveryFixture()
            defer { fixture.close() }
            fixture.getStatus = status
            let model = fixture.model()
            model.open(cwd: "/worktree")
            try await waitUntil { !model.busy }
            XCTAssertFalse(model.canCreateTerminal, "HTTP \(status) does not confirm that the original terminal is gone")
            model.createNewTerminal()
            XCTAssertEqual(fixture.methods, ["GET"])
            XCTAssertEqual(fixture.defaults.string(forKey: fixture.key + ".session"), "pty-old")
            fixture.getStatus = 200
            model.reconnect()
            try await waitUntil { !model.busy }
            XCTAssertNotNil(model.terminal)
            XCTAssertEqual(fixture.methods, ["GET", "GET"])
        }
    }

    func testQuickTerminalEndedProcessCanBeReplacedWithoutStoppingOrDeletingHistory() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        let model = fixture.model()
        model.open(cwd: "/worktree")
        try await waitUntil { !model.busy }
        let original = try XCTUnwrap(model.terminal)
        fixture.sockets[0].onEvent?(try event("init", data: ["status": "running", "output": "OLD HISTORY"], id: "pty-old"))
        XCTAssertFalse(model.canCreateTerminal)
        fixture.sockets[0].onEvent?(try event("ended", data: ["status": "exited"], id: "pty-old"))
        XCTAssertTrue(model.canCreateTerminal)
        XCTAssertTrue(model.recoveryMessage?.contains("已结束") == true)
        model.createNewTerminal()
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.terminal === original)
        XCTAssertTrue(visibleText(original.terminal).contains("OLD HISTORY"))
        XCTAssertEqual(fixture.methods, ["GET", "POST"], "Replacement only creates; it must never stop/delete the original session")
    }

    func testQuickTerminalEndedSnapshotAllowsReplacementBeforeSocketConnects() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        fixture.snapshotStatus = "exited"
        let model = fixture.model()
        model.open(cwd: "/worktree")
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.canCreateTerminal)
        XCTAssertEqual(model.connectionLabel, "进程已结束")
        fixture.sockets[0].onEvent?(try event("init", data: ["status": "running"], id: "pty-old"))
        XCTAssertFalse(model.canCreateTerminal, "A newer runtime fact supersedes the read snapshot")
        fixture.sockets[0].onConnectionChange?(false)
        XCTAssertFalse(model.canCreateTerminal, "A later disconnect cannot revive the superseded ended snapshot")
        fixture.sockets[0].onEvent?(try event("ended", data: ["status": "exited"], id: "pty-old"))
        XCTAssertTrue(model.canCreateTerminal)
        fixture.snapshotStatus = "running"
        model.reconnect()
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.canCreateTerminal, "A newer HTTP fact also supersedes the old runtime status before reconnect finishes")
    }

    func testQuickTerminalUnknownReplacementIsNotRetriedAfterReopenOrReload() async throws {
        for postStatus in [503, 404, 200] {
            let fixture = QuickTerminalRecoveryFixture()
            defer { fixture.close() }
            fixture.getStatus = 404
            fixture.postStatus = postStatus
            fixture.invalidPostResponse = postStatus == 200
            let model = fixture.model()
            model.open(cwd: "/worktree")
            try await waitUntil { !model.busy }
            model.createNewTerminal()
            try await waitUntil { !model.busy }
            XCTAssertFalse(model.canCreateTerminal)
            XCTAssertTrue(fixture.defaults.bool(forKey: fixture.key + ".creating"))
            model.reconnect()
            model.open(cwd: nil)
            model.createNewTerminal()
            let reloaded = fixture.model()
            reloaded.open(cwd: "/worktree")
            reloaded.createNewTerminal()
            XCTAssertEqual(fixture.methods, ["GET", "POST"], "An unknown creation result remains guarded across every retry entry")
            XCTAssertNil(reloaded.terminal)
        }
    }

    func testQuickTerminalReconnectChecksMountedSessionBeforeReattaching() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        let model = fixture.model()
        model.open(cwd: "/worktree")
        try await waitUntil { !model.busy }
        let original = try XCTUnwrap(model.terminal)
        fixture.sockets[0].onEvent?(try event("init", data: ["status": "running"], id: "pty-old"))
        model.reconnect()
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.terminal === original, "A successful reconnect keeps the terminal surface")
        XCTAssertEqual(fixture.sockets[0].connects, 2)
        fixture.getStatus = 404
        model.reconnect()
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.canCreateTerminal, "A reference deleted after mounting must not be trapped in WebSocket retries")
        XCTAssertFalse(original.terminal.inputEnabled)
        fixture.getStatus = 503
        model.reconnect()
        try await waitUntil { !model.busy }
        XCTAssertFalse(model.canCreateTerminal, "The latest failed verification must not retain an old replacement decision")
        XCTAssertEqual(fixture.methods, ["GET", "GET", "GET", "GET"])
    }

    func testQuickTerminalReplacementIsSharedAcrossWindows() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        fixture.getStatus = 404
        let first = fixture.model(), second = fixture.model()
        first.open(cwd: "/first")
        second.open(cwd: "/second")
        try await waitUntil { !first.busy && !second.busy }
        first.createNewTerminal()
        second.createNewTerminal()
        try await waitUntil { !first.busy && !second.busy }
        XCTAssertEqual(fixture.methods.filter { $0 == "POST" }.count, 1)
        fixture.getStatus = 200
        second.reconnect()
        try await waitUntil { !second.busy }
        XCTAssertNotNil(second.terminal)
        XCTAssertEqual(fixture.sockets.last?.subscriptions, ["pty-new:true"])
        XCTAssertEqual(fixture.methods.filter { $0 == "POST" }.count, 1)
    }

    func testQuickTerminalCreationMarksOnlyTheDetailPanelShell() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        fixture.defaults.set("", forKey: fixture.key + ".session")
        let model = fixture.model()
        model.open(cwd: "/panel-worktree")
        try await waitUntil { !model.busy }
        XCTAssertNotNil(model.terminal)
        XCTAssertEqual(fixture.requestBodies[0]["sessionSource"] as? String, "quick-terminal")
        XCTAssertEqual(fixture.requestBodies[0]["cwd"] as? String, "/panel-worktree")
        let ordinary = try await fixture.api.createBlankTerminal(cwd: "/ordinary-shell", initialInput: nil)
        XCTAssertEqual(fixture.requestBodies[1]["sessionSource"] as? String, "interactive")
        XCTAssertEqual(ordinary.sessionSource, "interactive")
        XCTAssertEqual(fixture.methods, ["POST", "POST"])
    }

    func testQuickTerminalLegacyReferenceIsClaimedBeforeMountingWithoutCreating() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        fixture.sessionSource = "interactive"
        var refreshes = 0
        let observer = NotificationCenter.default.addObserver(forName: .wandRefreshLists, object: nil, queue: .main) { _ in refreshes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let model = fixture.model()
        model.open(cwd: "/different-worktree")
        try await waitUntil { !model.busy }
        XCTAssertNotNil(model.terminal)
        XCTAssertEqual(fixture.methods, ["GET", "PUT"])
        XCTAssertEqual(fixture.requests[1].url?.path, "/api/sessions/pty-old/quick-terminal")
        XCTAssertEqual(fixture.sockets[0].subscriptions, ["pty-old:true"])
        XCTAssertEqual(fixture.defaults.string(forKey: fixture.key + ".session"), "pty-old")
        XCTAssertEqual(refreshes, 1)
        model.reconnect()
        try await waitUntil { !model.busy }
        XCTAssertEqual(fixture.methods, ["GET", "PUT", "GET"])
        XCTAssertEqual(refreshes, 1, "Already marked shells need no metadata write or list refresh")
    }

    func testQuickTerminalFailedClaimCannotMasqueradeAsMissingOriginal() async throws {
        for status in [404, 410, 403, 503] {
            let fixture = QuickTerminalRecoveryFixture()
            defer { fixture.close() }
            fixture.sessionSource = "interactive"
            fixture.claimStatus = status
            let model = fixture.model()
            model.open(cwd: "/worktree")
            try await waitUntil { !model.busy }
            XCTAssertNil(model.terminal)
            XCTAssertFalse(model.canCreateTerminal)
            model.createNewTerminal()
            XCTAssertEqual(fixture.methods, ["GET", "PUT"])
            XCTAssertEqual(fixture.defaults.string(forKey: fixture.key + ".session"), "pty-old")
            fixture.claimStatus = 200
            model.reconnect()
            try await waitUntil { !model.busy }
            XCTAssertNotNil(model.terminal)
            XCTAssertEqual(fixture.methods, ["GET", "PUT", "GET", "PUT"])
        }
    }

    func testQuickTerminalAuthenticatedReconciliationDoesNotOpenOrCreate() async throws {
        let fixture = QuickTerminalRecoveryFixture()
        defer { fixture.close() }
        fixture.sessionSource = "interactive"
        let model = fixture.model()
        await model.reconcileSavedTerminal()
        XCTAssertEqual(fixture.methods, ["GET", "PUT"])
        XCTAssertFalse(model.isOpen)
        XCTAssertNil(model.terminal)
        XCTAssertTrue(fixture.sockets.isEmpty)
        await model.reconcileSavedTerminal()
        XCTAssertEqual(fixture.methods, ["GET", "PUT", "GET"])
        fixture.defaults.set("", forKey: fixture.key + ".session")
        await model.reconcileSavedTerminal()
        fixture.defaults.set("unconfirmed", forKey: fixture.key + ".session")
        fixture.defaults.set(true, forKey: fixture.key + ".creating")
        await model.reconcileSavedTerminal()
        XCTAssertEqual(fixture.methods, ["GET", "PUT", "GET"], "Empty or unconfirmed references must never trigger discovery or creation")
    }

    func testQuickTerminalAuthenticatedReconciliationIgnoresOtherSessionKindsAndFailures() async throws {
        for scenario in ["structured", "provider", "missing", "claim-failed"] {
            let fixture = QuickTerminalRecoveryFixture()
            defer { fixture.close() }
            fixture.sessionSource = "interactive"
            if scenario == "structured" { fixture.sessionKind = "structured" }
            if scenario == "provider" { fixture.provider = "claude" }
            if scenario == "missing" { fixture.getStatus = 404 }
            if scenario == "claim-failed" { fixture.claimStatus = 503 }
            let model = fixture.model()
            await model.reconcileSavedTerminal()
            XCTAssertEqual(fixture.methods, scenario == "claim-failed" ? ["GET", "PUT"] : ["GET"])
            XCTAssertFalse(model.isOpen)
            XCTAssertNil(model.terminal)
            XCTAssertFalse(model.canCreateTerminal)
            XCTAssertEqual(fixture.defaults.string(forKey: fixture.key + ".session"), "pty-old")
        }
    }

    private func captureQuickTerminal(model: QuickTerminalModel, directory: String) async throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, dock, size, appearance) in [
            ("quick-right-light", QuickTerminalDock.right, NSSize(width: 1000, height: 640), NSAppearance.Name.aqua),
            ("quick-bottom-dark", QuickTerminalDock.bottom, NSSize(width: 1000, height: 640), NSAppearance.Name.darkAqua),
            ("quick-narrow", QuickTerminalDock.right, NSSize(width: 560, height: 640), NSAppearance.Name.aqua)
        ] {
            model.setDock(dock)
            let host = NSHostingView(rootView: QuickTerminalWorkspace(model: model) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("工作区").font(.headline)
                    Text("主编辑区草稿保持原位")
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Theme.workspaceBackground)
            })
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    func testHiddenQuickTerminalDoesNotResizeOrStopTheProcess() async throws {
        let socket = RecordingTerminalSocket()
        let store = store(socket)
        store.start()
        socket.onEvent?(try event("init", data: ["status": "running"]))
        store.setLayoutActive(false)
        let count = socket.sizes.count
        store.terminal.setFrameSize(NSSize(width: 0, height: 0))
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(socket.sizes.count, count)
        XCTAssertTrue(store.ready)
        store.setLayoutActive(true)
        store.terminal.setFrameSize(NSSize(width: 800, height: 400))
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertGreaterThan(socket.sizes.count, count)
        store.shutdown()
    }

    func testSocketDropsGapFramesUntilNewSnapshotAndIgnoresOtherSessions() throws {
        let socket = WandSocket(baseURL: api.baseURL)
        socket.subscribe(sessionId: "pty-1", ptyAck: true)
        var types: [String] = []
        var resyncs = 0
        socket.onEvent = { types.append($0.type) }
        socket.onResync = { resyncs += 1 }
        func receive(_ type: String, _ seq: Int, id: String = "pty-1") throws {
            try socket.handle(JSONSerialization.data(withJSONObject: [
                "type": type, "sessionId": id, "seq": seq, "data": [:],
            ]))
        }
        try receive("output", 1)
        try receive("init", 2)
        try receive("output", 3)
        try receive("output", 3) // duplicate
        try receive("output", 5) // gap
        try receive("output", 6) // stale during resync
        try receive("init", 99, id: "other")
        try receive("init", 7)
        try receive("output", 8)
        XCTAssertEqual(types, ["init", "output", "init", "output"])
        XCTAssertEqual(resyncs, 1)
    }

    /// Explicit opt-in: final acceptance must use the owner's installed service, not a mock.
    func testInstalledServiceNativeTerminalRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAND_INSTALLED_TERMINAL_ACCEPTANCE"] == "1")
        struct Connection: Decodable { let serverURL: URL; let connectionCode: String }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wand/acceptance-connection.json")
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: path))
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: connection.serverURL, token: decoded.token)
        // No commands run in existing user sessions; remove only the shell created by this test.
        let session = try await api.createBlankTerminal(cwd: NSTemporaryDirectory(), initialInput: nil)
        let store = PtyTerminalStore(sessionId: session.id, api: api)
        do {
            store.start()
            try await waitUntil { store.ready }
            store.terminal.insertText("printf '\\033[32m原生接口%s\\033[0m\\n' '验收_OK'", replacementRange: NSRange(location: NSNotFound, length: 0))
            store.terminal.send(txt: "\r")
            try await waitUntil { self.visibleText(store.terminal).contains("原生接口验收_OK") }
            store.terminal.setFrameSize(NSSize(width: 1000, height: 540))
            try await Task.sleep(nanoseconds: 250_000_000)
            let cols = store.terminal.getTerminal().cols
            let rows = store.terminal.getTerminal().rows
            store.sendInput("stty size")
            store.sendInput("\r")
            try await waitUntil { self.visibleText(store.terminal).contains("\(rows) \(cols)") }
            store.refresh()
            try await waitUntil { store.ready }
            XCTAssertTrue(visibleText(store.terminal).contains("原生接口验收_OK"))
            store.shutdown()
            store.start()
            try await waitUntil { store.ready }
            XCTAssertTrue(visibleText(store.terminal).contains("原生接口验收_OK"))
            store.sendInput("seq 1 130; printf 'PTY_TAIL_READY\\n'")
            store.sendInput("\r")
            try await waitUntil {
                self.visibleText(store.terminal).components(separatedBy: "\n").contains("PTY_TAIL_READY")
            }
            XCTAssertEqual(store.terminal.scrollPosition, 1, "Live server output should follow the tail")
            store.terminal.scroll(toPosition: 0)
            store.sendInput("printf 'PTY_WHILE_BROWSING\\n'")
            store.sendInput("\r")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(store.terminal.scrollPosition, 0, "Output must not interrupt history browsing")
            store.terminal.scroll(toPosition: 1)
            try await waitUntil {
                self.visibleText(store.terminal).components(separatedBy: "\n").contains("PTY_WHILE_BROWSING")
            }
            store.refresh()
            try await waitUntil { store.ready }
            XCTAssertEqual(store.terminal.scrollPosition, 1, "Resync at the tail must not jump to the top")
            store.sendInput("printf '\\033[?1049h\\033[2J\\033[H原生_TUI_OK'; sleep 2; printf '\\033[?1049l'")
            store.sendInput("\r")
            try await waitUntil { store.terminal.getTerminal().isCurrentBufferAlternate }
            XCTAssertTrue(visibleText(store.terminal).contains("原生_TUI_OK"))
            try await waitUntil { !store.terminal.getTerminal().isCurrentBufferAlternate }
            if let directory = ProcessInfo.processInfo.environment["WAND_TERMINAL_SCREENSHOT_DIR"] {
                try await captureInstalledPtyPage(sessionId: session.id, api: api, driver: store, directory: directory)
            }
            store.shutdown()
            try await api.deleteSession(id: session.id)
        } catch {
            store.shutdown()
            try? await api.deleteSession(id: session.id)
            throw error
        }
    }

    private func captureInstalledPtyPage(sessionId: String, api: WandAPI,
                                         driver: PtyTerminalStore, directory: String) async throws {
        // Render the actual product page against the same installed-service PTY, not a fixture.
        let host = NSHostingView(rootView: PtySessionView(sessionId: sessionId, api: api))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wand 原生终端验收"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func findTerminal(_ view: NSView) -> NativeTerminalView? {
            if let terminal = view as? NativeTerminalView { return terminal }
            return view.subviews.lazy.compactMap { findTerminal($0) }.first
        }
        // The initial marker has scrolled out after the 130-line history probe.
        try await waitUntil { findTerminal(host).map { self.visibleText($0).contains("PTY_WHILE_BROWSING") } ?? false }
        let view = try XCTUnwrap(findTerminal(host))
        // A clean alternate screen keeps shell usernames, local paths and unrelated history out of screenshots.
        driver.sendInput("printf '\\033[?1049h\\033[2J\\033[H\\033[32mWand Native Terminal\\033[0m\\n\\r原生终端 · WebSocket 直连接口\\n\\r中文输入 / ANSI / TUI / 尺寸同步 / 断线恢复\\n\\r\\n\\rNo WebView. No JavaScript bridge.'; sleep 5; printf '\\033[?1049l'")
        driver.sendInput("\r")
        try await waitUntil { view.getTerminal().isCurrentBufferAlternate }
        XCTAssertTrue(visibleText(view).contains("No WebView."))
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, size) in [("native-terminal", NSSize(width: 1000, height: 640)),
                             ("native-terminal-compact", NSSize(width: 650, height: 480))] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Native terminal acceptance condition timed out (credentials intentionally omitted)", file: file, line: line)
        throw NSError(domain: "NativeTerminalAcceptance", code: 1)
    }
}

@MainActor
private final class QuickTerminalRecoveryFixture {
    let host = "quick-recovery-\(UUID().uuidString).example.test"
    let suite = "QuickTerminalRecovery.\(UUID().uuidString)"
    let defaults: UserDefaults
    let session: URLSession
    let api: WandAPI
    let key: String
    var getStatus = 200
    var postStatus = 200
    var claimStatus = 200
    var sessionSource = "quick-terminal"
    var sessionKind = "pty"
    var provider: String?
    var invalidPostResponse = false
    var snapshotStatus = "running"
    var methods: [String] = []
    var requests: [URLRequest] = []
    var requestBodies: [[String: Any]] = []
    var sockets: [RecordingTerminalSocket] = []
    private var models: [QuickTerminalModel] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuickTerminalRecoveryURLProtocol.self]
        session = URLSession(configuration: configuration)
        let url = URL(string: "https://\(host)")!
        api = WandAPI(baseURL: url, token: nil, session: session, reportServerFailure: { _, _, _ in })
        key = "wand.quick-terminal.v1." + url.absoluteString
        defaults.set("pty-old", forKey: key + ".session")
        QuickTerminalRecoveryURLProtocol.register(host: host) { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            let method = request.httpMethod ?? "GET"
            self.methods.append(method)
            self.requests.append(request)
            var bodyData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bodyData.append(buffer, count: count)
                }
            }
            let body = bodyData.isEmpty ? [:] : try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
            self.requestBodies.append(body)
            let status = method == "POST" ? self.postStatus : method == "PUT" ? self.claimStatus : self.getStatus
            if status == -1 { throw URLError(.notConnectedToInternet) }
            if method == "POST", self.invalidPostResponse { return (200, Data("invalid-json".utf8)) }
            let id = method == "POST" ? "pty-new" : method == "PUT" ? request.url!.deletingLastPathComponent().lastPathComponent : request.url!.lastPathComponent
            if method == "PUT", status == 200 { self.sessionSource = "quick-terminal" }
            let source = method == "POST" ? body["sessionSource"] as? String ?? "interactive" : self.sessionSource
            var payload: [String: Any] = ["id": id, "sessionKind": self.sessionKind, "sessionSource": source, "cwd": "/worktree", "status": self.snapshotStatus]
            if let provider = self.provider { payload["provider"] = provider }
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (status, data)
        }
    }

    func model() -> QuickTerminalModel {
        let model = QuickTerminalModel(api: api, defaults: defaults) { [unowned self] id, api in
            let socket = RecordingTerminalSocket()
            self.sockets.append(socket)
            return PtyTerminalStore(sessionId: id, api: api, socket: socket, defaults: self.defaults)
        }
        models.append(model)
        return model
    }

    func close() {
        for model in models { model.terminal?.shutdown() }
        session.invalidateAndCancel()
        QuickTerminalRecoveryURLProtocol.unregister(host: host)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class QuickTerminalRecoveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: @MainActor (URLRequest) throws -> (Int, Data)] = [:]
    static func register(host: String, handler: @escaping @MainActor (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func unregister(host: String) { lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
        Task { @MainActor in
            do {
                guard let handler, let url = self.request.url else { throw URLError(.unsupportedURL) }
                let (status, data) = try handler(self.request)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch { self.client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

private final class RecordingTerminalSocket: PtySocketTransport {
    var onEvent: ((WsIncoming) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onResync: (() -> Void)?
    var onError: ((String) -> Void)?
    var onAck: ((Int) -> Void)?
    var connects = 0
    var subscriptions: [String] = []
    var inputs: [(String, Bool)] = []
    var sizes: [(Int, Int)] = []
    var acks: [Int] = []
    func connect() { connects += 1 }
    func close() { onConnectionChange?(false) }
    func subscribe(sessionId: String, ptyAck: Bool) { subscriptions.append("\(sessionId):\(ptyAck)") }
    func requestResync() { onResync?() }
    func sendPtyInput(_ text: String, userInput: Bool) { inputs.append((text, userInput)) }
    func resizePty(cols: Int, rows: Int) { sizes.append((cols, rows)) }
    func acknowledgePty(bytes: Int) {
        guard bytes > 0 else { return }
        onAck?(bytes)
        acks.append(bytes)
    }
}
