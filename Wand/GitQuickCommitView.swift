import SwiftUI

/// 快速 Git 面板：与 iOS 共用磁吸气泡操作语义。
///
/// message 或 Tag 留空时由服务端生成并提交；AI 按钮用于提前生成和编辑。
/// 提交未推送时结果面板提供 Push & Close。
struct GitQuickCommitView: View {
    let sessionId: String
    let api: WandAPI
    let onRunning: () -> Void
    let onCompleted: (String) -> Void
    let onFailed: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // git 状态
    @State private var status: GitStatusResult?
    @State private var statusLoading = true
    @State private var statusError: String?

    // 表单
    @State private var message = ""
    @State private var tagName = ""
    @State private var tagEdited = false
    @FocusState private var focusedInput: QuickCommitInput?

    private enum QuickCommitInput: Hashable {
        case message
        case tag
    }

    // AI 预生成
    @State private var generating = false

    // 提交
    @State private var committing = false
    @State private var submoduleIntent = false
    @State private var mergingWorktrees = false
    @State private var errorMessage: String?
    @State private var worktreeFeedback: String?
    @State private var worktreeSummary: String?

    // 结果
    @State private var outcome: CommitOutcome?
    @State private var pushing = false
    @State private var pushError: String?

    /// 一次快捷提交的结果（new 侧），old 侧字段来自提交前的 git 状态快照。
    private struct CommitOutcome {
        var includeSubmodule: Bool
        var pushed: Bool
        var pushError: String?
        var commitHash: String
        var commitMessage: String
        var tagName: String
        var oldTag: String
        var oldCommitHash: String
        var oldCommitSubject: String
        var submoduleCount: Int
    }

