import AppKit
import Combine
import XCTest
@testable import Wand

final class DesktopConversationTests: XCTestCase {
    @MainActor
    func testNativePasteConsumesImagesAndFinderURLsWithoutChangingText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        XCTAssertTrue(board.writeObjects([image]))
        let editor = ComposerNSTextView(frame: .zero)
        editor.isRichText = false; editor.importsGraphics = false
        editor.string = "原草稿"
        var imported: [ComposerPasteboardAttachment] = []
        editor.onPasteAttachment = {
            guard let content = try? ComposerPasteboardAttachment(pasteboard: $0) else { return false }
            imported.append(content)
            return true
        }
        XCTAssertTrue(editor.pasteAttachment(from: board))
        let snapshot = try XCTUnwrap(imported.first)
        defer { imported.forEach { $0.removeTemporaryFiles() } }
        XCTAssertEqual(snapshot.urls.count, 1)
        XCTAssertEqual(snapshot.urls[0].pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: snapshot.urls[0]))
        board.clearContents()
        let file = URL(fileURLWithPath: "/tmp/copied-image.png")
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        XCTAssertTrue(editor.pasteAttachment(from: board))
        XCTAssertEqual(imported.last?.urls, [file])
        XCTAssertTrue(imported.last?.temporaryURLs.isEmpty == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.urls[0].path), "Clipboard changes cannot replace an in-flight image")
        XCTAssertEqual(editor.string, "原草稿")
        board.clearContents(); board.setString("纯文本", forType: .string)
        XCTAssertFalse(editor.pasteAttachment(from: board))
        XCTAssertEqual(imported.count, 2, "Plain text must fall back to AppKit")
        editor.isEditable = false
        board.clearContents(); board.writeObjects([image])
        XCTAssertFalse(editor.pasteAttachment(from: board), "Inactive/disabled composers cannot upload")
    }

    @MainActor
    func testNativePasteActionAndMenuValidationUseAttachmentHandlerAndTextFallback() throws {
        // Preserve all current clipboard representations; never leave a test image in the user's clipboard.
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(items)
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        board.clearContents(); board.setData(png, forType: .png)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerNSTextView(frame: window.contentView!.bounds)
        window.contentView = editor
        defer { window.contentView = nil }
        editor.isRichText = false; editor.importsGraphics = false
        editor.allowsUndo = true
        editor.string = "已有草稿"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(editor)
        var count = 0
        editor.onPasteAttachment = { _ in count += 1; return true }
        let menu = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        XCTAssertTrue(editor.validateUserInterfaceItem(menu), "Image-only clipboard enables Paste")
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.paste(_:)), to: editor, from: menu))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(editor.string, "已有草稿")
        board.clearContents(); board.setString("中文\n第二行", forType: .string)
        editor.paste(nil)
        XCTAssertEqual(editor.string, "已有中文\n第二行草稿")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "已有草稿")
    }

    @MainActor
    func testComposerReportsFocusBeforeTypingAndPreservesNativeEditing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = editor
        var focus: [Bool] = []
        editor.onFocusChange = { focus.append($0) }
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertEqual(focus, [true])
        editor.insertText("中文草稿", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "中文草稿")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(focus, [true, false])
    }

    @MainActor
    func testSwitchingSessionsAndServersKeepsIndependentDrafts() {
        let cache = ConversationDraftCache()
        let firstServer = URL(string: "https://first.example")!
        let secondServer = URL(string: "https://second.example")!
        cache.save(ConversationDraft(text: "第一台服务器的工作", attachments: []), serverURL: firstServer, sessionID: "same-id")
        cache.save(ConversationDraft(text: "另一项工作", attachments: []), serverURL: firstServer, sessionID: "other-id")
        cache.save(ConversationDraft(text: "第二台服务器的工作", attachments: []), serverURL: secondServer, sessionID: "same-id")

        XCTAssertEqual(cache.draft(serverURL: firstServer, sessionID: "same-id")?.text, "第一台服务器的工作")
        XCTAssertEqual(cache.draft(serverURL: firstServer, sessionID: "other-id")?.text, "另一项工作")
        XCTAssertEqual(cache.draft(serverURL: secondServer, sessionID: "same-id")?.text, "第二台服务器的工作")
        cache.save(ConversationDraft(text: "", attachments: []), serverURL: firstServer, sessionID: "same-id")
        XCTAssertNil(cache.draft(serverURL: firstServer, sessionID: "same-id"))
        XCTAssertNotNil(cache.draft(serverURL: secondServer, sessionID: "same-id"))
    }

    @MainActor
    func testAttachmentOnlyDraftSurvivesNavigation() {
        let cache = ConversationDraftCache()
        let server = URL(string: "https://example.test")!
        cache.save(ConversationDraft(text: "", attachments: [attachment("diagram.png")]), serverURL: server, sessionID: "one")
        XCTAssertEqual(cache.draft(serverURL: server, sessionID: "one")?.attachments.first?.originalName, "diagram.png")
    }

    func testFailedSendRecoversOriginalPromptWithoutDiscardingNewWork() {
        let original = ConversationDraft(text: "修复登录", attachments: [attachment("before.png"), attachment("shared.txt")])
        let newer = ConversationDraft(text: "也检查中文输入法", attachments: [attachment("shared.txt"), attachment("after.png")])
        let recovered = ConversationDraft.recover(submitted: original, current: newer)
        XCTAssertEqual(recovered.text, "修复登录\n\n也检查中文输入法")
        XCTAssertEqual(recovered.attachments.map(\.originalName), ["before.png", "shared.txt", "after.png"])
    }

    @MainActor
    func testFailedSendAfterLeavingAndReopeningSessionRecoversIntoLatestDraft() {
        let cache = ConversationDraftCache()
        let server = URL(string: "https://example.test")!
        let submitted = ConversationDraft(text: "最初提交", attachments: [attachment("original.png")])
        // A sent, then unmounted. B and a newly mounted A now have independent fresh work.
        cache.save(ConversationDraft(text: "", attachments: []), serverURL: server, sessionID: "A")
        cache.save(ConversationDraft(text: "B 的内容", attachments: []), serverURL: server, sessionID: "B")
        cache.save(ConversationDraft(text: "重新打开 A 后输入", attachments: [attachment("new.png")]), serverURL: server, sessionID: "A")
        var visibleDraft: ConversationDraft?
        let subscription = cache.recoveries.sink { event in
            if event.serverURL == server && event.sessionID == "A" { visibleDraft = event.draft }
        }

        // The old request callback supplies only the submitted content, never stale view state.
        cache.recover(submitted: submitted, serverURL: server, sessionID: "A")

        XCTAssertEqual(cache.draft(serverURL: server, sessionID: "A")?.text, "最初提交\n\n重新打开 A 后输入")
        XCTAssertEqual(visibleDraft?.text, "最初提交\n\n重新打开 A 后输入")
        XCTAssertEqual(visibleDraft?.attachments.map(\.originalName), ["original.png", "new.png"])
        XCTAssertEqual(cache.draft(serverURL: server, sessionID: "B")?.text, "B 的内容")
        withExtendedLifetime(subscription) {}
    }

    func testFailedAttachmentOnlySendDoesNotAddWhitespaceToNewPrompt() {
        let recovered = ConversationDraft.recover(
            submitted: ConversationDraft(text: "", attachments: [attachment("screen.png")]),
            current: ConversationDraft(text: "分析这张图", attachments: [])
        )
        XCTAssertEqual(recovered.text, "分析这张图")
        XCTAssertEqual(recovered.attachments.count, 1)
    }

    func testInputMethodConfirmationNeverSendsInEitherKeyboardMode() {
        for commandEnter in [false, true] {
            for modifiers: NSEvent.ModifierFlags in [[], .command, .shift] {
                XCTAssertFalse(ConversationSendPolicy.shouldSubmit(modifiers: modifiers, commandEnter: commandEnter, composing: true))
            }
        }
    }

    func testReturnPreferenceKeepsExplicitNewlineModifiers() {
        XCTAssertTrue(ConversationSendPolicy.shouldSubmit(modifiers: [], commandEnter: false, composing: false))
        XCTAssertFalse(ConversationSendPolicy.shouldSubmit(modifiers: [], commandEnter: true, composing: false))
        XCTAssertTrue(ConversationSendPolicy.shouldSubmit(modifiers: .command, commandEnter: true, composing: false))
        for commandEnter in [false, true] {
            for modifiers: NSEvent.ModifierFlags in [.shift, .option, [.command, .shift]] {
                XCTAssertFalse(ConversationSendPolicy.shouldSubmit(modifiers: modifiers, commandEnter: commandEnter, composing: false))
            }
        }
    }

    func testStructuredImageResultStaysVisibleWithoutImagePath() throws {
        let json = """
        {"type":"tool_result","tool_use_id":"view-1","content":[
          {"type":"text","text":"截图"},
          {"type":"image","source":{"type":"url","url":"/api/sessions/s/tool-images/view-1/0"}}
        ]}
        """
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        guard case .toolResult(let id, let text, _, _, let images, _) = block else {
            return XCTFail("图片工具结果未解析")
        }
        XCTAssertEqual(id, "view-1")
        XCTAssertEqual(text, "截图")
        XCTAssertEqual(images, ["/api/sessions/s/tool-images/view-1/0"])
        let result = ToolResultInfo(text: text, isError: false, truncated: false, images: images)
        XCTAssertTrue(toolHasVisibleImage(input: [:], result: result))
        XCTAssertTrue(toolHasVisibleImage(input: ["path": .string("/tmp/capture.png")], result: nil))
        XCTAssertFalse(toolHasVisibleImage(input: ["path": .string("/tmp/config.json")], result: nil))
    }

    func testImageOnlyToolResultDecodesWithoutText() throws {
        let json = """
        {"type":"tool_result","tool_use_id":"view-2","content":[
          {"type":"image","source":{"type":"url","url":"/api/sessions/s/tool-images/view-2/0"}}
        ]}
        """
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        guard case .toolResult(_, let text, _, _, let images, _) = block else {
            return XCTFail("纯图片工具结果未解析")
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(images.count, 1)
    }

    func testSearchFindsTextAndToolOutputAndKeepsAbsoluteHistoryPositions() {
        let turns = [
            ConversationTurn(role: "user", content: [.text(text: "请检查登录", subagent: nil)]),
            ConversationTurn(role: "assistant", content: [
                .toolUse(id: "read-1", name: "Read", description: "读取文件", input: ["path": .string("/repo/auth.ts")], subagent: nil),
                .toolResult(toolUseId: "read-1", text: "登录错误已定位", isError: false, truncated: false, images: [], subagent: nil)
            ]),
            ConversationTurn(role: "assistant", content: [.text(text: "修复完成", subagent: nil)])
        ]
        XCTAssertEqual(ConversationSearch.matches(in: turns, offset: 80, query: " 登录 \n"), [80, 81])
        XCTAssertEqual(ConversationSearch.matches(in: turns, offset: 80, query: "AUTH.TS"), [81])
        XCTAssertEqual(ConversationSearch.matches(in: turns, offset: 80, query: "不存在"), [])
        XCTAssertEqual(ConversationSearch.matches(in: turns, offset: 80, query: " \n"), [])
        XCTAssertEqual(ConversationSearch.matches(in: [turns[0]] + turns, offset: 79, query: "auth.ts"), [81])
    }

    func testSearchExcerptShowsHiddenToolMatchWithUnicodeContext() {
        let text = String(repeating: "上下文🙂", count: 30) + "\n登录失败\n" + String(repeating: "后续内容", count: 60)
        let turn = ConversationTurn(role: "assistant", content: [
            .toolResult(toolUseId: "tool-1", text: text, isError: true, truncated: false, images: [], subagent: nil)
        ])
        let excerpt = ConversationSearch.excerpt(from: turn, query: "登录失败")
        XCTAssertTrue(excerpt?.contains("登录失败") == true)
        XCTAssertTrue(excerpt?.hasPrefix("…") == true)
        XCTAssertTrue(excerpt?.hasSuffix("…") == true)
        XCTAssertFalse(excerpt?.contains("\n") == true)
        XCTAssertNil(ConversationSearch.excerpt(from: turn, query: "无匹配"))
    }

    private func attachment(_ name: String) -> UploadedFile {
        UploadedFile(originalName: name, savedPath: "/uploads/" + name, size: 10, mimeType: "application/octet-stream")
    }
}
