import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Wand

private struct RuntimeSettingsProbe: View {
    @ObservedObject var focus: ComposerFocusController
    var model = "Ultimate"
    var todos: [TodoItem] = []
    var queueStore: ChatStore? = nil
    @State private var queueExpanded = false
    @State private var todoExpanded = false
    private var progress: AnyView? {
        guard !todos.isEmpty || queueStore != nil else { return nil }
        return AnyView(HStack(spacing: 4) {
            if !todos.isEmpty { TodoProgressBar(todos: todos, expanded: $todoExpanded).frame(maxWidth: .infinity).background(ComposerGeometryProbe(id: "runtime-todo")) }
            if let queueStore { ComposerQueue(store: queueStore, expanded: $queueExpanded).frame(maxWidth: .infinity).background(ComposerGeometryProbe(id: "runtime-queue")) }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            ComposerIdentityHeader(progress: progress, portrait: {
                Image(nsImage: NSImage(named: "plush_cat_silver")!).resizable().scaledToFit()
                    .background(ComposerGeometryProbe(id: "runtime-avatar"))
            }, identity: { Text("赛博虎妞：") }, runtime: {
                HStack(spacing: 6) {
                    ComposerSettingLabel(title: model)
                    Text("·")
                    ComposerSettingLabel(title: "思考：高").fixedSize()
                }.background(ComposerGeometryProbe(id: "runtime-settings"))
            })
            FocusComposerSurface(expanded: focus.editing, hasDraft: false, summary: "输入消息…", onFocus: focus.focus,
            editor: {
                Text("帮我检查这次修改的界面与交互。\n保留输入内容，确认后再发送。")
                    .font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .background(ComposerGeometryProbe(id: "runtime-editor"))
            }, add: {
                Image(systemName: "plus").font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .background(ComposerGeometryProbe(id: "runtime-add"))
            }, send: {
                NativeComposerActionButton(phase: .idle, turnRunning: true, canSubmit: false, onSend: {})
                    .background(ComposerGeometryProbe(id: "runtime-send"))
            })
            .background(ComposerGeometryProbe(id: "runtime-surface"))
        }
        .background(Theme.workspaceBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
private struct ComposerGeometryProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(id); return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
final class AvatarComposerParityTests: XCTestCase {
    func testLatestAndroidIdentityPriorityAndTokens() {
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e_wand_default", name: "改名", avatar: "data:image/png;base64,eA=="), "plush_cat_silver")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e_wand_ops", avatar: "cat:7"), "plush_cat_orange")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e_hr", avatar: "plush-dog:v1:shiba:red-scarf"), "plush_dog_shiba_red")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "e1", avatar: ""), "plush_round_lavender_ink_beret")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "😀员工", avatar: ""), "plush_round_blue_none_beret")
        XCTAssertNil(PlushAvatarIdentity.asset(id: "", avatar: ""))
        XCTAssertNil(PlushAvatarIdentity.asset(id: "e1", avatar: "cat:7"))
        XCTAssertNil(PlushAvatarIdentity.asset(id: "e1", avatar: "data:image/png;base64,eA=="))
        XCTAssertEqual(ContactCatAvatar.coatIndex(id: "any", avatar: "cat:9"), 1)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 0)[2][1], 0xF0923A)
        XCTAssertEqual(plushSceneConfig("plush_dog_shiba_red")?["kind"] as? String, "dog")
    }

    func testEveryConfiguredPortraitIsPresentAndStable() {
        for shape in PlushAvatarIdentity.shapes { for color in PlushAvatarIdentity.colors {
            for glasses in PlushAvatarIdentity.glasses { for hat in PlushAvatarIdentity.hats {
                let token = "plush:v1:\(shape):\(color):\(glasses):\(hat)"
                let asset = "plush_\(shape)_\(color)_\(glasses)_\(hat)"
                XCTAssertEqual(PlushAvatarIdentity.asset(id: "e", avatar: token), asset)
                XCTAssertNotNil(NSImage(named: asset), asset)
            } }
        } }
        for asset in ["plush_cat_silver", "plush_cat_orange", "plush_dog_shiba_red"] { XCTAssertNotNil(NSImage(named: asset)) }
        XCTAssertNotNil(Bundle.main.url(forResource: "scene", withExtension: "html", subdirectory: "PlushScene"))
    }

