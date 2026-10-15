import AppKit
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class ChatContentWidthTests: XCTestCase {
    private var suites: [String] = []

    private func defaults() -> UserDefaults {
        let suite = "WandChatContentWidthTests." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    func testModesReuseTheReadingColumnAndMatchWebReadingColumn() {
        XCTAssertEqual(ChatContentWidth.full.maxWidth, .infinity)
        XCTAssertEqual(ChatContentWidth.column.maxWidth, 940)
        XCTAssertEqual(ChatContentWidth.allCases.map(\.title), ["铺满", "居中"])
    }

    func testNativePickerUpdatesMountedMessageAndComposerWithoutReplacingEditor() async throws {
        let storage = defaults()
        storage.set("full", forKey: ChatContentWidth.storageKey)
        let host = NSHostingView(rootView: WidthSample().defaultAppStorage(storage))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        XCTAssertEqual(try width("messages", in: host), 1200, accuracy: 1)
        XCTAssertEqual(try width("composer", in: host), 1200, accuracy: 1)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        editor.insertText("保留的新草稿", replacementRange: NSRange(location: 0, length: 0))
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(picker.segmentCount, 2)
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        await settle(host)
        XCTAssertEqual(storage.string(forKey: ChatContentWidth.storageKey), "column")
        XCTAssertEqual(try width("messages", in: host), 940, accuracy: 1)
        XCTAssertEqual(try width("composer", in: host), 940, accuracy: 1)
        XCTAssertTrue(descendants(host).contains { $0 === editor })
        XCTAssertTrue(editor.string.contains("保留的新草稿"))
        let messageFrame = try frame("messages", in: host)
        XCTAssertEqual(messageFrame.minX, 130, accuracy: 1)
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        await settle(host)
        XCTAssertEqual(try width("messages", in: host), 1200, accuracy: 1)
        XCTAssertEqual(try width("composer", in: host), 1200, accuracy: 1)
    }

    func testEmployeePrivateAndGroupConversationComposersShareThePreference() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/communications.json")
        let fixture = try JSONDecoder().decode(CommunicationsVisualTests.Fixture.self, from: Data(contentsOf: fixtureURL))
        let api = CommunicationsStub()
        api.contacts = fixture.contacts; api.items = fixture.conversations
        api.detailHandler = { id in try XCTUnwrap(fixture.conversations.first { $0.id == id }) }
        let storage = defaults()
        let baseURL = URL(string: "https://fixture.example.test")!
        let store = CommunicationsStore(api: api, serverURL: baseURL, defaults: storage)
        await store.refreshIndex()
        for id in ["dm_e_fixture_default", "group-fixture"] {
            storage.set("full", forKey: ChatContentWidth.storageKey)
            store.select(id); await store.waitForDetailForTesting()
            let scope = try XCTUnwrap(store.selectedScope)
            let owner = store.composer(for: scope)
            owner.edit("切换宽度保留私聊与群聊的草稿")
            let host = NSHostingView(rootView: ConversationPane(store: store, conversation: try XCTUnwrap(store.detail), scope: scope,
                baseURL: baseURL, onOpenSession: { _ in }).defaultAppStorage(storage))
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            await settle(host)
            let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
            let fullWidth = editor.bounds.width
            XCTAssertGreaterThan(fullWidth, 1000)
            storage.set("column", forKey: ChatContentWidth.storageKey)
            await settle(host)
            XCTAssertEqual(fullWidth - editor.bounds.width, 260, accuracy: 2)
            XCTAssertTrue(descendants(host).contains { $0 === editor })
            XCTAssertEqual(owner.text, "切换宽度保留私聊与群聊的草稿")
            XCTAssertTrue(api.posts.isEmpty)
            window.contentView = nil
        }
    }

    func testPersistedModeRestoresAndNarrowWindowsNeverOverflow() async throws {
        let storage = defaults()
        storage.set("column", forKey: ChatContentWidth.storageKey)
        for available: CGFloat in [360, 600, 1200] {
            let host = NSHostingView(rootView: WidthSample().defaultAppStorage(storage))
            host.frame = NSRect(x: 0, y: 0, width: available, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            await settle(host)
            XCTAssertEqual(try width("messages", in: host), min(available, 940), accuracy: 1)
            XCTAssertEqual(try width("composer", in: host), min(available, 940), accuracy: 1)
            host.frame.size.width = 500
            await settle(host)
            XCTAssertEqual(try width("messages", in: host), 500, accuracy: 1)
            window.contentView = nil
        }
    }

    func testInvalidPreferenceFallsBackToColumnAndDoesNotLeakToAnotherDeviceStore() async throws {
        let first = defaults(), second = defaults()
        first.set("unsupported", forKey: ChatContentWidth.storageKey)
        for storage in [first, second] {
            let host = NSHostingView(rootView: WidthSample().defaultAppStorage(storage))
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            await settle(host)
            XCTAssertEqual(try width("messages", in: host), 940, accuracy: 1)
            window.contentView = nil
        }
        first.set("column", forKey: ChatContentWidth.storageKey)
        XCTAssertNil(second.string(forKey: ChatContentWidth.storageKey))
    }

    func testNativeStructuredWidthScreenshotMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["WAND_CHAT_WIDTH_VISUAL_DIR"] else {
            throw XCTSkip("opt-in native width screenshot matrix")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = defaults()
        for mode in ChatContentWidth.allCases {
            storage.set(mode.rawValue, forKey: ChatContentWidth.storageKey)
            for dark in [false, true] {
                for available: CGFloat in [600, 1440] {
                    let host = NSHostingView(rootView: WidthSample().defaultAppStorage(storage).preferredColorScheme(dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: available, height: 650)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = host
                    await settle(host)
                    XCTAssertEqual(try width("messages", in: host), min(available, mode.maxWidth), accuracy: 1)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(mode.rawValue)-\(dark ? "dark" : "light")-\(Int(available)).png"))
                    window.contentView = nil
                }
            }
        }
    }

    /// Read-only final acceptance: actual source ChatView + installed service; no model input, App installation or production preferences.
    func testInstalledServiceStructuredChatUsesWidthPreferenceAndKeepsDraft() async throws {
        guard ProcessInfo.processInfo.environment["WAND_CHAT_WIDTH_LIVE"] == "1" else {
            throw XCTSkip("installed-service read-only width acceptance is opt-in")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/acceptance-connection.json"))) as! [String: Any]
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/config.json"))) as! [String: Any]
        guard let host = config["host"] as? String, ["127.0.0.1", "localhost", "0.0.0.0", "::", "::1", "[::]"].contains(host),
              let port = config["port"] as? Int, let code = connection["connectionCode"] as? String else {
            throw NSError(domain: "ChatWidthAcceptance", code: 1)
        }
        var encoded = code.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf8)!
        let token = String(decoded.suffix(from: decoded.index(after: decoded.lastIndex(of: "#")!)))
        let origin = URL(string: "\((config["https"] as? Bool) == true ? "https" : "http")://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var login = URLRequest(url: origin.appendingPathComponent("api/login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["appToken": token])
        let (_, response) = try await session.data(for: login)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "ChatWidthAcceptance", code: 2) }
        // The native socket owns SelfSignedSession, not this ephemeral REST test session.
        // Share only this test process's login cookies, restoring its prior state afterward.
        let socketCookies = try XCTUnwrap(SelfSignedSession.shared.cookieStorage)
        let previousCookies = socketCookies.cookies(for: origin) ?? []
        for cookie in session.configuration.httpCookieStorage?.cookies(for: origin) ?? [] { socketCookies.setCookie(cookie) }
        defer {
            for cookie in socketCookies.cookies(for: origin) ?? [] { socketCookies.deleteCookie(cookie) }
            for cookie in previousCookies { socketCookies.setCookie(cookie) }
        }
        let api = WandAPI(baseURL: origin, token: nil, session: session)
        let sessions = try await api.listSessions()
        let selected = try XCTUnwrap(sessions.first { $0.isStructured && $0.employeeId == "e_wand_default" })
        _ = try await api.getSession(id: selected.id)
        let connectionProbe = ChatStore(sessionId: selected.id, api: api)
        connectionProbe.start()
        defer { connectionProbe.shutdown() }
        for _ in 0..<50 {
            if connectionProbe.connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(connectionProbe.connected, "read-only installed-service WebSocket is connected")
        let storage = defaults()
        storage.set("full", forKey: ChatContentWidth.storageKey)
        let hostView = NSHostingView(rootView: ChatView(sessionId: selected.id, api: api, gitStatusStore: GitStatusStore()).defaultAppStorage(storage))
        hostView.frame = NSRect(x: 0, y: 0, width: 1400, height: 780)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView
        defer { window.contentView = nil }
        await settle(hostView)
        NotificationCenter.default.post(name: .wandDesktopCommand, object: DesktopCommand.focusComposer)
        await settle(hostView)
        let editor = try XCTUnwrap(descendants(hostView).compactMap { $0 as? ComposerNSTextView }.first)
        let fullWidth = editor.convert(editor.bounds, to: hostView).width
        XCTAssertGreaterThan(fullWidth, 1100)
        editor.insertText("仅本地验收草稿，不发送", replacementRange: NSRange(location: 0, length: 0))
        let draft = editor.string
        storage.set("column", forKey: ChatContentWidth.storageKey)
        await settle(hostView)
        let columnWidth = editor.convert(editor.bounds, to: hostView).width
        XCTAssertEqual(fullWidth - columnWidth, 460, accuracy: 2)
        XCTAssertTrue(descendants(hostView).contains { $0 === editor })
        XCTAssertEqual(editor.string, draft)
        storage.set("full", forKey: ChatContentWidth.storageKey)
        hostView.frame.size.width = 600
        await settle(hostView)
        XCTAssertLessThan(editor.convert(editor.bounds, to: hostView).maxX, 601)
        if let directory = ProcessInfo.processInfo.environment["WAND_CHAT_LAYOUT_LIVE_VISUAL_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            storage.set("column", forKey: ChatContentWidth.storageKey)
            hostView.frame.size = CGSize(width: 1400, height: 780)
            window.makeKeyAndOrderFront(nil)
            await settle(hostView)
            func click(_ point: NSPoint) async throws {
                let location = hostView.convert(point, to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                NSApp.postEvent(up, atStart: false); window.sendEvent(down)
                await settle(hostView)
            }
            let existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            let addPoint = NSPoint(x: (1400 - ChatContentWidth.columnMaxWidth) / 2 + 20 + 24, y: hostView.isFlipped ? 780 - 36 : 36)
            try await click(addPoint)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) }, "native add button opens its configuration popover")
            let panelView = try XCTUnwrap(panel.contentView)
            panelView.layoutSubtreeIfNeeded()
            let panelBitmap = try XCTUnwrap(panelView.bitmapImageRepForCachingDisplay(in: panelView.bounds))
            panelView.cacheDisplay(in: panelView.bounds, to: panelBitmap)
            try XCTUnwrap(panelBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("live-configuration-panel.png"))
            XCTAssertEqual(editor.string, draft)
            try await click(addPoint)
            XCTAssertFalse(panel.isVisible, "pressing the same add button closes the popover")
            try await click(addPoint)
            let reopened = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) })
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: reopened.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            // Route key equivalents through NSApplication as a real OS key event does.
            NSApp.sendEvent(escape)
            await settle(hostView)
            XCTAssertFalse(reopened.isVisible, "Escape closes the add panel without sending")
            XCTAssertEqual(editor.string, draft)
            _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await settle(hostView)
            let avatarPoint = NSPoint(x: (1400 - ChatContentWidth.columnMaxWidth) / 2 + 20 + 36, y: hostView.isFlipped ? 780 - 98 : 98)
            try await click(avatarPoint)
            print("companionFocusGeometry", hostView.isFlipped, avatarPoint, editor.convert(editor.bounds, to: hostView), "key", window.isKeyWindow, "responder", window.firstResponder?.className ?? "nil")
            XCTAssertTrue(window.firstResponder === editor, "the relocated companion still focuses the same editor")
            XCTAssertEqual(editor.string, draft)
            window.orderOut(nil)
            for dark in [false, true] { for width: CGFloat in [600, 1400, 2243] { for expanded in [false, true] {
                hostView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hostView.frame.size = CGSize(width: width, height: 780)
                if expanded { NotificationCenter.default.post(name: .wandDesktopCommand, object: DesktopCommand.focusComposer) }
                else { _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) }
                await settle(hostView)
                XCTAssertTrue(descendants(hostView).contains { $0 === editor })
                XCTAssertEqual(editor.string, draft)
                let bitmap = try XCTUnwrap(hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds))
                hostView.cacheDisplay(in: hostView.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("live-\(dark ? "dark" : "light")-\(Int(width))-\(expanded ? "expanded" : "collapsed").png"))
            } } }
        }
        _ = try? await api.requestData(method: "POST", path: "/api/logout")
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 750_000_000)
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private func frame(_ id: String, in host: NSView) throws -> NSRect {
        let view = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
        return view.convert(view.bounds, to: host)
    }
    private func width(_ id: String, in host: NSView) throws -> CGFloat { try frame(id, in: host).width }

    private struct WidthProbe: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(id); return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private struct WidthSample: View {
        @State private var text = "未发送的中文草稿"
        var body: some View {
            VStack(spacing: 12) {
                ChatContentWidthPicker().frame(width: 320).padding(12)
                ScrollView {
                    TurnView(turn: ConversationTurn(role: "assistant", content: [.text(text: "## 结构化宽度检查\n\n正文随显示区域自适应，代码块仍可横向滚动。\n\n```swift\nlet message = \"" + String(repeating: "长代码内容", count: 35) + "\"\n```\n\n| 项目 | 说明 |\n| --- | --- |\n| 宽度 | 铺满 / 居中 |", subagent: nil)]))
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WidthProbe(id: "messages"))
                        .chatContentWidth()
                }
                IMEAwareComposerTextView(text: $text, placeholder: "草稿", isFocused: false, sendWithCommandEnter: false,
                    onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
                    .frame(height: 90)
                    .background(WidthProbe(id: "composer"))
                    .chatContentWidth()
            }
            .background(Theme.workspaceBackground)
        }
    }
}
