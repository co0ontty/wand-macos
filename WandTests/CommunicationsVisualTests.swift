import AppKit
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class CommunicationsVisualTests: XCTestCase {
    func testRootNavigationContractAndSnapshot() async throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Wand/MainShellView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rail = try XCTUnwrap(source.components(separatedBy: "struct DesktopNavigationRail: View {").last)
            .components(separatedBy: "private func item(").first ?? ""
        XCTAssertFalse(rail.contains("item(.contacts"))
        for command in ["conversations", "workspaces", "knowledge", "taskBoard", "settings"] {
            XCTAssertTrue(rail.contains("item(." + command + ","), command)
        }
        let host = NSHostingView(rootView: DesktopNavigationRail(selection: .workspaces, onCommand: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 56, height: 700)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/wand-hide-contacts/macos-navigation.png"))
    }

    func testRootNavigationOmitsContactsAndKeepsWorkDestinations() async throws {
        var commands: [DesktopCommand] = []
        let host = NSHostingView(rootView: DesktopNavigationRail(selection: .workspaces, onCommand: { commands.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 56, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        let children = NSSelectorFromString("accessibilityChildren")
        let label = NSSelectorFromString("accessibilityLabel")
        var queue: [NSObject] = [host], seen = Set<ObjectIdentifier>(), labels: [String] = []
        while !queue.isEmpty && seen.count < 2000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.responds(to: label), let value = node.perform(label)?.takeUnretainedValue() as? String { labels.append(value) }
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: next) }
        }
        guard !labels.isEmpty else { throw XCTSkip("NSHostingView exports no accessibility labels in this test host") }
        XCTAssertFalse(labels.contains("通讯录"))
        for command in [DesktopCommand.conversations, .workspaces, .knowledge, .taskBoard, .settings] {
            XCTAssertTrue(labels.contains(command.title), command.title)
            XCTAssertTrue(try press(host, label: command.title))
        }
        XCTAssertEqual(commands, [.conversations, .workspaces, .knowledge, .taskBoard, .settings])
    }

    struct Fixture: Decodable { let contacts: [EmployeeContact]; let conversations: [NativeConversation] }
    private var suites: [String] = []
    private func setup() async throws -> (CommunicationsStore, CommunicationsStub) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/communications.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let api = CommunicationsStub()
        api.contacts = fixture.contacts; api.items = fixture.conversations
        api.detailHandler = { id in try XCTUnwrap(fixture.conversations.first { $0.id == id }) }
        let suite = "WandCommunicationsVisual.\(UUID().uuidString)"; suites.append(suite)
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: UserDefaults(suiteName: suite)!)
        await store.refreshIndex()
        return (store, api)
    }
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []; super.tearDown()
    }

    func testNativeEditorBindsTheSelectedComposerAndKeepsIMEAndNewInputSafe() async throws {
        let (store, api) = try await setup()
        store.select("dm_e_fixture_default"); await store.waitForDetailForTesting()
        let scope = ConversationScope(conversationID: "dm_e_fixture_default", target: nil)
        let owner = store.composer(for: scope)
        let focus = ComposerFocusController(); focus.focus()
        let host = NSHostingView(rootView: ConversationComposerSurface(owner: owner, store: store, conversation: try XCTUnwrap(store.detail), focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 230)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("真实原生编辑草稿", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(owner.text, "真实原生编辑草稿")
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let blocked = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(blocked, true)
        XCTAssertTrue(api.posts.isEmpty, "IME confirmation never sends")
        editor.unmarkText()
        host.layoutSubtreeIfNeeded(); await Task.yield()
        let sent = expectation(description: "real native editor submits the selected scope")
        api.postHandler = { _, body in
            sent.fulfill()
            return try JSONDecoder().decode(ConversationReceipt.self, from: JSONSerialization.data(withJSONObject: ["requestId":body["requestId"]!, "state":"accepted","conversationId":"dm_e_fixture_default"]))
        }
        _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertEqual(api.posts.count, 1)
        XCTAssertEqual(api.posts[0].path, "/api/conversations/dm_e_fixture_default/messages")
    }

    func testPastedImageUploadsThroughNativeConversationEditorAndCleansTemporaryFile() async throws {
        let (store, api) = try await setup()
        store.select("dm_e_fixture_default"); await store.waitForDetailForTesting()
        let scope = ConversationScope(conversationID: "dm_e_fixture_default", target: nil)
        let owner = store.composer(for: scope)
        owner.edit("保留正文")
        let focus = ComposerFocusController(); focus.focus()
        let host = NSHostingView(rootView: ConversationComposerSurface(owner: owner, store: store, conversation: try XCTUnwrap(store.detail), focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 230)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.writeObjects([image])
        var temporaryURL: URL?
        let uploaded = expectation(description: "pasted image upload")
        api.uploadHandler = { session, urls in
            XCTAssertEqual(session, "attachment-channel")
            let url = try XCTUnwrap(urls.first); temporaryURL = url
            XCTAssertNotNil(NSImage(contentsOf: url))
            uploaded.fulfill()
            return [UploadedFile(originalName: url.lastPathComponent, savedPath: "/fixture/pasted.png", size: 10, mimeType: "image/png")]
        }
        XCTAssertTrue(editor.pasteAttachment(from: board))
        XCTAssertTrue(owner.uploading, "The upload gate is acquired before returning to the event loop")
        XCTAssertTrue(editor.pasteAttachment(from: board))
        XCTAssertTrue(owner.uploading, "A second paste cannot release an active upload")
        board.clearContents(); board.setString("后来复制的文字", forType: .string)
        await fulfillment(of: [uploaded], timeout: 3)
        for _ in 0..<30 where owner.uploading { await Task.yield() }
        XCTAssertEqual(owner.attachments.map(\.savedPath), ["/fixture/pasted.png"])
        XCTAssertEqual(owner.text, "保留正文")
        XCTAssertEqual(editor.string, "保留正文")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryURL).path))
        XCTAssertEqual(api.posts.filter { $0.path.hasSuffix("/channel") }.count, 1)
        XCTAssertTrue(api.posts.allSatisfy { !$0.path.hasSuffix("/messages") }, "Pasting does not submit a model message")
    }

    func testNativeContactButtonOpensStableDMAndReplyButtonUsesExactSession() async throws {
        let (store, _) = try await setup()
        store.selectContact(try XCTUnwrap(store.contacts.first))
        var opened: [String] = []
        let host = NSHostingView(rootView: CommunicationsContent(store: store, baseURL: URL(string: "https://fixture.example.test")!, onOpenSession: { opened.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        let exported = host.accessibilityChildren() ?? []
        guard !exported.isEmpty else {
            throw XCTSkip("This NSHostingView test host exports no AX children; native editor events and protocol routing run separately. No OS accessibility setting is changed.")
        }
        XCTAssertTrue(try press(host, label: "打开私聊"))
        await store.waitForDetailForTesting(); try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.selectedID, "dm_e_fixture_default")
        XCTAssertTrue(try press(host, label: "打开对应执行会话"))
        XCTAssertEqual(opened, ["session-exact"])
    }

    private func press(_ root: NSObject, label: String) throws -> Bool {
        let children = NSSelectorFromString("accessibilityChildren")
        let name = NSSelectorFromString("accessibilityLabel")
        let action = NSSelectorFromString("accessibilityPerformPress")
        var queue = [root], seen = Set<ObjectIdentifier>(), labels: [String] = []
        while !queue.isEmpty && seen.count < 2000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.responds(to: name), let value = node.perform(name)?.takeUnretainedValue() as? String { labels.append(value) }
            if node.responds(to: name), (node.perform(name)?.takeUnretainedValue() as? String) == label, node.responds(to: action) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let invoke = unsafeBitCast(node.method(for: action), to: Press.self)
                return invoke(node, action)
            }
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: next) }
        }
        XCTFail("native accessibility action not found: \(label); scanned=\(seen.count); labels=\(labels)")
        return false
    }

    func testHiddenGroupNavigationHasNoCreationAction() async throws {
        let (store, _) = try await setup()
        XCTAssertTrue(store.items.contains(where: \.isGroup))
        XCTAssertTrue(store.filteredConversations.allSatisfy { !$0.isGroup })
        try await verifyHiddenGroupNavigation(store: store, baseURL: URL(string: "https://fixture.example.test")!, name: "fixture-sidebar")
        store.query = "不存在的对话"
        XCTAssertTrue(store.filteredConversations.isEmpty)
        try await verifyHiddenGroupNavigation(store: store, baseURL: URL(string: "https://fixture.example.test")!, name: "fixture-no-results")
    }

    func testInstalledServiceGroupNavigationIsHiddenReadOnly() async throws {
        guard NativeAcceptance.enabled else { throw XCTSkip("Installed-service read-only acceptance is opt-in") }
        let storage = NativeAcceptance.defaults
        defer { NativeAcceptance.cleanup() }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(storage.string(forKey: "wand.serverURL"))))
        let token = try XCTUnwrap(storage.string(forKey: "wand.token"))
        let store = CommunicationsStore(api: WandAPI(baseURL: origin, token: token), serverURL: origin, defaults: storage)
        defer { store.stopRealtime() }
        await store.refreshIndex()
        XCTAssertNil(store.conversationsError)
        XCTAssertTrue(store.indexLoaded)
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), Set(store.items.filter { !$0.isGroup }.map(\.id)))
        try await verifyHiddenGroupNavigation(store: store, baseURL: origin, name: "installed-sidebar")
        store.section = .contacts
        try await verifyHiddenGroupNavigation(store: store, baseURL: origin, name: "installed-contacts")
    }

    private func verifyHiddenGroupNavigation(store: CommunicationsStore, baseURL: URL, name: String) async throws {
        let view = HStack(spacing: 0) {
            CommunicationsSidebar(store: store).frame(width: 260).padding(.top, 12)
            Divider()
            CommunicationsContent(store: store, baseURL: baseURL, onOpenSession: { _ in })
        }.frame(width: 900, height: 780).background(Theme.workspaceBackground)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        // The view owns a refresh task. Let it settle before capturing or removing
        // the host so a previous window cannot surface cancellation in the next one.
        for _ in 0..<50 where store.indexLoading { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(store.indexLoading)
        XCTAssertNil(store.contactsError)
        XCTAssertNil(store.conversationsError)
        host.needsDisplay = true
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); host.displayIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let children = NSSelectorFromString("accessibilityChildren")
        let nameSelector = NSSelectorFromString("accessibilityLabel")
        var queue: [NSObject] = [host], seen = Set<ObjectIdentifier>(), labels: [String] = []
        while !queue.isEmpty && seen.count < 2000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.responds(to: nameSelector), let value = node.perform(nameSelector)?.takeUnretainedValue() as? String { labels.append(value) }
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: next) }
        }
        XCTAssertFalse(labels.contains("发起群聊"))
        if let path = ProcessInfo.processInfo.environment["WAND_GROUP_NAVIGATION_VISUAL_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let evidence: [String: Any] = ["accessibilityNodes": seen.count, "accessibilityLabels": labels.count,
                "accessibilityExportAvailable": !labels.isEmpty,
                "groupCreationAccessibilityFound": labels.isEmpty ? NSNull() : NSNumber(value: labels.contains("发起群聊")), "visibleConversations": store.filteredConversations.count,
                "sourceConversations": store.items.count]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".json"))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    func testIsolatedNativeCommunicationsScreenshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["WAND_COMMUNICATIONS_VISUAL_DIR"] else {
            throw XCTSkip("opt-in isolated native screenshot matrix")
        }
        let (store, _) = try await setup()
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for screen in ["contacts", "dm", "group", "unknown"] {
            if screen == "contacts" { store.selectContact(try XCTUnwrap(store.contacts.first)) }
            else {
                store.select(screen == "group" ? "group-fixture" : "dm_e_fixture_default")
                await store.waitForDetailForTesting()
                if screen == "unknown", let scope = store.selectedScope {
                    let owner = store.composer(for: scope)
                    owner.failUpload(ConversationDeliveryError.uncertain(requestID: "fixture-request", message: "上一份请求送达未确认；新输入保留，核对不会重发。"))
                    owner.edit("核对期间仍可编辑的新输入")
                }
            }
            for dark in [false, true] {
                for width in [900.0, 1440.0] {
                    let view = HStack(spacing: 0) {
                        CommunicationsSidebar(store: store).frame(width: 260).padding(.top, 12)
                        Divider()
                        CommunicationsContent(store: store, baseURL: URL(string: "https://fixture.example.test")!, onOpenSession: { _ in })
                    }
                    .frame(width: width, height: 780)
                    .background(Theme.workspaceBackground)
                    .preferredColorScheme(dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 780)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("\(screen)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    window.contentView = nil
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
