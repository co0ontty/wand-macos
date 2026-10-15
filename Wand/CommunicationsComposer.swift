import Combine
import Foundation

/// A conversation/target owns one draft and receipt lifecycle, independently of any mounted page.
@MainActor
final class ConversationComposerState: ObservableObject {
    enum Phase: Equatable {
        case idle, sending, sent
        case acceptedWithFailure(String)
        case rejected(String)
        case unknown(String)
    }
    struct Submission {
        let text: String
        let attachments: [UploadedFile]
        let releasedRevision: UInt64
    }

    let scope: ConversationScope
    @Published private(set) var text = ""
    @Published private(set) var attachments: [UploadedFile] = []
    @Published private(set) var cwd = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var feedback = ""
    @Published private(set) var uploading = false
    @Published private(set) var reconciling = false
    private(set) var revision: UInt64 = 0
    private var discardedRevision: UInt64 = 0
    private var removedAttachments: [String: UInt64] = [:]
    private var submission: Submission?
    private var cwdEdited = false

    init(scope: ConversationScope, cwd: String, pending: ConversationPendingRequest? = nil) {
        self.scope = scope; self.cwd = cwd
        if let pending { phase = .unknown(pending.id); feedback = "有上次送达未确认的请求，请先核对；提交正文未持久化。" }
    }
    var isSending: Bool { phase == .sending }
    var unknownID: String? { if case let .unknown(id) = phase { return id }; return nil }
    var canSubmit: Bool { !isSending && !uploading && unknownID == nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    func edit(_ value: String) {
        guard value != text else { return }
        let cleared = !text.isEmpty && value.isEmpty
        text = value; revision &+= 1
        if cleared { discardedRevision = revision }
        if phase == .sent { phase = .idle; feedback = "" }
    }
    func editCwd(_ value: String) { cwd = value; cwdEdited = true; revision &+= 1 }
    func applyDefaultCwd(_ value: String) { if !cwdEdited && cwd.isEmpty { cwd = value } }
    func discard() {
        text = ""; attachments = []; revision &+= 1; discardedRevision = revision
        if !isSending && unknownID == nil { phase = .idle; feedback = "" }
    }
    func removeAttachment(_ path: String) {
        attachments.removeAll { $0.savedPath == path }; revision &+= 1; removedAttachments[path] = revision
    }
    func beginUpload() -> UInt64? {
        guard !uploading && !isSending && unknownID == nil else { return nil }
        uploading = true; feedback = "正在准备附件…"
        return revision
    }
    func uploadStillCurrent(_ captured: UInt64) -> Bool { revision == captured }
    func completeUpload(_ files: [UploadedFile], revision captured: UInt64) {
        defer { uploading = false }
        guard revision == captured else { feedback = "输入已变化，本次附件未自动加入；请重新选择。"; return }
        guard attachments.count + files.count <= 5 else { feedback = "最多添加 5 个附件。"; return }
        attachments.append(contentsOf: files); revision &+= 1; feedback = ""
    }
    func failUpload(_ error: Error) {
        uploading = false; handle(error, restoringSubmission: false)
    }
    /// A second paste must not release an upload or message already in flight.
    func reportAttachmentBlocked(_ message: String) { feedback = message }

    func submit(ledger: ConversationRequestLedger) async -> ConversationReceipt? {
        guard canSubmit else { return nil }
        guard text.utf16.count <= 256_000 else { phase = .rejected("消息不能超过 256000 个字符。"); feedback = "消息过长，尚未发送。"; return nil }
        let capturedText = text, capturedFiles = attachments, capturedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending; feedback = ""
        text = ""; attachments = []; revision &+= 1
        submission = Submission(text: capturedText, attachments: capturedFiles, releasedRevision: revision)
        var body: [String: Any] = ["input": buildAttachmentPrompt(capturedFiles, body: capturedText),
                                   "target": scope.target.map { $0.body as Any } ?? NSNull()]
        if !capturedCwd.isEmpty { body["cwd"] = capturedCwd }
        do {
            let receipt = try await ledger.perform(
                path: "/api/conversations/\(Self.encode(scope.conversationID))/messages",
                body: body, scope: scope, operation: "message"
            )
            submission = nil
            phase = receipt.error.map { .acceptedWithFailure($0) } ?? .sent
            feedback = receipt.error ?? "已接受；新输入保留。"
            return receipt
        } catch { handle(error, restoringSubmission: true); return nil }
    }

    func reconcile(ledger: ConversationRequestLedger) async -> ConversationReceipt? {
        guard !reconciling, let requestID = unknownID else { return nil }
        let isChannel = ledger.pending.first { $0.id == requestID }?.operation == "channel"
        reconciling = true; defer { reconciling = false }
        do {
            let receipt = try await ledger.reconcile(requestID)
            if receipt.state == "pending" { feedback = "仍未确认，请勿重复提交。"; return receipt }
            if receipt.state == "accepted" {
                submission = nil; phase = receipt.error.map { .acceptedWithFailure($0) } ?? .sent
                feedback = receipt.error ?? (isChannel ? "附件通道已准备；原消息未发送，请重新选择文件。" : "已核对：请求已接受，新输入保留。")
            } else {
                restoreSubmission(); phase = .rejected(receipt.error ?? "请求未接受。")
                feedback = receipt.error ?? "已核对：未接受，草稿保留。"
            }
            return receipt
        } catch { feedback = error.localizedDescription; return nil }
    }

    private func handle(_ error: Error, restoringSubmission: Bool) {
        if let delivery = error as? ConversationDeliveryError, case let .uncertain(id, message) = delivery {
            phase = .unknown(id); feedback = message
            return
        }
        if restoringSubmission { restoreSubmission() }
        phase = .rejected(error.localizedDescription); feedback = error.localizedDescription
    }
    private func restoreSubmission() {
        guard let submitted = submission else { return }
        submission = nil
        guard discardedRevision <= submitted.releasedRevision else { return }
        if !submitted.text.isEmpty { text = text.isEmpty ? submitted.text : submitted.text + "\n\n" + text }
        let current = Set(attachments.map(\.savedPath))
        attachments = submitted.attachments.filter {
            !current.contains($0.savedPath) && (removedAttachments[$0.savedPath] ?? 0) <= submitted.releasedRevision
        } + attachments
        revision &+= 1
    }
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

/// Non-message mutations use the same ledger, but must never settle a message draft.
@MainActor
final class ConversationOperationState: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var unknownID: String?
    @Published private(set) var feedback = ""
    @Published private(set) var receipt: ConversationReceipt?

    init(pending: ConversationPendingRequest? = nil) { unknownID = pending?.id }
    func perform(ledger: ConversationRequestLedger, path: String, body: [String: Any], scope: ConversationScope, operation: String) async -> ConversationReceipt? {
        guard !busy && unknownID == nil && receipt?.state != "accepted" else { return nil }
        busy = true; feedback = ""; receipt = nil
        defer { busy = false }
        do {
            let accepted = try await ledger.perform(path: path, body: body, scope: scope, operation: operation)
            receipt = accepted; feedback = accepted.error ?? "操作已接受。"
            return accepted
        } catch {
            if let delivery = error as? ConversationDeliveryError, case let .uncertain(id, _) = delivery { unknownID = id }
            feedback = error.localizedDescription; return nil
        }
    }
    func reconcile(ledger: ConversationRequestLedger) async -> ConversationReceipt? {
        guard !busy, let id = unknownID else { return nil }
        busy = true; defer { busy = false }
        do {
            let result = try await ledger.reconcile(id)
            if result.isTerminal { unknownID = nil; receipt = result }
            feedback = result.error ?? (result.state == "pending" ? "仍未确认，勿重复提交。" : result.state == "accepted" ? "已核对：操作已接受。" : "请求未接受。")
            return result
        } catch { feedback = error.localizedDescription; return nil }
    }
    func localFailure(_ message: String) { feedback = message }
    func resetAcceptedOutcome() {
        guard !busy, unknownID == nil else { return }
        receipt = nil; feedback = ""
    }
}
