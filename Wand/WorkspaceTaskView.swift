import SwiftUI

/// 主栏任务窗：Orca 风格的标签条 + 当前工作窗口。
/// 桌面端去掉 iOS 导航栏，标签和空态直接铺在工作区里。
struct WorkspaceTaskView: View {
    let workspace: Workspace
    let task: WorkspaceTask
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gitStatusStore: GitStatusStore

    var body: some View {
        ZStack {
            Theme.workspaceBackground
            content
        }
        .sheet(isPresented: pickerBinding) {
            WorkspaceTargetPicker(store: store, taskId: task.id)
        }
        .task(id: task.id) {
            await store.openTask(workspace: workspace, task: task)
        }
    }

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { store.pickerPresented && store.currentTask?.id == task.id },
            set: { presented in if !presented { store.dismissTargetPicker() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        if store.currentTask?.id != task.id {
            loadingState("正在打开任务…")
        } else {
            switch store.taskState {
            case .idle, .loading:
                loadingState("正在恢复任务上下文…")
            case .failed(let message):
                errorState(message)
            case .empty(let detail):
                emptyTask(detail)
            case .ready(let detail):
                readyTask(detail)
            }
        }
    }

    private func emptyTask(_ detail: WorkspaceTaskDetail) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Text(workspace.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.wandAccent)
            Image(systemName: "terminal")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(Theme.wandAccent)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.wandAccent.opacity(0.10))
                )
            Text(detail.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(detail.isIsolated ? "独立 worktree 已就绪" : "使用项目共享目录")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Button {
                store.presentTargetPicker()
            } label: {
                Label("选择工作窗口", systemImage: "plus")
                    .frame(minWidth: 200)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("工作目录")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Text(detail.cwd)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .padding(.top, 10)

            if let warning = detail.worktreeError, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 8)
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readyTask(_ detail: WorkspaceTaskDetail) -> some View {
        VStack(spacing: 0) {
            if let warning = store.layoutWarning {
                warningBanner(warning)
            }
            sessionStrip(detail.sessions)
            Rectangle()
                .fill(Color(nsColor: Theme.borderSubtle))
                .frame(height: 0.5)
            sessionContent
        }
    }

    private func sessionStrip(_ sessions: [WorkspaceSessionSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    let selected = store.visibleSessionID == session.id
                    Button {
                        Task { await store.selectSession(id: session.id) }
                    } label: {
                        HStack(spacing: 7) {
                            BrandLogo(
                                provider: session.provider ?? "terminal",
                                color: selected ? Theme.wandAccent : Theme.textSecondary
                            )
                            .frame(width: 13, height: 13)
                            Text(sessionLabel(session, index: index))
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .lineLimit(1)
                            if ["initializing", "running", "thinking"].contains(session.status ?? "") {
                                Circle()
                                    .fill(Theme.success)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? Theme.textPrimary.opacity(0.08) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button { store.presentTargetPicker() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(WandIconButtonStyle())
                .help("新建工作窗口")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Theme.workspaceBackground)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if let snapshot = store.visibleSnapshot,
           snapshot.id == store.visibleSessionID {
            MainColumn(
                api: api,
                sessionId: snapshot.id,
                provider: snapshot.provider ?? "claude",
                session: snapshot,
                gitStatusStore: gitStatusStore,
                showsHeader: false
            )
            .id(snapshot.id)
        } else if store.sessionLoading {
            loadingState("正在加载工作窗口…")
        } else if let error = store.sessionError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.danger)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let id = store.visibleSessionID {
                    Button("重试") { Task { await store.selectSession(id: id) } }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadingState("正在选择工作窗口…")
        }
    }

    private func sessionLabel(_ session: WorkspaceSessionSummary, index: Int) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "\(session.providerLabel) \(index + 1)" : title
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { store.clearLayoutWarning() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.wandAccent.opacity(0.08))
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.wandAccent)
            Text(text)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.reloadCurrentTask() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
