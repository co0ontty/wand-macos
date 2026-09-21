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
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建任务")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .windowDrag()
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.projectHint.map { "在「\($0)」中创建任务。" }
                         ?? "目录留空时使用全局临时目录。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("任务名称（可选）")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        TextField("留空则自动命名", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focusedField, equals: "name")
                            .padding(12)
                            .wandInputSurface(focused: focusedField == "name", cornerRadius: Theme.Radius.control)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("工作目录")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        TextField(request.projectHint == nil ? "留空则使用全局临时目录" : "例如：/home/user/wand", text: $cwd)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focusedField, equals: "cwd")
                            .padding(12)
                            .wandInputSurface(focused: focusedField == "cwd", cornerRadius: Theme.Radius.control)
                    }
                    if !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("使用独立工作树")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Text(worktreeEnabled
                                    ? "任务在独立分支中运行，完成后可以审查并合并。"
                                    : "会话直接使用任务目录。")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Toggle("使用独立工作树", isOn: $worktreeEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Theme.wandAccent)
                                .onChange(of: worktreeEnabled) { enabled in
                                    store.rememberCreationChoice(worktree: enabled)
                                }
                        }
                    }
                    Rectangle().fill(Theme.border).frame(height: 0.5)
                    Picker("工具", selection: $target) {
                        ForEach(WorkspaceSessionTarget.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .onChange(of: target) { value in
                        store.rememberCreationChoice(provider: value)
                    }
                    if target != .shell {
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
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 13))
                .padding(24)
                .disabled(creating)
                .wandMotion(value: target == .shell, layout: true)
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(creating)
                Button {
                    Task { await submit() }
                } label: {
                    Text(creating ? "创建中…" : "创建任务")
                        .frame(minWidth: 76)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(creating)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
        .frame(minHeight: 460, idealHeight: 520, maxHeight: 560)
        .background(Theme.workspaceBackground)
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
