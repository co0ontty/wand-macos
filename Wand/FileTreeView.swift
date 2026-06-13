import SwiftUI

/// 原生文件浏览器:把 web 端的 `.file-panel`(.file-tree)搬到 SwiftUI。
/// 数据从 `/api/directory` 拉;支持任意深度展开/折叠、`..` 导航上一级、显示当前路径面包屑。
/// Git 状态展示交给 FilePanelView 的 git tab 处理(直接调现有的 `getSessionGitStatus`)。

struct FileTreeView: View {
    let api: WandAPI
    /// 起始目录:默认走服务端 defaultCwd(传空字符串让服务端 resolve)。
    @State private var currentPath: String = ""
    @State private var items: [DirectoryItem] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var expandedDirs: Set<String> = []
    /// 各子目录的缓存项,key 是绝对路径。
    @State private var childCache: [String: [DirectoryItem]] = [:]
    @State private var childLoading: Set<String> = []

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
                    } else {
                        if let parent = parentPath {
                            parentRow(parent)
                        }
                        ForEach(items) { item in
                            FileTreeRow(
                                item: FileTreeRow.RowItem(item),
                                depth: 0,
                                expandedDirs: $expandedDirs,
                                childCache: $childCache,
                                childLoading: $childLoading,
                                onToggle: toggle
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
        .task { await reload() }
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
        currentPath.isEmpty ? "/" : currentPath
    }

    private var parentPath: String? {
        guard !currentPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: currentPath)
        let parent = url.deletingLastPathComponent().path
        return parent == currentPath ? nil : parent
    }

    /// `..` 行:点击导航到上一级目录(换根重载),区别于普通目录的就地展开。
    private func parentRow(_ parent: String) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 10)
            Image(systemName: "arrow.up.left")
                .font(.system(size: 12))
                .foregroundColor(Theme.wandAccent)
                .frame(width: 16)
            Text("..")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            currentPath = parent
            Task { await reload() }
        }
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
            if childCache[item.path] == nil {
                Task { await loadChildren(of: item.path) }
            }
        }
    }

    // MARK: - 数据加载

    private func reload() async {
        loading = true
        loadError = nil
        // 换根时清掉旧的展开态与子目录缓存,避免跨目录的陈旧节点。
        expandedDirs.removeAll()
        childCache.removeAll()
        childLoading.removeAll()
        do {
            let listing = try await api.listDirectory(currentPath)
            items = listing.items
        } catch {
            loadError = error.localizedDescription
            items = []
        }
        loading = false
    }

    private func loadChildren(of path: String) async {
        childLoading.insert(path)
        defer { childLoading.remove(path) }
        do {
            let listing = try await api.listDirectory(path)
            childCache[path] = listing.items
        } catch {
            childCache[path] = []
        }
    }
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

    var body: some View {
        let isDir = item.isDirectory
        let isExpanded = expandedDirs.contains(item.path)
        let isLoadingChildren = childLoading.contains(item.path)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: iconFor(item))
                    .font(.system(size: 12))
                    .foregroundColor(isDir ? Theme.wandAccent : Theme.textSecondary)
                    .frame(width: 16)
                Text(item.name)
                    .font(.system(size: 12, design: isDir ? .default : .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isDir, isLoadingChildren {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { onToggle(item) }

            if isDir, isExpanded, let children = childCache[item.path] {
                ForEach(children) { child in
                    FileTreeRow(
                        item: RowItem(child),
                        depth: depth + 1,
                        expandedDirs: $expandedDirs,
                        childCache: $childCache,
                        childLoading: $childLoading,
                        onToggle: onToggle
                    )
                }
            }
        }
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
