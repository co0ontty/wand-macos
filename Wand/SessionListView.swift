import SwiftUI

/// 会话列表：原生渲染 /api/sessions，下拉刷新 + 周期轮询，
/// 点击进入原生 ChatView，支持滑动删除与新建会话。
struct SessionListView: View {
    let api: WandAPI

    @State private var sessions: [SessionSnapshot] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var showNewSession = false
    @State private var showArchived = false

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { ($0.archived ?? false) == showArchived }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("会话范围", selection: $showArchived) {
                    Text("进行中").tag(false)
                    Text("已归档").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(10)
                Divider()
                content
            }
        }
        .navigationTitle("Wand")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSession = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.brand)
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(api: api) { newSession in
                showNewSession = false
                sessions.insert(newSession, at: 0)
            }
        }
        .task { await load() }
        .onReceive(refreshTimer) { _ in
            Task { await load(silent: true) }
        }
    }

    @ViewBuilder private var content: some View {
        if loading && sessions.isEmpty {
            ProgressView().tint(Theme.brand)
        } else if let error = loadError, sessions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.textSecondary)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
                    .buttonStyle(WandSecondaryButtonStyle())
                // macOS 15 已知问题：重启 Mac 后「本地网络」授权偶尔失效（开关
                // 显示打开但实际被拒），表现就是这里一直加载失败。给个入口。
                if LocalNetworkPermission.isEnforced {
                    Button("连不上？检查「本地网络」权限") {
                        LocalNetworkPermission.openSettings()
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                }
            }
            .padding(32)
        } else if visibleSessions.isEmpty {
            VStack(spacing: 14) {
                WandBrandMark(size: 52)
                Text(showArchived ? "没有已归档的会话" : "还没有会话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if !showArchived {
                    Button { showNewSession = true } label: {
                        Text("新建会话")
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                }
            }
        } else {
            List {
                ForEach(visibleSessions) { session in
                    ZStack {
                        NavigationLink(destination: ChatView(sessionId: session.id, api: api)) {
                            EmptyView()
                        }
                        .opacity(0)
                        SessionRow(session: session)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    .listRowBackground(Theme.background)
                    .compatHideListRowSeparator()
                }
                .onDelete(perform: deleteSessions)
            }
            .listStyle(.plain)
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        do {
            sessions = try await api.listSessions()
            loadError = nil
        } catch {
            if !silent || sessions.isEmpty {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }

    private func deleteSessions(at offsets: IndexSet) {
        let targets = offsets.map { visibleSessions[$0] }
        sessions.removeAll { snap in targets.contains { $0.id == snap.id } }
        Task {
            for target in targets {
                try? await api.deleteSession(id: target.id)
            }
        }
    }
}

// MARK: - 兼容封装

private extension View {
    /// `listRowSeparator` 是 macOS 13+ API，部署目标是 12.0，
    /// 老系统上降级为默认分隔线。
    @ViewBuilder
    func compatHideListRowSeparator() -> some View {
        if #available(macOS 13.0, *) {
            listRowSeparator(.hidden)
        } else {
            self
        }
    }
}

// MARK: - 列表行

private struct SessionRow: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 13) {
            providerMark
            VStack(alignment: .leading, spacing: 7) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(session.providerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(providerTint)
                    metadataLabel(
                        session.isStructured ? "聊天" : "终端",
                        icon: session.isStructured ? "bubble.left.fill" : "terminal.fill"
                    )
                    if !cwdTail.isEmpty {
                        Text(cwdTail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(statusTint.opacity(0.11)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 7, y: 2)
    }

    private var cwdTail: String {
        guard let cwd = session.cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).lastPathComponent
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(providerTint.opacity(0.13))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(providerTint.opacity(0.24), lineWidth: 1)
            Image(systemName: providerIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(providerTint)
        }
        .frame(width: 42, height: 42)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusTint)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
        .accessibilityLabel("\(session.providerLabel)，\(statusLabel)")
    }

    private func metadataLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.textSecondary)
    }

    private var providerIcon: String {
        session.provider == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkles"
    }

    private var providerTint: Color {
        session.provider == "codex" ? Color(red: 0.20, green: 0.45, blue: 0.72) : Theme.brand
    }

    private var statusTint: Color {
        if session.hasPendingPermission { return .orange }
        switch session.status ?? "" {
        case "running": return session.isResponding ? .green : Theme.brand
        case "idle": return Theme.brand.opacity(0.6)
        default: return .gray
        }
    }

    private var statusLabel: String {
        if session.hasPendingPermission { return "待授权" }
        if session.isResponding { return "回复中" }
        switch session.status ?? "" {
        case "running": return "运行中"
        case "idle": return "空闲"
        case "exited", "stopped": return "已结束"
        case "failed": return "失败"
        default: return session.status ?? ""
        }
    }
}
