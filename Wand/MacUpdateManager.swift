import Combine
import Foundation

/// Wand macOS 更新的唯一状态源。
///
/// 调用方只负责触发检查、安装、取消或重启；Stable GitHub / Beta 服务端策略、缓存、防抖、
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

    /// @Published 会在赋值前通知订阅者；弹窗/安装动作必须等 state 真正提交后执行。
    var committedStates: AnyPublisher<State, Never> {
        $state.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

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
    private static let betaServerKey = "wand.macUpdate.beta.serverURL"
    private static let pendingInstallKey = "wand.macUpdate.pendingInstall"
    private static let legacyLastCheckKey = "wand.githubRelease.lastCheckAt"
    private static let legacyCachedUpdateKey = "wand.githubRelease.cachedUpdate"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentVersionProvider: () -> String
    private let dataLoader: DataLoader
    private let betaDataLoader: DataLoader
    private let connectedServer: () -> URL?
    private let fileManager: FileManager
    private var activeCheck: Task<CheckResult, Never>?
    private var activeCheckID: UUID?
    private var activeCheckServerURL: URL?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        currentVersion: @escaping () -> String = { MacUpdateManager.currentVersion },
        fileManager: FileManager = .default,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        },
        betaDataLoader: @escaping DataLoader = { request in
            try await SelfSignedSession.shared.session.data(for: request)
        },
        connectedServer: @escaping () -> URL? = { ServerStore.shared.serverURL }
    ) {
        self.defaults = defaults
        self.now = now
        self.currentVersionProvider = currentVersion
        self.fileManager = fileManager
        self.dataLoader = dataLoader
        self.betaDataLoader = betaDataLoader
        self.connectedServer = connectedServer
        self.channel = Channel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? .stable

        migrateLegacyKeysIfNeeded()
        restorePersistedState()
    }

    /// 启动检查受 24 小时防抖；手动检查与通道切换始终请求所选来源。
    @discardableResult
    func check(_ trigger: CheckTrigger) async -> CheckResult? {
        // 已准备好的更新优先级最高；不要用一次网络检查覆盖可恢复的安装事务。
        if pendingInstall != nil { return nil }
        let checkedServer = channel == .beta ? connectedServer() : nil
        if trigger == .launch,
           let lastSuccessfulCheck,
           (channel == .stable || defaults.string(forKey: Self.betaServerKey) == checkedServer?.absoluteString),
           now().timeIntervalSince(lastSuccessfulCheck) < Self.launchCheckInterval {
            return nil
        }

        if channel == .beta, activeCheck != nil, activeCheckServerURL != checkedServer {
            activeCheck?.cancel()
            activeCheck = nil
            activeCheckID = nil
        }
        if let activeCheck {
            return await activeCheck.value
        }

        let checkedChannel = channel
        let previousUpdate = availableUpdate.flatMap { isCurrentSource($0) ? $0 : nil }
        state = .checking
        let checkID = UUID()
        let task = Task { [weak self] () -> CheckResult in
            guard let self else { return .failed(message: "更新检查器已释放。") }
            return checkedChannel == .beta
                ? await self.fetchServerBeta(serverURL: checkedServer)
                : await self.fetchLatestRelease()
        }
        activeCheck = task
        activeCheckID = checkID
        activeCheckServerURL = checkedServer
        let result = await task.value
        // 通道/服务器切换会取消旧任务；旧响应不得覆盖新连接状态。
        guard activeCheckID == checkID else { return result }
        activeCheck = nil
        activeCheckID = nil
        activeCheckServerURL = nil
        guard checkedChannel == channel else { return result }
        if checkedChannel == .beta, checkedServer != connectedServer() {
            restoreAvailability(for: channel)
            return result
        }
        persist(result, channel: checkedChannel, previousUpdate: previousUpdate)
        return result
    }

    @discardableResult
    func setChannel(_ newChannel: Channel) async -> CheckResult? {
        guard newChannel != channel else { return await check(.manual) }

        activeCheck?.cancel()
        activeCheck = nil
        activeCheckID = nil
        activeCheckServerURL = nil
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
        guard let update = availableUpdate, isCurrentSource(update) else { return "请先连接服务器并重新检查更新。" }
        guard update.preferredAsset != nil else { return "当前来源没有可用于自动更新的 ZIP 或 DMG。" }
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
    /// 返回 true 供启动流程重新检查可能因 ad-hoc 签名变化而失效的系统权限。
    @discardableResult
    func completeLaunchedUpdateIfNeeded(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let token = argument(after: "--wand-update-token", in: arguments),
              let ackPath = argument(after: "--wand-update-ack", in: arguments),
              let pending = loadPendingInstall(),
              pending.transactionID == token,
              pending.version == currentVersionProvider(),
              isSafeAcknowledgementPath(ackPath, pending: pending) else {
            return false
        }

        do {
            try Data("ok\n".utf8).write(to: URL(fileURLWithPath: ackPath), options: .atomic)
            clearPendingInstall()
            restoreAvailability(for: channel)
            return true
        } catch {
            state = .failed(message: "无法确认新版启动：\(error.localizedDescription)", update: nil)
            return false
        }
    }

    // MARK: - Installer state

    func handleInstallerStage(_ stage: UpdateInstaller.Stage, update: Update) {
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

    // MARK: - Stable GitHub / Beta server sources

    private func fetchLatestRelease() async -> CheckResult {
        do {
            let url = try githubURL(path: "/releases/latest")
            let data = try await loadGitHubData(from: url)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease,
                  let latestVersion = Self.version(fromTag: release.tagName) else {
                return .failed(message: "GitHub 尚未发布有效的稳定版 Release。")
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
                channel: .stable,
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

    private func fetchServerBeta(serverURL: URL?) async -> CheckResult {
        guard let serverURL,
              ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""),
              serverURL.host != nil, serverURL.user == nil, serverURL.password == nil else {
            return .failed(message: "请先连接 Wand 服务端，再检查 Beta 更新。")
        }
        do {
            let path = "/api/macos-app-update?currentVersion=\(percentEncode(currentVersionProvider()))"
            guard let url = URL(string: path, relativeTo: serverURL)?.absoluteURL else {
                return .failed(message: "无法构造服务端更新地址。")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await betaDataLoader(request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let responseURL = http.url,
                  Self.sameOrigin(responseURL, serverURL) else {
                return .failed(message: "当前服务端无法提供 macOS Beta 更新信息。")
            }
            let info = try JSONDecoder().decode(ServerBetaUpdate.self, from: data)
            guard info.channel == "beta", info.source == "local" || info.latestVersion == nil else {
                return .failed(message: "服务端返回了无效的 Beta 更新来源。")
            }
            guard let version = info.latestVersion else {
                return .failed(message: "当前连接的服务端尚未提供 macOS Beta 更新包。")
            }
            let current = currentVersionProvider()
            guard ParsedVersion(version) != nil else {
                return .failed(message: "服务端返回了无效的更新版本。")
            }
            guard Self.isVersionNewer(version, than: current) else {
                return .upToDate(currentVersion: current)
            }
            guard info.updateAvailable, info.source == "local",
                  let name = info.fileName,
                  Self.isMatchingServerAsset(name, version: version),
                  let link = info.downloadUrl, link.hasPrefix("/"), !link.hasPrefix("//"),
                  let downloadURL = URL(string: link, relativeTo: serverURL)?.absoluteURL,
                  Self.sameOrigin(downloadURL, serverURL),
                  downloadURL.path == "/macos/update-download",
                  downloadURL.fragment == nil,
                  URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)?
                    .queryItems == [URLQueryItem(name: "fileName", value: name)],
                  let size = info.size, size > 0,
                  let sha256 = info.sha256,
                  sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                return .failed(message: "服务端 Beta 更新包缺少有效的下载地址、大小或 SHA-256。")
            }
            let asset = Update.Asset(name: name, downloadURL: downloadURL, size: size, sha256: sha256)
            return .updateAvailable(Update(
                channel: .beta,
                currentVersion: current,
                latestVersion: version,
                releaseURL: serverURL,
                releaseNotes: nil,
                zipAsset: name.lowercased().hasSuffix(".zip") ? asset : nil,
                dmgAsset: name.lowercased().hasSuffix(".dmg") ? asset : nil
            ))
        } catch is CancellationError {
            return .failed(message: "更新检查已取消。")
        } catch {
            return .failed(message: "检查当前服务端 Beta 更新失败：\(error.localizedDescription)")
        }
    }

    private static func isMatchingServerAsset(_ name: String, version: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: version)
        return name.range(
            of: "^wand-v\(escaped)(?:\\+[A-Za-z0-9.-]+)?\\.(zip|dmg)$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }

    private func isCurrentSource(_ update: Update) -> Bool {
        guard update.channel == .beta else { return true }
        guard let server = connectedServer(),
              update.releaseURL == server,
              let asset = update.preferredAsset,
              asset.sha256 != nil else { return false }
        return Self.sameOrigin(asset.downloadURL, server)
            && asset.downloadURL.path == "/macos/update-download"
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
        if channel == .beta { defaults.set(connectedServer()?.absoluteString, forKey: Self.betaServerKey) }
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
        lastSuccessfulCheck = timestamp > 0
            && (channel == .stable || defaults.string(forKey: Self.betaServerKey) == connectedServer()?.absoluteString)
            ? Date(timeIntervalSince1970: timestamp) : nil
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
              isCurrentSource(update),
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
    private struct ServerBetaUpdate: Decodable {
        let updateAvailable: Bool
        let latestVersion: String?
        let downloadUrl: String?
        let fileName: String?
        let size: Int64?
        let source: String?
        let channel: String
        let sha256: String?
    }

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
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
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
