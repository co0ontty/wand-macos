import Foundation

/// 从 Wand 的 GitHub Release 检查 macOS 更新。
///
/// 这个更新通道不依赖当前连接的 Wand 服务：即使服务离线、切换到另一台服务器，
/// 客户端也始终从官方 Release 获得同一个 macOS 安装包。
@MainActor
final class GitHubReleaseUpdater: ObservableObject {

    static let shared = GitHubReleaseUpdater()

    struct Update: Codable, Equatable {
        struct Asset: Codable, Equatable {
            let name: String
            let downloadURL: URL
            let size: Int64
        }

        let currentVersion: String
        let latestVersion: String
        let releaseURL: URL
        let releaseNotes: String?
        let dmgAsset: Asset?
    }

    enum CheckResult: Equatable {
        case upToDate(currentVersion: String)
        case updateAvailable(Update)
        case failed(message: String)
    }

    @Published private(set) var availableUpdate: Update?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccessfulCheck: Date?

    private static let repository = "co0ontty/wand"
    private static let launchCheckInterval: TimeInterval = 30 * 60
    private static let lastCheckKey = "wand.githubRelease.lastCheckAt"
    private static let cachedUpdateKey = "wand.githubRelease.cachedUpdate"

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let timestamp = defaults.double(forKey: Self.lastCheckKey)
        if timestamp > 0 {
            lastSuccessfulCheck = Date(timeIntervalSince1970: timestamp)
        }

        if let data = defaults.data(forKey: Self.cachedUpdateKey),
           let cached = try? JSONDecoder().decode(Update.self, from: data),
           Self.isVersionNewer(cached.latestVersion, than: Self.currentVersion) {
            availableUpdate = cached
        } else {
            defaults.removeObject(forKey: Self.cachedUpdateKey)
        }
    }

    /// 当前 app 的营销版本；构建时间戳属于构建元数据，不参与 Release 比较。
    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// 启动提醒使用 30 分钟防抖；网络错误不写入检查时间，以便下次启动重试。
    func checkOnLaunchIfNeeded() async -> CheckResult? {
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.launchCheckInterval else {
            return nil
        }
        return await performCheck()
    }

    /// 设置页的强制检查：无视启动检查的时间间隔，直接请求 GitHub Releases API。
    func checkManually() async -> CheckResult {
        await performCheck()
    }

    // MARK: - GitHub API

    private func performCheck() async -> CheckResult {
        guard !isChecking else {
            if let update = availableUpdate { return .updateAvailable(update) }
            return .failed(message: "正在检查更新，请稍候。")
        }

        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let result = await fetchLatestRelease()
        switch result {
        case .upToDate:
            recordSuccessfulCheck()
            availableUpdate = nil
            defaults.removeObject(forKey: Self.cachedUpdateKey)
        case .updateAvailable(let update):
            recordSuccessfulCheck()
            availableUpdate = update
            if let data = try? JSONEncoder().encode(update) {
                defaults.set(data, forKey: Self.cachedUpdateKey)
            }
        case .failed(let message):
            lastError = message
        }
        return result
    }

    private func recordSuccessfulCheck() {
        let now = Date()
        lastSuccessfulCheck = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    private func fetchLatestRelease() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            return .failed(message: "无法构造 GitHub Release 地址。")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wand-macOS-UpdateChecker", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "GitHub 返回了无效响应。")
            }
            if http.statusCode == 404 {
                return .failed(message: "GitHub 尚未发布稳定版 Release。")
            }
            guard http.statusCode == 200 else {
                return .failed(message: "GitHub 返回 HTTP \(http.statusCode)。")
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else {
                return .failed(message: "GitHub 最新 Release 尚未公开发布。")
            }
            guard let latestVersion = Self.version(fromTag: release.tagName) else {
                return .failed(message: "GitHub Release 的版本标签无效：\(release.tagName)")
            }

            let currentVersion = Self.currentVersion
            guard Self.isVersionNewer(latestVersion, than: currentVersion) else {
                return .upToDate(currentVersion: currentVersion)
            }

            let dmg = release.assets
                .filter { $0.name.lowercased().hasSuffix(".dmg") }
                .sorted { lhs, rhs in
                    let lhsLooksLikeWand = lhs.name.lowercased().contains("wand")
                    let rhsLooksLikeWand = rhs.name.lowercased().contains("wand")
                    if lhsLooksLikeWand != rhsLooksLikeWand { return lhsLooksLikeWand }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                .first
                .map { Update.Asset(name: $0.name, downloadURL: $0.browserDownloadURL, size: $0.size) }

            return .updateAvailable(
                Update(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    releaseURL: release.htmlURL,
                    releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                    dmgAsset: dmg
                )
            )
        } catch is DecodingError {
            return .failed(message: "无法解析 GitHub Release 信息。")
        } catch {
            return .failed(message: "检查 GitHub Release 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    /// 只使用 semver 的主版本和预发布标识比较；`+build` 只是构建元数据，必须忽略。
    static func isVersionNewer(_ candidate: String, than baseline: String) -> Bool {
        guard let candidate = ParsedVersion(candidate), let baseline = ParsedVersion(baseline) else {
            return false
        }

        let count = max(candidate.numbers.count, baseline.numbers.count)
        for index in 0..<count {
            let lhs = index < candidate.numbers.count ? candidate.numbers[index] : 0
            let rhs = index < baseline.numbers.count ? baseline.numbers[index] : 0
            if lhs != rhs { return lhs > rhs }
        }

        switch (candidate.prerelease, baseline.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhs), .some(rhs)):
            return Self.isPrereleaseNewer(lhs, than: rhs)
        }
    }

    private static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return ParsedVersion(version) == nil ? nil : version
    }

    private static func isPrereleaseNewer(_ candidate: [String], than baseline: [String]) -> Bool {
        for (lhs, rhs) in zip(candidate, baseline) {
            guard lhs != rhs else { continue }
            let lhsNumber = Int(lhs)
            let rhsNumber = Int(rhs)
            switch (lhsNumber, rhsNumber) {
            case let (.some(left), .some(right)):
                return left > right
            case (.some, nil):
                return false
            case (nil, .some):
                return true
            case (nil, nil):
                return lhs.compare(rhs, options: .literal) == .orderedDescending
            }
        }
        return candidate.count > baseline.count
    }
}

private extension GitHubReleaseUpdater {
    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
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

    struct ParsedVersion {
        let numbers: [Int]
        let prerelease: [String]?

        init?(_ raw: String) {
            let withoutPrefix = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
            let withoutBuild = String(withoutPrefix.split(separator: "+", maxSplits: 1).first ?? "")
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numericPart = pieces.first.map(String.init) ?? ""
            let values = numericPart.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard !values.isEmpty,
                  values.count == numericPart.split(separator: ".", omittingEmptySubsequences: false).count else {
                return nil
            }

            if pieces.count == 2 {
                let identifiers = pieces[1]
                    .split(separator: ".", omittingEmptySubsequences: false)
                    .map(String.init)
                guard !identifiers.isEmpty, !identifiers.contains(where: { $0.isEmpty }) else {
                    return nil
                }
                prerelease = identifiers
            } else {
                prerelease = nil
            }
            numbers = values
        }
    }
}
