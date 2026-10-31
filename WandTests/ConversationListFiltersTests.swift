import Foundation
import XCTest
#if !CONVERSATION_FILTER_STANDALONE
@testable import Wand
#endif

final class ConversationListFiltersTests: XCTestCase {
    private func session(_ id: String, extra: [String: Any] = [:]) throws -> WorkspaceSessionSummary {
        let value = ["id": id, "employeeId": "employee", "employeeName": "员工", "title": id, "cwd": "/same/path"].merging(extra) { _, new in new }
        return try JSONDecoder().decode(WorkspaceSessionSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func task(_ id: String, stage: String? = nil, status: String = "active", archived: Bool = false,
                      sessions: [WorkspaceSessionSummary]) -> WorkspaceTaskSummary {
        WorkspaceTaskSummary(id: id, workspaceId: "different-task-owner", name: id, worktree: nil, layout: nil,
            status: status, createdAt: "", lastOpenedAt: nil, cwd: "/same/path", isolated: nil, worktreeError: nil,
            sessions: sessions, archived: archived, boardTaskId: stage == nil ? nil : "board-" + id, boardTaskStatus: stage)
    }
    private func group(_ id: String, tasks: [WorkspaceTaskSummary] = [], sessions: [WorkspaceSessionSummary] = [],
                       synthetic: Bool = false, global: Bool = false) -> TaskDirectoryGroup {
        TaskDirectoryGroup(workspaceId: id, workspaceName: "同名工作区", workspaceCwd: "/same/path", synthetic: synthetic,
            tasks: tasks, standaloneSessions: sessions, global: global)
    }
    private func dm(archived: Bool = false) throws -> NativeConversation {
        try JSONDecoder().decode(NativeConversation.self, from: JSONSerialization.data(withJSONObject: [
            "id": "dm_employee", "kind": "dm", "peerEmployeeId": "employee", "title": "员工",
            "dissolvedAt": archived ? "2026-01-01" : ""
        ]))
    }

    func testSameSessionIntersectionAndParentCount() throws {
        let groups = [group("A", tasks: [task("review-A", stage: "review", sessions: [try session("a")])]),
                      group("B", tasks: [task("doing-B", stage: "doing", sessions: [try session("b")])])]
        let entries = ConversationSessionEntry.index(groups: groups)
        let impossible = ConversationListFilters(taskStage: .review, workspace: "id:B")
        XCTAssertTrue(entries.filter { $0.matches(impossible, query: "") }.isEmpty)
        XCTAssertFalse(ConversationSessionEntry.matchesConversation(try dm(), entries: entries, filters: impossible, query: ""))
        let valid = ConversationListFilters(taskStage: .review, workspace: "id:A")
        XCTAssertEqual(entries.filter { $0.matches(valid, query: "") }.map(\.id), ["a"])
        XCTAssertTrue(ConversationSessionEntry.matchesConversation(try dm(), entries: entries, filters: valid, query: "员工"))
        XCTAssertFalse(ConversationSessionEntry.matchesConversation(try dm(), entries: entries, filters: valid, query: "b"))
    }

    func testOldDoneMapsToReviewNotWorkspaceStatus() throws {
        let groups = [group("A", tasks: [task("old", stage: "done", status: "active", sessions: [try session("a")]),
                                       task("workspace-done", stage: "doing", status: "done", sessions: [try session("b")])])]
        let entries = ConversationSessionEntry.index(groups: groups)
        XCTAssertEqual(entries.map(\.taskStage), [.review, .doing])
        XCTAssertEqual(entries[0].caption, "待验收 · 同名工作区")
    }

    func testUnknownDoesNotBecomeUnassociated() throws {
        let groups = [group("A", tasks: [task("container", status: "done", sessions: [try session("container")])],
                            sessions: [try session("orphan", extra: ["workspaceTaskId": "missing"]), try session("standalone")])]
        let entries = ConversationSessionEntry.index(groups: groups, fallback: [try session("unloaded")])
        let none = ConversationListFilters(taskStage: .none)
        XCTAssertEqual(entries.filter { $0.matches(none, query: "") }.map(\.id), ["standalone"])
        XCTAssertNil(entries.first { $0.id == "container" }?.taskStage)
        XCTAssertNil(entries.first { $0.id == "unloaded" }?.workspace)
        XCTAssertFalse(ConversationSessionEntry.matchesConversation(try dm(), entries: [], filters: none, query: ""))
    }

    func testWorkspaceUsesStableGroupIDNotPathNameOrTaskOwner() throws {
        let groups = [group("A", sessions: [try session("a")]), group("B", sessions: [try session("b")]),
                      group("synthetic", sessions: [try session("c")], synthetic: true),
                      group("global", sessions: [try session("d")], global: true),
                      group("wand-global", sessions: [try session("e")])]
        let entries = ConversationSessionEntry.index(groups: groups)
        XCTAssertEqual(entries.filter { $0.matches(ConversationListFilters(workspace: "id:B"), query: "") }.map(\.id), ["b"])
        XCTAssertEqual(entries.filter { $0.workspace == "none" }.map(\.id), ["c", "d", "e"])
        XCTAssertEqual(ConversationSessionEntry.workspaceOptions(groups).map(\.id), ["all", "none", "id:A", "id:B"])
        let owned = ConversationSessionEntry.index(groups: [group("A", tasks: [task("t", stage: "ready", sessions: [try session("s")])])])
        XCTAssertEqual(owned.first?.workspace, "id:A")
    }

    func testConversationArchiveAndBoardArchiveAreOrthogonal() throws {
        let groups = [group("A", tasks: [task("board-archived", stage: "archived", sessions: [try session("a")]),
                                       task("container-archived", stage: "review", archived: true, sessions: [try session("b")])],
                            sessions: [try session("c", extra: ["archived": true])])]
        let entries = ConversationSessionEntry.index(groups: groups)
        XCTAssertEqual(entries.filter { $0.matches(ConversationListFilters(taskStage: .archived, archive: .unarchived), query: "") }.map(\.id), ["a"])
        XCTAssertEqual(entries.filter { $0.matches(ConversationListFilters(archive: .archived), query: "") }.map(\.id), ["b", "c"])
        XCTAssertTrue(ConversationSessionEntry.matchesConversation(try dm(archived: true), entries: [entries[0]], filters: ConversationListFilters(archive: .archived), query: ""))
        XCTAssertFalse(ConversationSessionEntry.matchesConversation(try dm(archived: true), entries: [entries[0]], filters: ConversationListFilters(archive: .unarchived), query: ""))
    }

    func testActivityMustMatchTheSameSession() throws {
        let entries = ConversationSessionEntry.index(groups: [group("A", tasks: [
            task("review-idle", stage: "review", sessions: [try session("a")]),
            task("doing-active", stage: "doing", sessions: [try session("b", extra: ["inFlight": true])])])])
        XCTAssertFalse(ConversationSessionEntry.matchesConversation(try dm(), entries: entries,
            filters: ConversationListFilters(taskStage: .review, activityOnly: true), query: ""))
        XCTAssertEqual(entries.filter { $0.matches(ConversationListFilters(activityOnly: true), query: "") }.map(\.id), ["b"])
    }

    func testSystemCallsStayReadOnlyAndDoNotInventWorkspace() throws {
        let groups = [group("system-calls:employee", sessions: [try session("system")], synthetic: true)]
        let entry = try XCTUnwrap(ConversationSessionEntry.index(groups: groups).first)
        XCTAssertTrue(entry.isSystemCall)
        XCTAssertNil(entry.workspace)
        XCTAssertFalse(entry.matches(ConversationListFilters(workspace: "none"), query: ""))
        XCTAssertEqual(ConversationSessionEntry.workspaceOptions(groups).map(\.id), ["all", "none"])
    }

    func testHiddenGroupsAndDuplicatesNeverInflateCounts() throws {
        let visible = try session("same")
        let hidden = try session("hidden", extra: ["teamChat": ["teamId": "team", "runId": "run", "teamName": "群聊", "memberCount": 2]])
        let entries = ConversationSessionEntry.index(groups: [group("A", tasks: [task("t", stage: "doing", sessions: [visible, hidden])], sessions: [visible])], fallback: [visible])
        XCTAssertEqual(entries.map(\.id), ["same"])
        XCTAssertEqual(entries.first?.taskStage, .doing)
        XCTAssertFalse(DesktopGroupChatPresentation.isVisible)
    }

    func testBoardFieldsDecodeAndLegacyInitializerRemainsCompatible() throws {
        let legacy = task("legacy", sessions: [])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        value.removeValue(forKey: "boardTaskId"); value.removeValue(forKey: "boardTaskStatus")
        let old = try JSONDecoder().decode(WorkspaceTaskSummary.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(old.boardTaskId); XCTAssertNil(old.boardTaskStatus)
        value["boardTaskId"] = "board"; value["boardTaskStatus"] = "ready"
        let current = try JSONDecoder().decode(WorkspaceTaskSummary.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(current.boardTaskId, "board"); XCTAssertEqual(current.boardTaskStatus, "ready")
        value["boardTaskStatus"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(WorkspaceTaskSummary.self, from: JSONSerialization.data(withJSONObject: value)).boardTaskStatus)
    }

    func testCompleteArchiveResponseDerivesLegacyActiveProjection() throws {
        let active = try session("active")
        let archived = try session("archived", extra: ["archived": true])
        let groups = [group("A", tasks: [
            task("visible", stage: "archived", sessions: [active, archived]),
            task("hidden", stage: "review", archived: true, sessions: [active])
        ], sessions: [active, archived]), group("empty-synthetic", sessions: [archived], synthetic: true),
            group("empty-real"), group("wand-global", sessions: [archived], global: true)]
        let projection = TaskGroupsPage.activeGroups(from: groups)
        XCTAssertEqual(projection.map(\.workspaceId), ["A", "empty-real"])
        XCTAssertEqual(projection[0].tasks.map(\.id), ["visible"])
        XCTAssertEqual(projection[0].tasks[0].sessions.map(\.id), ["active"])
        XCTAssertEqual(projection[0].tasks[0].listedSessionCount, 1)
        XCTAssertEqual(projection[0].tasks[0].boardTaskStatus, "archived", "Board status is not the conversation archive marker")
        XCTAssertEqual(projection[0].tasks[0].boardTaskId, "board-visible")
        XCTAssertEqual(projection[0].standaloneSessions.map(\.id), ["active"])
        XCTAssertEqual(groups[0].tasks.count, 2, "Complete conversation snapshot remains untouched")
        XCTAssertEqual(groups[0].tasks[0].sessions.count, 2)
    }

    func testActiveProjectionRetainsRequiredArchivedAncestorLikeServer() throws {
        let parent = task("parent", stage: "review", archived: true, sessions: [])
        var child = task("child", stage: "todo", sessions: [])
        child.parentWorkspaceTaskId = parent.id
        let projection = TaskGroupsPage.activeGroups(from: [group("A", tasks: [parent, child])])
        XCTAssertEqual(projection[0].tasks.map(\.id), ["parent", "child"])
        XCTAssertEqual(projection[0].tasks[0].archived, true)
        XCTAssertEqual(projection[0].tasks[1].parentWorkspaceTaskId, "parent")
    }

    func testDraftValueChangesDoNotApplyUntilAssigned() {
        let applied = ConversationListFilters(taskStage: .review, workspace: "id:A", archive: .unarchived, activityOnly: true)
        var draft = applied
        draft = ConversationListFilters()
        XCTAssertEqual(applied.count, 4)
        XCTAssertEqual(draft.count, 0)
    }
}
