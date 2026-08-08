import Foundation
import XCTest
@testable import Wand

@MainActor
final class MacUpdateManagerTests: XCTestCase {

    func testInstallOrderTreatsSameBaseBetaAsNewerThanStable() {
        XCTAssertGreaterThan(
            MacUpdateManager.compareInstallOrder("4.38.0-beta.202608081200.10.gabcdef", "4.38.0"),
            0
        )
        XCTAssertGreaterThan(
            MacUpdateManager.compareInstallOrder("4.39.0", "4.38.0-beta.202608081200.10.gabcdef"),
            0
        )
        XCTAssertLessThan(MacUpdateManager.compareInstallOrder("4.38.0-rc.1", "4.38.0"), 0)
        XCTAssertEqual(MacUpdateManager.compareInstallOrder("4.38.0+123", "4.38.0+456"), 0)
    }

    func testStableCheckUsesStrictAssetNameAndAppliesManifest() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requestedPaths: [String] = []
        let release = """
        {
          "tag_name": "v2.0.0",
          "html_url": "https://github.com/co0ontty/wand/releases/tag/v2.0.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-08-08T00:00:00Z",
          "body": "changes",
          "assets": [
            {"name":"another.zip","browser_download_url":"https://example.test/another.zip","size":42},
            {"name":"wand-v2.0.0+202608081200.zip","browser_download_url":"https://example.test/wand.zip","size":42},
            {"name":"wand-v2.0.0.update.json","browser_download_url":"https://example.test/manifest","size":10}
          ]
        }
        """
        let manifest = """
        {
          "version":"2.0.0",
          "assets":[
            {"fileName":"wand-v2.0.0+202608081200.zip","size":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
          ]
        }
        """
        let manager = MacUpdateManager(
            defaults: defaults,
            currentVersion: { "1.0.0" },
            dataLoader: { request in
                requestedPaths.append(request.url?.absoluteString ?? "")
                let body = request.url?.host == "example.test" ? manifest : release
                return Self.response(for: request, body: body)
            }
        )

