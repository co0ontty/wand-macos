import AppKit
import Darwin
import Foundation
import Network

/// macOS 15 (Sequoia) 起，访问局域网需要用户授权「本地网络」权限（Apple TN3179）。
///
/// 关键事实：
/// - 系统设置 → 隐私与安全性 → 本地网络 的列表**没有手动添加入口**——应用必须先
///   发起一次本地网络访问、触发系统弹窗后才会出现在列表里。
/// - WKWebView 的流量**豁免**该权限（TN3179 明确列出），所以旧 WebView 壳从未触发过；
///   原生化之后 URLSession 直连 LAN IP 在未授权状态下会被**静默拒绝**（连接超时），
///   用户看不到任何提示，也找不到去哪里授权。
/// - ad-hoc 签名（本项目的分发方式）下系统对应用身份的跟踪不稳定，弹窗有概率不出现
///   （Quinn/Apple DTS 确认的 15.x 已知问题；app 不在 /Applications 时也会复现）。
///
/// 因此这里做三件事：
/// 1. `triggerPromptIfNeeded()`：启动时用「UDP connect 到随机 link-local IPv6 地址:9」
///    主动触发授权弹窗。这是 TN3179 给出的官方技巧——不产生真实网络流量，且实测能
///    绕开部分"正常访问不弹窗"的系统 bug。
/// 2. `probeDenied(_:)`：用 NWBrowser 探测当前是否已被拒绝——被拒时浏览操作会进入
///    `.waiting(.dns(kDNSServiceErr_PolicyDenied = -65570))`。注意第一次 start 在
///    「未决定/被拒」状态下可能停在 `.ready` 不动（Quinn 确认的怪癖），所以探测要
///    跑两轮、以第二轮为准。
/// 3. `openSettings()`：深链到系统设置的「本地网络」面板（锚点无官方文档，按
///    Sequel-Ace 同款回退链尝试）。
enum LocalNetworkPermission {

    /// kDNSServiceErr_PolicyDenied —— 用户拒绝「本地网络」权限时 DNS-SD 返回的错误码。
    /// （-65555 NoAuth 是另一回事：iOS 上缺 NSBonjourServices 声明，不代表用户拒绝。）
    private static let policyDeniedCode: Int32 = -65570

    /// 本进程是否已触发过弹窗（系统只在「未决定」状态弹窗，重复触发无害但没必要）。
    private static var triggered = false

    /// 是否运行在受本地网络隐私约束的系统上（macOS 15+）。
    static var isEnforced: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 启动时调用：把系统的「本地网络」授权弹窗主动钓出来。
    /// macOS 15 之前没有这个权限概念，直接跳过。
    static func triggerPromptIfNeeded() {
        guard isEnforced, !triggered else { return }
        triggered = true
        // TN3179：connect 一个 UDP socket 到随机 link-local IPv6 地址的 9 端口
        // （discard 协议），即可触发本地网络权限检查，不发出任何真实流量。
        // connect 本身可能立刻失败（未授权时），这无所谓——触发弹窗的目的已达到。
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(9).bigEndian
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = 0xfe
        raw[1] = 0x80
        for i in 8..<16 { raw[i] = UInt8.random(in: 1...254) }
        memcpy(&addr.sin6_addr, &raw, 16)
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        close(fd)
    }

    /// 探测「本地网络」权限是否已被拒绝。回调在主线程；`true` = 确认被拒，
    /// `false` = 未被拒或无法确定（未决定状态/老系统都归入 false）。
    static func probeDenied(_ completion: @escaping (Bool) -> Void) {
        guard isEnforced else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        // 第一轮主要是把 DNS-SD 的状态机踢醒（首次 start 可能误报 .ready）；
        // 第一轮没看到 PolicyDenied 就再跑一轮，以第二轮为准。
        runBrowserProbe(timeout: 0.6) { firstDenied in
            if firstDenied {
                completion(true)
            } else {
                runBrowserProbe(timeout: 1.2, completion)
            }
        }
    }

    private static func runBrowserProbe(timeout: TimeInterval,
                                        _ completion: @escaping (Bool) -> Void) {
        let queue = DispatchQueue(label: "wand.localnetwork.probe")
        // 浏览什么服务类型不重要——只看权限层面的反应。macOS 上不声明
        // NSBonjourServices 即「允许浏览所有类型」（声明了反而变成白名单）。
        let browser = NWBrowser(for: .bonjour(type: "_wand._tcp", domain: nil),
                                using: NWParameters())
        var finished = false
        let finish: (Bool) -> Void = { denied in
            guard !finished else { return }
            finished = true
            browser.cancel()
            DispatchQueue.main.async { completion(denied) }
        }
        browser.stateUpdateHandler = { state in
            if case .waiting(let error) = state,
               case .dns(let code) = error,
               code == policyDeniedCode {
                finish(true)
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    /// 判断 host 是否大概率在局域网内（私有网段 / mDNS / link-local）。
    /// 回环地址不算——本机流量不需要「本地网络」权限。
    static func isLikelyLanHost(_ host: String?) -> Bool {
        guard let raw = host?.lowercased(), !raw.isEmpty else { return false }
        if raw == "localhost" || raw == "127.0.0.1" || raw == "::1" { return false }
        if raw.hasSuffix(".local") { return true }
        if raw.hasPrefix("10.") || raw.hasPrefix("192.168.")
            || raw.hasPrefix("169.254.") || raw.hasPrefix("fe80:") { return true }
        if raw.hasPrefix("172.") {
            let parts = raw.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// 打开系统设置 →「隐私与安全性 → 本地网络」。锚点没有官方文档，按
    /// Sequel-Ace 的回退链依次尝试，最后兜底打开「隐私与安全性」根页面。
    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
