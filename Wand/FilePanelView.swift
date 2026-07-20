import SwiftUI

/// 横屏 native 右栏容器:三 tab(文件 / Git / 详情),每个 tab 一个独立视图。
/// 文件 tab 走 FileTreeView;Git tab 走 SessionGitStatusView;详情 tab 走 SessionDetailsView。
/// 主壳 `MainShellView` 的 `rightColumn` 直接挂这个 view。

struct FilePanelView: View {
    let sessionId: String?
    let api: WandAPI
    let session: SessionSnapshot?
    @Binding var tab: MainShellView.RightPanelTab

    var body: some View {
        switch tab {
        case .files:
            FileTreeView(api: api)
        case .git:
            if let id = sessionId {
                SessionGitStatusView(sessionId: id, api: api)
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Git 状态 tab

struct SessionGitStatusView: View {
    let sessionId: String
    let api: WandAPI

    @State private var status: GitStatusResult?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showQuickCommit = false

    // MARK: - 聚合计数(从 files 数组按 status 字符统计)

    private struct Counts {
        var modified = 0
        var added = 0
        var deleted = 0
        var untracked = 0
        var total: Int { modified + added + deleted + untracked }
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
            } else if unstaged == "M" || staged == "M" {
                c.modified += 1
            } else if staged == "A" {
                c.added += 1
            } else if staged == "D" || unstaged == "D" {
                c.deleted += 1
            }
        }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .background(Theme.background)
        .task { await reload() }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: sessionId,
                api: api,
                onCompleted: { _ in
                    Task { await reload() }
                },
                onFailed: { _ in
                    Task { await reload() }
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
            if let s = status, aggregate(s).total > 0 {
                Button {
                    showQuickCommit = true
                } label: {
                    Label("快捷提交", systemImage: "arrow.up.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.wandAccent)
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if loading && status == nil {
            VStack {
                Spacer()
                ProgressView().controlSize(.small).tint(Theme.wandAccent)
                Spacer()
            }
        } else if let loadError {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(Theme.warning)
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
        } else if let s = status {
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
                if aggregate(s).total == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.success)
                        Text("工作区干净")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(12)
                } else {
                    countsList(aggregate(s))
                }
                Spacer()
            }
        } else {
            EmptyTabState(systemImage: "arrow.triangle.branch", label: "无 Git 状态")
        }
    }

    @ViewBuilder
    private func countsList(_ c: Counts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            countRow(symbol: "plus.circle.fill", color: Theme.success, label: "新增", count: c.added)
            countRow(symbol: "pencil.circle.fill", color: Theme.warning, label: "修改", count: c.modified)
            countRow(symbol: "minus.circle.fill", color: Theme.danger, label: "删除", count: c.deleted)
            countRow(symbol: "questionmark.circle.fill", color: Theme.textMuted, label: "未跟踪", count: c.untracked)
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

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            status = try await api.gitStatus(sessionId: sessionId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
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
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("会话 ID", session.id, mono: true)
                    detailRow("Provider", session.providerLabel)
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
                .padding(12)
            }
        }
        .background(Theme.background)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }
}
