import Foundation
import Combine

/// 包装 UserDefaults，存连接的服务器、token 和最近连接记录。
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    private let defaults = UserDefaults.standard
    private let serverURLKey = "wand.serverURL"
    private let tokenKey = "wand.token"
    private let recentInputsKey = "wand.recentInputs"

    private static let maxRecent = 6

    @Published private(set) var serverURL: URL?
    @Published private(set) var token: String?
    /// 最近一次成功连接用到的"原始输入"（连接码或地址），供 ConnectView 一键重连。
    @Published private(set) var recentInputs: [String] = []

    init() {
        if let s = defaults.string(forKey: serverURLKey), let u = URL(string: s) {
            self.serverURL = u
        }
        self.token = defaults.string(forKey: tokenKey)
        self.recentInputs = defaults.stringArray(forKey: recentInputsKey) ?? []
    }

    func connect(serverURL: URL, token: String?) {
        self.serverURL = serverURL
        self.token = token
        defaults.set(serverURL.absoluteString, forKey: serverURLKey)
        if let token { defaults.set(token, forKey: tokenKey) }
        else { defaults.removeObject(forKey: tokenKey) }
    }

    func disconnect() {
        serverURL = nil
        token = nil
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: tokenKey)
    }

    // MARK: - Recent inputs

    /// 记录一次成功连接用的原始输入，置顶去重，最多保留 maxRecent 条。
    func addRecent(_ rawInput: String) {
        let value = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var list = recentInputs.filter { $0 != value }
        list.insert(value, at: 0)
        if list.count > Self.maxRecent { list = Array(list.prefix(Self.maxRecent)) }
        recentInputs = list
        defaults.set(list, forKey: recentInputsKey)
    }

    func removeRecent(_ rawInput: String) {
        recentInputs.removeAll { $0 == rawInput }
        defaults.set(recentInputs, forKey: recentInputsKey)
    }
}
