import AppKit
import Combine
import CryptoKit
import Foundation

/// GitHub Release 自更新器：下载 ZIP/DMG、校验其中的 Wand.app，并在当前进程退出后原位替换。
///
/// ZIP 是首选格式；已有 Release 只有 DMG 时也能直接解包更新。真正替换由临时 helper
/// 完成，因此不需要用户重新挂载 DMG 或把 app 拖进 Applications。
final class UpdateInstaller {

    enum Stage {
        case downloading(received: Int64, total: Int64)
        case verifying
        case extracting
        case readyToRelaunch(stagedAppPath: String)
        case failed(String)
    }

    typealias ProgressHandler = (Stage) -> Void

    static let shared = UpdateInstaller()

    static var installBlockReason: String? {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundleURL.pathExtension.lowercased() == "app" else {
            return "当前进程不是从 Wand.app 中运行，无法原位更新。"
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            return "当前 Wand.app 正在系统隔离目录中运行。请先把 Wand.app 移到 Applications 文件夹。"
        }
        if bundleURL.path.hasPrefix("/Volumes/") {
            return "当前 Wand.app 正从磁盘镜像或外置只读卷运行。请先把 Wand.app 移到 Applications 文件夹。"
        }

        let parentURL = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            return "当前 Wand.app 所在目录不可写（\(parentURL.path)）。请先把 Wand.app 移到 Applications 文件夹。"
        }
        return nil
    }

    static var canInstallInPlace: Bool { installBlockReason == nil }

    private let stateLock = NSLock()
    private var activeUpdateID: UUID?
    private var progressHandler: ProgressHandler?
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    private init() {}

    func startUpdate(
        _ update: MacUpdateManager.Update,
        progress: @escaping ProgressHandler
    ) {
        guard let asset = update.preferredAsset else {
            progress(.failed("Release 没有可用于自动更新的 ZIP 或 DMG。"))
            return
        }
        guard asset.downloadURL.scheme?.lowercased() == "https" else {
            progress(.failed("更新包不是安全的 HTTPS 下载地址。"))
            return
        }
        guard Self.canInstallInPlace else {
            progress(.failed(Self.installBlockReason ?? "当前 Wand.app 无法原位更新。"))
            return
        }

        let fileExtension = asset.name.lowercased().hasSuffix(".zip") ? "zip" : "dmg"
        let updateID = UUID()

        stateLock.lock()
        guard activeUpdateID == nil else {
            stateLock.unlock()
            progress(.failed("已有更新任务正在进行。"))
            return
        }
        activeUpdateID = updateID
        progressHandler = progress
        stateLock.unlock()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegate = UpdateDownloadDelegate(
            fileExtension: fileExtension,
            onProgress: { [weak self] received, reportedTotal in
                let total = reportedTotal > 0 ? reportedTotal : asset.size
                self?.emit(.downloading(received: received, total: total), for: updateID)
            },
            onFinish: { [weak self] result in
                self?.handleDownloadResult(
                    result,
                    updateID: updateID,
                    fileExtension: fileExtension,
                    expectedVersion: update.latestVersion,
                    expectedAsset: asset
                )
            }
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("Wand-macOS-UpdateInstaller", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)

        stateLock.lock()
        self.session = session
        downloadTask = task
        stateLock.unlock()
        task.resume()
    }

    func cancel() {
        stateLock.lock()
        let task = downloadTask
        let session = session
        activeUpdateID = nil
        progressHandler = nil
        downloadTask = nil
        self.session = nil
        stateLock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
    }

    /// 用户确认后启动 helper；调用方随后应终止当前 Wand 进程。
    func relaunch(pending: MacUpdateManager.PendingInstall) -> Result<Void, Error> {
        do {
            guard Self.canInstallInPlace else {
                throw installerError(code: 20, message: Self.installBlockReason ?? "当前 Wand.app 无法原位更新。")
            }

            let stagedURL = URL(fileURLWithPath: pending.stagedAppPath).standardizedFileURL
            try validateApp(at: stagedURL, expectedVersion: pending.version)

            let destinationPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            let scriptPath = try writeHelperScript(
                parentPID: ProcessInfo.processInfo.processIdentifier,
                stagedAppPath: stagedURL.path,
                destinationAppPath: destinationPath,
                transactionID: pending.transactionID,
                expectedVersion: pending.version
            )
            try launchHelper(scriptPath: scriptPath)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

#if DEBUG
    /// 只供集成测试执行 helper 的临时目录回滚路径；生产调用仍必须经过 relaunch 校验。
    func makeHelperScriptForTesting(
        parentPID: Int32,
        stagedAppPath: String,
        destinationAppPath: String,
        transactionID: String,
        expectedVersion: String,
        logPath: String
    ) throws -> String {
        try writeHelperScript(
            parentPID: parentPID,
            stagedAppPath: stagedAppPath,
            destinationAppPath: destinationAppPath,
            transactionID: transactionID,
            expectedVersion: expectedVersion,
            logPathOverride: logPath
        )
    }
#endif

    // MARK: - Download and extraction

    private func handleDownloadResult(
        _ result: Result<URL, Error>,
        updateID: UUID,
        fileExtension: String,
        expectedVersion: String,
        expectedAsset: MacUpdateManager.Update.Asset
    ) {
        guard isActive(updateID) else {
            if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }

        switch result {
        case let .failure(error):
            finish(.failed("下载失败：\(error.localizedDescription)"), for: updateID)
        case let .success(downloadedURL):
            emit(.verifying, for: updateID)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.extractAndValidate(
                    downloadedURL: downloadedURL,
                    fileExtension: fileExtension,
                    expectedVersion: expectedVersion,
                    expectedAsset: expectedAsset,
                    updateID: updateID
                )
            }
        }
    }

    private func extractAndValidate(
        downloadedURL: URL,
        fileExtension: String,
        expectedVersion: String,
        expectedAsset: MacUpdateManager.Update.Asset,
        updateID: UUID
    ) {
        var stagingDirectory: URL?
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        do {
            guard isActive(updateID) else { return }
            try validateDownloadedAsset(at: downloadedURL, expected: expectedAsset)
            emit(.extracting, for: updateID)
            let directory = try makeStagingDirectory()
            stagingDirectory = directory

            let appURL: URL
            if fileExtension == "zip" {
                appURL = try extractZip(downloadedURL, into: directory)
            } else {
                appURL = try extractDMG(downloadedURL, into: directory)
            }
            try validateApp(at: appURL, expectedVersion: expectedVersion)

            guard isActive(updateID) else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            finish(.readyToRelaunch(stagedAppPath: appURL.path), for: updateID)
        } catch {
            if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
            finish(.failed("准备更新失败：\(error.localizedDescription)"), for: updateID)
        }
    }

    private func makeStagingDirectory() throws -> URL {
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = cacheDirectory
            .appendingPathComponent("Wand/Updates", isDirectory: true)
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func extractZip(_ zipURL: URL, into directory: URL) throws -> URL {
        try runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-xk", zipURL.path, directory.path],
            failureMessage: "无法解压 ZIP"
        )
        return try findWandApp(in: directory)
    }

    private func extractDMG(_ dmgURL: URL, into directory: URL) throws -> URL {
        let mountPoint = directory.appendingPathComponent("mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: [
                "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", mountPoint.path, dmgURL.path,
            ],
            failureMessage: "无法挂载 DMG"
        )
        defer {
            try? runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-quiet", "-force"],
                failureMessage: "无法卸载 DMG"
            )
        }

        let mountedAppURL = try findWandApp(in: mountPoint)
        let stagedAppURL = directory.appendingPathComponent("Wand.app", isDirectory: true)
        try runProcess(
            executable: "/usr/bin/ditto",
            arguments: [mountedAppURL.path, stagedAppURL.path],
            failureMessage: "无法从 DMG 复制 Wand.app"
        )
        return stagedAppURL
    }

    private func findWandApp(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let firstLevel = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        func isAppDirectory(_ url: URL) -> Bool {
            guard url.pathExtension.lowercased() == "app",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }

        var candidates = firstLevel.filter(isAppDirectory)
        for child in firstLevel where child.pathExtension.lowercased() != "app" {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let nested = (try? fileManager.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            candidates.append(contentsOf: nested.filter(isAppDirectory))
        }

        let expectedBundleID = Bundle.main.bundleIdentifier ?? "com.wand.app"
        if let match = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == expectedBundleID }) {
            return match
        }
        throw installerError(code: 4, message: "更新包中未找到 bundle id 为 \(expectedBundleID) 的 Wand.app。")
    }

    private func validateApp(at appURL: URL, expectedVersion: String?) throws {
        guard appURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: appURL) else {
            throw installerError(code: 5, message: "更新包中的应用结构无效。")
        }

        let expectedBundleID = Bundle.main.bundleIdentifier ?? "com.wand.app"
        guard bundle.bundleIdentifier == expectedBundleID else {
            throw installerError(code: 6, message: "更新包 bundle id 不匹配。")
        }
        if let expectedVersion {
            let actualVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard actualVersion == expectedVersion else {
                throw installerError(
                    code: 7,
                    message: "更新包版本为 \(actualVersion ?? "未知")，与 GitHub Release 的 \(expectedVersion) 不一致。"
                )
            }
        }
        guard let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw installerError(code: 8, message: "更新包缺少可执行的 Wand 主程序。")
        }

        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--deep", appURL.path],
            failureMessage: "更新包代码签名校验失败"
        )
    }

    private func validateDownloadedAsset(
        at fileURL: URL,
        expected asset: MacUpdateManager.Update.Asset
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard asset.size <= 0 || actualSize == asset.size else {
            throw installerError(
                code: 9,
                message: "更新包大小为 \(actualSize) 字节，与 Release 的 \(asset.size) 字节不一致。"
            )
        }
        guard let expectedHash = asset.sha256 else { return }

        let actualHash = try sha256(of: fileURL)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw installerError(code: 10, message: "更新包 SHA-256 校验失败，文件可能不完整或已被替换。")
        }
    }

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(executable: String, arguments: [String], failureMessage: String) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.map { "：\($0)" } ?? "（退出码 \(process.terminationStatus)）"
            throw installerError(code: Int(process.terminationStatus), message: failureMessage + suffix)
        }
    }

    // MARK: - Replacement helper

    private func writeHelperScript(
        parentPID: Int32,
        stagedAppPath: String,
        destinationAppPath: String,
        transactionID: String,
        expectedVersion: String,
        logPathOverride: String? = nil
    ) throws -> String {
        let identifier = UUID().uuidString
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wand-update-\(identifier).sh")
        let backupPath = destinationAppPath + ".wand-update-backup-" + identifier
        let stagingDirectory = (stagedAppPath as NSString).deletingLastPathComponent
        let acknowledgementPath = (stagingDirectory as NSString).appendingPathComponent(".wand-update-ack")
        let resultPath = ((stagingDirectory as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("last-result.txt")

        let logPath: String
        if let logPathOverride {
            logPath = logPathOverride
        } else {
            let logsDirectory = try FileManager.default.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Logs/Wand", isDirectory: true)
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            logPath = logsDirectory.appendingPathComponent("update.log").path
        }

        let script = """
        #!/bin/bash
        set -u
        STAGED=\(shellQuote(stagedAppPath))
        STAGED_DIR=\(shellQuote(stagingDirectory))
        DEST=\(shellQuote(destinationAppPath))
        BACKUP=\(shellQuote(backupPath))
        ACK=\(shellQuote(acknowledgementPath))
        RESULT=\(shellQuote(resultPath))
        TRANSACTION_ID=\(shellQuote(transactionID))
        VERSION=\(shellQuote(expectedVersion))
        LOG=\(shellQuote(logPath))
        PARENT_PID=\(parentPID)

        exec >>"$LOG" 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') starting Wand update to $VERSION"
        /bin/rm -f "$ACK" "$RESULT"

        cleanup() {
            /bin/rm -rf "$STAGED_DIR"
            /bin/rm -f "$0"
        }

        mark_failure() {
            /usr/bin/printf '%s\n' "$1" > "$RESULT"
        }

        rollback() {
            echo "update failed; restoring previous app"
            /bin/rm -rf "$DEST"
            if [ -d "$BACKUP" ]; then
                /bin/mv "$BACKUP" "$DEST"
            fi
        }

        for _ in $(/usr/bin/seq 1 150); do
            if ! /bin/kill -0 "$PARENT_PID" 2>/dev/null; then break; fi
            /bin/sleep 0.2
        done
        if /bin/kill -0 "$PARENT_PID" 2>/dev/null; then
            echo "Wand did not exit within 30 seconds; aborting"
            mark_failure "上次更新未完成：旧版 Wand 未在 30 秒内退出。"
            cleanup
            exit 10
        fi
        if [ ! -d "$STAGED" ]; then
            echo "staged app is missing"
            mark_failure "上次更新未完成：待安装的 Wand.app 已丢失。"
            cleanup
            exit 11
        fi

        if [ -d "$DEST" ]; then
            /bin/mv "$DEST" "$BACKUP" || {
                mark_failure "上次更新未完成：无法备份旧版 Wand.app。"
                cleanup
                exit 12
            }
        fi
        if ! /usr/bin/ditto "$STAGED" "$DEST"; then
            rollback
            mark_failure "上次更新失败，已恢复旧版 Wand.app。"
            cleanup
            exit 13
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        if ! /usr/bin/open "$DEST" --args --wand-update-token "$TRANSACTION_ID" --wand-update-ack "$ACK"; then
            rollback
            mark_failure "新版 Wand 无法启动，已恢复旧版。"
            /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            cleanup
            exit 14
        fi

        for _ in $(/usr/bin/seq 1 150); do
            if [ -f "$ACK" ]; then break; fi
            /bin/sleep 0.2
        done
        if [ ! -f "$ACK" ]; then
            echo "new Wand did not acknowledge launch; rolling back"
            /usr/bin/pkill -TERM -x Wand 2>/dev/null || true
            /bin/sleep 1
            /usr/bin/pkill -KILL -x Wand 2>/dev/null || true
            rollback
            mark_failure "新版 Wand 未能完成启动，已自动恢复旧版。"
            /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            cleanup
            exit 15
        fi

        /bin/rm -rf "$BACKUP"
        echo "Wand update completed"
        cleanup
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func launchHelper(scriptPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: - State

    private func isActive(_ updateID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeUpdateID == updateID
    }

    private func emit(_ stage: Stage, for updateID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let handler = self.activeUpdateID == updateID ? self.progressHandler : nil
            self.stateLock.unlock()
            handler?(stage)
        }
    }

    private func finish(_ stage: Stage, for updateID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.activeUpdateID == updateID else {
                self.stateLock.unlock()
                return
            }
            let handler = self.progressHandler
            let session = self.session
            self.activeUpdateID = nil
            self.progressHandler = nil
            self.downloadTask = nil
            self.session = nil
            self.stateLock.unlock()

            session?.finishTasksAndInvalidate()
            handler?(stage)
        }
    }

    private func installerError(code: Int, message: String) -> NSError {
        NSError(
            domain: "Wand.UpdateInstaller",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// 统一承接启动提醒和设置页发起的更新，避免两个入口各自维护下载与重启状态。
@MainActor
final class UpdateFlowController {

    static let shared = UpdateFlowController()

    private let manager = MacUpdateManager.shared
    private var progressWindow: UpdateProgressWindow?
    private var stateObservation: AnyCancellable?
    private var isPresentingInstall = false
    private var presentedReminderVersion: String?

    private init() {
        stateObservation = manager.$state.sink { [weak self] state in
            self?.handle(state)
        }
    }

    func presentLaunchReminder(for update: MacUpdateManager.Update) {
        guard manager.shouldPresentReminder(for: update),
              presentedReminderVersion != update.latestVersion else { return }
        presentedReminderVersion = update.latestVersion
        presentUpdateAlert(update, automatic: true)
    }

    func checkManually() async {
        guard let result = await manager.check(.manual) else {
            if manager.pendingInstall != nil { relaunchPending() }
            return
        }
        switch result {
        case let .upToDate(currentVersion):
            let alert = NSAlert()
            alert.messageText = "Wand 已是最新版本"
            alert.informativeText = "当前版本 v\(currentVersion) · \(manager.channel.title) 通道"
            alert.addButton(withTitle: "好的")
            present(alert)
        case let .updateAvailable(update):
            presentUpdateAlert(update, automatic: false)
        case let .failed(message):
            showFailure(message, releaseURL: nil, title: "检查更新失败")
        }
    }

    func start() {
        if let progressWindow {
            progressWindow.showCentered()
            return
        }
        if manager.pendingInstall != nil {
            relaunchPending()
            return
        }
        guard let update = manager.availableUpdate else {
            showFailure("当前没有可安装的新版本。", releaseURL: nil)
            return
        }
        guard update.preferredAsset != nil else {
            showFailure("该 Release 没有可用于自动更新的 ZIP 或 DMG。", releaseURL: update.releaseURL)
            return
        }
        if let reason = UpdateInstaller.installBlockReason {
            showFailure(reason, releaseURL: update.releaseURL)
            return
        }

        let window = UpdateProgressWindow()
        window.onCancel = { [weak self] in
            self?.manager.cancelInstall()
            self?.progressWindow = nil
            self?.isPresentingInstall = false
        }
        progressWindow = window
        isPresentingInstall = true
        window.showCentered()
        if let reason = manager.installAvailableUpdate() {
            progressWindow?.close()
            progressWindow = nil
            isPresentingInstall = false
            showFailure(reason, releaseURL: update.releaseURL)
        }
    }

    func relaunchPending() {
        guard let pending = manager.pendingInstall else { return }
        confirmRelaunch(pending: pending)
    }

    private func handle(_ state: MacUpdateManager.State) {
        guard isPresentingInstall else { return }
        switch state {
        case let .downloading(_, received, total):
            progressWindow?.setDownloading(received: received, total: total)
        case .preparing:
            progressWindow?.setExtracting()
        case let .readyToRelaunch(pending):
            progressWindow?.close()
            progressWindow = nil
            isPresentingInstall = false
            confirmRelaunch(pending: pending)
        case let .failed(message, update):
            progressWindow?.close()
            progressWindow = nil
            isPresentingInstall = false
            showFailure(message, releaseURL: update?.releaseURL)
        case .available:
            // 下载被用户取消时 manager 回到 available。
            progressWindow?.close()
            progressWindow = nil
            isPresentingInstall = false
        default:
            break
        }
    }

    private func presentUpdateAlert(_ update: MacUpdateManager.Update, automatic: Bool) {
        let alert = NSAlert()
        alert.messageText = "发现 Wand 新版本 v\(update.latestVersion)"
        alert.alertStyle = .informational

        let canAutoUpdate = update.preferredAsset != nil && UpdateInstaller.canInstallInPlace
        if let asset = update.preferredAsset, canAutoUpdate {
            let size = ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)
            let integrity = asset.sha256 == nil ? "旧版 Release 将使用应用签名校验。" : "下载完成后会校验 SHA-256 与应用签名。"
            alert.informativeText = "当前版本 v\(update.currentVersion) · \(update.channel.title) 通道。\n\n更新包：\(asset.fileExtension.uppercased()) · \(size)\n\(integrity)"
            alert.addButton(withTitle: "立即更新")
            alert.addButton(withTitle: "查看 Release")
            alert.addButton(withTitle: "稍后提醒")
        } else {
            let reason = update.preferredAsset == nil
                ? "该 GitHub Release 未包含匹配版本的 macOS ZIP 或 DMG。"
                : (UpdateInstaller.installBlockReason ?? "当前 Wand.app 无法原位更新。")
            alert.informativeText = "当前版本 v\(update.currentVersion)。\n\n\(reason)请在 Release 页面手动下载。"
            alert.addButton(withTitle: "查看 Release")
            alert.addButton(withTitle: "稍后提醒")
        }

        let response = present(alert)
        if canAutoUpdate {
            switch response {
            case .alertFirstButtonReturn:
                start()
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(update.releaseURL)
            default:
                if automatic { manager.deferReminder(for: update) }
            }
        } else if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.releaseURL)
        } else if automatic {
            manager.deferReminder(for: update)
        }
    }

    private func confirmRelaunch(pending: MacUpdateManager.PendingInstall) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "新版本已准备完成"
        alert.informativeText = "v\(pending.version) 已完成校验。重启 Wand 后会替换当前应用；如果新版未能完成启动，将自动恢复旧版。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启更新")
        alert.addButton(withTitle: "稍后")

        guard present(alert) == .alertFirstButtonReturn else {
            let info = NSAlert()
            info.messageText = "更新包已保留"
            info.informativeText = "稍后可在设置的“关于”页面点击“重启完成更新”。待安装包会保留 7 天。"
            info.addButton(withTitle: "好的")
            present(info)
            return
        }

        switch manager.relaunchPendingUpdate() {
        case .success:
            NSApp.terminate(nil)
        case let .failure(error):
            showFailure(
                "启动替换程序失败：\(error.localizedDescription)\n\n更新包仍保留在：\(pending.stagedAppPath)",
                releaseURL: pending.releaseURL
            )
        }
    }

    private func showFailure(_ message: String, releaseURL: URL?, title: String = "自动更新失败") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if releaseURL != nil { alert.addButton(withTitle: "查看 Release") }
        alert.addButton(withTitle: "关闭")
        if present(alert) == .alertFirstButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        // 更新提醒统一使用 application-modal，避免设置 sheet 关闭或切换服务器时
        // 把 alert 一并销毁，导致更新任务失去呈现上下文。
        return alert.runModal()
    }
}

private final class UpdateProgressWindow: NSWindowController {

    private let titleLabel = NSTextField(labelWithString: "正在准备下载…")
    private let detailLabel = NSTextField(labelWithString: "正在连接 GitHub Release")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    var onCancel: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Wand 更新"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        buildLayout()
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 350).isActive = true

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(progressIndicator)
        stack.addArrangedSubview(detailLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(buttonRow)
    }

    func showCentered() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setDownloading(received: Int64, total: Int64) {
        titleLabel.stringValue = "正在下载新版本…"
        if total > 0 {
            let ratio = max(0, min(1, Double(received) / Double(total)))
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = ratio
            detailLabel.stringValue = "\(formatBytes(received)) / \(formatBytes(total))（\(Int(ratio * 100))%）"
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            detailLabel.stringValue = "已下载 \(formatBytes(received))"
        }
    }

    func setExtracting() {
        titleLabel.stringValue = "正在校验并准备 Wand.app…"
        detailLabel.stringValue = "完成后即可重启更新"
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        cancelButton.isEnabled = false
    }

    @objc private func cancelTapped() {
        onCancel?()
        close()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let fileExtension: String
    private let onProgress: (Int64, Int64) -> Void
    private let onFinish: (Result<URL, Error>) -> Void
    private var didFinish = false

    init(
        fileExtension: String,
        onProgress: @escaping (Int64, Int64) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.fileExtension = fileExtension
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wand-update-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            didFinish = true
            onFinish(.success(destination))
        } catch {
            didFinish = true
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !didFinish {
            onFinish(.failure(error))
        }
    }
}
