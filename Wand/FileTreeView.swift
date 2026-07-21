import AppKit
import SwiftUI

/// 原生文件浏览器:把 web 端的 `.file-panel`(.file-tree)搬到 SwiftUI。
/// 数据从 `/api/directory` 拉;以所选会话的工作目录为根，支持任意深度展开/折叠。
/// Git 状态展示交给 FilePanelView 的 git tab 处理(直接调现有的 `getSessionGitStatus`)。

struct FileTreeView: View {
    let api: WandAPI
    /// 用 sessionId + cwd 共同作为重载键：不同会话即使工作目录相同，也要重新拉取目录。
    let sessionId: String?
    /// 会话的工作目录；为空时由服务端使用默认工作目录。
    let rootPath: String?

    @State private var items: [DirectoryItem] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var expandedDirs: Set<String> = []
    /// 各子目录的缓存项,key 是绝对路径。
    @State private var childCache: [String: [DirectoryItem]] = [:]
    @State private var childLoading: Set<String> = []
    @State private var rootGeneration = 0
    @State private var activeListingRequest = UUID()
    @State private var selectedFile: FileTreeRow.RowItem?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let loadError {
                        errorState(loadError)
                    } else if loading && items.isEmpty {
                        loadingState
                    } else {
                        ForEach(items) { item in
                            FileTreeRow(
                                item: FileTreeRow.RowItem(item),
                                depth: 0,
                                expandedDirs: $expandedDirs,
                                childCache: $childCache,
                                childLoading: $childLoading,
                                onToggle: toggle,
                                onShowFileInfo: showFileInfo
                            )
                        }
                        if items.isEmpty && !loading {
                            emptyState
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .task(id: rootLoadKey) { await reload() }
        .sheet(item: $selectedFile) { file in
            FileInfoSheet(file: file)
        }
    }

    // MARK: - 顶部面包屑

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            Text(displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
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
            .help("刷新")
        }
    }

    private var displayPath: String {
        effectiveRootPath.isEmpty ? "服务器默认目录" : effectiveRootPath
    }

    private var effectiveRootPath: String {
        rootPath ?? ""
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundColor(Theme.textMuted)
            Text("空目录")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.wandAccent)
            Text("正在读取文件…")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在读取文件")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await reload() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: - 展开/折叠

    private func toggle(_ item: FileTreeRow.RowItem) {
        guard item.isDirectory else { return }
        if expandedDirs.contains(item.path) {
            expandedDirs.remove(item.path)
        } else {
            expandedDirs.insert(item.path)
            if childCache[item.path] == nil && !childLoading.contains(item.path) {
                Task { await loadChildren(of: item.path) }
            }
        }
    }

    private func showFileInfo(_ item: FileTreeRow.RowItem) {
        guard !item.isDirectory else { return }
        selectedFile = item
    }

    // MARK: - 数据加载

    private func reload() async {
        let rootKey = rootLoadKey
        let path = effectiveRootPath
        rootGeneration += 1
        let generation = rootGeneration
        let requestID = UUID()
        activeListingRequest = requestID
        loading = true
        loadError = nil
        items = []
        // 换会话或手动刷新时清掉展开态和缓存，避免跨目录的陈旧节点。
        expandedDirs.removeAll()
        childCache.removeAll()
        childLoading.removeAll()
        selectedFile = nil
        do {
            let listing = try await api.listDirectory(path)
            guard isCurrentRootRequest(
                generation: generation,
                requestID: requestID,
                rootKey: rootKey
            ) else { return }
            items = listing.items
        } catch {
            guard isCurrentRootRequest(
                generation: generation,
                requestID: requestID,
                rootKey: rootKey
            ) else { return }
            loadError = error.localizedDescription
            items = []
        }
        guard isCurrentRootRequest(
            generation: generation,
            requestID: requestID,
            rootKey: rootKey
        ) else { return }
        loading = false
    }

    private func loadChildren(of path: String) async {
        let rootKey = rootLoadKey
        let generation = rootGeneration
        childLoading.insert(path)
        do {
            let listing = try await api.listDirectory(path)
            guard isCurrentRoot(generation: generation, rootKey: rootKey) else { return }
            childCache[path] = listing.items
        } catch {
            guard isCurrentRoot(generation: generation, rootKey: rootKey) else { return }
            childCache[path] = []
        }
        guard isCurrentRoot(generation: generation, rootKey: rootKey) else { return }
        childLoading.remove(path)
    }

