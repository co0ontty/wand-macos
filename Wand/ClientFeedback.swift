import Foundation

/// Only stacks recorded by the failing operation belong here, never Thread.callStackSymbols.
protocol ClientFeedbackStackProviding {
    var feedbackStack: String? { get }
}

struct ClientFeedbackReport: Encodable {
    struct Failure: Encodable {
        let name: String
        let message: String
        let code: String?
        let stack: String?
    }
    let schema = 1
    let source = "macos"
    let event: String
    let version: String
    let feature: String
    let error: Failure

    static func failure(_ error: Error, token: String?, secrets: [String] = []) -> Failure? {
        let ns = error as NSError
        guard !(error is CancellationError), !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return nil }
        let stack = (error as? ClientFeedbackStackProviding)?.feedbackStack
            ?? (ns.userInfo["NSStackTraceKey"] as? String)
            ?? (ns.userInfo["NSStackTraceKey"] as? [String])?.joined(separator: "\n")
        let message = (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        return Failure(name: redact(ns.domain, token: token, secrets: secrets), message: redact(message, token: token, secrets: secrets),
                       code: String(ns.code), stack: stack.map { redact($0, token: token, secrets: secrets) })
    }

    static func redact(_ text: String, token: String?, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets + [token].compactMap({ $0 }) where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // Preserve diagnostic text outside explicit credential values.
        for pattern in [
            #"(?im)(["']?\b(?:authorization|proxy-authorization|cookie|set-cookie)["']?\s*:\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\r\n]+)"#,
            #"(?i)([\"']?\b(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|app[_-]?token|session[_-]?(?:token|id)|token|(?:client[_-]?)?secret)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}&]+)"#,
            #"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#
        ] {
            value = value.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        return value
    }

    static func feature(path: String) -> String {
        let parts = (path.split(separator: "?").first ?? "").split(separator: "/")
        guard parts.count >= 2, parts[0] == "api" else { return "api" }
        switch parts[1] {
        case "sessions", "structured-sessions", "commands", "session-list", "session-directories": return "sessions"
        case "conversations": return "conversations"
        case "wand-tasks", "workspace-tasks", "workspaces", "wand-milestones": return "tasks"
        case "files", "upload": return "files"
        case "settings", "config", "user-profile": return "settings"
        case "models", "model-groups": return "models"
        case "login", "logout": return "authentication"
        case "git": return "repository"
        default: return "api"
        }
    }
}

/// Best effort, no queue/retries, no business request replay. Two in flight and five per minute.
@MainActor
final class ClientFeedback {
    struct Connection: Equatable {
        let origin: URL
        let token: String?
        let generation: UUID
        let cookieHeader: String?

        init(origin: URL, token: String?, generation: UUID = UUID(), cookieHeader: String? = nil) {
            self.origin = origin
            self.token = token
            self.generation = generation
            self.cookieHeader = cookieHeader
        }
    }

    static let shared = ClientFeedback()

    static func currentConnection() -> Connection? {
        guard !isTesting, let origin = ServerStore.shared.serverURL else { return nil }
        let token = ServerStore.shared.token
        let cookie = token?.isEmpty == false ? nil : HTTPCookie.requestHeaderFields(
            with: SelfSignedSession.shared.cookieStorage?.cookies(for: origin) ?? []
        )["Cookie"]
        return Connection(origin: origin, token: token, generation: ServerStore.shared.connectionID, cookieHeader: cookie)
    }

    /// Source clients bind while constructed on the UI actor. If ownership cannot
    /// be established synchronously, diagnostics are dropped, never guessed later.
    nonisolated static func connectionForRequest(origin: URL, token: String?) -> Connection? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            guard let current = currentConnection(), current.origin == origin, current.token == token else { return nil }
            return current
        }
    }

    private nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    private var recent: [Data: Date] = [:]
    private var admitted: [Date] = []
    private var inFlight = 0
    private let now: () -> Date
    private let currentConnection: @MainActor () -> Connection?
    private let transport: (URLRequest) async -> Void

    init(now: @escaping () -> Date = Date.init,
         currentConnection: @escaping @MainActor () -> Connection? = { ClientFeedback.currentConnection() }, transport: @escaping (URLRequest) async -> Void = { request in
        let delegate = ClientFeedbackSessionDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Discard the response body at headers; the feedback endpoint never needs parsing.
        _ = try? await session.data(for: request)
    }) {
        self.now = now
        self.currentConnection = currentConnection
        self.transport = transport
    }

    nonisolated static func capture(_ error: Error, event: String, feature: String, connection: Connection?) {
        guard !isTesting, let connection else { return }
        DispatchQueue.main.async {
            shared.submit(error, event: event, feature: feature, connection: connection)
        }
    }

    func submit(_ error: Error, event: String, feature: String, connection: Connection) {
        // The operation owns this immutable origin/token pair. Never borrow credentials
        // from a later connection, including a token refresh at the same URL.
        guard currentConnection() == connection else { return }
        let baseURL = connection.origin
        let token = connection.token
        let cookieSecrets = (connection.cookieHeader ?? "").split(separator: ";").compactMap { field in
            field.split(separator: "=", maxSplits: 1).dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        guard Self.isSafe(baseURL), let failure = ClientFeedbackReport.failure(error, token: token, secrets: cookieSecrets),
              !failure.name.isEmpty, failure.name.utf8.count <= 128,
              failure.message.utf8.count <= 8192, (failure.stack?.utf8.count ?? 0) <= 16384,
              let url = URL(string: "/api/feedback/client", relativeTo: baseURL)?.absoluteURL else { return }
        let report = ClientFeedbackReport(event: event, version: MacUpdateManager.currentVersion, feature: feature, error: failure)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(report), data.count <= 32768 else { return }
        let time = now()
        recent = recent.filter { time.timeIntervalSince($0.value) < 300 }
        admitted = admitted.filter { time.timeIntervalSince($0) < 60 }
        guard inFlight < 2, admitted.count < 5, recent[data] == nil else { return }
        if recent.count >= 128 { recent.removeAll() }
        recent[data] = time
        admitted.append(time)
        inFlight += 1
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        else if let cookie = connection.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        Task {
            if currentConnection() == connection { await transport(request) }
            inFlight -= 1
        }
    }

    nonisolated static func isSafe(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        if ["localhost", "::1", "[::1]"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

final class ClientFeedbackSessionDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Match existing Wand connection TLS policy, without forwarding credentials on redirects.
        SelfSignedSession.shared.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}
