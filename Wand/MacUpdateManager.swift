import Combine
import Foundation

/// Wand macOS 更新的唯一状态源。
///
/// 调用方只负责触发检查、安装、取消或重启；GitHub 通道策略、缓存、防抖、
/// 延后提醒和待重启事务都封装在这个 module 内。
@MainActor
final class MacUpdateManager: ObservableObject {

    enum Channel: String, Codable, CaseIterable, Identifiable {
        case stable
        case beta

        var id: String { rawValue }
        var title: String { self == .stable ? "Stable" : "Beta" }
    }

    enum CheckTrigger {
        case launch
        case manual
        case channelChanged
    }

    struct Update: Codable, Equatable {
        struct Asset: Codable, Equatable {
            let name: String
            let downloadURL: URL
            let size: Int64
            let sha256: String?

            var fileExtension: String {
                name.lowercased().hasSuffix(".zip") ? "zip" : "dmg"
            }
        }

        let channel: Channel
        let currentVersion: String
        let latestVersion: String
        let releaseURL: URL
        let releaseNotes: String?
        let zipAsset: Asset?
        let dmgAsset: Asset?

        /// ZIP 不需要挂载磁盘镜像，自动更新优先使用；旧 Release 可回退到 DMG。
        var preferredAsset: Asset? { zipAsset ?? dmgAsset }
    }