    private var rootLoadKey: FileTreeRootKey {
        FileTreeRootKey(sessionId: sessionId, rootPath: effectiveRootPath)
    }

    private func isCurrentRootRequest(
        generation: Int,
        requestID: UUID,
        rootKey: FileTreeRootKey
    ) -> Bool {
        !Task.isCancelled
            && rootGeneration == generation
            && activeListingRequest == requestID
            && rootLoadKey == rootKey
    }

    private func isCurrentRoot(generation: Int, rootKey: FileTreeRootKey) -> Bool {
        !Task.isCancelled && rootGeneration == generation && rootLoadKey == rootKey
    }
}

private struct FileTreeRootKey: Hashable {
    let sessionId: String?
    let rootPath: String
}

// MARK: - 递归行(支持任意深度嵌套)

/// 单个文件/目录行,目录展开后递归渲染子节点。
/// 展开态/子目录缓存/加载态都由 FileTreeView 持有,这里通过 @Binding 共享读写,
/// 用命名 struct 自引用实现递归(避免 @ViewBuilder 计算属性自引用的 opaque type 报错)。
struct FileTreeRow: View {
    let item: RowItem
    let depth: Int
    @Binding var expandedDirs: Set<String>
    @Binding var childCache: [String: [DirectoryItem]]
    @Binding var childLoading: Set<String>
    let onToggle: (RowItem) -> Void
    let onShowFileInfo: (RowItem) -> Void

    var body: some View {
        let isDir = item.isDirectory
        let isExpanded = expandedDirs.contains(item.path)
        let isLoadingChildren = childLoading.contains(item.path)

        VStack(alignment: .leading, spacing: 0) {
            if isDir {
                Button {
                    onToggle(item)
                } label: {
                    rowLabel(isExpanded: isExpanded, isLoadingChildren: isLoadingChildren)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name)，文件夹")
                .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                .accessibilityHint(isExpanded ? "按下以折叠文件夹" : "按下以展开文件夹")
                .help(isExpanded ? "折叠文件夹" : "展开文件夹")
            } else {
                Button {
                    onShowFileInfo(item)
                } label: {
                    rowLabel(isExpanded: false, isLoadingChildren: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name)，文件")
                .accessibilityHint("按下以显示文件信息并复制服务器路径；不会打开或下载远端文件")
                .help("显示文件信息")
            }

            if isDir, isExpanded, let children = childCache[item.path] {
                ForEach(children) { child in
                    FileTreeRow(
                        item: RowItem(child),
                        depth: depth + 1,
                        expandedDirs: $expandedDirs,
                        childCache: $childCache,
                        childLoading: $childLoading,
                        onToggle: onToggle,
                        onShowFileInfo: onShowFileInfo
                    )
                }
            }
        }
    }

    private func rowLabel(isExpanded: Bool, isLoadingChildren: Bool) -> some View {
        HStack(spacing: 6) {
            if item.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: iconFor(item))
                .font(.system(size: 12))
                .foregroundColor(item.isDirectory ? Theme.wandAccent : Theme.textSecondary)
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 12, design: item.isDirectory ? .default : .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if item.isDirectory, isLoadingChildren {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * 14 + 12)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func iconFor(_ item: RowItem) -> String {
        if item.isDirectory { return "folder" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "js", "py", "go", "rs", "java", "kt", "c", "cpp", "h":
            return "doc.text"
        case "md", "txt":
            return "doc.plaintext"
        case "json", "yaml", "yml", "toml":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return "photo"
        default:
            return "doc"
        }
    }

    // MARK: - RowItem(从 DirectoryItem 转换的轻量行模型)

    struct RowItem: Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        var id: String { path }

        init(_ item: DirectoryItem) {
            self.path = item.path
            self.name = item.name
            self.isDirectory = item.isDirectory
        }
    }
}

private struct FileInfoSheet: View {
    let file: FileTreeRow.RowItem

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("文件信息", systemImage: "doc")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.wandAccent)
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                detailRow(label: "名称", value: file.name, monospaced: false)
                detailRow(label: "类型", value: "文件", monospaced: false)
                detailRow(label: "服务器路径", value: file.path, monospaced: true)
            }

            Text("文件位于服务器端；这里不会在本机打开或下载它。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)

            HStack {
                Spacer()
                Button {
                    copyServerPath()
                } label: {
                    Label(
                        copied ? "已复制服务器路径" : "复制服务器路径",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .accessibilityHint("将服务器上的完整文件路径复制到剪贴板")
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .background(Theme.background)
    }

    private func detailRow(label: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyServerPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
        copied = true
    }
}
