import SwiftUI

/// UI-only identity. Legacy rows are valid only inside the exact loaded window;
/// they are never persisted or treated as a history migration.
struct TurnNavigationWindow: Hashable {
    struct Stamp: Hashable {
        let role: String
        let messageID: String?
        let createdAt: String?
        let question: String?
    }
    let offset: Int
    let stamps: [Stamp]
}

enum TurnNavigationID: Hashable {
    case message(scope: String, id: String)
    case window(scope: String, window: TurnNavigationWindow, absoluteIndex: Int)
}

struct TurnNavigationEntry: Identifiable {
    let id: TurnNavigationID
    let absoluteIndex: Int
    let preview: String
    let reply: String
}

struct TurnNavigationIndex {
    let entries: [TurnNavigationEntry]

    init(scope: String, turns: [ConversationTurn], offset: Int, visibleIndices: Set<Int>? = nil) {
        let window = TurnNavigationWindow(offset: offset, stamps: turns.map {
            .init(role: $0.role, messageID: $0.messageId, createdAt: $0.createdAt,
                  question: $0.role == "user" ? userQuestionPreview($0) : nil)
        })
        let idCounts = Dictionary(grouping: turns.compactMap(\.messageId), by: { $0 }).mapValues { $0.count }
        entries = turns.enumerated().compactMap { index, turn in
            guard visibleIndices?.contains(index) != false,
                  turn.role == "user", turn.notice != true,
                  turn.sessionLink == nil else { return nil }
            let preview = userQuestionPreview(turn)
            guard !preview.isEmpty else { return nil }
            let absoluteIndex = offset + index
            let identity: TurnNavigationID
            if let id = turn.messageId, !id.isEmpty, idCounts[id] == 1 {
                identity = .message(scope: scope, id: id)
            } else {
                identity = .window(scope: scope, window: window, absoluteIndex: absoluteIndex)
            }
            let reply = turns.dropFirst(index + 1).prefix(while: { $0.role != "user" })
                .filter { $0.role == "assistant" }.map { userQuestionPreview($0) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return TurnNavigationEntry(id: identity, absoluteIndex: absoluteIndex, preview: preview, reply: reply)
        }
    }

    /// Resolve against the current owner projection at click time, not a captured index.
    func resolve(_ id: TurnNavigationID) -> Int? {
        entries.first { $0.id == id }?.absoluteIndex
    }
}

/// A fixed-size trigger and a native, keyboard-navigable directory. The scroll
/// owner keeps pagination, actual row anchors and follow-latest policy.
struct TurnNavigator: View {
    let entries: [TurnNavigationEntry]
    let windowNote: String
    let onJump: (TurnNavigationID) -> Void
    @State private var presented = false
    @State private var selection: TurnNavigationID?
    @FocusState private var listFocused: Bool
    @Environment(\.desktopPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: TurnNavigationEntry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        selection = entry.id
                        presented = true
                    } label: {
                        Capsule()
                            .fill(selection == entry.id ? Theme.textPrimary : Theme.textSecondary.opacity(0.55))
                            .frame(width: selection == entry.id ? 24 : 8, height: 2)
                            .frame(width: 32, height: 12, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.preview)
                    .onHover { hovering in
                        if hovering { selection = entry.id; presented = true }
                    }
                }
            }
        }
        .frame(width: 36, height: min(CGFloat(entries.count * 12), 240))
        .help(windowNote)
        .popover(isPresented: $presented, arrowEdge: .leading) {
            if let selected {
                Button {
                    presented = false
                    onJump(selected.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.preview).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(selected.reply.isEmpty ? "暂无回复摘要" : String(selected.reply.prefix(240)))
                            .font(.callout).foregroundColor(Theme.textSecondary).lineLimit(3)
                        Text("点击跳转到提问").font(.caption).foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 280, alignment: .leading).padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .background(Theme.surface)
                .onExitCommand { presented = false }
            }
        }
        .onChange(of: entries.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil; presented = false }
        }
        .onChange(of: pageActive) { active in if !active { presented = false } }
        .onDisappear { presented = false }
    }
}
