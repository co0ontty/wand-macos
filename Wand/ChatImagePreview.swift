import AppKit
import SwiftUI

/// 结构化会话里的图片打开方式：缩略图点击后在当前窗口弹出预览，
/// 不跳转页面，也不把预览状态挂在会被 LazyVStack 回收的行上。

enum MarkdownImagePiece: Equatable {
    case text(String)
    case image(alt: String, source: String)
}

/// 从一段非代码 Markdown 里拆出图片。反引号内的原文保持不动。
func splitMarkdownImages(_ raw: String) -> [MarkdownImagePiece] {
    var pieces: [MarkdownImagePiece] = []
    var text = ""
    var index = raw.startIndex

    func flush() {
        guard !text.isEmpty else { return }
        pieces.append(.text(text))
        text = ""
    }

    while index < raw.endIndex {
        if raw[index] == "`" {
            let start = index
            let after = raw.index(after: index)
            if let end = raw[after...].firstIndex(of: "`") {
                text.append(contentsOf: raw[start...end])
                index = raw.index(after: end)
                continue
            }
            text.append(contentsOf: raw[start...])
            break
        }
        if raw[index] == "\\", let next = raw.index(index, offsetBy: 1, limitedBy: raw.index(before: raw.endIndex)), raw[next] == "!" {
            text.append(raw[next])
            index = raw.index(after: next)
            continue
        }
        if let parsed = parseMarkdownImage(raw, from: index) {
            flush()
            pieces.append(.image(alt: parsed.alt, source: parsed.source))
            index = parsed.end
            continue
        }
        text.append(raw[index])
        index = raw.index(after: index)
    }
    flush()
    return pieces.isEmpty ? [.text(raw)] : pieces
}

private func parseMarkdownImage(_ raw: String, from start: String.Index) -> (alt: String, source: String, end: String.Index)? {
    guard raw[start] == "!" else { return nil }
    var index = raw.index(after: start)
    guard index < raw.endIndex, raw[index] == "[" else { return nil }
    index = raw.index(after: index)
    let altStart = index
    while index < raw.endIndex, raw[index] != "]" {
        if raw[index] == "\\", let next = raw.index(index, offsetBy: 1, limitedBy: raw.index(before: raw.endIndex)) {
            index = raw.index(after: next)
            continue
        }
        index = raw.index(after: index)
    }
    guard index < raw.endIndex, raw[index] == "]" else { return nil }
    let alt = String(raw[altStart..<index]).replacingOccurrences(of: "\\]", with: "]")
    index = raw.index(after: index)
    guard index < raw.endIndex, raw[index] == "(" else { return nil }
    index = raw.index(after: index)
    let sourceStart = index
    while index < raw.endIndex, raw[index] != ")" && !raw[index].isWhitespace {
        index = raw.index(after: index)
    }
    let source = String(raw[sourceStart..<index])
    guard !source.isEmpty else { return nil }
    if index < raw.endIndex, raw[index].isWhitespace {
        while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
        if index < raw.endIndex, raw[index] == "\"" {
            index = raw.index(after: index)
            while index < raw.endIndex, raw[index] != "\"" { index = raw.index(after: index) }
            guard index < raw.endIndex else { return nil }
            index = raw.index(after: index)
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
        }
    }
    guard index < raw.endIndex, raw[index] == ")" else { return nil }
    return (alt, source, raw.index(after: index))
}

/// 只接受结构化消息里实际会出现的图片源。拒绝脚本、本机 file: 和协议相对地址。
func resolvedChatImageSource(_ raw: String) -> String? {
    let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return nil }
    let lower = source.lowercased()
    if lower.hasPrefix("data:image/") { return source }
    if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return source }
    if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") {
        return nil
    }
    if source.hasPrefix("//") { return nil }
    if source.hasPrefix("/api/") { return source }
    if source.hasPrefix("/"), isImageAttachmentPath(source) {
        return "/api/file-raw?path=\(chatImageQueryEncoded(source))"
    }
    if source.hasPrefix("/") { return source }
    return nil
}

func chatImageLabel(source: String, fallback: String) -> String {
    if source.lowercased().hasPrefix("data:") { return fallback }
    let path = source.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? source
    let name = (path as NSString).lastPathComponent.removingPercentEncoding ?? (path as NSString).lastPathComponent
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "/" || trimmed == "." { return fallback }
    return trimmed
}

func chatImageQueryEncoded(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

func writeChatPreviewPNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    try png.write(to: url, options: .atomic)
}

@discardableResult
func openChatImageInPreview(_ image: NSImage) -> Bool {
    guard let url = try? prepareChatPreviewFile(image) else { return false }
    return NSWorkspace.shared.open(url)
}

