import Combine
import SwiftUI

/// 会话级 Git 状态的单一数据源。顶栏徽标、右侧 Git 面板和快捷提交回调都通过
/// 同一个 store 刷新，避免各自请求后长期显示互相矛盾的计数。
@MainActor
final class GitStatusStore: ObservableObject {
    @Published private(set) var statuses: [String: GitStatusResult] = [:]
    @Published private(set) var loadingSessions: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    private var generations: [String: Int] = [:]

    func status(for sessionId: String) -> GitStatusResult? { statuses[sessionId] }
    func isLoading(_ sessionId: String) -> Bool { loadingSessions.contains(sessionId) }
    func error(for sessionId: String) -> String? { errors[sessionId] }

    func refresh(sessionId: String, api: WandAPI) async {
        let generation = (generations[sessionId] ?? 0) + 1
        generations[sessionId] = generation
        loadingSessions.insert(sessionId)
        defer {
            if generations[sessionId] == generation {
                loadingSessions.remove(sessionId)
            }
        }
        do {
            let next = try await api.gitStatus(sessionId: sessionId)
            guard generations[sessionId] == generation else { return }
            statuses[sessionId] = next
            errors[sessionId] = nil
        } catch {
            guard generations[sessionId] == generation else { return }
            errors[sessionId] = error.localizedDescription
        }
    }
}

/// 横屏 native 右栏容器:三 tab(文件 / Git / 详情),每个 tab 一个独立视图。
/// 文件 tab 走 FileTreeView;Git tab 走 SessionGitStatusView;详情 tab 走 SessionDetailsView。
/// 主壳 `MainShellView` 的 `rightColumn` 直接挂这个 view。

struct FilePanelView: View {
    let sessionId: String?
    let api: WandAPI
    let session: SessionSnapshot?
    /// 文件栏的实际根目录；会话快照未到时由调用方用侧栏摘要里的 cwd 兜底。
    var rootPath: String? = nil
    /// 会话已选定、工作目录还在读：文件树只等目录，不请求默认目录。
    var rootPathPending = false
    @ObservedObject var gitStatusStore: GitStatusStore
    @Binding var tab: MainShellView.RightPanelTab

    var body: some View {
        switch tab {
        case .files:
            FileTreeView(
                api: api,
                sessionId: sessionId,
                rootPath: rootPath,
                isResolvingRoot: rootPathPending
            )
        case .git:
            if let id = sessionId {
                SessionGitStatusView(sessionId: id, api: api, gitStatusStore: gitStatusStore)
            } else {
                EmptyTabState(systemImage: "arrow.triangle.branch", label: "选择一个会话以查看 Git 状态")
            }
        case .details:
            if let s = session {
                SessionDetailsView(session: s, api: api)
            } else {
                EmptyTabState(systemImage: "info.circle", label: "选择一个会话以查看详情")
            }
        }
    }
}

struct EmptyTabState: View {
    let systemImage: String
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Git 状态 tab

enum GitStatusPresentation: Equatable {
    case loading
    case failure(String)
    case nonRepository
    case unavailable
    case clean
    case dirty

    static func resolve(status: GitStatusResult?, loading: Bool, error: String?) -> Self {
        if loading && status == nil { return .loading }
        if let error, !error.isEmpty { return .failure(error) }
        guard let status else { return .unavailable }
        if let error = status.error, !error.isEmpty { return .failure(error) }
        guard status.isGit else { return .nonRepository }
        if !(status.files ?? []).isEmpty || (status.modifiedCount ?? 0) > 0 { return .dirty }
        if status.files != nil || status.modifiedCount == 0 { return .clean }
        return .unavailable
    }

    func permitsCommit(loading: Bool) -> Bool { self == .dirty && !loading }
}

struct SessionGitStatusView: View {
    let sessionId: String
    let api: WandAPI
    @ObservedObject var gitStatusStore: GitStatusStore
    @State private var showQuickCommit = false

    private var status: GitStatusResult? { gitStatusStore.status(for: sessionId) }
    private var loading: Bool { gitStatusStore.isLoading(sessionId) }
    private var loadError: String? { gitStatusStore.error(for: sessionId) }
    private var presentation: GitStatusPresentation {
        .resolve(status: status, loading: loading, error: loadError)
    }

    // MARK: - 聚合计数(从 files 数组按 status 字符统计)

    private struct Counts {
        var modified = 0
        var added = 0
        var deleted = 0
        var untracked = 0
        var renamed = 0
        var conflicted = 0
        var other = 0
    }

