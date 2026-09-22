import AppKit
import SwiftUI
import SwiftTerm

/// An AppKit terminal emulator, not a local shell and not an HTML surface.
/// All program bytes come from Wand; only explicit user input goes back as userInput=true.
final class NativeTerminalView: TerminalView, TerminalViewDelegate {
    var onInput: ((String, Bool) -> Void)?
    var onSizeChange: ((Int, Int) -> Void)?
    var onScaleChange: ((Double?) -> Void)?
    private var feeding = false
    private var restoring = false

    static let canvasColor = NSColor(srgbRed: 0.090, green: 0.071, blue: 0.059, alpha: 1)

    init() {
        super.init(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 5000,
                                     kittyImageCacheLimitBytes: 16 * 1024 * 1024)
        )
        terminalDelegate = self
        nativeBackgroundColor = Self.canvasColor
        nativeForegroundColor = NSColor(srgbRed: 0.92, green: 0.90, blue: 0.87, alpha: 1)
        caretColor = nativeForegroundColor
        optionAsMetaKey = false // Keep the system's Option/IME composition behavior.
        setAccessibilityLabel("原生终端")
        setAccessibilityIdentifier("wand.native-terminal")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func feedOutput(_ text: String) {
        feeding = true
        defer { feeding = false }
        feed(text: text)
    }

    func restore(_ data: WsData) {
        restoring = true
        let previousScroll = scrollPosition
        let wasBrowsing = previousScroll < 0.999
        let terminal = getTerminal()
        terminal.resetToInitialState()
        nativeBackgroundColor = Self.canvasColor
        nativeForegroundColor = NSColor(srgbRed: 0.92, green: 0.90, blue: 0.87, alpha: 1)
        if let snapshot = data.terminalState, snapshot.isReplayable {
            terminal.resize(cols: snapshot.cols, rows: snapshot.rows)
            feedOutput(snapshot.data)
            for operation in snapshot.pending {
                if operation.type == "resize", let cols = operation.cols, let rows = operation.rows {
                    // TerminalView.resize performs a soft reset, which would lose ANSI modes.
                    terminal.resize(cols: cols, rows: rows)
                } else if let text = operation.data {
                    feedOutput(text)
                }
            }
        } else {
            // Older servers have raw history only. Never append it to an existing screen.
            if let cols = data.ptyCols, let rows = data.ptyRows,
               PtyTerminalSnapshot.validSize(cols: cols, rows: rows) {
                terminal.resize(cols: cols, rows: rows)
            }
            feedOutput(data.output ?? "")
        }
        // Replay at recorded geometry first, THEN fit once to the current native view.
        setFrameSize(frame.size)
        scroll(toPosition: wasBrowsing ? previousScroll : 1)
        restoring = false
        onSizeChange?(terminal.cols, terminal.rows)
        needsDisplay = true
    }

    func setScale(_ scale: Double) {
        font = .monospacedSystemFont(ofSize: CGFloat(13 * scale), weight: .regular)
        setFrameSize(frame.size)
        onSizeChange?(getTerminal().cols, getTerminal().rows)
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(text)
    }

    /// Keep paste distinct from key/IME events (including negotiated keyboard protocols).
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        unmarkText()
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { send(txt: "\u{1B}[200~") }
        send(txt: text)
        if bracketed { send(txt: "\u{1B}[201~") }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Some macOS input methods commit attributed strings, not NSString.
        super.insertText((string as? NSAttributedString)?.string ?? string,
                         replacementRange: replacementRange)
    }

    func focusTerminal() {
        guard let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(self)
    }

    func showFind() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": onScaleChange?(0.25)
        case "-": onScaleChange?(-0.25)
        case "0": onScaleChange?(nil)
        case "k": clearScrollback()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: - SwiftTerm callbacks

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Device-status, focus and mouse-mode replies are not user submissions.
        guard !restoring, !data.isEmpty else { return }
        onInput?(String(decoding: data, as: UTF8.self), false)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !restoring, !data.isEmpty else { return }
        onInput?(String(decoding: data, as: UTF8.self), true)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !restoring, !feeding else { return }
        onSizeChange?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // Terminal output must not read or overwrite the system clipboard via OSC 52.
    // Cmd-C/Cmd-V remain explicit, native user actions implemented by SwiftTerm.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct NativeTerminalSurface: NSViewRepresentable {
    let terminal: NativeTerminalView

    func makeNSView(context: Context) -> NativeTerminalView {
        DispatchQueue.main.async { [weak terminal] in terminal?.focusTerminal() }
        return terminal
    }

    func updateNSView(_ nsView: NativeTerminalView, context: Context) {}
}