    func testCompactComposerIsOneRowAndActionsStayAnchoredWhileEditorGrows() async throws {
        let focus = ComposerFocusController()
        let host = NSHostingView(rootView: RuntimeSettingsProbe(focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rect(_ id: String) throws -> NSRect {
            let view = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            return view.convert(view.bounds, to: host)
        }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
        let add = try rect("runtime-add"), send = try rect("runtime-send")
        XCTAssertEqual(add.height, 32, accuracy: 1)
        XCTAssertEqual(send.midY, add.midY, accuracy: 1)
        XCTAssertEqual(try rect("runtime-surface").height, 56, accuracy: 1)
        XCTAssertEqual(try rect("runtime-settings").maxX, host.bounds.maxX, accuracy: 1)
        XCTAssertLessThan(try rect("runtime-settings").midY, add.midY)
        XCTAssertEqual(try rect("runtime-avatar").minX, 0, accuracy: 1)
        focus.focus()
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try rect("runtime-surface").height, 120)
        XCTAssertEqual(try rect("runtime-add").minY, add.minY, accuracy: 1)
        XCTAssertEqual(try rect("runtime-send").minY, send.minY, accuracy: 1)
        focus.collapse()
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try rect("runtime-surface").height, 56, accuracy: 1)
        XCTAssertEqual(try rect("runtime-send"), send)
    }

    func testCompactComposerFitsNarrowWidthsAndLongSummaries() async throws {
        let focus = ComposerFocusController()
        let host = NSHostingView(rootView: RuntimeSettingsProbe(focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rect(_ id: String) throws -> NSRect {
            let view = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            return view.convert(view.bounds, to: host)
        }
        for model in ["发消息…", String(repeating: "保留长草稿摘要", count: 20)] {
            host.rootView = RuntimeSettingsProbe(focus: focus, model: model)
            for dark in [false, true] { for width: CGFloat in [320, 896] { for expanded in [false, true] {
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 220))
                host.frame.size.width = width
                if expanded { focus.focus() } else { focus.collapse() }
                host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000)
                host.layoutSubtreeIfNeeded()
                let add = try rect("runtime-add"), send = try rect("runtime-send")
                XCTAssertEqual(add.minX, 12, accuracy: 0.5)
                XCTAssertEqual(send.maxX, width - 12, accuracy: 0.5)
                XCTAssertEqual(send.width, 32, accuracy: 0.5)
                XCTAssertEqual(try rect("runtime-settings").maxX, width, accuracy: 1)
                XCTAssertGreaterThanOrEqual(try rect("runtime-settings").minX, 84)
                XCTAssertLessThan(try rect("runtime-settings").maxY, send.minY)
                if expanded { XCTAssertEqual(try rect("runtime-editor").width, width - 24, accuracy: 1) }
                XCTAssertEqual(add.midY, send.midY, accuracy: 0.5)
                if let directory = ProcessInfo.processInfo.environment["WAND_COMPOSER_OUTPUT"] {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "composer-\(model == "发消息…" ? "short" : "long")-\(dark ? "dark" : "light")-\(Int(width))-\(expanded ? "expanded" : "collapsed").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                }
            } } }
        }
    }

