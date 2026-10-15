import XCTest
@testable import Wand

final class TurnNavigatorTests: XCTestCase {
    private func user(_ text: String, id: String? = nil, notice: Bool = false) throws -> ConversationTurn {
        var object: [String: Any] = ["role": "user", "content": [["type": "text", "text": text]], "notice": notice]
        if let id { object["messageId"] = id }
        return try JSONDecoder().decode(ConversationTurn.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func index(_ turns: [ConversationTurn], offset: Int = 0, scope: String = "session-a",
                       visible: Set<Int>? = nil) -> TurnNavigationIndex {
        TurnNavigationIndex(scope: scope, turns: turns, offset: offset, visibleIndices: visible)
    }

    func testOnlyVisibleUserQuestionsAreIndexed() throws {
        let turns = [try user("问题"), ConversationTurn(role: "assistant", content: [.text(text: "回答", subagent: nil)]),
                     try user("系统通知", notice: true), ConversationTurn(role: "system", content: [.text(text: "提示词", subagent: nil)]),
                     ConversationTurn(role: "user", content: [.toolResult(toolUseId: "t", text: "secret", isError: false, truncated: false, images: [], subagent: nil)])]
        XCTAssertEqual(index(turns).entries.map(\.preview), ["问题"])
    }

    func testMessageIDSurvivesHistoryPrependAndReorderAndResolvesCurrentPosition() throws {
        let first = try user("第一问", id: "one")
        let second = try user("第二问", id: "two")
        let target = try XCTUnwrap(index([first, second], offset: 10).entries.last)
        let earlier = try user("更早", id: "earlier")
        XCTAssertEqual(index([earlier, first, second], offset: 9).resolve(target.id), 11)
        XCTAssertEqual(index([second, first], offset: 10).resolve(target.id), 10)
        XCTAssertNil(index([first], offset: 10).resolve(target.id))
    }

    func testSameMessageIDCannotCrossSessionOrServerScope() throws {
        let turns = [try user("问题", id: "shared")]
        let id = try XCTUnwrap(index(turns, scope: "server-a|session-a").entries.first?.id)
        XCTAssertNil(index(turns, scope: "server-a|session-b").resolve(id))
        XCTAssertNil(index(turns, scope: "server-b|session-a").resolve(id))
    }

    func testLegacyFallbackIsBoundToWindowAndAbsolutePosition() throws {
        let first = try user("旧问题")
        let second = try user("另一问题")
        let turns = [first, second]
        let id = try XCTUnwrap(index(turns, offset: 20).entries.first?.id)
        XCTAssertEqual(index(turns, offset: 20).resolve(id), 20)
        XCTAssertNil(index(turns, offset: 19).resolve(id))
        XCTAssertNil(index([second, first], offset: 20).resolve(id))
        XCTAssertNil(index([try user("更早"), first, second], offset: 19).resolve(id))
        XCTAssertNil(index(turns, offset: 20, scope: "other").resolve(id))
    }

    func testAssistantStreamingDoesNotInvalidateLegacyQuestionWithinSameWindow() throws {
        let question = try user("问题")
        let before = [question, ConversationTurn(role: "assistant", content: [.text(text: "回", subagent: nil)])]
        let after = [question, ConversationTurn(role: "assistant", content: [.text(text: "回答继续", subagent: nil)])]
        let id = try XCTUnwrap(index(before).entries.first?.id)
        XCTAssertEqual(index(after).resolve(id), 0)
    }

    func testDuplicateOrEmptyMessageIDsUseDistinctWindowPositions() throws {
        let turns = [try user("一", id: "same"), try user("二", id: "same"), try user("三", id: "")]
        let entries = index(turns, offset: 30).entries
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        for (position, entry) in entries.enumerated() {
            guard case .window = entry.id else { return XCTFail("Ambiguous IDs must not be stable IDs") }
            XCTAssertEqual(index(turns, offset: 30).resolve(entry.id), 30 + position)
        }
    }

    func testCommunicationsFilterKeepsOriginalPositionsAndRejectsHiddenTargets() throws {
        let turns = [try user("一", id: "1"), try user("二", id: "2"), try user("三", id: "3")]
        let original = index(turns)
        let filtered = index(turns, visible: [1, 2])
        XCTAssertEqual(filtered.entries.map(\.absoluteIndex), [1, 2])
        XCTAssertNil(filtered.resolve(original.entries[0].id))
        XCTAssertEqual(filtered.resolve(original.entries[2].id), 2)
    }

    func testPreviewReusesVisibleAttachmentBodyAndPreservesUserJSON() throws {
        let attachment = try user("[附件已上传，请查看以下文件:\n/private/secret.txt\n]\n\n请查看附件")
        XCTAssertEqual(index([attachment]).entries.first?.preview, "请查看附件")
        let onlyAttachment = try user("[附件已上传，请查看以下文件:\n/private/secret.txt\n]\n\n")
        XCTAssertEqual(index([onlyAttachment]).entries.first?.preview, "1 个附件")
        let json = "{\"question\":\"这是我的正文\"}"
        XCTAssertEqual(index([try user(json)]).entries.first?.preview, json)
    }

    func testPreviewExcludesThinkingAndToolPayloads() {
        let turn = ConversationTurn(role: "user", content: [
            .text(text: "可见问题", subagent: nil),
            .thinking(thinking: "hidden context", subagent: nil),
            .toolUse(id: "t", name: "shell", description: nil, input: ["secret": .string("credential")], subagent: nil),
            .toolResult(toolUseId: "t", text: "secret output", isError: false, truncated: false, images: [], subagent: nil)
        ])
        XCTAssertEqual(index([turn]).entries.first?.preview, "可见问题")
    }
}
