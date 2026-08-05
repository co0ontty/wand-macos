import AppKit
import PDFKit
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
    @State private var searchQuery = ""
    @State private var searchResults: [FileSearchResult] = []
    @State private var searchLoading = false
    @State private var searchError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                breadcrumb
                searchField
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !trimmedSearchQuery.isEmpty {
                        searchContent
                    } else if let loadError {
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
        .task(id: searchTaskKey) { await runSearch() }
        .sheet(item: $selectedFile) { file in
            FilePreviewSheet(file: file, api: api)
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

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textMuted)
            TextField("搜索此工作目录", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if searchLoading {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            } else if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除文件搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.border.opacity(0.8), lineWidth: 0.75)
                )
        )
    }

    @ViewBuilder
    private var searchContent: some View {
        if let searchError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.warning)
                Text(searchError)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重新搜索") { Task { await runSearch() } }
                    .buttonStyle(WandSecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        } else if searchLoading && searchResults.isEmpty {
            loadingState
        } else if searchResults.isEmpty {
            VStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textMuted)
                Text("没有找到匹配文件")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ForEach(searchResults) { result in
                searchResultRow(result)
            }
        }
    }

    @ViewBuilder
    private func searchResultRow(_ result: FileSearchResult) -> some View {
        let label = HStack(spacing: 7) {
            Image(systemName: result.isDirectory ? "folder" : "doc")
                .font(.system(size: 12))
                .foregroundColor(result.isDirectory ? Theme.wandAccent : Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 12, design: result.isDirectory ? .default : .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(relativeSearchPath(result.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        if result.isDirectory {
            label
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(result.name)，文件夹")
        } else {
            Button {
                selectedFile = FileTreeRow.RowItem(searchResult: result)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览文件 \(result.name)")
        }
    }

    private var displayPath: String {
        effectiveRootPath.isEmpty ? "服务器默认目录" : effectiveRootPath
    }

    private var effectiveRootPath: String {
        rootPath ?? ""
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskKey: FileSearchTaskKey {
        FileSearchTaskKey(root: effectiveRootPath, query: trimmedSearchQuery)
    }

    private func relativeSearchPath(_ path: String) -> String {
        guard !effectiveRootPath.isEmpty, path.hasPrefix(effectiveRootPath) else { return path }
        let suffix = String(path.dropFirst(effectiveRootPath.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
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

    private func runSearch() async {
        let query = trimmedSearchQuery
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            searchLoading = false
            return
        }
        searchLoading = true
        searchError = nil
        // 输入期间让频繁任务自然取消；结果只会落到最新 query 对应的 task。
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard !Task.isCancelled else { return }
        do {
            let response = try await api.searchFiles(query: query, cwd: effectiveRootPath)
            guard !Task.isCancelled, trimmedSearchQuery == query else { return }
            searchResults = response.results
            searchError = nil
        } catch {
            guard !Task.isCancelled, trimmedSearchQuery == query else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
        guard !Task.isCancelled, trimmedSearchQuery == query else { return }
        searchLoading = false
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

private struct FileSearchTaskKey: Hashable {
    let root: String
    let query: String
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

        init(searchResult: FileSearchResult) {
            self.path = searchResult.path
            self.name = searchResult.name
            self.isDirectory = searchResult.isDirectory
        }
    }
}

private struct FilePreviewSheet: View {
    let file: FileTreeRow.RowItem
    let api: WandAPI

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var preview: FilePreviewResponse?
    @State private var rawData: Data?
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: previewIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(file.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    copyServerPath()
                } label: {
                    Label(copied ? "已复制" : "复制路径", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("将服务器上的完整文件路径复制到剪贴板")
                Button("完成") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .wandGlass(.chrome)

            Divider().opacity(0.35)

            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let preview {
                HStack(spacing: 12) {
                    Label(previewKindLabel(preview.kind), systemImage: previewIcon)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))
                    if let lang = preview.lang, !lang.isEmpty { Text(lang) }
                    Spacer()
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.surface)
            }
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 540, idealHeight: 640)
        .background(Theme.background)
        .task(id: file.path) { await loadPreview() }
    }

    @ViewBuilder
    private var previewBody: some View {
        if loading {
            VStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("正在加载预览…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(loadError)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("重试") { Task { await loadPreview() } }
                    .buttonStyle(.bordered)
            }
            .padding(32)
        } else if let preview {
            switch preview.kind {
            case .text:
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.content ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(18)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.26))
            case .image:
                if let rawData, let image = NSImage(data: rawData) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(18)
                    }
                } else {
                    unsupportedPreview("无法解码此图片格式")
                }
            case .pdf:
                if let rawData, PDFDocument(data: rawData) != nil {
                    PDFDocumentView(data: rawData)
                } else {
                    unsupportedPreview("无法读取 PDF 内容")
                }
            case .video:
                unsupportedPreview("视频可在网页版中预览")
            case .audio:
                unsupportedPreview("音频可在网页版中预览")
            case .binary:
                unsupportedPreview("此文件不支持文本预览")
            }
        } else {
            unsupportedPreview("没有可用预览")
        }
    }

    private func unsupportedPreview(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: previewIcon)
                .font(.system(size: 30))
                .foregroundColor(Theme.textMuted)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(32)
    }

    private var previewIcon: String {
        switch preview?.kind {
        case .text: return "doc.text"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        case .binary: return "doc"
        case nil: return "doc"
        }
    }

    private func previewKindLabel(_ kind: FilePreviewKind) -> String {
        switch kind {
        case .text: return "文本"
        case .image: return "图片"
        case .pdf: return "PDF"
        case .video: return "视频"
        case .audio: return "音频"
        case .binary: return "二进制"
        }
    }

    private func loadPreview() async {
        loading = true
        loadError = nil
        rawData = nil
        do {
            let next = try await api.filePreview(path: file.path)
            guard !Task.isCancelled else { return }
            preview = next
            if next.kind == .image || next.kind == .pdf {
                rawData = try await api.rawFile(path: file.path)
            }
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            loadError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        loading = false
    }

    private func copyServerPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
        copied = true
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.dataRepresentation() != data {
            nsView.document = PDFDocument(data: data)
        }
    }
}