func copyChatImage(_ image: NSImage) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
}

private func prepareChatPreviewFile(_ image: NSImage) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wand-image-preview", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    sweepOldPreviewFiles(in: directory)
    let url = directory.appendingPathComponent(UUID().uuidString + ".png")
    try writeChatPreviewPNG(image, to: url)
    return url
}

private func sweepOldPreviewFiles(in directory: URL) {
    let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    for file in files {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if (modified ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct ChatImageClickProbe: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = ChatImageClickProbeView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
    }
}

/// 只给测试定位点击区域，不能挡住真正的按钮命中。
private final class ChatImageClickProbeView: NSView {
    static weak var lastHostWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { Self.lastHostWindow = window }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct ChatImageOpenButton<Content: View>: View {
    let image: NSImage
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            ChatImagePreviewPresenter.shared.open(image: image, label: displayLabel)
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看\(displayLabel)")
        .accessibilityIdentifier("chat-image-open")
        .help("查看大图")
        .background(ChatImageClickProbe(id: "chat-image-open-\(displayLabel)"))
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .contextMenu {
            Button("查看大图") {
                ChatImagePreviewPresenter.shared.open(image: image, label: displayLabel)
            }
            Button("用预览打开") { _ = openChatImageInPreview(image) }
            Button("复制图片") { copyChatImage(image) }
        }
    }

    private var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "图片" : trimmed
    }
}

/// 预览挂在窗口上，避免消息行被回收时把已打开的图片关掉。
final class ChatImagePreviewPresenter {
    static let shared = ChatImagePreviewPresenter()

    private var panel: NSPanel?
    private var host: NSHostingController<ChatImageViewer>?

    /// 点在哪个窗口，预览就挂在哪个窗口。不能退到应用里另一个 key window，
    /// 否则结构化会话的图片会在别的窗口弹出。
    private static func previewParent(excluding panel: NSPanel?) -> NSWindow? {
        func usable(_ window: NSWindow?) -> NSWindow? {
            guard let window, window !== panel, window.sheetParent == nil, window.isVisible else { return nil }
            return window
        }
        let eventWindow = usable(NSApp.currentEvent?.window)
        let hostWindow = usable(ChatImageClickProbeView.lastHostWindow)
        if let eventWindow, hostWindow == nil || eventWindow === hostWindow {
            return eventWindow
        }
        if let hostWindow { return hostWindow }
        return usable(NSApp.keyWindow) ?? usable(NSApp.mainWindow)
            ?? NSApp.windows.first { usable($0) != nil }
    }

    func open(image: NSImage, label: String) {
        let safeLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "图片" : label
        let viewer = ChatImageViewer(image: image, label: safeLabel, onClose: { [weak self] in
            self?.close()
        })
        let parent = Self.previewParent(excluding: panel)
        let canReuse = panel?.isVisible == true && panel?.sheetParent === parent
        if canReuse, let panel, let host {
            host.rootView = viewer
            panel.title = safeLabel
            return
        }
        close()
        let host = NSHostingController(rootView: viewer)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.title = safeLabel
        panel.minSize = NSSize(width: 640, height: 420)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .documentWindow
        self.panel = panel
        self.host = host
        if let parent {
            parent.beginSheet(panel) { [weak self] _ in
                panel.orderOut(nil)
                self?.clear(panel)
            }
            if self.panel === panel && parent.attachedSheet !== panel {
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard let panel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.close()
            clear(panel)
        }
    }

    private func clear(_ panel: NSPanel) {
        guard self.panel === panel else { return }
        self.panel = nil
        self.host = nil
    }
}

struct ChatImageViewer: View {
    let image: NSImage
    let label: String
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var note = "滚动或双击缩放，Esc 关闭"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ChatImageCanvas(image: image, scale: $scale, offset: $offset, onClose: onClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .accessibilityLabel(label)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.black)
        .accessibilityIdentifier("chat-image-viewer")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片预览 \(label)")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                Spacer(minLength: 8)
                zoomButton("minus.magnifyingglass", label: "缩小图片", enabled: scale > 1.01) {
                    setScale(scale / 1.25)
                }
                Text(scaleLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.86))
                    .frame(width: 52)
                    .accessibilityLabel("当前缩放 \(scaleLabel)")
                zoomButton("plus.magnifyingglass", label: "放大图片", enabled: scale < 4.99) {
                    setScale(scale * 1.25)
                }
                toolbarButton("1:1", label: "恢复原始大小", width: 44) {
                    setScale(1)
                }
                toolbarButton("复制", label: "复制图片", width: 52) {
                    copyChatImage(image)
                    note = "已复制图片"
                }
                toolbarButton("用预览打开", label: "用预览打开", width: 92) {
                    note = openChatImageInPreview(image) ? "已用预览打开" : "系统预览未能打开"
                }
                zoomButton("xmark", label: "关闭图片预览", enabled: true, probeID: "chat-image-close", action: onClose)
            }
            Text(note)
                .font(.system(size: 11))
                .foregroundColor(note == "系统预览未能打开" ? Theme.danger : .white.opacity(0.62))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                .accessibilityLabel(note)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.black)
    }

    private var scaleLabel: String { "\(Int((scale * 100).rounded()))%" }

    private func setScale(_ next: CGFloat) {
        let clamped = min(5, max(1, next))
        scale = clamped
        if clamped <= 1.01 { offset = .zero }
    }

    private func zoomButton(_ systemName: String, label: String, enabled: Bool, probeID: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(enabled ? 0.92 : 0.35))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
        .background {
            if let probeID {
                ChatImageClickProbe(id: probeID)
            }
        }
    }

    private func toolbarButton(_ title: String, label: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: width, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct ChatImageCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(scale: $scale, offset: $offset, onClose: onClose)
    }

    func makeNSView(context: Context) -> ChatImageCanvasView {
        let view = ChatImageCanvasView()
        view.coordinator = context.coordinator
        view.image = image
        return view
    }

    func updateNSView(_ view: ChatImageCanvasView, context: Context) {
        context.coordinator.scale = $scale
        context.coordinator.offset = $offset
        context.coordinator.onClose = onClose
        view.coordinator = context.coordinator
        view.image = image
        view.applyExternal(scale: scale, offset: offset)
    }

    final class Coordinator {
        var scale: Binding<CGFloat>
        var offset: Binding<CGSize>
        var onClose: () -> Void

        init(scale: Binding<CGFloat>, offset: Binding<CGSize>, onClose: @escaping () -> Void) {
            self.scale = scale
            self.offset = offset
            self.onClose = onClose
        }
    }
}

