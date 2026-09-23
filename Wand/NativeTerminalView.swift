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
    private var interpretingComposition = false
    private var committingComposition = false
    private var compositionKeyCodes: Set<UInt16> = []
    private var compositionEventMonitor: Any?
    private var magnifyAccumulated: CGFloat = 0

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
        let reporting = allowMouseReporting
        let terminal = getTerminal()
        // SwiftTerm clears selections before every feed when mouse reporting is allowed,
        // even if the shell has not enabled a mouse mode. Preserve manual shell selection
        // without permanently disabling mouse input in interactive TUIs.
        if !terminal.isCurrentBufferAlternate && terminal.mouseMode == .off {
            allowMouseReporting = false
        }
        defer {
            allowMouseReporting = reporting
            feeding = false
        }
        // SwiftTerm normally tracks the tail itself, but a prior restore/resize can leave
        // its userScrolling flag stale. Follow only when the user was already at the tail;
        // never pull a reader away from scrollback during a streaming response.
        let shouldFollow = !restoring && (!canScroll || scrollPosition >= 1)
        feed(text: text)
        if shouldFollow && !terminal.isCurrentBufferAlternate { scroll(toPosition: 1) }
        if reporting && (terminal.isCurrentBufferAlternate || terminal.mouseMode != .off) {
            selection.active = false
        }
    }

    func restore(_ data: WsData) {
        restoring = true
        selection.active = false
        let previousScroll = scrollPosition
        // With no scrollback SwiftTerm reports position 0, not 1. A fresh view
        // must therefore be considered at the tail, not browsing history.
        let wasBrowsing = canScroll && previousScroll < 1
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let compositionEventMonitor { NSEvent.removeMonitor(compositionEventMonitor) }
        compositionEventMonitor = nil
        compositionKeyCodes.removeAll()
        guard window != nil else {
            unmarkText()
            return
        }
        // SwiftTerm 1.18's keyDown/keyUp overrides are not open. Use an AppKit local
        // monitor scoped to this view's first responder, never a global keyboard hook.
        compositionEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.firstResponder === self else { return event }
            return self.handleCompositionEvent(event)
        }
    }

    deinit {
        if let compositionEventMonitor { NSEvent.removeMonitor(compositionEventMonitor) }
    }

    func handleCompositionEvent(_ event: NSEvent) -> NSEvent? {
        // Application shortcuts (copy/paste/find/settings) must still reach the responder chain.
        if event.modifierFlags.contains(.command) { return event }
        if event.type == .keyUp {
            // Confirmation can clear marked text before the matching release arrives.
            if compositionKeyCodes.remove(event.keyCode) != nil || hasMarkedText() { return nil }
        } else if event.type == .keyDown {
            if hasMarkedText() {
                compositionKeyCodes.insert(event.keyCode)
                // Kitty functional-key encoding must not run before the input method.
                interpretingComposition = true
                defer { interpretingComposition = false }
                interpretKeyEvents([event])
                return nil
            }
            compositionKeyCodes.remove(event.keyCode)
        }
        return event
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Some macOS input methods commit attributed strings, not NSString.
        let normalized: Any = (string as? NSAttributedString)?.string ?? string
        if (hasMarkedText() || interpretingComposition), let text = normalized as? String {
            unmarkText()
            // IME commits are text, not a replay of the phonetic key or candidate Return.
            committingComposition = true
            defer { committingComposition = false }
            send(txt: text)
            return
        }
        super.insertText(normalized, replacementRange: replacementRange)
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

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            magnifyAccumulated = 0
        case .changed:
            magnifyAccumulated += event.magnification
            if magnifyAccumulated >= 0.12 {
                magnifyAccumulated = 0
                onScaleChange?(0.25)
            } else if magnifyAccumulated <= -0.12 {
                magnifyAccumulated = 0
                onScaleChange?(-0.25)
            }
        default:
            break
        }
    }

    // MARK: - SwiftTerm callbacks

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Device-status, focus and mouse-mode replies are not user submissions.
        guard !restoring, !data.isEmpty else { return }
        onInput?(String(decoding: data, as: UTF8.self), false)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !restoring, !data.isEmpty else { return }
        // An input method may fall back to doCommand during interpretKeyEvents. Such
        // candidate keys must not become remote input; only the committed text may pass.
        guard committingComposition || (!interpretingComposition && !hasMarkedText()) else { return }
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
