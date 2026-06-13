import SwiftUI

/// 原生文件浏览器:把 web 端的 `.file-panel`(.file-tree)搬到 SwiftUI。
/// 数据从 `/api/directory` 拉;支持展开/折叠、点击进入子目录、显示当前路径面包屑。
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
                    if let parent = parentPath {
                        row(.parentRow(parent: parent))
                    }
                    ForEach(items) { item in
                        row(.init(item))
                    }
                    if items.isEmpty && !loading {
                        emptyState
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

    // MARK: - 行渲染

    @ViewBuilder
    private func row(_ item: RowItem) -> some View {
        let isDir = item.isDirectory
        let isExpanded = expandedDirs.contains(item.path)
        let isLoadingChildren = childLoading.contains(item.path)
        let children = childCache[item.path]

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
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if isDir {
                    if isExpanded {
                        expandedDirs.remove(item.path)
                    } else {
                        expandedDirs.insert(item.path)
                        if childCache[item.path] == nil {
                            Task { await loadChildren(of: item.path) }
                        }
                    }
                }
            }

            if isDir, isExpanded, let children {
                // 递归展开子目录:用 ForEach + Group 拆成两层避免 opaque type 自引用。
                Group {
                    ForEach(children) { child in
                        rowContent(RowItem(child))
                    }
                }
            }
        }
    }

    /// 单一行的渲染,不带递归子节点;递归在 row(_:) 里通过 ForEach + Group 显式拼装。
    @ViewBuilder
    private func rowContent(_ item: RowItem) -> some View {
        let isDir = item.isDirectory
        let isExpanded = expandedDirs.contains(item.path)
        let isLoadingChildren = childLoading.contains(item.path)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDir {
                if isExpanded {
                    expandedDirs.remove(item.path)
                } else {
                    expandedDirs.insert(item.path)
                    if childCache[item.path] == nil {
                        Task { await loadChildren(of: item.path) }
                    }
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

    // MARK: - 数据加载

    private func reload() async {
        loading = true
        loadError = nil
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

    // MARK: - RowItem(把 DirectoryItem + parent 假行统一成一种)

    struct RowItem: Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        var id: String { path }

        init(path: String, name: String, isDirectory: Bool) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
        }

        init(_ item: DirectoryItem) {
            self.path = item.path
            self.name = item.name
            self.isDirectory = item.isDirectory
        }

        /// parent 假行专用(用 .. 作名字,标 isDirectory 让它走目录点击逻辑)。
        static func parentRow(parent: String) -> RowItem {
            RowItem(path: parent, name: "..", isDirectory: true)
        }
    }
}
