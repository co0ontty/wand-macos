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
            return TurnNavigationEntry(id: identity, absoluteIndex: absoluteIndex, preview: preview)
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
        Button {
            presented.toggle()
        } label: {
            ZStack {
                Image(systemName: "list.number")
                    .opacity(presented ? 0 : 1)
                    .rotationEffect(.degrees(reduceMotion || !presented ? 0 : -45))
                Image(systemName: "xmark")
                    .opacity(presented ? 1 : 0)
                    .rotationEffect(.degrees(reduceMotion || presented ? 0 : 45))
            }
        }
        .buttonStyle(WandIconButtonStyle())
        .wandMotion(value: presented)
        .help("提问目录 · 仅当前已加载范围")
        .accessibilityLabel(presented ? "关闭提问目录" : "打开提问目录")
        .popover(isPresented: $presented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("提问目录").font(.headline)
                Text(windowNote).font(.caption).foregroundColor(Theme.textSecondary)
                if entries.isEmpty {
                    Text("当前范围没有用户提问")
                        .font(.callout).foregroundColor(Theme.textSecondary)
                } else {
                    List(selection: $selection) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("消息 \(entry.absoluteIndex + 1)")
                                    .font(.caption).foregroundColor(Theme.textSecondary)
                                Text(String(entry.preview.prefix(100)))
                                    .font(.callout).lineLimit(2)
                            }
                            .tag(entry.id)
                        }
                    }
                    .listStyle(.plain)
                    .focused($listFocused)
                    .frame(height: 220)
                    Text(selected.map { String($0.preview.prefix(400)) } ?? "选择一条提问以预览")
                        .font(.callout).lineLimit(5)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    Button("跳转到提问") {
                        guard let selected else { return }
                        presented = false
                        onJump(selected.id)
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
                }
            }
            .padding(16)
            .frame(width: 280)
            .foregroundColor(Theme.textPrimary)
            .background(Theme.surface)
            .onAppear {
                if selected == nil { selection = entries.last?.id }
                listFocused = true
            }
            .onExitCommand { presented = false }
        }
        .onChange(of: entries.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: entries.count) { _ in presented = false }
        .onChange(of: pageActive) { active in if !active { presented = false } }
        .onDisappear { presented = false }
    }
}
