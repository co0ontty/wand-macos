import Combine
import CryptoKit
import Foundation

/// Endpoint-owned in-memory materialized view. Only fingerprints/cursors travel to the server;
/// history bodies never enter preferences, navigation persistence or another endpoint.
actor ConversationSyncBuffer {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private var pending: [String: (UUID, Task<Data, Error>)] = [:]

    func read(_ id: String, older: Bool = false, fetch: @escaping (String) async throws -> Data) async throws -> Data {
        if let (token, task) = pending[id] {
            let data = try await task.value
            commit(id, token: token, data: data)
            return older ? try await read(id, older: true, fetch: fetch) : data
        }
        let previous = entries[id]
        let token = UUID()
        let task = Task<Data, Error> {
            var parts: [String] = []
            if let previous, let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any],
               let history = object["history"] as? [String: Any] {
                for name in ["revision", "from"] {
                    if let value = history[name] as? String {
                        let key = name == "revision" ? "since" : "from"
                        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=?#")
                        parts.append(key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
                    }
                }
            }
            if older { parts.append("older=1") }
            let response = try await fetch("/sync" + (parts.isEmpty ? "" : "?" + parts.joined(separator: "&")))
            guard let update = try JSONSerialization.jsonObject(with: response) as? [String: Any], update["id"] as? String == id else {
                throw WandAPI.APIError.network("对话同步身份不一致")
            }
            guard let history = update["history"] as? [String: Any] else { return response } // older service
            let old = try previous.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if update["unchanged"] as? Bool == true {
                guard var old else { throw WandAPI.APIError.network("对话同步缺少基线") }
                old["history"] = history
                return try JSONSerialization.data(withJSONObject: old)
            }
            var merged = (update["detail"] as? [String: Any]) ?? old ?? [:]
            guard merged["id"] as? String == id else { throw WandAPI.APIError.network("对话同步缺少详情") }
            var rows: [String: [String: Any]] = [:]
            if update["reset"] as? Bool != true {
                for row in old?["messages"] as? [[String: Any]] ?? [] { if let key = row["messageId"] as? String { rows[key] = row } }
            }
            for row in update["messages"] as? [[String: Any]] ?? [] { if let key = row["messageId"] as? String { rows[key] = row } }
            merged["messages"] = try (update["messageOrder"] as? [String] ?? []).map { key -> [String: Any] in
                guard let row = rows[key] else { throw WandAPI.APIError.network("对话同步缺少消息") }; return row
            }
            merged["history"] = history
            return try JSONSerialization.data(withJSONObject: merged)
        }
        pending[id] = (token, task)
        do { let data = try await task.value; commit(id, token: token, data: data); return data }
        catch { if pending[id]?.0 == token { pending.removeValue(forKey: id) }; throw error }
    }
    private func commit(_ id: String, token: UUID, data: Data) {
        guard pending[id]?.0 == token else { return }
        pending.removeValue(forKey: id); entries[id] = data
        order.removeAll { $0 == id }; order.append(id)
        while order.count > 24 { entries.removeValue(forKey: order.removeFirst()) }
    }
    func forget(_ id: String) { entries.removeValue(forKey: id); order.removeAll { $0 == id }; pending.removeValue(forKey: id)?.1.cancel() }
}

struct ConversationHistory: Decodable {
    let revision: String
    let from: String?
    let hasEarlier: Bool
    let total: Int
}


protocol CommunicationsServing: AnyObject {
    func employeeContacts() async throws -> [EmployeeContact]
    func conversations() async throws -> [NativeConversation]
    func conversation(id: String) async throws -> NativeConversation
    func conversationPage(id: String, older: Bool) async throws -> NativeConversation
    func conversationReceipt(requestID: String) async throws -> ConversationReceipt
    func postConversation(path: String, body: [String: Any]) async throws -> ConversationReceipt
    func communicationsDefaultCwd() async throws -> String
    func communicationsModels() async throws -> ModelsResponse?
    func communicationsUserProfile() async throws -> NativeUserProfile
    func uploadAttachments(id: String, urls: [URL]) async throws -> [UploadedFile]
}

