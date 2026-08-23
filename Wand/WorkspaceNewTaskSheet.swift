import SwiftUI

/// 新建任务表单（macOS sheet 主体）：名称 + 目录 + worktree 隔离开关。
/// 目录按 find-or-create 归入隐式项目；git 仓库默认生成独立 worktree，
/// 可通过开关显式关闭（服务端 `worktree: false`）。对齐 web/iOS 同名流程。
struct NewTaskSheetBody: View {
    let request: NewTaskSheetRequest
    @ObservedObject var store: WorkspaceStore
    let onCreated: (Workspace, WorkspaceTaskCreation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var worktreeEnabled = true
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新任务")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(16)
            .windowDrag()
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 12) {
                if let hint = request.projectHint {
                    Text("将在项目「\(hint)」下创建任务。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("任务归属所选目录；之后在任务里新建会话无需再选目录。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("任务名称")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    TextField("例如：重构会话恢复流程", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("任务目录")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    TextField("例如：/home/user/wand", text: $cwd)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(worktreeEnabled ? Theme.wandAccent : Theme.textMuted)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(worktreeEnabled ? Theme.wandAccent.opacity(0.12) : Theme.surface)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("独立 worktree 隔离")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(worktreeEnabled
                            ? "为任务创建独立分支与工作树，改动隔离、可审查后合并。"
                            : "会话直接运行在任务目录；非 git 目录自动用这种模式。")
                            .font(.system(size: 10.5))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $worktreeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.wandAccent)
                        .onChange(of: worktreeEnabled) { _, enabled in
                            store.rememberCreationChoice(worktree: enabled)
                        }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(worktreeEnabled ? Theme.wandAccent.opacity(0.4) : Theme.border.opacity(0.6), lineWidth: 1)
                )
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(16)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(creating)
                Button(creating ? "创建中…" : "创建") {
                    Task { await submit() }
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(WandAmbientBackground())
        .hideNativeTitleBar()
        .onAppear {
            cwd = request.cwd
            worktreeEnabled = store.defaultTaskWorktree
            Task {
                await store.loadCreationDefaults()
                worktreeEnabled = store.defaultTaskWorktree
            }
        }
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creating = true
        defer { creating = false }
        do {
            let directory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let (workspace, creation) = try await store.createTask(
                name: trimmed,
                directory: directory,
                worktree: worktreeEnabled ? nil : false
            )
            dismiss()
            onCreated(workspace, creation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
