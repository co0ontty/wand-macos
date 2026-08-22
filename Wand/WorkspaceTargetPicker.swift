import SwiftUI

struct WorkspaceTargetPicker: View {
    @ObservedObject var store: WorkspaceStore
    let taskId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().opacity(0.35)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(WorkspaceSessionTarget.allCases) { target in
                        targetRow(target)
                    }
                    if let error = store.creationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.danger.opacity(0.10))
                            )
                    }
                }
                .padding(20)
            }
            Divider().opacity(0.35)
            sheetFooter
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 580)
        .background(WandAmbientBackground())
        .hideNativeTitleBar()
        .onChange(of: store.pickerPresented) { presented in
            if !presented { dismiss() }
        }
    }

    private func targetRow(_ target: WorkspaceSessionTarget) -> some View {
        let selected = store.selectedTarget == target
        return Button {
            guard !store.creating else { return }
            store.selectedTarget = target
        } label: {
            HStack(spacing: 12) {
                BrandLogo(
                    provider: target.provider?.rawValue ?? "terminal",
                    color: selected ? Theme.wandAccent : Theme.textSecondary
                )
                .frame(width: 20, height: 20)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Theme.wandAccent.opacity(0.12) : Theme.surface)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selected ? Theme.wandAccent : Theme.textPrimary)
                    Text(target.summary)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(selected ? Theme.wandAccent : Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.wandAccent.opacity(0.06) : Theme.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.wandAccent : Theme.border, lineWidth: selected ? 1.4 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.creating)
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("新建工作窗口")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("在当前任务的 worktree 里启动一个 Agent 或终端")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.workspaceBackground)
        .contentShape(Rectangle())
        .windowDrag()
    }

    private var sheetFooter: some View {
        HStack {
            Button("取消") {
                store.dismissTargetPicker()
                dismiss()
            }
            .buttonStyle(WandSecondaryButtonStyle())
            .disabled(store.creating)
            Spacer()
            Button {
                Task { await store.createSelectedWindow(expectedTaskId: taskId) }
            } label: {
                Text(store.creating ? "创建中…" : "创建 \(store.selectedTarget.title)")
                    .frame(minWidth: 120)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(store.creating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.workspaceBackground)
    }
}