        let result = await manager.check(.manual)
        guard case let .updateAvailable(update) = result else {
            return XCTFail("expected updateAvailable, got \(String(describing: result))")
        }
        XCTAssertEqual(update.latestVersion, "2.0.0")
        XCTAssertEqual(update.preferredAsset?.name, "wand-v2.0.0+202608081200.zip")
        XCTAssertEqual(update.preferredAsset?.sha256, String(repeating: "a", count: 64))
        XCTAssertTrue(requestedPaths.first?.hasSuffix("/releases/latest") == true)
        XCTAssertEqual(requestedPaths.count, 2)
    }

    func testBetaCheckIncludesPrereleaseAndChoosesProductInstallOrder() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let releases = """
        [
          {
            "tag_name":"v4.38.0",
            "html_url":"https://github.com/co0ontty/wand/releases/tag/v4.38.0",
            "draft":false,
            "prerelease":false,
            "published_at":"2026-08-01T00:00:00Z",
            "body":null,
            "assets":[{"name":"wand-v4.38.0.zip","browser_download_url":"https://example.test/stable.zip","size":1}]
          },
          {
            "tag_name":"v4.38.0-beta.202608081230.12.gabcdef",
            "html_url":"https://github.com/co0ontty/wand/releases/tag/beta",
            "draft":false,
            "prerelease":true,
            "published_at":"2026-08-08T04:30:00Z",
            "body":null,
            "assets":[{"name":"wand-v4.38.0-beta.202608081230.12.gabcdef+202608081230.zip","browser_download_url":"https://example.test/beta.zip","size":2}]
          }
        ]
        """
        var requestedURL: URL?
        let manager = MacUpdateManager(
            defaults: defaults,
            currentVersion: { "4.38.0" },
            dataLoader: { request in
                requestedURL = request.url
                return Self.response(for: request, body: releases)
            }
        )

        let result = await manager.setChannel(.beta)
        guard case let .updateAvailable(update) = result else {
            return XCTFail("expected beta update, got \(String(describing: result))")
        }
        XCTAssertEqual(update.channel, .beta)
        XCTAssertEqual(update.latestVersion, "4.38.0-beta.202608081230.12.gabcdef")
        XCTAssertEqual(requestedURL?.query, "per_page=20")
    }

    func testFailedLaunchCheckDoesNotThrottleRetry() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let manager = MacUpdateManager(
            defaults: defaults,
            currentVersion: { "1.0.0" },
            dataLoader: { _ in
                requests += 1
                throw URLError(.notConnectedToInternet)
            }
        )

        _ = await manager.check(.launch)
        _ = await manager.check(.launch)
        XCTAssertEqual(requests, 2)
        XCTAssertNil(manager.lastSuccessfulCheck)
    }

    func testSuccessfulLaunchCheckThrottlesButManualCheckBypassesThrottle() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let release = """
        {
          "tag_name":"v1.0.0",
          "html_url":"https://github.com/co0ontty/wand/releases/tag/v1.0.0",
          "draft":false,
          "prerelease":false,
          "published_at":"2026-08-08T00:00:00Z",
          "body":null,
          "assets":[]
        }
        """
        let manager = MacUpdateManager(
            defaults: defaults,
            currentVersion: { "1.0.0" },
            dataLoader: { request in
                requests += 1
                return Self.response(for: request, body: release)
            }
        )

        _ = await manager.check(.launch)
        let throttledResult = await manager.check(.launch)
        XCTAssertNil(throttledResult)
        _ = await manager.check(.manual)
        XCTAssertEqual(requests, 2)
    }

    func testReminderDeferralIsScopedToVersion() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let manager = MacUpdateManager(
            defaults: defaults,
            now: { currentDate },
            currentVersion: { "1.0.0" }
        )
        let first = makeUpdate(version: "2.0.0")
        let second = makeUpdate(version: "2.1.0")

        XCTAssertTrue(manager.shouldPresentReminder(for: first))
        manager.deferReminder(for: first)
        XCTAssertFalse(manager.shouldPresentReminder(for: first))
        XCTAssertTrue(manager.shouldPresentReminder(for: second))
        currentDate = currentDate.addingTimeInterval(24 * 60 * 60)
        XCTAssertTrue(manager.shouldPresentReminder(for: first))
    }

    func testPendingInstallAcknowledgementClearsTransaction() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging-test", isDirectory: true)
        let stagedApp = staging.appendingPathComponent("Wand.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pending = MacUpdateManager.PendingInstall(
            transactionID: "transaction-1",
            version: "2.0.0",
            stagedAppPath: stagedApp.path,
            releaseURL: URL(string: "https://example.test/release")!,
            preparedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: "wand.macUpdate.pendingInstall")
        let manager = MacUpdateManager(defaults: defaults, currentVersion: { "2.0.0" })
        let ack = staging.appendingPathComponent(".wand-update-ack")

        manager.completeLaunchedUpdateIfNeeded(arguments: [
            "Wand", "--wand-update-token", "transaction-1", "--wand-update-ack", ack.path,
        ])

        XCTAssertEqual(try String(contentsOf: ack, encoding: .utf8), "ok\n")
        XCTAssertNil(defaults.data(forKey: "wand.macUpdate.pendingInstall"))
    }

    func testHelperRestoresBackupWhenReplacementCannotLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wand update quote's \(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging-test", isDirectory: true)
        let stagedApp = staging.appendingPathComponent("Wand.app", isDirectory: true)
        let installedParent = root.appendingPathComponent("Installed", isDirectory: true)
        let destination = installedParent.appendingPathComponent("Wand.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(to: stagedApp.appendingPathComponent("new-marker"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("old-marker"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptPath = try UpdateInstaller.shared.makeHelperScriptForTesting(
            parentPID: Int32.max,
            stagedAppPath: stagedApp.path,
            destinationAppPath: destination.path,
            transactionID: "test-transaction",
            expectedVersion: "2.0.0",
            logPath: root.appendingPathComponent("helper.log").path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 14)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new-marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let result = try String(contentsOf: root.appendingPathComponent("last-result.txt"), encoding: .utf8)
        XCTAssertTrue(result.contains("已恢复旧版"))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "WandTests.suiteName")
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: "WandTests.suiteName") else { return }
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeUpdate(version: String) -> MacUpdateManager.Update {
        MacUpdateManager.Update(
            channel: .stable,
            currentVersion: "1.0.0",
            latestVersion: version,
            releaseURL: URL(string: "https://example.test/release")!,
            releaseNotes: nil,
            zipAsset: nil,
            dmgAsset: nil
        )
    }

    nonisolated private static func response(
        for request: URLRequest,
        body: String,
        status: Int = 200
    ) -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
