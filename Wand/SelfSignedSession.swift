import Foundation

/// 共享的 URLSession，对自签名 HTTPS 证书（wand 默认 cert.ts 产出的）放行。
/// 等价 Android 端 MainActivity.trustSelfSigned()。
final class SelfSignedSession: NSObject, URLSessionDelegate {
    static let shared = SelfSignedSession()

    /// session.configuration.httpCookieStorage 的便捷别名 —— 给 WandAuth 在
    /// allHeaderFields 字典合并语义吃掉多份 Set-Cookie 时做兜底读取用。
    var cookieStorage: HTTPCookieStorage? { session.configuration.httpCookieStorage }

    lazy var session: URLSession = {
        // 用 ephemeral —— 它自带独立的内存 cookieStorage / URLCache，
        // 不会和系统 / 其他 App 的 .shared 存储互相污染，也不需要 App Groups entitlement。
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
