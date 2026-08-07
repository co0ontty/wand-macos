import AppKit
import Foundation

/// GitHub Release 自更新器：下载 ZIP/DMG、校验其中的 Wand.app，并在当前进程退出后原位替换。
///
/// ZIP 是首选格式；已有 Release 只有 DMG 时也能直接解包更新。真正替换由临时 helper
/// 完成，因此不需要用户重新挂载 DMG 或把 app 拖进 Applications。
final class UpdateInstaller {

    enum Stage {
        case downloading(received: Int64, total: Int64)
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
        _ update: GitHubReleaseUpdater.Update,
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
                    expectedVersion: update.latestVersion
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
    func relaunch(stagedAppPath: String) -> Result<Void, Error> {
        do {
            guard Self.canInstallInPlace else {
                throw installerError(code: 20, message: Self.installBlockReason ?? "当前 Wand.app 无法原位更新。")
            }

            let stagedURL = URL(fileURLWithPath: stagedAppPath).standardizedFileURL
            try validateApp(at: stagedURL, expectedVersion: nil)

            let destinationPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            let scriptPath = try writeHelperScript(
                parentPID: ProcessInfo.processInfo.processIdentifier,
                stagedAppPath: stagedURL.path,
                destinationAppPath: destinationPath
            )
            try launchHelper(scriptPath: scriptPath)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Download and extraction

    private func handleDownloadResult(
        _ result: Result<URL, Error>,
        updateID: UUID,
        fileExtension: String,
        expectedVersion: String
    ) {
        guard isActive(updateID) else {
            if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
            return
        }

        switch result {
        case let .failure(error):
            finish(.failed("下载失败：\(error.localizedDescription)"), for: updateID)
        case let .success(downloadedURL):
            emit(.extracting, for: updateID)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.extractAndValidate(
                    downloadedURL: downloadedURL,
                    fileExtension: fileExtension,
                    expectedVersion: expectedVersion,
                    updateID: updateID
                )
            }
        }
    }

    private func extractAndValidate(
        downloadedURL: URL,
        fileExtension: String,
        expectedVersion: String,
        updateID: UUID
    ) {
        var stagingDirectory: URL?
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        do {
            guard isActive(updateID) else { return }
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
        destinationAppPath: String
    ) throws -> String {
        let identifier = UUID().uuidString
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wand-update-\(identifier).sh")
        let backupPath = destinationAppPath + ".wand-update-backup-" + identifier

        let logsDirectory = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Logs/Wand", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logPath = logsDirectory.appendingPathComponent("update.log").path

        let script = """
        #!/bin/bash
        set -u
        STAGED=\(shellQuote(stagedAppPath))
        STAGED_DIR=\(shellQuote((stagedAppPath as NSString).deletingLastPathComponent))
        DEST=\(shellQuote(destinationAppPath))
        BACKUP=\(shellQuote(backupPath))
        LOG=\(shellQuote(logPath))
        PARENT_PID=\(parentPID)

        exec >>"$LOG" 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S') starting Wand update"

        cleanup() {
            /bin/rm -rf "$STAGED_DIR"
            /bin/rm -f "$0"
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
            cleanup
            exit 10
        fi
        if [ ! -d "$STAGED" ]; then
            echo "staged app is missing"
            cleanup
            exit 11
        fi

        if [ -d "$DEST" ]; then
            /bin/mv "$DEST" "$BACKUP" || { cleanup; exit 12; }
        fi
        if ! /usr/bin/ditto "$STAGED" "$DEST"; then
            rollback
            cleanup
            exit 13
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        if ! /usr/bin/open "$DEST"; then
            rollback
            cleanup
            exit 14
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

    private var progressWindow: UpdateProgressWindow?
    private var releaseURL: URL?

    private init() {}

    func start(update: GitHubReleaseUpdater.Update) {
        if let progressWindow {
            progressWindow.showCentered()
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

        releaseURL = update.releaseURL
        let window = UpdateProgressWindow()
        window.onCancel = { [weak self] in
            UpdateInstaller.shared.cancel()
            self?.progressWindow = nil
            self?.releaseURL = nil
        }
        progressWindow = window
        window.showCentered()

        UpdateInstaller.shared.startUpdate(update) { [weak self] stage in
            self?.handle(stage)
        }
    }

    private func handle(_ stage: UpdateInstaller.Stage) {
        switch stage {
        case let .downloading(received, total):
            progressWindow?.setDownloading(received: received, total: total)
        case .extracting:
            progressWindow?.setExtracting()
        case let .readyToRelaunch(stagedAppPath):
            progressWindow?.close()
            progressWindow = nil
            confirmRelaunch(stagedAppPath: stagedAppPath)
        case let .failed(message):
            let releaseURL = self.releaseURL
            progressWindow?.close()
            progressWindow = nil
            self.releaseURL = nil
            showFailure(message, releaseURL: releaseURL)
        }
    }

    private func confirmRelaunch(stagedAppPath: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "新版本已准备完成"
        alert.informativeText = "重启 Wand 即可完成更新，不需要重新安装应用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启更新")
        alert.addButton(withTitle: "稍后")

        guard alert.runModal() == .alertFirstButtonReturn else {
            let info = NSAlert()
            info.messageText = "更新包已保留"
            info.informativeText = "稍后可从这里打开新版 Wand.app：\n\(stagedAppPath)"
            info.addButton(withTitle: "好的")
            info.runModal()
            releaseURL = nil
            return
        }

        switch UpdateInstaller.shared.relaunch(stagedAppPath: stagedAppPath) {
        case .success:
            NSApp.terminate(nil)
        case let .failure(error):
            let releaseURL = self.releaseURL
            self.releaseURL = nil
            showFailure("启动替换程序失败：\(error.localizedDescription)\n\n更新包位于：\(stagedAppPath)", releaseURL: releaseURL)
        }
    }

    private func showFailure(_ message: String, releaseURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "自动更新失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        if releaseURL != nil { alert.addButton(withTitle: "查看 Release") }
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
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
