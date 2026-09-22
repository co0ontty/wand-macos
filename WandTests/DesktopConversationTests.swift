import AppKit
import Combine
import XCTest
@testable import Wand

final class DesktopConversationTests: XCTestCase {
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
