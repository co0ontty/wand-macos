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
    @State private var target: WorkspaceSessionTarget = .claude
    @State private var sessionKind: WorkspaceSessionKind = .structured
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
                    Text("将在目录「\(hint)」下创建任务。创建时必须选择 CLI。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("可以不选目录（使用全局临时目录）。创建任务时必须选择 CLI。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("任务名称（可选）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    TextField("留空则由系统自动命名", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("任务目录")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    TextField(request.projectHint == nil ? "留空则使用全局临时目录" : "例如：/home/user/wand", text: $cwd)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                if !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        .onChange(of: worktreeEnabled) { enabled in
                            store.rememberCreationChoice(worktree: enabled)
                        }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(worktreeEnabled ? Theme.wandAccent.opacity(0.4) : Theme.border.opacity(0.6), lineWidth: 1)
                )
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLI 工具")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Picker("CLI", selection: $target) {
                        ForEach(WorkspaceSessionTarget.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: target) { value in
                        store.rememberCreationChoice(provider: value)
                    }
                }
                if target != .shell {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("会话类型")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Picker("会话类型", selection: $sessionKind) {
                            ForEach(WorkspaceSessionKind.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: sessionKind) { value in
                            store.rememberCreationChoice(kind: value)
                        }
                    }
                }
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
                .disabled(creating)
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
                target = store.selectedTarget
                sessionKind = store.selectedKind
            }
        }
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        defer { creating = false }
        do {
            let directory = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            store.rememberCreationChoice(provider: target, kind: sessionKind)
            // 名称可选：留空时服务端先用「未命名任务」，看板再按会话内容自动补标题。
            let (workspace, creation) = try await store.createTask(
                name: trimmed,
                directory: directory,
                worktree: directory.isEmpty ? false : (worktreeEnabled ? nil : false),
                workspaceId: request.workspaceId
            )
            dismiss()
            onCreated(workspace, creation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
