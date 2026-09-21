import Foundation
import XCTest
@testable import Wand

final class GitStatusPresentationTests: XCTestCase {
    func testNonRepositoryIsNeutralEvenWhenAStaleFileListIsPresent() throws {
        let status = try decode(#"{"isGit":false,"files":[{"path":"old.txt","status":".M"}]}"#)
        let state = GitStatusPresentation.resolve(status: status, loading: false, error: nil)
        XCTAssertEqual(state, .nonRepository)
        XCTAssertFalse(state.permitsCommit(loading: false))
    }

    func testTransportAndPayloadFailuresCannotShowCachedCleanOrEnableCommit() throws {
        let cached = try decode(#"{"isGit":true,"files":[{"path":"draft.txt","status":".M"}]}"#)
        let failed = GitStatusPresentation.resolve(status: cached, loading: false, error: "offline")
        XCTAssertEqual(failed, .failure("offline"))
        XCTAssertFalse(failed.permitsCommit(loading: false))

        let payload = try decode(#"{"isGit":false,"error":"工作目录不存在。"}"#)
        XCTAssertEqual(
            GitStatusPresentation.resolve(status: payload, loading: false, error: nil),
            .failure("工作目录不存在。")
        )
    }

    func testLoadingAndMissingStatusNeverImplyACleanRepository() {
        XCTAssertEqual(GitStatusPresentation.resolve(status: nil, loading: true, error: "previous failure"), .loading)
        XCTAssertEqual(GitStatusPresentation.resolve(status: nil, loading: false, error: nil), .unavailable)
    }

    func testCleanRequiresARepositoryAndAnExplicitEmptyResult() throws {
        for json in [#"{"isGit":true,"files":[]}"#, #"{"isGit":true,"modifiedCount":0}"#] {
            let state = GitStatusPresentation.resolve(status: try decode(json), loading: false, error: nil)
            XCTAssertEqual(state, .clean)
            XCTAssertFalse(state.permitsCommit(loading: false))
        }
        XCTAssertEqual(
            GitStatusPresentation.resolve(status: try decode(#"{"isGit":true}"#), loading: false, error: nil),
            .unavailable
        )
    }

    func testRenamesConflictsAndOtherPorcelainStatesRemainDirty() throws {
        for code in [".M", "A.", ".D", "??", "R.", "UU", "AA", "DD", "C.", ".T"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "isGit": true,
                "files": [["path": "file.txt", "status": code]],
            ])
            let status = try JSONDecoder().decode(GitStatusResult.self, from: data)
            let state = GitStatusPresentation.resolve(status: status, loading: false, error: nil)
            XCTAssertEqual(state, .dirty, code)
            XCTAssertTrue(state.permitsCommit(loading: false), code)
            XCTAssertFalse(state.permitsCommit(loading: true), "Refreshing never offers a stale commit action")
        }
    }

    func testLegacyModifiedCountRemainsDirtyWithoutAFileList() throws {
        let status = try decode(#"{"isGit":true,"modifiedCount":3}"#)
        XCTAssertEqual(GitStatusPresentation.resolve(status: status, loading: false, error: nil), .dirty)
    }

    private func decode(_ json: String) throws -> GitStatusResult {
        try JSONDecoder().decode(GitStatusResult.self, from: Data(json.utf8))
    }
}