    private func aggregate(_ status: GitStatusResult) -> Counts {
        var c = Counts()
        for entry in status.files ?? [] {
            let s = entry.status
            // porcelain v2: 第一字符 staged,第二字符 unstaged,??" untracked
            let unstaged = s.count > 1 ? s[s.index(s.startIndex, offsetBy: 1)] : " "
            let staged = s.first ?? " "
            if s == "??" || unstaged == "?" {
                c.untracked += 1
            } else if s.contains("U") || s == "AA" || s == "DD" {
                c.conflicted += 1
            } else if s.contains("R") {
                c.renamed += 1
            } else if unstaged == "M" || staged == "M" {
                c.modified += 1
            } else if staged == "A" {
                c.added += 1
            } else if staged == "D" || unstaged == "D" {
                c.deleted += 1
            } else {
                c.other += 1
            }
        }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 0.5)
            content
        }
        .background(Theme.background)
        .task(id: sessionId) { await gitStatusStore.refresh(sessionId: sessionId, api: api) }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: sessionId,
                api: api,
                onCompleted: { _ in
                    Task { await gitStatusStore.refresh(sessionId: sessionId, api: api) }
                },
                onFailed: { _ in
                    Task { await gitStatusStore.refresh(sessionId: sessionId, api: api) }
                }
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Git 状态")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if presentation == .dirty {
                Button {
                    showQuickCommit = true
                } label: {
                    Label("快捷提交", systemImage: "arrow.up.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.wandAccent)
                        .padding(.horizontal, 6)
                        .frame(height: 30)
                }
                .buttonStyle(DesktopNavigationButtonStyle())
                .disabled(!presentation.permitsCommit(loading: loading))
            }
            Button {
                Task { await gitStatusStore.refresh(sessionId: sessionId, api: api) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(WandIconButtonStyle())
            .disabled(loading)
            .help(loading ? "正在刷新 Git 状态" : "刷新 Git 状态")
            .accessibilityLabel("刷新 Git 状态")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .loading:
            VStack {
                Spacer()
                ProgressView().controlSize(.small).tint(Theme.wandAccent)
                Spacer()
            }
        case .failure(let message):
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    Task { await gitStatusStore.refresh(sessionId: sessionId, api: api) }
                }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(loading)
                Spacer()
            }
            .padding(20)
        case .nonRepository:
            EmptyTabState(systemImage: "folder", label: "此目录未启用 Git")
        case .unavailable:
            EmptyTabState(systemImage: "arrow.triangle.branch", label: "暂无可用的 Git 状态")
        case .clean, .dirty:
            if let s = status {
                VStack(alignment: .leading, spacing: 0) {
                    if let branch = s.branch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textMuted)
                            Text(branch)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    if presentation == .clean {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.success)
                            Text("工作区干净")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(12)
                    } else if !(s.files ?? []).isEmpty {
                        countsList(aggregate(s))
                    } else {
                        Text("有 \(s.modifiedCount ?? 0) 项未提交改动")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func countsList(_ c: Counts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            countRow(symbol: "plus.circle.fill", color: Theme.success, label: "新增", count: c.added)
            countRow(symbol: "pencil.circle.fill", color: Theme.warning, label: "修改", count: c.modified)
            countRow(symbol: "minus.circle.fill", color: Theme.danger, label: "删除", count: c.deleted)
            countRow(symbol: "questionmark.circle.fill", color: Theme.textMuted, label: "未跟踪", count: c.untracked)
            if c.renamed > 0 {
                countRow(symbol: "arrow.right.circle.fill", color: Theme.textSecondary, label: "重命名", count: c.renamed)
            }
            if c.conflicted > 0 {
                countRow(symbol: "exclamationmark.circle.fill", color: Theme.danger, label: "冲突", count: c.conflicted)
            }
            if c.other > 0 {
                countRow(symbol: "ellipsis.circle.fill", color: Theme.textSecondary, label: "其他改动", count: c.other)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func countRow(symbol: String, color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
        }
    }

}

// MARK: - 详情 tab

struct SessionDetailsView: View {
    let session: SessionSnapshot
    let api: WandAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("详情")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailRow("会话 ID", session.id, mono: true)
                    detailRow("工具", session.providerLabel)
                    detailRow("模式", session.mode ?? "—")
                    detailRow("类型", session.isStructured ? "结构化" : "PTY")
                    if let cwd = session.cwd {
                        detailRow("工作目录", cwd, mono: true)
                    }
                    if let model = session.selectedModel, !model.isEmpty {
                        detailRow("模型", model, mono: true)
                    }
                    if let eff = session.thinkingEffort {
                        detailRow("思考深度", eff)
                    }
                    detailRow("状态", session.status ?? "—")
                    if let started = session.startedAt {
                        detailRow("开始时间", started, mono: true)
                    }
                }
                .padding(14)
            }
        }
        .background(Theme.background)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