final class ChatImageCanvasView: NSView {
    fileprivate var coordinator: ChatImageCanvas.Coordinator?
    var image: NSImage? {
        didSet { imageView.image = image; needsLayout = true }
    }

    private let imageView = NSImageView()
    private var scale: CGFloat = 1
    private var offset: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.imageFrameStyle = .none
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = bounds
            return
        }
        let available = bounds.insetBy(dx: 24, dy: 24)
        let fitted = aspectFit(image.size, in: available.size)
        let width = max(1, fitted.width * scale)
        let height = max(1, fitted.height * scale)
        imageView.frame = NSRect(
            x: bounds.midX - width / 2 + offset.width,
            y: bounds.midY - height / 2 + offset.height,
            width: width,
            height: height
        )
    }

    func applyExternal(scale: CGFloat, offset: CGSize) {
        guard abs(self.scale - scale) > 0.001 || self.offset != offset else { return }
        self.scale = scale
        self.offset = offset
        needsLayout = true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = event.hasPreciseScrollingDeltas ? 0.004 : 0.08
        commit(scale: scale * (1 + delta * factor), offset: offset)
    }

    override func magnify(with event: NSEvent) {
        commit(scale: scale * (1 + event.magnification), offset: offset)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            commit(scale: scale > 1.05 ? 1 : 2, offset: scale > 1.05 ? .zero : offset)
            return
        }
        guard scale > 1.01 else { return }
        let start = event.locationInWindow
        let startOffset = offset
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { next, stop in
            guard let next else { return }
            if next.type == .leftMouseDragged {
                let point = next.locationInWindow
                self.commit(
                    scale: self.scale,
                    offset: CGSize(width: startOffset.width + point.x - start.x, height: startOffset.height + point.y - start.y)
                )
            } else {
                stop.pointee = true
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            coordinator?.onClose()
        case 24, 69:
            commit(scale: scale * 1.25, offset: offset)
        case 27, 78:
            commit(scale: scale / 1.25, offset: offset)
        default:
            if event.charactersIgnoringModifiers == "0" {
                commit(scale: 1, offset: .zero)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func commit(scale: CGFloat, offset: CGSize) {
        let next = min(5, max(1, scale))
        let nextOffset = next <= 1.01 ? .zero : offset
        self.scale = next
        self.offset = nextOffset
        needsLayout = true
        coordinator?.scale.wrappedValue = next
        coordinator?.offset.wrappedValue = nextOffset
    }

    private func aspectFit(_ size: NSSize, in available: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return available }
        let ratio = min(available.width / size.width, available.height / size.height)
        return NSSize(width: size.width * ratio, height: size.height * ratio)
    }
}