    func testTodoSharesInputEdgeWithoutMovingActions() async throws {
        let focus = ComposerFocusController()
        let host = NSHostingView(rootView: RuntimeSettingsProbe(focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 940, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rect(_ id: String) throws -> NSRect {
            let view = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            return view.convert(view.bounds, to: host)
        }
        let todos = [TodoItem(content: String(repeating: "核对界面与输入", count: 12), status: "in_progress", activeForm: nil)]
        for width: CGFloat in [390, 940] {
            window.setContentSize(NSSize(width: width, height: 240)); host.frame.size.width = width
            host.rootView = RuntimeSettingsProbe(focus: focus)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let send = try rect("runtime-send")
            host.rootView = RuntimeSettingsProbe(focus: focus, todos: todos)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let todo = try rect("runtime-todo"), runtime = try rect("runtime-settings")
            XCTAssertEqual(try rect("runtime-send"), send, "Todo must not create a detached row")
            XCTAssertGreaterThanOrEqual(todo.minX, 0); XCTAssertLessThanOrEqual(todo.maxX, width)
            XCTAssertFalse(todo.intersects(runtime), "Todo and execution settings need independent lanes")
            if width > 640 { XCTAssertEqual(todo.midX, width / 2, accuracy: 1) }
            if let directory = ProcessInfo.processInfo.environment["WAND_COMPOSER_OUTPUT"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("todo-\(Int(width)).png"))
            }
        }
    }

    func testPendingQueueSharesTodoEdgeWithoutMovingActions() async throws {
        let focus = ComposerFocusController()
        let store = ChatStore(sessionId: "queue-layout", api: WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil))
        store.queuedMessages = [String(repeating: "待发消息内容与长文本 ", count: 60), "第二条消息"]
        let todos = [TodoItem(content: "正在核对布局", status: "in_progress", activeForm: nil)]
        let host = NSHostingView(rootView: RuntimeSettingsProbe(focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 940, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rect(_ id: String) throws -> NSRect {
            let view = try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            return view.convert(view.bounds, to: host)
        }
        for width: CGFloat in [320, 390, 940] {
            window.setContentSize(NSSize(width: width, height: 240)); host.frame.size.width = width
            host.rootView = RuntimeSettingsProbe(focus: focus)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let send = try rect("runtime-send")
            for withTodo in [false, true] {
                host.rootView = RuntimeSettingsProbe(focus: focus, todos: withTodo ? todos : [], queueStore: store)
                host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
                let queue = try rect("runtime-queue")
                XCTAssertEqual(try rect("runtime-send"), send)
                XCTAssertGreaterThan(queue.width, 0); XCTAssertLessThanOrEqual(queue.height, 36)
                XCTAssertGreaterThanOrEqual(queue.minX, 0); XCTAssertLessThanOrEqual(queue.maxX, width)
                XCTAssertFalse(queue.intersects(try rect("runtime-settings")))
                XCTAssertFalse(queue.intersects(try rect("runtime-avatar")))
                if withTodo {
                    let todo = try rect("runtime-todo")
                    XCTAssertFalse(queue.intersects(todo))
                    XCTAssertEqual(queue.width, todo.width, accuracy: 1, "Todo and queue retain equal half-width slots")
                    XCTAssertEqual(queue.minY, todo.minY, accuracy: 1, "Both summaries remain in the same horizontal row")
                }
                if let directory = ProcessInfo.processInfo.environment["WAND_COMPOSER_OUTPUT"] {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("queue-\(Int(width))-todo-\(withTodo).png"))
                }
            }
        }
    }

    func testPopoverEscapeIsWindowScopedAndKeepsIMECancellationLocal() async throws {
        var closes = 0
        let host = NSHostingView(rootView: ComposerPopoverHeader(title: "执行配置") { closes += 1 })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 90)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); other.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        func escape(_ target: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(event)
        }
        try escape(other)
        XCTAssertEqual(closes, 0, "another window's Escape cannot close this popover")
        let editor = NSTextView(frame: NSRect(x: 10, y: 40, width: 260, height: 36))
        host.addSubview(editor); XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        try escape(window)
        XCTAssertEqual(closes, 0, "Escape during IME belongs to the input context")
        editor.unmarkText()
        try escape(window)
        XCTAssertEqual(closes, 1)
        window.contentView = nil
        try escape(window)
        XCTAssertEqual(closes, 1, "unmounted popovers release their local event monitor")
    }

    func testPermissionDisplayDoesNotChangeProtocolValues() {
        XCTAssertEqual(composerPermissionLabel("managed"), "托管")
        XCTAssertEqual(composerPermissionLabel("full-access"), "完全访问")
        XCTAssertEqual(composerPermissionLabel("default"), "标准")
        XCTAssertEqual(composerPermissionLabel("future-mode"), "future-mode")
    }

    func testComposerThinkingPreferencesDoNotPretendUnknownLevelsAreOff() {
        XCTAssertEqual(composerThinkingPreference("pi:xhigh"), "超高")
        XCTAssertEqual(composerThinkingPreference("off"), "自动（模型默认）")
        XCTAssertEqual(composerThinkingPreference("pi:new-level"), "new-level")
        XCTAssertEqual(composerThinkingPreference("pi:max"), "极高")
        let pi = thinkingEffortOptions(provider: "pi", selectedModel: nil, defaultModel: nil, models: [])
        XCTAssertEqual(pi.first { $0.id == "deep" }?.label, "高")
        XCTAssertEqual(pi.first { $0.id == "off" }?.label, "自动")
        let codex = thinkingEffortOptions(provider: "codex", selectedModel: nil, defaultModel: nil, models: [])
        XCTAssertEqual(codex.first { $0.id == "max" }?.label, "超高")
    }

    func testFocusBorrowingExplicitDismissAckAndRecoveryMatchAndroid() {
        let focus = ComposerFocusController()
        XCTAssertFalse(focus.editing)
        focus.focus(); focus.borrow("model", open: true); focus.borrow("files", open: true)
        XCTAssertTrue(focus.editing); XCTAssertFalse(focus.focused)
        focus.resume("model"); XCTAssertFalse(focus.focused)
        focus.resume("files"); XCTAssertTrue(focus.focused)
        focus.borrow("model"); focus.collapse(); focus.resume("model")
        XCTAssertFalse(focus.editing); XCTAssertFalse(focus.focused)
        focus.focus(); focus.submit(); focus.collapse()
        XCTAssertTrue(focus.editing, "pending ack cannot hide the submission feedback")
        focus.accepted(hasPendingContent: true); XCTAssertTrue(focus.editing)
        focus.submit(); focus.accepted(hasPendingContent: false); XCTAssertFalse(focus.editing)
        focus.focus(); focus.failed(); focus.collapse()
        XCTAssertTrue(focus.editing, "failed/unknown recovery is sticky")
        focus.resetPresentation(); XCTAssertFalse(focus.editing)
        focus.accepted(hasPendingContent: false); XCTAssertFalse(focus.editing)
    }

    func testIMECommitInsertTextReleasesSendGate() {
        let editor = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var composing = false
        editor.onMarkedTextChange = { composing = $0 }
        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(composing)
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(composing, "IME normally commits through insertText, not an explicit unmarkText call; send must enable after confirmation")
    }

    func testMouseSendAfterIMECommitUsesTheSameNativeEditor() async throws {
        let focus = ComposerFocusController(); focus.focus()
        let probe = NativeProbe()
        let host = NSHostingView(rootView: MouseSendProbe(focus: focus, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        func clickSend() throws {
            let region = try XCTUnwrap(descendants(host).compactMap { $0 as? MouseSendRegion }.first)
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: false); window.sendEvent(down)
        }
        try clickSend(); await Task.yield()
        XCTAssertEqual(probe.submissions, 0, "empty input cannot dispatch")
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(probe.composing)
        try clickSend(); await Task.yield()
        XCTAssertEqual(probe.submissions, 0, "active marked text cannot dispatch")
        editor.insertText("仅本地鼠标验证", replacementRange: NSRange(location: NSNotFound, length: 0))
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(probe.composing); XCTAssertFalse(probe.text.isEmpty)
        try clickSend(); await Task.yield()
        XCTAssertEqual(probe.submissions, 1, "actual native mouse dispatch reaches enabled send action after IME commit")
        XCTAssertTrue(descendants(host).contains { $0 === editor })
    }

    func testExteriorActionVisibilityAndRunningPriorityMatchMobile() {
        for text in ["", " \n\t"] {
            XCTAssertFalse(nativeComposerPrimaryVisible(text: text, hasAttachments: false, turnRunning: false, phase: .idle))
            XCTAssertFalse(nativeComposerPrimaryVisible(text: text, hasAttachments: false, turnRunning: false, phase: .sent))
            XCTAssertTrue(nativeComposerPrimaryVisible(text: text, hasAttachments: true, turnRunning: false, phase: .idle))
            XCTAssertTrue(nativeComposerPrimaryVisible(text: text, hasAttachments: false, turnRunning: true, phase: .idle))
        }
        XCTAssertTrue(nativeComposerPrimaryVisible(text: "消息", hasAttachments: false, turnRunning: false, phase: .idle))
        for phase: NativeComposerPhase in [.idle, .sending, .sent, .failed, .unknown] {
            XCTAssertEqual(nativeComposerActionPhase(phase: phase, turnRunning: true), .idle, "execution must remain stoppable even with new text or pending feedback")
            XCTAssertEqual(nativeComposerActionPhase(phase: phase, turnRunning: false), phase)
        }
        for phase: NativeComposerPhase in [.sending, .failed, .unknown] {
            XCTAssertTrue(nativeComposerPrimaryVisible(text: "", hasAttachments: false, turnRunning: false, phase: phase))
        }
    }

    func testDraftRemainsExpandedWhenFocusLeaves() {
        let focus = ComposerFocusController()
        focus.focus()
        focus.lostFocus()
        XCTAssertTrue(focus.editing)
        XCTAssertFalse(focus.focused)
        focus.focus()
        focus.collapseFromContent()
        XCTAssertTrue(focus.editing)
        focus.collapse()
        XCTAssertFalse(focus.editing)
    }

    func testSendStopMouseDispatchAndStableSlotAcrossCollapse() async throws {
        let focus = ComposerFocusController()
        let probe = NativeProbe()
        let host = NSHostingView(rootView: MouseSendProbe(focus: focus, probe: probe)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded() }
        try await settle()
        let region = try XCTUnwrap(descendants(host).compactMap { $0 as? MouseSendRegion }.first)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        func rect() -> NSRect { region.convert(region.bounds, to: host) }
        func click() async throws {
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: false); window.sendEvent(down); await Task.yield()
        }
        let emptySlot = rect()
        XCTAssertEqual(emptySlot.width, 32, accuracy: 0.5)
        XCTAssertEqual(emptySlot.maxX, host.bounds.maxX, accuracy: 0.5)
        try await click(); XCTAssertEqual(probe.submissions, 0, "hidden empty action cannot dispatch")
        probe.text = "保留草稿"; try await settle()
        try await click(); XCTAssertEqual(probe.submissions, 1, "collapsed draft can send without opening editor")
        focus.focus(); try await settle()
        XCTAssertEqual(rect().midX, emptySlot.midX, accuracy: 0.5)
        XCTAssertEqual(rect().midY, emptySlot.midY, accuracy: 0.5)
        XCTAssertTrue(editor === descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        probe.running = true; probe.phase = .sending; probe.composing = true
        focus.collapse(); try await settle()
        try await click(); XCTAssertEqual(probe.stops, 1, "running task can stop despite draft, IME and send feedback")
        XCTAssertEqual(probe.submissions, 1, "stop never sends or clears the draft")
        XCTAssertEqual(probe.text, "保留草稿")
        XCTAssertEqual(rect().midX, emptySlot.midX, accuracy: 0.5)
        XCTAssertEqual(rect().midY, emptySlot.midY, accuracy: 0.5)
        probe.running = false; probe.composing = false; probe.phase = .sending
        try await settle(); try await click(); XCTAssertEqual(probe.submissions, 1, "sending cannot submit twice")
        probe.phase = .idle; probe.text = ""; probe.hasAttachments = true
        try await settle(); try await click(); XCTAssertEqual(probe.submissions, 2, "attachment-only input remains sendable")
        if let directory = ProcessInfo.processInfo.environment["WAND_COMPOSER_OUTPUT"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] { for width: CGFloat in [320, 800] { for expanded in [false, true] {
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame.size.width = width
                if expanded { focus.focus() } else { focus.collapse() }
                probe.running = true; probe.phase = .idle; probe.text = "运行中保留的草稿"; probe.hasAttachments = false
                try await settle()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(width))-\(expanded ? "expanded" : "collapsed").png"))
                XCTAssertEqual(rect().width, 32, accuracy: 0.5)
                XCTAssertEqual(rect().maxX, host.bounds.maxX, accuracy: 0.5)
            } } }
        }
    }

    func testAvatarUsesOnlyCurrentUnfinishedSemanticCallsNotNames() throws {
        func turn(_ body: String) throws -> ConversationTurn { try JSONDecoder().decode(ConversationTurn.self, from: Data(body.utf8)) }
        let user = ConversationTurn(role: "user", content: [.text(text: "任务", subagent: nil)])
        let read = try turn(#"{"role":"assistant","content":[{"type":"tool_use","id":"r","name":"anything","input":{"__wandToolActivity":{"kind":"read_file"}}}]}"#)
        let write = try turn(#"{"role":"assistant","content":[{"type":"tool_use","id":"w","name":"anything","input":{"__wandToolActivity":{"kind":"edit_file"}}}]}"#)
        let done = try turn(#"{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"w","content":"done","is_error":true}]}"#)
        let fakeName = try turn(#"{"role":"assistant","content":[{"type":"tool_use","id":"fake","name":"Read","input":{}}]}"#)
        XCTAssertEqual(avatarFileActivity(messages: [user, read], executing: true), .reading)
        XCTAssertEqual(avatarFileActivity(messages: [user, read, write], executing: true), .writing)
        XCTAssertEqual(avatarFileActivity(messages: [user, read, write, done], executing: true), .reading)
        XCTAssertEqual(avatarFileActivity(messages: [user, fakeName], executing: true), .idle)
        XCTAssertEqual(avatarFileActivity(messages: [user, read], executing: false), .idle)
        let retired = try turn(#"{"role":"assistant","completedAt":"2026","content":[{"type":"tool_use","id":"r","name":"Read","input":{"__wandToolActivity":{"kind":"read_file"}}}]}"#)
        XCTAssertEqual(avatarFileActivity(messages: [user, retired], executing: true), .idle)
        let thinking = try turn(#"{"role":"assistant","content":[{"type":"thinking","text":"reason"}]}"#)
        XCTAssertTrue(avatarIsThinking(messages: [user, thinking], executing: true))
        XCTAssertFalse(avatarIsThinking(messages: [user, thinking], executing: false))
        XCTAssertFalse(avatarIsThinking(messages: [read, user], executing: true))
    }

    func testOneNativeEditorSurvivesCollapseAndRestoresExplicitFocus() async throws {
        let focus = ComposerFocusController(); focus.focus()
        let probe = NativeProbe()
        let host = NSHostingView(rootView: FocusProbe(focus: focus, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 230)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        func find(_ view: NSView) -> ComposerNSTextView? { if let edit = view as? ComposerNSTextView { return edit }; return view.subviews.compactMap(find).first }
        let editor = try XCTUnwrap(find(host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("保留文字", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(probe.text, "保留文字")
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        focus.collapse(); host.layoutSubtreeIfNeeded(); await Task.yield()
        XCTAssertTrue(editor === find(host)); XCTAssertEqual(editor.string, "保留文字")
        focus.focus(); host.layoutSubtreeIfNeeded(); await Task.yield()
        XCTAssertTrue(editor === find(host)); XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(probe.submissions, 0)
        _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(focus.editing)
    }

    func testOfflineAndroidSceneRendersActualFramesAndReadWriteProps() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 96, height: 96), configuration: config)
        view.setValue(false, forKey: "drawsBackground"); view.underPageBackgroundColor = .clear
        let observer = SceneObserver(); view.navigationDelegate = observer
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { view.evaluateJavaScript("window.disposeScene?.()"); view.stopLoading(); window.orderOut(nil); window.contentView = nil }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "scene", withExtension: "html", subdirectory: "PlushScene"))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        await fulfillment(of: [observer.loaded], timeout: 10)
        let payload: [String: Any] = ["config": try XCTUnwrap(plushSceneConfig("plush_cat_silver")), "size": 96,
            "interactive": false, "fileActivity": "reading", "thinking": false, "speaking": false, "reducedMotion": false]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("window.setScene(\(json));true")
        let documentHidden = try await view.evaluateJavaScript("document.hidden") as? Bool ?? true
        if documentHidden { throw XCTSkip("This native test host document remains hidden; lifecycle correctly pauses renderer. Foreground native motion needs a visible active app context, not a mocked visibility flag.") }
        var result: [String: Any] = [:]
        for _ in 0..<100 {
            result = (try await view.evaluateJavaScript("(()=>{let c=document.querySelector('canvas');return {...c.dataset,title:document.title,hidden:document.hidden,rect:c.getBoundingClientRect().toJSON(),diagnostics:window.__wandPlushDiagnostics?.()}})()")) as? [String: Any] ?? [:]
            if result["title"] as? String == "scene-fallback" { throw XCTSkip("Native WebKit GPU unavailable; same-identity static fallback is tested separately") }
            if Int(result["frame"] as? String ?? "0") ?? 0 > 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("nativeAvatarDiagnostics", result)
        XCTAssertEqual(result["title"] as? String, "scene-ready")
        XCTAssertEqual(result["fileActivity"] as? String, "reading")
        let before = Int(result["frame"] as? String ?? "0") ?? 0
        _ = try await view.evaluateJavaScript("window.setScene({...\(json),fileActivity:'writing'});true")
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = try await view.evaluateJavaScript("(()=>{let c=document.querySelector('canvas');return {...c.dataset}})()") as! [String: Any]
        XCTAssertEqual(after["fileActivity"] as? String, "writing")
        XCTAssertGreaterThan(Int(after["frame"] as? String ?? "0") ?? 0, before)
        if let directory = ProcessInfo.processInfo.environment["WAND_AVATAR_NATIVE_OUTPUT"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["before": result, "after": after], options: [.sortedKeys]).write(to: output.appendingPathComponent("scene-frames.json"))
            let image = try await view.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("native-scene-writing.png"))
        }
    }
    private final class SceneObserver: NSObject, WKNavigationDelegate {
        let loaded = XCTestExpectation(description: "offline avatar loaded")
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }

    private final class NativeProbe: ObservableObject {
        @Published var text = ""
        @Published var composing = false
        @Published var running = false
        @Published var phase = NativeComposerPhase.idle
        @Published var hasAttachments = false
        var submissions = 0
        var stops = 0
    }
    private final class MouseSendRegion: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    private struct MouseSendMarker: NSViewRepresentable {
        func makeNSView(context: Context) -> MouseSendRegion { MouseSendRegion() }
        func updateNSView(_ view: MouseSendRegion, context: Context) {}
    }
    private struct MouseSendProbe: View {
        @ObservedObject var focus: ComposerFocusController
        @ObservedObject var probe: NativeProbe
        var body: some View {
            FocusComposerSurface(expanded: focus.editing, hasDraft: !probe.text.isEmpty, onFocus: focus.focus, editor: {
                IMEAwareComposerTextView(text: $probe.text, placeholder: "本地测试", isFocused: focus.focused, sendWithCommandEnter: false,
                    onFocusChange: { focus.focused = $0 }, onCompositionChange: { probe.composing = $0 }, onSubmit: { probe.submissions += 1 }, onHeightChange: { _ in }, onEscape: focus.collapse).frame(height: 48)
            }, add: { Color.clear }, send: {
                NativeComposerActionButton(phase: probe.phase, turnRunning: probe.running,
                    canSubmit: !probe.composing && (!probe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || probe.hasAttachments),
                    onSend: { probe.submissions += 1 }, onStop: { probe.stops += 1 }).background(MouseSendMarker())
            },
                primaryVisible: nativeComposerPrimaryVisible(text: probe.text, hasAttachments: probe.hasAttachments,
                    turnRunning: probe.running, phase: probe.phase))
        }
    }
    private struct FocusProbe: View {
        @ObservedObject var focus: ComposerFocusController
        @ObservedObject var probe: NativeProbe
        var body: some View {
            FocusComposerSurface(expanded: focus.editing, hasDraft: !probe.text.isEmpty, onFocus: focus.focus, editor: {
                IMEAwareComposerTextView(text: $probe.text, placeholder: "发消息…", isFocused: focus.focused, sendWithCommandEnter: false,
                    onFocusChange: { if $0 { focus.focus() } }, onCompositionChange: { _ in }, onSubmit: { probe.submissions += 1 }, onHeightChange: { _ in }, onEscape: focus.collapse).frame(height: 48)
            }, add: { Text("+").frame(width: 32, height: 32) }, send: { Text("发送") })
        }
    }
}
