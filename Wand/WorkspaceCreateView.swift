import SwiftUI

/// 新建项目 sheet：名称 + 服务器目录 + 默认 Agent。
/// 目录走服务端路径（可远程），浏览器用已有 DirectoryBrowserView。
struct WorkspaceCreateView: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let onCreated: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var defaultProvider: WandProvider = .claude
    @State private var recentPaths: [WorkspaceRecentPath] = []
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fieldLabel("项目名称")
                    TextField("例如：Wand", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(fieldBackground)

                    fieldLabel("项目目录")
                    HStack(spacing: 8) {
                        TextField("服务器上的路径，例如 /Users/you/project", text: $cwd)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        Button("浏览…") { showBrowser = true }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(fieldBackground)

                    if !recentPaths.isEmpty {
                        fieldLabel("最近使用")
                        VStack(spacing: 4) {
                            ForEach(recentPaths.prefix(5)) { item in
                                Button {
                                    cwd = item.path
                                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        name = item.name
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textMuted)
                                        Text(item.path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Theme.surface.opacity(0.7))
                                )
                            }
                        }
                    }

                    fieldLabel("默认 Agent")
                    HStack(spacing: 8) {
                        ForEach(WandProvider.allCases) { provider in
                            providerChip(provider)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                    }
                }
                .padding(22)
            }
            Divider().opacity(0.35)
            sheetFooter
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 520)
        .background(WandAmbientBackground())
        .hideNativeTitleBar()
        .sheet(isPresented: $showBrowser) {
            DirectoryBrowserView(api: api, startPath: cwd) { picked in
                cwd = picked
                showBrowser = false
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = (picked as NSString).lastPathComponent
                }
            }
        }
        .task {
            if let provider = try? await api.workspaceDefaultProvider() {
                defaultProvider = provider
            }
            if let recent = try? await api.workspaceRecentPaths() {
                recentPaths = recent
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCwd: String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !creating && !trimmedName.isEmpty && !trimmedCwd.isEmpty
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
    }

    private func providerChip(_ provider: WandProvider) -> some View {
        let selected = defaultProvider == provider
        return Button {
            defaultProvider = provider
        } label: {
            VStack(spacing: 6) {
                BrandLogo(
                    provider: provider.rawValue,
                    color: selected ? Theme.wandAccent : Theme.textSecondary
                )
                .frame(width: 18, height: 18)
                Text(provider.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? Theme.wandAccent : Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.wandAccent.opacity(0.08) : Theme.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.wandAccent : Theme.border, lineWidth: selected ? 1.4 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating)
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("新建项目")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("锚定一个目录，任务会在独立 worktree 里跑")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Theme.workspaceBackground)
        .contentShape(Rectangle())
        .windowDrag()
    }

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(creating)
            Button {
                Task { await submit() }
            } label: {
                Text(creating ? "创建中…" : "创建项目")
                    .frame(minWidth: 88)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.workspaceBackground)
    }

    private func submit() async {
        guard canSubmit else { return }
        creating = true
        errorMessage = nil
        do {
            let created = try await store.createWorkspace(
                name: trimmedName,
                cwd: trimmedCwd,
                defaultProvider: defaultProvider
            )
            creating = false
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            creating = false
        }
    }
}