extension CommunicationsServing {
    func conversationPage(id: String, older: Bool) async throws -> NativeConversation { try await conversation(id: id) }
    func communicationsModels() async throws -> ModelsResponse? { nil }
    func communicationsUserProfile() async throws -> NativeUserProfile { NativeUserProfile() }
}

extension WandAPI: CommunicationsServing {
    func communicationsUserProfile() async throws -> NativeUserProfile { try await serverConfig().userProfile ?? NativeUserProfile() }
    func saveUserProfile(_ profile: NativeUserProfile) async throws -> NativeUserProfile {
        struct Response: Decodable { let config: ServerConfigInfo }
        return try await request(Response.self, method: "POST", path: "/api/settings/config",
            body: ["userProfile": ["name": profile.name, "avatar": profile.avatar]]).config.userProfile ?? NativeUserProfile()
    }
    func saveEmployeeIdentity(id: String, name: String, avatar: String, systemSessionLimit: Int?, maxConcurrentTasks: Int, locked: Bool) async throws -> EmployeeContact {
        var body: [String: Any] = [
            "systemSessionLimit": systemSessionLimit.map { $0 as Any } ?? NSNull(),
            "maxConcurrentTasks": maxConcurrentTasks,
        ]
        if !locked {
            body["name"] = name
            if PlushAvatarIdentity.fixedAsset(id: id) == nil { body["avatar"] = avatar }
        }
        return try await request(EmployeeContact.self, method: "PUT", path: "/api/silicon-employees/\(percentEncodePathComponent(id))", body: body)
    }
    func communicationsModels() async throws -> ModelsResponse? { try await models() }
    func employeeContacts() async throws -> [EmployeeContact] {
        struct Response: Decodable { let employees: [EmployeeContact] }
        return try await request(Response.self, method: "GET", path: "/api/silicon-employees?includeArchived=1").employees
    }
    func conversations() async throws -> [NativeConversation] {
        struct Response: Decodable { let conversations: [NativeConversation] }
        return try await request(Response.self, method: "GET", path: "/api/conversations").conversations
    }
    func conversation(id: String) async throws -> NativeConversation {
        try await conversationPage(id: id, older: false)
    }
    func conversationPage(id: String, older: Bool) async throws -> NativeConversation {
        let path = "/api/conversations/" + percentEncodePathComponent(id)
        let data = try await conversationSync.read(id, older: older) { suffix in
            do { return try await self.requestData(method: "GET", path: path + suffix) }
            catch APIError.server(let status, _) where status == 404 { return try await self.requestData(method: "GET", path: path) }
        }
        return try JSONDecoder().decode(NativeConversation.self, from: data)
    }
    func conversationReceipt(requestID: String) async throws -> ConversationReceipt {
        try await request(ConversationReceipt.self, method: "GET", path: "/api/conversations/requests/\(percentEncodePathComponent(requestID))")
    }
    func postConversation(path: String, body: [String: Any]) async throws -> ConversationReceipt {
        try await request(ConversationReceipt.self, method: "POST", path: path, body: body, timeout: 180)
    }
    func communicationsDefaultCwd() async throws -> String {
        struct Response: Decodable { let defaultCwd: String? }
        return try await request(Response.self, method: "GET", path: "/api/config").defaultCwd ?? ""
    }
}

enum ConversationDeliveryError: LocalizedError {
    case notSent(String)
    case uncertain(requestID: String, message: String)
    var errorDescription: String? {
        switch self {
        case let .notSent(message): return message
        case let .uncertain(_, message): return message
        }
    }
}

/// One receipt owner for every conversation mutation. Only opaque IDs/fingerprints are persisted, never submitted text.
@MainActor
final class ConversationRequestLedger: ObservableObject {
    @Published private(set) var pending: [ConversationPendingRequest]
    private let api: CommunicationsServing
    private let defaults: UserDefaults
    private let persistenceKey: String
    private let serverID: String

