import AppKit
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class CommunicationsVisualTests: XCTestCase {
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