    struct PendingInstall: Codable, Equatable {
        let transactionID: String
        let version: String
        let stagedAppPath: String
        let releaseURL: URL
        let preparedAt: Date
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String, checkedAt: Date)
        case available(Update)
        case downloading(update: Update, received: Int64, total: Int64)
        case preparing(Update)
        case readyToRelaunch(PendingInstall)
        case failed(message: String, update: Update?)
    }

    enum CheckResult: Equatable {
        case upToDate(currentVersion: String)
        case updateAvailable(Update)
        case failed(message: String)
    }

    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    static let shared = MacUpdateManager()

    @Published private(set) var state: State = .idle
    @Published private(set) var channel: Channel
    @Published private(set) var lastSuccessfulCheck: Date?

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var availableUpdate: Update? {
        switch state {
        case let .available(update),
             let .downloading(update, _, _),
             let .preparing(update),
             let .failed(_, .some(update)):
            return update
        default:
            return nil
        }
    }

    var pendingInstall: PendingInstall? {
        if case let .readyToRelaunch(pending) = state { return pending }
        return nil
    }

    var lastError: String? {
        if case let .failed(message, _) = state { return message }
        return nil
    }

    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private static let repository = "co0ontty/wand"
    private static let launchCheckInterval: TimeInterval = 24 * 60 * 60
    private static let reminderDelay: TimeInterval = 24 * 60 * 60
    private static let pendingInstallLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let channelKey = "wand.macUpdate.channel"
    private static let pendingInstallKey = "wand.macUpdate.pendingInstall"
    private static let legacyLastCheckKey = "wand.githubRelease.lastCheckAt"
    private static let legacyCachedUpdateKey = "wand.githubRelease.cachedUpdate"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentVersionProvider: () -> String
    private let dataLoader: DataLoader
    private let fileManager: FileManager
    private var activeCheck: Task<CheckResult, Never>?
    private var activeCheckID: UUID?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        currentVersion: @escaping () -> String = { MacUpdateManager.currentVersion },
        fileManager: FileManager = .default,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.currentVersionProvider = currentVersion
        self.fileManager = fileManager
        self.dataLoader = dataLoader
        self.channel = Channel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? .stable

        migrateLegacyKeysIfNeeded()
        restorePersistedState()
    }

    /// 启动检查受 24 小时防抖；手动检查与通道切换始终请求 GitHub。
    @discardableResult
    func check(_ trigger: CheckTrigger) async -> CheckResult? {
        // 已准备好的更新优先级最高；不要用一次网络检查覆盖可恢复的安装事务。
        if pendingInstall != nil { return nil }
        if trigger == .launch,
           let lastSuccessfulCheck,
           now().timeIntervalSince(lastSuccessfulCheck) < Self.launchCheckInterval {
            return nil
        }

        if let activeCheck {
            return await activeCheck.value
        }

        let checkedChannel = channel
        let previousUpdate = availableUpdate
        state = .checking
        let checkID = UUID()
        let task = Task { [weak self] () -> CheckResult in
            guard let self else { return .failed(message: "更新检查器已释放。") }
            return await self.fetchLatestRelease(channel: checkedChannel)
        }
        activeCheck = task
        activeCheckID = checkID
        let result = await task.value
        if activeCheckID == checkID {
            activeCheck = nil
            activeCheckID = nil
        }

        // 通道切换会取消旧任务；旧响应不得覆盖新通道状态。
        guard checkedChannel == channel else { return result }
        persist(result, channel: checkedChannel, previousUpdate: previousUpdate)
        return result
    }

    @discardableResult
    func setChannel(_ newChannel: Channel) async -> CheckResult? {
        guard newChannel != channel else { return await check(.manual) }

        activeCheck?.cancel()
        activeCheck = nil
        activeCheckID = nil
        channel = newChannel
        defaults.set(newChannel.rawValue, forKey: Self.channelKey)
        clearReminderDeferral()
        restoreAvailability(for: newChannel)
        return await check(.channelChanged)
    }

    /// 返回 nil 表示安装任务已启动；否则返回可直接展示给用户的原因。
    @discardableResult
    func installAvailableUpdate() -> String? {
        if pendingInstall != nil { return nil }
        guard let update = availableUpdate else { return "当前没有可安装的新版本。" }
        guard update.preferredAsset != nil else { return "该 Release 没有可用于自动更新的 ZIP 或 DMG。" }
        if let reason = UpdateInstaller.installBlockReason { return reason }

        state = .downloading(update: update, received: 0, total: update.preferredAsset?.size ?? 0)
        UpdateInstaller.shared.startUpdate(update) { [weak self] stage in
            self?.handleInstallerStage(stage, update: update)
        }
        return nil
    }

    func cancelInstall() {
        guard let update = availableUpdate else { return }
        UpdateInstaller.shared.cancel()
        state = .available(update)
    }

    func relaunchPendingUpdate() -> Result<Void, Error> {
        guard let pendingInstall else {
            return .failure(managerError(code: 40, message: "没有已准备好的更新。"))
        }
        return UpdateInstaller.shared.relaunch(pending: pendingInstall)
    }

    func shouldPresentReminder(for update: Update) -> Bool {
        let deferredVersion = defaults.string(forKey: reminderVersionKey(channel))
        let deferredUntil = defaults.double(forKey: reminderUntilKey(channel))
        return deferredVersion != update.latestVersion || now().timeIntervalSince1970 >= deferredUntil
    }

    func deferReminder(for update: Update) {
        defaults.set(update.latestVersion, forKey: reminderVersionKey(channel))
        defaults.set(now().addingTimeInterval(Self.reminderDelay).timeIntervalSince1970, forKey: reminderUntilKey(channel))
    }

    /// 新版 App 由 helper 以一次性 token 启动。写入确认文件后，helper 才删除旧版备份。
    func completeLaunchedUpdateIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard let token = argument(after: "--wand-update-token", in: arguments),
              let ackPath = argument(after: "--wand-update-ack", in: arguments),
              let pending = loadPendingInstall(),
              pending.transactionID == token,
              pending.version == currentVersionProvider(),
              isSafeAcknowledgementPath(ackPath, pending: pending) else {
            return
        }

        do {
            try Data("ok\n".utf8).write(to: URL(fileURLWithPath: ackPath), options: .atomic)
            clearPendingInstall()
            restoreAvailability(for: channel)
        } catch {
            state = .failed(message: "无法确认新版启动：\(error.localizedDescription)", update: nil)
        }
    }

    // MARK: - Installer state

    private func handleInstallerStage(_ stage: UpdateInstaller.Stage, update: Update) {
        switch stage {
        case let .downloading(received, total):
            state = .downloading(update: update, received: received, total: total)
        case .verifying, .extracting:
            state = .preparing(update)
        case let .readyToRelaunch(stagedAppPath):
            let pending = PendingInstall(
                transactionID: UUID().uuidString,
                version: update.latestVersion,
                stagedAppPath: stagedAppPath,
                releaseURL: update.releaseURL,
                preparedAt: now()
            )
            do {
                try persistPendingInstall(pending)
                state = .readyToRelaunch(pending)
            } catch {
                discardStagingDirectory(for: stagedAppPath)
                state = .failed(message: "无法保存待安装更新：\(error.localizedDescription)", update: update)
            }
        case let .failed(message):
            state = .failed(message: message, update: update)
        }
    }

    // MARK: - GitHub release source

    private func fetchLatestRelease(channel: Channel) async -> CheckResult {
        do {
            let releases: [GitHubRelease]
            switch channel {
            case .stable:
                let url = try githubURL(path: "/releases/latest")
                let data = try await loadGitHubData(from: url)
                releases = [try JSONDecoder().decode(GitHubRelease.self, from: data)]
            case .beta:
                let url = try githubURL(path: "/releases?per_page=20")
                let data = try await loadGitHubData(from: url)
                releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            }

            guard let release = Self.selectRelease(releases, channel: channel) else {
                return .failed(message: channel == .stable
                    ? "GitHub 尚未发布稳定版 Release。"
                    : "GitHub 尚未发布可用的 Stable 或 Beta Release。")
            }
            guard let latestVersion = Self.version(fromTag: release.tagName) else {
                return .failed(message: "GitHub Release 的版本标签无效：\(release.tagName)")
            }

            let currentVersion = currentVersionProvider()
            guard Self.compareInstallOrder(latestVersion, currentVersion) > 0 else {
                return .upToDate(currentVersion: currentVersion)
            }

            var zip = Self.preferredAsset(in: release.assets, version: latestVersion, fileExtension: "zip")
            var dmg = Self.preferredAsset(in: release.assets, version: latestVersion, fileExtension: "dmg")
            if let manifestAsset = Self.manifestAsset(in: release.assets, version: latestVersion) {
                let manifestData = try await loadGitHubData(from: manifestAsset.browserDownloadURL)
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
                guard manifest.version == latestVersion else {
                    throw managerError(code: 12, message: "更新清单版本与 Release 标签不一致。")
                }
                zip = try Self.apply(manifest: manifest, to: zip)
                dmg = try Self.apply(manifest: manifest, to: dmg)
            }

            return .updateAvailable(Update(
                channel: channel,
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: release.htmlURL,
                releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                zipAsset: zip,
                dmgAsset: dmg
            ))
        } catch is CancellationError {
            return .failed(message: "更新检查已取消。")
        } catch is DecodingError {
            return .failed(message: "无法解析 GitHub Release 或更新清单。")
        } catch {
            return .failed(message: "检查 GitHub Release 失败：\(error.localizedDescription)")
        }
    }

    private func githubURL(path: String) throws -> URL {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)\(path)") else {
            throw managerError(code: 10, message: "无法构造 GitHub Release 地址。")
        }
        return url
    }

    private func loadGitHubData(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw managerError(code: 11, message: "GitHub 返回了非 HTTPS 地址。")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wand-macOS-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse else {
            throw managerError(code: 13, message: "GitHub 返回了无效响应。")
        }
        guard http.statusCode == 200 else {
            throw managerError(code: http.statusCode, message: "GitHub 返回 HTTP \(http.statusCode)。")
        }
        return data
    }

    // MARK: - Version and asset policy

    static func compareInstallOrder(_ candidate: String, _ baseline: String) -> Int {
        guard let lhs = ParsedVersion(candidate), let rhs = ParsedVersion(baseline) else { return 0 }

        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return 0
        case let (.some(pre), nil):
            return Self.isPostReleaseBeta(pre) ? 1 : -1
        case let (nil, .some(pre)):
            return Self.isPostReleaseBeta(pre) ? -1 : 1
        case let (.some(left), .some(right)):
            return comparePrerelease(left, right)
        }
    }

    static func isVersionNewer(_ candidate: String, than baseline: String) -> Bool {
        compareInstallOrder(candidate, baseline) > 0
    }

    static func selectRelease(_ releases: [GitHubRelease], channel: Channel) -> GitHubRelease? {
        releases
            .filter { !$0.draft && (channel == .beta || !$0.prerelease) && version(fromTag: $0.tagName) != nil }
            .max { left, right in
                guard let lhs = version(fromTag: left.tagName), let rhs = version(fromTag: right.tagName) else {
                    return left.publishedAt < right.publishedAt
                }
                let order = compareInstallOrder(lhs, rhs)
                return order == 0 ? left.publishedAt < right.publishedAt : order < 0
            }
    }

    static func preferredAsset(
        in assets: [GitHubRelease.Asset],
        version: String,
        fileExtension: String
    ) -> Update.Asset? {
        let escapedVersion = NSRegularExpression.escapedPattern(for: version)
        let pattern = "^wand-v\(escapedVersion)(?:\\+[A-Za-z0-9.-]+)?\\.\(fileExtension)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }

        return assets
            .filter { asset in
                let range = NSRange(asset.name.startIndex..<asset.name.endIndex, in: asset.name)
                return regex.firstMatch(in: asset.name, range: range) != nil
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            .first
            .map { Update.Asset(name: $0.name, downloadURL: $0.browserDownloadURL, size: $0.size, sha256: nil) }
    }

    private static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return ParsedVersion(version) == nil ? nil : version
    }

    private static func isPostReleaseBeta(_ identifiers: [String]) -> Bool {
        guard let first = identifiers.first?.lowercased() else { return false }
        return first == "beta" || first == "debug"
    }

    private static func comparePrerelease(_ candidate: [String], _ baseline: [String]) -> Int {
        for index in 0..<max(candidate.count, baseline.count) {
            guard index < candidate.count else { return -1 }
            guard index < baseline.count else { return 1 }
            let lhs = candidate[index]
            let rhs = baseline[index]
            guard lhs != rhs else { continue }
            switch (Int(lhs), Int(rhs)) {
            case let (.some(left), .some(right)):
                return left < right ? -1 : 1
            case (.some, nil):
                return -1
            case (nil, .some):
                return 1
            case (nil, nil):
                return lhs.compare(rhs, options: .literal) == .orderedAscending ? -1 : 1
            }
        }
        return 0
    }

    private static func manifestAsset(in assets: [GitHubRelease.Asset], version: String) -> GitHubRelease.Asset? {
        let expected = "wand-v\(version).update.json"
        return assets.first { $0.name.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private static func apply(manifest: UpdateManifest, to asset: Update.Asset?) throws -> Update.Asset? {
        guard let asset else { return nil }
        guard let entry = manifest.assets.first(where: { $0.fileName == asset.name }) else {
            throw NSError(
                domain: "Wand.MacUpdateManager",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "更新清单缺少产物 \(asset.name)。"]
            )
        }
        guard entry.size == asset.size,
              entry.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw NSError(
                domain: "Wand.MacUpdateManager",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "更新清单中的大小或 SHA-256 无效。"]
            )
        }
        return Update.Asset(
            name: asset.name,
            downloadURL: asset.downloadURL,
            size: asset.size,
            sha256: entry.sha256.lowercased()
        )
    }

    // MARK: - Persistence

    private func persist(_ result: CheckResult, channel: Channel, previousUpdate: Update?) {
        switch result {
        case let .upToDate(currentVersion):
            recordSuccessfulCheck(channel: channel)
            defaults.removeObject(forKey: cachedUpdateKey(channel))
            state = .upToDate(currentVersion: currentVersion, checkedAt: lastSuccessfulCheck ?? now())
        case let .updateAvailable(update):
            recordSuccessfulCheck(channel: channel)
            if previousUpdate?.latestVersion != update.latestVersion { clearReminderDeferral() }
            if let data = try? JSONEncoder().encode(update) {
                defaults.set(data, forKey: cachedUpdateKey(channel))
            }
            state = .available(update)
        case let .failed(message):
            state = .failed(message: message, update: previousUpdate)
        }
    }

    private func recordSuccessfulCheck(channel: Channel) {
        let date = now()
        lastSuccessfulCheck = date
        defaults.set(date.timeIntervalSince1970, forKey: lastCheckKey(channel))
    }

    private func restorePersistedState() {
        if let resultMessage = consumeUpdateResultMarker() {
            clearPendingInstall()
            sweepOrphanedStaging(keepingStagedAppPath: nil)
            state = .failed(message: resultMessage, update: cachedUpdate(for: channel))
            return
        }

        if let pending = loadPendingInstall() {
            let age = now().timeIntervalSince(pending.preparedAt)
            if age >= 0,
               age < Self.pendingInstallLifetime,
               fileManager.fileExists(atPath: pending.stagedAppPath),
               Self.compareInstallOrder(pending.version, currentVersionProvider()) >= 0 {
                sweepOrphanedStaging(keepingStagedAppPath: pending.stagedAppPath)
                state = .readyToRelaunch(pending)
                return
            }
            discardStagingDirectory(for: pending.stagedAppPath)
            clearPendingInstall()
        }
        sweepOrphanedStaging(keepingStagedAppPath: nil)
        restoreAvailability(for: channel)
    }

    /// 下载/解压中途进程被杀（强退、断电、崩溃）会留下没有任何 pending 记录指向的
    /// `staging-*` 目录——里面是整个待安装 .app 副本，上百 MB，且永远不会被安装
    /// 脚本的 cleanup() 触及。启动恢复状态时扫一遍 Updates 目录，只保留正在生效
    /// 的 pending staging，其余孤儿全部删除（与安卓端 APK 启动清扫同一类修复）。
    private func sweepOrphanedStaging(keepingStagedAppPath stagedAppPath: String?) {
        Self.sweepOrphanedStagingDirectories(
            in: Self.updatesDirectory(fileManager: fileManager),
            keepingStagedAppPath: stagedAppPath,
            fileManager: fileManager
        )
    }

    /// 独立成 static 以便单测注入临时目录；只会碰 Updates 下自己创建的 staging-* 目录。
    static func sweepOrphanedStagingDirectories(
        in updatesDirectory: URL,
        keepingStagedAppPath stagedAppPath: String?,
        fileManager: FileManager = .default
    ) {
        let keep = stagedAppPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent()
        }
        let entries = (try? fileManager.contentsOfDirectory(
            at: updatesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            guard entry.hasDirectoryPath,
                  entry.lastPathComponent.hasPrefix("staging-"),
                  entry.standardizedFileURL != keep else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func restoreAvailability(for channel: Channel) {
        let timestamp = defaults.double(forKey: lastCheckKey(channel))
        lastSuccessfulCheck = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        if let update = cachedUpdate(for: channel) {
            state = .available(update)
        } else {
            defaults.removeObject(forKey: cachedUpdateKey(channel))
            state = .idle
        }
    }

    private func cachedUpdate(for channel: Channel) -> Update? {
        guard let data = defaults.data(forKey: cachedUpdateKey(channel)),
              let update = try? JSONDecoder().decode(Update.self, from: data),
              update.channel == channel,
              Self.isVersionNewer(update.latestVersion, than: currentVersionProvider()) else {
            return nil
        }
        return update
    }

    private func persistPendingInstall(_ pending: PendingInstall) throws {
        let data = try JSONEncoder().encode(pending)
        defaults.set(data, forKey: Self.pendingInstallKey)
        let transactionURL = URL(fileURLWithPath: pending.stagedAppPath)
            .deletingLastPathComponent()
            .appendingPathComponent("wand-update-transaction.json")
        try data.write(to: transactionURL, options: .atomic)
    }

    private func loadPendingInstall() -> PendingInstall? {
        guard let data = defaults.data(forKey: Self.pendingInstallKey) else { return nil }
        return try? JSONDecoder().decode(PendingInstall.self, from: data)
    }

    private func clearPendingInstall() {
        defaults.removeObject(forKey: Self.pendingInstallKey)
    }

    private func migrateLegacyKeysIfNeeded() {
        if defaults.object(forKey: lastCheckKey(.stable)) == nil {
            let legacy = defaults.double(forKey: Self.legacyLastCheckKey)
            if legacy > 0 { defaults.set(legacy, forKey: lastCheckKey(.stable)) }
        }
        defaults.removeObject(forKey: Self.legacyLastCheckKey)
        defaults.removeObject(forKey: Self.legacyCachedUpdateKey)
    }

    private func cachedUpdateKey(_ channel: Channel) -> String { "wand.macUpdate.\(channel.rawValue).cachedUpdate" }
    private func lastCheckKey(_ channel: Channel) -> String { "wand.macUpdate.\(channel.rawValue).lastCheckAt" }
    private func reminderVersionKey(_ channel: Channel) -> String { "wand.macUpdate.\(channel.rawValue).reminderVersion" }
    private func reminderUntilKey(_ channel: Channel) -> String { "wand.macUpdate.\(channel.rawValue).reminderUntil" }

    private func clearReminderDeferral() {
        defaults.removeObject(forKey: reminderVersionKey(channel))
        defaults.removeObject(forKey: reminderUntilKey(channel))
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func isSafeAcknowledgementPath(_ path: String, pending: PendingInstall) -> Bool {
        let ack = URL(fileURLWithPath: path).standardizedFileURL
        let staging = URL(fileURLWithPath: pending.stagedAppPath).deletingLastPathComponent().standardizedFileURL
        return ack.deletingLastPathComponent() == staging && ack.lastPathComponent == ".wand-update-ack"
    }

    private func discardStagingDirectory(for stagedAppPath: String) {
        let appURL = URL(fileURLWithPath: stagedAppPath).standardizedFileURL
        let staging = appURL.deletingLastPathComponent()
        guard staging.lastPathComponent.hasPrefix("staging-") else { return }
        let updatesDirectory = Self.updatesDirectory(fileManager: fileManager).standardizedFileURL
        guard staging.deletingLastPathComponent() == updatesDirectory else { return }
        try? fileManager.removeItem(at: staging)
    }

    private func consumeUpdateResultMarker() -> String? {
        let marker = Self.updatesDirectory(fileManager: fileManager).appendingPathComponent("last-result.txt")
        guard let data = try? Data(contentsOf: marker),
              let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }
        try? fileManager.removeItem(at: marker)
        return message
    }

    static func updatesDirectory(fileManager: FileManager = .default) -> URL {
        let cache = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return cache.appendingPathComponent("Wand/Updates", isDirectory: true)
    }

    private func managerError(code: Int, message: String) -> NSError {
        NSError(domain: "Wand.MacUpdateManager", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension MacUpdateManager.CheckTrigger: Equatable {}

extension MacUpdateManager {
    struct GitHubRelease: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadURL: URL
            let size: Int64

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case publishedAt = "published_at"
            case body
            case assets
        }
    }

    private struct UpdateManifest: Decodable {
        struct Asset: Decodable {
            let fileName: String
            let size: Int64
            let sha256: String
        }

        let version: String
        let assets: [Asset]
    }

    private struct ParsedVersion {
        let numbers: [Int]
        let prerelease: [String]?

        init?(_ raw: String) {
            let withoutPrefix = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
            let withoutBuild = String(withoutPrefix.split(separator: "+", maxSplits: 1).first ?? "")
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numericPart = pieces.first.map(String.init) ?? ""
            let numericPieces = numericPart.split(separator: ".", omittingEmptySubsequences: false)
            let values = numericPieces.compactMap { Int($0) }
            guard values.count == 3, values.count == numericPieces.count else { return nil }

            if pieces.count == 2 {
                let identifiers = pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !identifiers.isEmpty, !identifiers.contains(where: \.isEmpty) else { return nil }
                prerelease = identifiers
            } else {
                prerelease = nil
            }
            numbers = values
        }
    }
}