    init(
        sessionId: String,
        api: WandAPI,
        onRunning: @escaping () -> Void = {},
        onCompleted: @escaping (String) -> Void = { _ in },
        onFailed: @escaping (String) -> Void = { _ in }
    ) {
        self.sessionId = sessionId
        self.api = api
        self.onRunning = onRunning
        self.onCompleted = onCompleted
        self.onFailed = onFailed
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSubtitle
                    statusFilesSection
                    if outcome != nil {
                        resultPanel
                    } else {
                        formPanel
                    }
                }
                .padding(20)
            }
            .background { WandAmbientBackground() }
        }
        .frame(minWidth: 720, minHeight: 540)
        .focusedSceneValue(\.wandDesktopCommandsEnabled, false)
        .task { await loadStatus(force: true) }
    }

    /// `NavigationView` 在 macOS 会自动采用分栏导航，把整张提交表单挤进窄侧栏。
    /// 快捷提交是单页任务，用固定的 sheet chrome 保持内容宽度和操作层级稳定。
    private var sheetHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("快捷提交")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("检查改动，确认提交信息与后续操作")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if committing || pushing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(committing ? "正在提交" : "正在推送")
            }
            Button(outcome == nil ? "取消" : "完成") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .wandGlass(.chrome)
    }

    // MARK: - 头部与状态

    @ViewBuilder private var headerSubtitle: some View {
        if statusLoading && status == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("读取 git 状态…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
        } else if let statusError {
            HStack(spacing: 12) {
                Text(statusError)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("重试") { Task { await loadStatus(force: true) } }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(statusLoading)
            }
        } else if let s = status, !s.isGit {
            Text("当前会话目录不是 git 仓库")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
    }

    @ViewBuilder private var statusFilesSection: some View {
        if let s = status, s.isGit, let files = s.files, !files.isEmpty, outcome == nil {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(30)) { file in
                        HStack(spacing: 8) {
                            Text(file.shortStatus)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(file.shortStatus == "?" ? Theme.textSecondary : Theme.brand)
                                .frame(width: 18, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill((file.shortStatus == "?" ? Theme.textSecondary : Theme.brand).opacity(0.10))
                                )
                            Text(file.path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if file.isSubmodule == true {
                                tinyChip("submodule", color: Theme.brandStrong)
                            }
                        }
                    }
                    if files.count > 30 {
                        Text("…还有 \(files.count - 30) 个文件")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("改动 \(s.modifiedCount ?? files.count) 个文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.textSecondary)
        }
    }

    // MARK: - 表单面板

    private var hasChanges: Bool { (status?.modifiedCount ?? 0) > 0 }

    @ViewBuilder private var formPanel: some View {
        commitWorkspaceLens

        // 提交信息 + AI 预生成按钮
        HStack {
            Text("提交信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Button { Task { await generateAI() } } label: {
                HStack(spacing: 6) {
                    if generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(generating ? "生成中…" : "AI 生成")
                }
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 84)
            }
            .buttonStyle(WandSecondaryButtonStyle())
            .disabled(generating || committing || !hasChanges)
        }

        // Commit：上一笔 → 新 message
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "上次提交", old: oldCommitLine)
            Text("新提交")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            TextField("留空由 AI 根据改动生成", text: $message)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .focused($focusedInput, equals: .message)
                .wandInputSurface(focused: focusedInput == .message, cornerRadius: Theme.Radius.control)
                .disabled(committing)
        }

        // Tag：最新 tag → 新 tag
        VStack(alignment: .leading, spacing: 6) {
            pairOldLine(label: "当前 Tag", old: status?.latestTag ?? "无 tag")
            Text("新 Tag（可选）")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            TextField("选择含 Tag 的提交方式时生效；留空时点提交会先生成待确认", text: $tagName)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .focused($focusedInput, equals: .tag)
                .wandInputSurface(focused: focusedInput == .tag, cornerRadius: Theme.Radius.control)
                .disabled(committing)
                .onChange(of: tagName) { _ in tagEdited = true }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(Theme.danger)
        }

        MagneticDockView(
            hasChanges: hasChanges,
            hasSubmodule: status?.hasSubmodule == true,
            hasWorktrees: (status?.worktreeCount ?? 0) > 0,
            ahead: status?.ahead ?? 0,
            busy: committing || mergingWorktrees || generating || pushing,
            feedback: committing ? busyLabel : pushing ? "推送中…" : worktreeFeedback,
            onAction: { action, sub in submit(action: action, includeSubmodule: sub) },
            onWorktree: mergeWorktrees,
            onPush: pushCommitsOnly
        )
        .frame(height: 200)

        Text(worktreeFeedback == "已完成"
            ? worktreeSummary ?? "已合并并推送"
            : "点按气泡执行，拖动气泡组合后丢进提交区。Worktree：合并全部工作树到当前分支并推送。")
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
    }

    private var busyLabel: String {
        "执行中…" + (submoduleIntent ? "（含 submodule）" : "")
    }

    private var oldCommitLine: String {
        Self.joinedOr([status?.lastCommit?.shortHash, status?.lastCommit?.subject], fallback: "无 commit")
    }

    /// 提交前先交代当前分支、改动和待推送状态，避免表单脱离工作区上下文。
    private var commitWorkspaceLens: some View {
        let changeCount = status?.modifiedCount ?? 0
        let ahead = status?.ahead ?? 0
        let hasPendingChanges = changeCount > 0
        let stateText = hasPendingChanges
            ? "\(changeCount) 个改动待处理"
            : (ahead > 0 ? "\(ahead) 个 commit 待推送" : "工作区干净")

        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.branch ?? "未识别分支")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stateText)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if ahead > 0 && hasPendingChanges {
                Label("领先 \(ahead)", systemImage: "arrow.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }

    /// 拼接非空片段；全空时回退占位文案。
    private static func joinedOr(_ parts: [String?], fallback: String) -> String {
        let cleaned = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? fallback : cleaned.joined(separator: " ")
    }

    private func pairOldLine(label: String, old: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 54, alignment: .leading)
            Text(old)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(old)
            Spacer(minLength: 0)
        }
    }

    private func tinyChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - 结果面板

    @ViewBuilder private var resultPanel: some View {
        if let r = outcome {
            VStack(alignment: .leading, spacing: 12) {
                resultPair(
                    label: "Commit",
                    old: Self.joinedOr([r.oldCommitHash, r.oldCommitSubject], fallback: "无"),
                    new: Self.joinedOr([r.commitHash, r.commitMessage], fallback: "无")
                )
                resultPair(
                    label: "Tag",
                    old: r.oldTag.isEmpty ? "无 tag" : r.oldTag,
                    new: r.tagName.isEmpty ? "未打 tag" : r.tagName
                )
                if r.submoduleCount > 0 {
                    Text("已先提交 \(r.submoduleCount) 个 submodule")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                if let err = pushError ?? r.pushError, !err.isEmpty {
                    Text("push 失败:\(err)")
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
                HStack {
                    Button("关闭") { dismiss() }
                        .buttonStyle(WandSecondaryButtonStyle())
                    Spacer()
                    if r.pushed {
                        Label("已推送", systemImage: "icloud.and.arrow.up")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Button(action: pushAfterCommit) {
                            HStack(spacing: 6) {
                                if pushing { ProgressView().controlSize(.small).tint(.white) }
                                Text(pushing ? "推送中…" : "推送并关闭")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(minWidth: 98)
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(pushing)
                    }
                }
            }
        }
    }

    private func resultPair(label: String, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 8) {
                Text(old)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary.opacity(0.75))
                Text(new)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 逻辑

    private func loadStatus(force: Bool) async {
        statusLoading = true
        statusError = nil
        do {
            status = try await api.gitStatus(sessionId: sessionId)
        } catch {
            statusError = error.localizedDescription
        }
        statusLoading = false
    }

    /// 让服务端根据 staged diff 生成说明与 Tag 候选并回填表单；绝不覆盖用户已输入的内容。
    private func generateAI() async {
        guard !generating, !committing else { return }
        generating = true
        errorMessage = nil
        do {
            let r = try await api.generateCommitMessage(sessionId: sessionId)
            let aiMessage = (r.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let aiTag = (r.suggestedTag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 只在空白时填 message，绝不覆盖用户已输入的内容。
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !aiMessage.isEmpty {
                message = aiMessage
            }
            if !aiTag.isEmpty, !tagEdited {
                tagName = aiTag
                // onChange(tagName) 会把 tagEdited 置 true —— 这里是程序填充，复位。
                DispatchQueue.main.async { tagEdited = false }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        generating = false
    }

    /// action ∈ {commit, commit-tag, commit-push, commit-tag-push}，与网页一致；
    /// includeSubmodule 是正交 scope flag。
    private func submit(action: String, includeSubmodule: Bool) {
        guard !committing, !mergingWorktrees, !generating, hasChanges else { return }
        let withTag = action == "commit-tag" || action == "commit-tag-push"
        let userTag = withTag ? tagName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        performCommit(action: action, includeSubmodule: includeSubmodule, message: msg, tag: userTag)
    }

    private func performCommit(action: String, includeSubmodule: Bool, message msg: String, tag userTag: String) {
        let push = action == "commit-push" || action == "commit-tag-push"
        let before = status

        committing = true
        onRunning()
        submoduleIntent = includeSubmodule
        errorMessage = nil
        pushError = nil
        Task {
            do {
                let r = try await api.quickCommit(
                    sessionId: sessionId,
                    customMessage: msg.isEmpty ? nil : msg,
                    tag: userTag.isEmpty ? nil : userTag,
                    autoTag: (action == "commit-tag" || action == "commit-tag-push") && userTag.isEmpty,
                    push: push,
                    submodule: includeSubmodule
                )
                if !(r.archivedTaskIds ?? []).isEmpty {
                    NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
                }
                let o = CommitOutcome(
                    includeSubmodule: includeSubmodule,
                    pushed: r.pushed == true,
                    pushError: (r.pushError?.isEmpty == false) ? r.pushError : nil,
                    commitHash: String((r.commit?.hash ?? "").prefix(7)),
                    commitMessage: r.commit?.message ?? msg,
                    tagName: r.tag?.name ?? "",
                    oldTag: before?.latestTag ?? "",
                    oldCommitHash: before?.lastCommit?.shortHash ?? "",
                    oldCommitSubject: before?.lastCommit?.subject ?? "",
                    submoduleCount: r.submoduleCommits?.count ?? 0
                )
                if o.pushError == nil {
                    onCompleted(summaryText(o) + (push ? "，已推送" : ""))
                    // 请求继续在后台收尾；用户无需停在模态层等待网络往返。
                    dismiss()
                } else {
                    outcome = o
                    onFailed("推送失败：\(o.pushError ?? "未知错误")")
                    await loadStatus(force: true)
                }
            } catch {
                errorMessage = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            committing = false
        }
    }

    private func mergeWorktrees() {
        guard !mergingWorktrees, !committing, !pushing,
              let branch = status?.branch, let head = status?.head else { return }
        mergingWorktrees = true
        worktreeFeedback = "合并并推送中…"
        errorMessage = nil
        onRunning()
        Task {
            do {
                let result = try await api.mergeWorktrees(sessionId: sessionId, branch: branch, head: head)
                if result.ok && result.pushed {
                    worktreeFeedback = "已完成"
                    worktreeSummary = "已合并 \(result.mergedBranches.count) 个 Worktree 到 \(result.targetBranch) 并推送"
                    onCompleted("已合并 \(result.mergedBranches.count) 个 Worktree 到 \(result.targetBranch) 并推送")
                } else {
                    worktreeFeedback = "操作失败"
                    errorMessage = result.error ?? "合并或推送未完成"
                    onFailed(errorMessage ?? "合并失败")
                }
            } catch {
                worktreeFeedback = "操作失败"
                errorMessage = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            await loadStatus(force: true)
            mergingWorktrees = false
        }
    }

    /// 结果面板的 Push & Close。
    private func pushAfterCommit() {
        guard let r = outcome, !pushing else { return }
        pushing = true
        pushError = nil
        Task {
            do {
                let res = try await api.gitPush(
                    sessionId: sessionId,
                    pushCommits: true,
                    pushTags: !r.tagName.isEmpty,
                    submodule: r.includeSubmodule,
                    tag: r.tagName.isEmpty ? nil : r.tagName
                )
                if let err = res.error, !err.isEmpty {
                    pushError = err
                    onFailed("推送失败：\(err)")
                } else {
                    outcome?.pushed = true
                    onCompleted("已推送 commits")
                    dismiss()
                }
            } catch {
                pushError = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            pushing = false
        }
    }

    /// 工作区干净但 ahead > 0 时的「仅推送 commits」。
    private func pushCommitsOnly() {
        guard !pushing, !committing, !mergingWorktrees, !generating else { return }
        pushing = true
        onRunning()
        pushError = nil
        Task {
            do {
                let res = try await api.gitPush(
                    sessionId: sessionId,
                    pushCommits: true,
                    pushTags: false,
                    submodule: false,
                    tag: nil
                )
                if let err = res.error, !err.isEmpty {
                    pushError = err
                    onFailed(err)
                } else {
                    onCompleted("已推送 commits")
                    dismiss()
                }
            } catch {
                pushError = error.localizedDescription
                onFailed(error.localizedDescription)
            }
            pushing = false
        }
    }

    private func summaryText(_ outcome: CommitOutcome) -> String {
        let subPrefix = outcome.submoduleCount > 0 ? "已先提交 \(outcome.submoduleCount) 个 submodule，" : ""
        return subPrefix + "已提交"
            + (outcome.commitHash.isEmpty ? "" : " \(outcome.commitHash)")
            + (outcome.tagName.isEmpty ? "" : "，已打 Tag \(outcome.tagName)")
    }
}

// MARK: - 磁吸 dock

/// 力场 + 发射区：对齐网页 attachQuickCommitDrag 的手势语义。
/// 坐标系是力场（ZStack topLeading）的本地坐标，DragGesture 越界后仍持续上报，
/// 所以「拖出右缘 = 悬在发射区上」的 hot 判定与网页 pointInLaunch 等价。
private struct MagneticDockView: View {
    let hasChanges: Bool
    let hasSubmodule: Bool
    let hasWorktrees: Bool
    let ahead: Int
    let busy: Bool
    let feedback: String?
    let onAction: (String, Bool) -> Void
    let onWorktree: () -> Void
    let onPush: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let actionOrder = ["commit", "tag", "push"]
    private var allIds: [String] { Self.actionOrder + (hasSubmodule ? ["sub"] : []) + ["worktree"] }

    private func isEnabled(_ id: String) -> Bool {
        !busy && (id == "worktree" ? hasWorktrees : id == "push" ? hasChanges || ahead > 0 : hasChanges)
    }

    private static let chipColors: [String: Color] = [
        "commit": Theme.brand,
        "tag": Theme.info,
        "push": Theme.success,
        "sub": Theme.textSecondary,
        "worktree": Theme.info,
    ]
    private static let chipLabels: [String: String] = [
        "commit": "Commit", "tag": "Tag", "push": "Push", "sub": "Sub", "worktree": "Worktree",
    ]

    @State private var fieldSize: CGSize = .zero
    @State private var chipSizes: [String: CGSize] = [:]
    @State private var chipPos: [String: CGPoint] = [:]
    @State private var placed = false
    @State private var dragAnchor: String?
    @State private var dragMembers: [String]?
    @State private var dragMoved = false
    @State private var hot = false
    @State private var clusterBox: CGRect?

    private var composedAction: String {
        Self.compose(dragMembers ?? [])
    }

    private var launchTone: Color {
        switch composedAction {
        case "commit-tag": return Self.chipColors["tag"] ?? Theme.brand
        case "commit-push": return Self.chipColors["push"] ?? Theme.brand
        case "commit-tag-push": return Self.chipColors["sub"] ?? Theme.brand
        default: return Theme.brand
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                field
                    .frame(width: max(0, geo.size.width - 84))
                launchPad
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    // MARK: 力场

    private var field: some View {
        ZStack(alignment: .topLeading) {
            // 队伍光环（多球抱团时的描边框）
            if let box = clusterBox {
                RoundedRectangle(cornerRadius: 12)
                    .fill(launchTone.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(launchTone.opacity(0.4), lineWidth: 1))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            ForEach(allIds, id: \.self) { id in
                chipView(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        )
        .coordinateSpace(name: "qcdock")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        fieldSize = geo.size
                        placeHome(animated: false)
                    }
                    .onChange(of: geo.size) { newSize in
                        fieldSize = newSize
                        if dragAnchor == nil { placeHome(animated: false) }
                    }
            }
        )
        .onPreferenceChange(ChipSizeKey.self) { sizes in
            for (k, v) in sizes { chipSizes[k] = v }
            if dragAnchor == nil { placeHome(animated: false) }
        }
        .zIndex(1)
    }

    private func chipView(_ id: String) -> some View {
        let color = Self.chipColors[id] ?? Theme.brand
        let active = dragMembers?.contains(id) == true
        let pos = chipPos[id] ?? .zero
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(Self.chipLabels[id] ?? id)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(active ? color.opacity(0.16) : Theme.surface))
        .overlay(Capsule().stroke(color.opacity(active ? 0.7 : 0.32), lineWidth: 1.2))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ChipSizeKey.self, value: [id: geo.size])
            }
        )
        .opacity(!placed ? 0 : (isEnabled(id) ? 1 : 0.45))
        .scaleEffect(active && !reduceMotion ? 1.06 : 1)
        .offset(x: pos.x, y: pos.y)
        .zIndex(active ? 3 : 2)
        .allowsHitTesting(isEnabled(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(id == "worktree" ? "合并全部 Worktree 到当前分支并推送" : (Self.chipLabels[id] ?? id))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled(id) else { return }
            if id == "worktree" { onWorktree() }
            else if id == "push" && !hasChanges { onPush() }
            else { let intent = Self.tapIntent(id); onAction(intent.0, intent.1) }
        }
        .highPriorityGesture(dragGesture(id))
    }

    // MARK: 发射区

    private var launchPad: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(launchTone)
            Text(feedback ?? (hot ? "松手执行" : "提交"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hot ? launchTone : Theme.textSecondary)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(hot ? launchTone.opacity(0.14) : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(launchTone.opacity(hot ? 0.85 : 0.3), lineWidth: 1.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if hasChanges && !busy && dragAnchor == nil { onAction("commit", false) }
        }
    }

    // MARK: 几何

    private var chipH: CGFloat { chipSizes.values.first?.height ?? 38 }
    private func w(_ id: String) -> CGFloat { chipSizes[id]?.width ?? 86 }

    /// 原位布局：无 Sub 时 ∧ 三角（Commit 顶中 / Tag 左下 / Push 右下），
    /// 有 Sub 时 2×2 网格 —— 对齐网页窄屏 homePositions()。
    private func homePositions() -> [String: CGPoint] {
        guard fieldSize.width > 0, fieldSize.height > 0 else { return [:] }
        let rows = CGFloat((allIds.count + 1) / 2)
        var positions: [String: CGPoint] = [:]
        for (index, id) in allIds.enumerated() {
            let row = CGFloat(index / 2)
            let column = CGFloat(index % 2)
            let centerX = fieldSize.width * (column == 0 ? 0.27 : 0.73)
            positions[id] = CGPoint(
                x: max(4, min(fieldSize.width - w(id) - 4, centerX - w(id) / 2)),
                y: max(4, (row + 0.5) * fieldSize.height / rows - chipH / 2))
        }
        return positions
    }

    private func placeHome(animated: Bool) {
        let homes = homePositions()
        guard !homes.isEmpty, allIds.allSatisfy({ chipSizes[$0] != nil }) else { return }
        if animated && !reduceMotion {
            withAnimation(Theme.Motion.structure) { chipPos = homes }
        } else {
            chipPos = homes
        }
        placed = true
    }

    // MARK: 手势

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("qcdock"))
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = id
                    dragMembers = [id]
                    dragMoved = false
                }
                guard dragAnchor == id else { return }
                var members = dragMembers ?? [id]
                let loc = value.location
                if !dragMoved,
                   hypot(value.translation.width, value.translation.height) > 6 {
                    dragMoved = true
                }
                guard dragMoved else { return }

                // 磁吸拾取：只吸主动作球 —— Sub 永不被「路过吸附」（默认不纳入），
                // 但可作为锚点被显式抓起、反向吸附动作球。
                let homes = homePositions()
                for cand in Self.actionOrder where id != "worktree" && hasChanges && !members.contains(cand) {
                    guard let hp = homes[cand] else { continue }
                    let center = CGPoint(x: hp.x + w(cand) / 2, y: hp.y + chipH / 2)
                    if hypot(loc.x - center.x, loc.y - center.y) < 58 {
                        members.append(cand)
                    }
                }
                dragMembers = members

                // 拖动中的队伍层叠显示；标签无需完整可读，露出的前缘足以表示已吸附。
                let ids = allIds.filter { members.contains($0) }
                let stackStep: CGFloat = 24
                let widest = ids.map(w).max() ?? 0
                let total = widest + stackStep * CGFloat(max(0, ids.count - 1))
                let h = chipH
                let y = min(max(loc.y - h / 2, 2), max(2, fieldSize.height - h - 2))
                var x = loc.x - total / 2
                for cid in ids {
                    chipPos[cid] = CGPoint(x: x, y: y)
                    x += stackStep
                }
                clusterBox = ids.count > 1
                    ? CGRect(x: loc.x - total / 2 - 7, y: y - 7, width: total + 14, height: h + 14)
                    : nil

                // 拖出场地右缘 → 悬在发射区上方（hot）。
                let nowHot = loc.x > fieldSize.width + 4
                if nowHot && !hot {
                }
                hot = nowHot
            }
            .onEnded { _ in
                guard dragAnchor == id else { return }
                let members = dragMembers ?? [id]
                let endHot = hot
                let moved = dragMoved
                dragAnchor = nil
                dragMembers = nil
                dragMoved = false
                hot = false
                clusterBox = nil
                placeHome(animated: true)

                if !moved {
                    // 原地单击 → 直接执行该气泡自己的动作。
                    if id == "worktree" { onWorktree() }
                    else if id == "push" && !hasChanges { onPush() }
                    else { let intent = Self.tapIntent(id); onAction(intent.0, intent.1) }
                } else if endHot {
                    // 丢进发射区 → 执行组合动作（commit 永远隐含）。
                    if id == "worktree" { onWorktree() }
                    else if id == "push" && !hasChanges { onPush() }
                    else { onAction(Self.compose(members), members.contains("sub")) }
                }
                // 松手在别处：placeHome 已让全员弹回，不执行任何动作。
            }
    }

    // MARK: 动作合成

    private static func compose(_ members: [String]) -> String {
        let hasTag = members.contains("tag")
        let hasPush = members.contains("push")
        if hasTag && hasPush { return "commit-tag-push" }
        if hasTag { return "commit-tag" }
        if hasPush { return "commit-push" }
        return "commit"
    }

    /// 单击气泡的直发动作（tag/push 隐含 commit；sub 是正交 scope 修饰符）。
    private static func tapIntent(_ id: String) -> (String, Bool) {
        switch id {
        case "tag": return ("commit-tag", false)
        case "push": return ("commit-push", false)
        case "sub": return ("commit", true)
        default: return ("commit", false)
        }
    }
}

/// 气泡尺寸测量（PreferenceKey 聚合所有气泡）。
private struct ChipSizeKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}
