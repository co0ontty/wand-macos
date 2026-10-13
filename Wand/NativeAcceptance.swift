import Foundation

/// Explicit DEBUG-only live UI acceptance: real responses, isolated preferences, no business writes.
enum NativeAcceptance {
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["WAND_NATIVE_LIVE_ACCEPTANCE"] == "1"
        #else
        return false
        #endif
    }
    static let suite = "WandLiveAcceptance." + UUID().uuidString
    static let defaults: UserDefaults = {
        guard enabled else { return .standard }
        let storage = UserDefaults(suiteName: suite)!
        #if DEBUG
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/acceptance-connection.json"))) as! [String: Any]
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/config.json"))) as! [String: Any]
            guard let host = config["host"] as? String, ["127.0.0.1", "localhost", "0.0.0.0", "::", "::1", "[::]"].contains(host),
                  let port = config["port"] as? Int, let code = connection["connectionCode"] as? String else { return storage }
            var encoded = code.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
                  let split = decoded.lastIndex(of: "#") else { return storage }
            let token = String(decoded[decoded.index(after: split)...])
            let url = "\((config["https"] as? Bool) == true ? "https" : "http")://127.0.0.1:\(port)"
            storage.setVolatileDomain(["wand.serverURL": url, "wand.token": token], forName: UserDefaults.argumentDomain)
            storage.set("system", forKey: "wand.appearanceMode")
            storage.set(true, forKey: "wand.desktop.sidebarVisible")
        } catch {
            // Never serialize private config or decoding error payloads into diagnostics.
        }
        #endif
        return storage
    }()
    static func allows(method: String, path: String) -> Bool {
        guard enabled else { return true }
        return method == "GET" || path == "/api/login" || path == "/api/logout"
    }
    static func cleanup() {
        if enabled { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain); defaults.removePersistentDomain(forName: suite) }
    }
}