    init(api: CommunicationsServing, serverURL: URL, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        var origin = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        origin?.user = nil; origin?.password = nil; origin?.query = nil; origin?.fragment = nil; origin?.path = ""
        serverID = origin?.string ?? "invalid-server"
        persistenceKey = "wand.desktop.communications.pending." + Self.hash(Data(serverID.utf8))
        let saved = defaults.data(forKey: persistenceKey).flatMap { try? JSONDecoder().decode([ConversationPendingRequest].self, from: $0) } ?? []
        pending = Array(saved.prefix(200))
    }

    func request(for scope: ConversationScope) -> ConversationPendingRequest? {
        pending.first { $0.conversationID == scope.conversationID && $0.target == scope.target && ($0.operation == "message" || $0.operation == "channel") }
    }

    func perform(path: String, body: [String: Any], scope: ConversationScope, operation: String) async throws -> ConversationReceipt {
        let encoded: Data
        do { encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        catch { throw ConversationDeliveryError.notSent("请求格式无效，尚未发送。") }
        let fingerprint = Self.hash(Data((serverID + "\0" + path + "\0").utf8) + encoded)
        if let existing = pending.first(where: { $0.fingerprint == fingerprint }) {
            throw ConversationDeliveryError.uncertain(requestID: existing.id, message: "同一请求送达未确认，请先核对，勿重复发送。")
        }
        guard pending.count < 200 else { throw ConversationDeliveryError.notSent("请先核对未确认请求，再继续提交。") }
        let record = ConversationPendingRequest(id: UUID().uuidString, fingerprint: fingerprint,
                                                conversationID: scope.conversationID, target: scope.target, operation: operation)
        pending.append(record); persist()
        var payload = body; payload["requestId"] = record.id
        do {
            let receipt = try await api.postConversation(path: path, body: payload)
            guard valid(receipt, record: record), receipt.isTerminal else {
                throw ConversationDeliveryError.uncertain(requestID: record.id, message: "接受回执尚未确认，请先核对请求。")
            }
            forget(record.id)
            guard receipt.state == "accepted" else {
                throw ConversationDeliveryError.notSent(receipt.error ?? "请求明确未接受，草稿保留。")
            }
            return receipt
        } catch let error as ConversationDeliveryError {
            if case .notSent = error { forget(record.id) }
            throw error
        } catch {
            if Self.wasDefinitelyNotAccepted(error) {
                forget(record.id)
                throw ConversationDeliveryError.notSent(error.localizedDescription)
            }
            throw ConversationDeliveryError.uncertain(requestID: record.id, message: "送达未确认，请核对请求，勿重复发送。")
        }
    }

    func reconcile(_ requestID: String) async throws -> ConversationReceipt {
        guard let record = pending.first(where: { $0.id == requestID }) else {
            throw ConversationDeliveryError.notSent("当前没有这条待核对请求。")
        }
        do {
            let receipt = try await api.conversationReceipt(requestID: requestID)
            guard valid(receipt, record: record) else { throw ConversationDeliveryError.uncertain(requestID: requestID, message: "回执与原请求不一致，仍需核对。") }
            if receipt.isTerminal { forget(requestID) }
            return receipt
        } catch let error as ConversationDeliveryError { throw error }
        catch {
            // A missing receipt, authentication failure or transport error says nothing about original acceptance.
            throw ConversationDeliveryError.uncertain(requestID: requestID, message: "暂未查到有效回执，不能据此认定未接受。请稍后再次核对。")
        }
    }

    private func valid(_ receipt: ConversationReceipt, record: ConversationPendingRequest) -> Bool {
        receipt.requestId == record.id && ["accepted", "rejected", "pending"].contains(receipt.state)
            && (record.operation == "create-group" ? !receipt.conversationId.isEmpty : receipt.conversationId == record.conversationID)
    }
    private func forget(_ id: String) { pending.removeAll { $0.id == id }; persist() }
    private func persist() {
        if pending.isEmpty { defaults.removeObject(forKey: persistenceKey) }
        else if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: persistenceKey) }
    }
    static func wasDefinitelyNotAccepted(_ error: Error) -> Bool {
        guard let error = error as? WandAPI.APIError else { return false }
        switch error {
        case .invalidURL, .unauthorized: return true
        case let .server(status, _): return (400..<500).contains(status) && status != 408 && status != 409
        case .network: return false
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
