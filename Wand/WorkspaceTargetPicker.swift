import SwiftUI

struct WorkspaceTargetPicker: View {
    @ObservedObject var store: WorkspaceStore
    let taskId: String
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded {
            VStack(spacing: 16) {
                pickerFields
                sheetFooter
            }
        } else {
            VStack(spacing: 0) {
                sheetHeader
                Rectangle().fill(Theme.border).frame(height: 0.5)
                ScrollView {
                    pickerFields
                        .padding(24)
                }
                Rectangle().fill(Theme.border).frame(height: 0.5)
                sheetFooter
            }
            .frame(minWidth: 460, idealWidth: 500, minHeight: 460, idealHeight: 520)
            .focusedSceneValue(\.wandDesktopCommandsEnabled, false)
            .background(Theme.workspaceBackground)
            .hideNativeTitleBar()
            .onChange(of: store.pickerPresented) { presented in
                if !presented { dismiss() }
            }
        }
    }

    private var pickerFields: some View {
        VStack(spacing: 4) {
            ForEach(WorkspaceSessionTarget.allCases) { target in
                targetRow(target)
            }
            if store.selectedTarget != .shell {
                kindPicker
            }
            if let error = store.creationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.danger.opacity(0.10))
                    )
            }
        }
        .wandMotion(value: store.selectedTarget == .shell, layout: true)
    }

    private func targetRow(_ target: WorkspaceSessionTarget) -> some View {
        let selected = store.selectedTarget == target
        return Button {
            guard !store.creating else { return }
            store.rememberCreationChoice(provider: target)
        } label: {
            HStack(spacing: 12) {
                BrandLogo(
                    provider: target.provider?.rawValue ?? "terminal",
                    color: selected ? Theme.wandAccent : Theme.textSecondary
                )
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.system(size: 13, weight: .medium))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(DesktopNavigationButtonStyle(active: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(store.creating)
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
                .padding(.vertical, 10)
            Picker("会话类型", selection: Binding(
                get: { store.selectedKind },
                set: { store.rememberCreationChoice(kind: $0) }
            )) {
                ForEach(WorkspaceSessionKind.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.creating)
            Text(store.selectedKind.summary)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("新建工作窗口")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("在当前任务目录中开始一个会话。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Theme.workspaceBackground)
        .contentShape(Rectangle())
        .windowDrag()
    }

    private var sheetFooter: some View {
        HStack {
            if !embedded {
                Button("取消") {
                    store.dismissTargetPicker()
                    dismiss()
                }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(store.creating)
                Spacer()
            }
            Button {
                Task { await store.createSelectedWindow(expectedTaskId: taskId) }
            } label: {
                Text(store.creating ? "创建中…" : "创建 \(store.selectedTarget.title)")
                    .frame(minWidth: 120)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(store.creating)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.workspaceBackground)
    }
}
