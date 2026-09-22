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
        let session = try await api.request(SessionSnapshot.self, method: "POST", path: "/api/commands",
                                            body: ["shell": true, "cwd": NSTemporaryDirectory()])
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
        try await waitUntil { findTerminal(host).map { self.visibleText($0).contains("原生接口验收_OK") } ?? false }
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

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Native terminal acceptance condition timed out (credentials intentionally omitted)")
        throw NSError(domain: "NativeTerminalAcceptance", code: 1)
    }
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
