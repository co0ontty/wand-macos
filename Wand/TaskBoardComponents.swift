import SwiftUI

/**
 * 任务看板的共享零件：状态图标、胶囊、Agent 与会话列表、进度条、卡片本体。
 * 视觉口径对齐 Web `task-board-views.tsx` + `.task-board-*` 样式：
 * 细描边胶囊、14px 卡片圆角、3px 分段进度条、列头 2px 状态色下划线。
 */

// MARK: - 状态图标

struct WandBoardStatusGlyph: View {
    let status: WandBoardStatus

    var body: some View {
        ZStack {
            switch status {
            case .todo:
                Circle()
                    .strokeBorder(status.color, lineWidth: 1.6)
                    .frame(width: 10, height: 10)
            case .doing:
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .strokeBorder(status.color.opacity(0.35), lineWidth: 1.6)
                            .frame(width: 13, height: 13)
                    )
            case .done:
                Circle()
                    .fill(status.color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(Theme.surfaceElevated)
                    )
            case .archived:
                Image(systemName: "archivebox")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(status.color)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(status.label)
    }
}

// MARK: - 胶囊

/// 优先级胶囊；`none` 只在需要交互（详情选择器）时显示，卡片上不占位。
struct WandBoardPriorityChip: View {
    let priority: String
    var interactive = false

    var body: some View {
        if priority == WandBoardPriority.none.rawValue && !interactive {
            EmptyView()
        } else {
            let value = WandBoardPriority(rawValue: priority) ?? .none
            HStack(spacing: 4) {
                Image(systemName: value.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(value.label)
            }
            .font(.system(size: 11))
            .foregroundColor(value.color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.surfaceElevated))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .accessibilityLabel("优先级 \(value.label)")
        }
    }
}

struct WandBoardLabelChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(wandBoardLabelColor(label)).frame(width: 6, height: 6)
            Text(wandBoardLabelName(label))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .help(label)
    }
}

struct WandBoardMilestoneChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.textPrimary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .help("里程碑：\(name)")
    }
}

struct WandBoardProjectChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .help(name)
    }
}

struct WandBoardDueChip: View {
    let dueDate: String
    let status: String

    var body: some View {
        let overdue = wandBoardIsOverdue(dueDate, status: status)
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 9))
            Text(wandBoardDueStamp(dueDate))
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundColor(overdue ? Theme.wandAccent : Theme.textSecondary)
        .help(overdue ? "已逾期：\(dueDate)" : "截止 \(dueDate)")
    }
}

// MARK: - Agent 胶囊

/// 该 Agent 有会话在跑时，末尾跟一组跳动圆点（对齐 Web `.task-board-agent-dots`）。
struct WandBoardAgentChip: View {
    let agent: WandBoardTaskAgent
    var running = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            BrandLogo(provider: agent.provider, color: Theme.textSecondary, onDark: nil)
                .frame(width: 12, height: 12)
            Text(wandBoardProviderLabel(agent.provider))
                .lineLimit(1)
            if running {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Theme.wandAccent)
                            .frame(width: 3, height: 3)
                            .opacity(phase ? 1 : 0.35)
                            .offset(y: phase ? -1.5 : 0)
                            .animation(
                                reduceMotion
                                    ? nil
                                    : .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.15),
                                value: phase
                            )
                    }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundColor(running ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .onAppear { if !reduceMotion { phase = true } }
        .accessibilityLabel("\(wandBoardProviderLabel(agent.provider))\(running ? "，正在运行" : "")")
    }
}

struct WandBoardAgentChips: View {
    let sessions: [WandBoardTaskSession]
    let assigned: WandBoardTaskAgent?

    var body: some View {
        let agents = wandBoardListAgents(sessions: sessions, assigned: assigned)
        HStack(spacing: 4) {
            ForEach(agents, id: \.provider) { agent in
                WandBoardAgentChip(
                    agent: agent,
                    running: sessions.contains { $0.provider == agent.provider && $0.isRunning }
                )
            }
        }
    }
}

// MARK: - 关联会话按钮

/// 卡片右下角的会话入口：单个会话直接打开，多个会话用菜单列出。
struct WandBoardConversationButton: View {
    let sessions: [WandBoardTaskSession]
    let onOpen: (String) -> Void

    var body: some View {
        if sessions.isEmpty {
            EmptyView()
        } else if sessions.count == 1, let session = sessions.first {
            Button {
                onOpen(session.id)
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(WandBoardChipButtonStyle())
            .help(session.title.isEmpty ? session.id : session.title)
            .accessibilityLabel("打开关联会话")
        } else {
            Menu {
                ForEach(sessions) { session in
                    Button {
                        onOpen(session.id)
                    } label: {
                        Text("\(wandBoardProviderLabel(session.provider)) · \(session.title.isEmpty ? session.id : session.title)")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 11))
                    Text("+\(sessions.count)")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: 22)
            .fixedSize()
            .help("查看 \(sessions.count) 个关联会话")
        }
    }
}

/// 胶囊形态的小按钮（细描边、圆角端点），用于卡片上的会话 / 等待确认操作。
struct WandBoardChipButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(emphasized ? Theme.wandAccent : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(configuration.isPressed ? Color(nsColor: Theme.wandAccentMuted) : Theme.surfaceElevated))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - 进度与处理中

/// 处理中卡片的进度条：已结束会话数 / 总段数（至少 4 段）。
struct WandBoardProgressRow: View {
    let task: WandBoardTask

    var body: some View {
        if task.status == WandBoardStatus.doing.rawValue {
            let total = max(4, task.sessions.count + 2)
            let completed = task.sessions.filter { $0.status == "exited" || $0.status == "idle" }.count
            HStack(spacing: 2) {
                ForEach(0..<total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < completed ? WandBoardStatus.doing.color : WandBoardStatus.doing.color.opacity(0.18))
                        .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("完成 \(completed) / \(total) 段")
        }
    }
}

/// 4×4 跳动方块，表示 Agent 正在跑（对齐 Web `.task-board-processing-glyph`）。
private struct WandBoardProcessingGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(3), spacing: 1), count: 4)
        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(0..<16, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .fill(WandBoardStatus.doing.color)
                    .frame(width: 3, height: 3)
                    .opacity(phase ? 1 : 0.2)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double((index % 4) + (index / 4)) * 0.06),
                        value: phase
                    )
            }
        }
        .frame(width: 15, height: 15)
        .onAppear { if !reduceMotion { phase = true } }
    }
}

/// 处理中卡片的底部状态行：正在处理 / 暂停处理 / 等待派发。
struct WandBoardProcessingRow: View {
    let task: WandBoardTask
    let onOpenSession: (String) -> Void

    var body: some View {
        if task.status == WandBoardStatus.doing.rawValue {
            let running = task.sessions.contains(where: \.isRunning)
            let label = running
                ? "正在处理…"
                : (task.sessions.isEmpty ? "等待派发" : "暂停处理")
            HStack(spacing: 6) {
                if running { WandBoardProcessingGlyph() }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(running ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                WandBoardConversationButton(sessions: task.sessions, onOpen: onOpenSession)
            }
            .frame(height: 20)
        }
    }
}

// MARK: - 会话列表

/// 卡片底部的绑定会话行；可拖到另一张卡片上换归属。
struct WandBoardSessionList: View {
    let task: WandBoardTask
    let busy: Bool
    let onOpenSession: (String) -> Void
    let onUnbind: (String) -> Void

    var body: some View {
        if !task.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(task.sessions) { session in
                    HStack(spacing: 4) {
                        Button {
                            onOpenSession(session.id)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted)
                                Text(session.title.isEmpty ? (session.provider.isEmpty ? "CLI 会话" : session.provider) : session.title)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(session.title)\n\(session.cwd)")
                        .accessibilityLabel("打开会话 \(session.title)")
                    }
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.border).frame(width: 1)
                    }
                    .contextMenu {
                        Button("打开会话") { onOpenSession(session.id) }
                        Button("移出此任务") { onUnbind(session.id) }
                    }
                    .onDrag { NSItemProvider(item: session.id as NSString, typeIdentifier: wandBoardSessionDragType) }
                    .disabled(busy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 详情页的「已指派的 Agent」列表：按 CLI 工具分组，组头带模型 / 思考深度 / 工作模式。
struct WandBoardAgentSessionList: View {
    let sessions: [WandBoardTaskSession]
    let assigned: WandBoardTaskAgent?
    let onOpenSession: (String) -> Void

    var body: some View {
        let groups = wandBoardSessionGroups(sessions: sessions, assigned: assigned)
        if groups.isEmpty {
            Text("还没有指派 Agent。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            BrandLogo(provider: group.agent?.provider ?? group.provider, color: Theme.textPrimary)
                                .frame(width: 14, height: 14)
                            Text(wandBoardProviderLabel(group.agent?.provider ?? group.provider))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            if let agent = group.agent {
                                Text(wandBoardAgentSummary(agent))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text("\(group.sessions.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                        if group.sessions.isEmpty {
                            Text("已指派，等待派发")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                                .padding(.leading, 21)
                        } else {
                            ForEach(group.sessions) { session in
                                Button {
                                    onOpenSession(session.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(session.isRunning ? Theme.wandAccent : Theme.textMuted)
                                            .frame(width: 6, height: 6)
                                        Text(session.title.isEmpty ? wandBoardProviderLabel(session.provider) : session.title)
                                            .font(.system(size: 13))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(wandBoardSessionSummary(session))
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textMuted)
                                            .lineLimit(1)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(WandBoardRowButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }
}

func wandBoardAgentSummary(_ agent: WandBoardTaskAgent) -> String {
    let model = agent.model == "default" || agent.model.isEmpty ? "默认模型" : agent.model
    return "\(model) · \(wandBoardEffortLabel(agent.thinkingEffort)) · \(WandBoardAgentMode.label(forValue: agent.mode))"
}

func wandBoardSessionSummary(_ session: WandBoardTaskSession) -> String {
    let model = session.model.isEmpty || session.model == "default" ? nil : session.model
    return [model, wandBoardSessionStatusLabel(session.status)].compactMap { $0 }.joined(separator: " · ")
}

/// 列表 / 详情里成行的可点区域：hover 时给一层浅底。
struct WandBoardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Color(nsColor: Theme.wandAccentMuted) : Color.clear)
            )
    }
}

// MARK: - 表单零件

/// 表单小节标题（新建 / 详情共用）。
struct WandBoardSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「标签 + 控件」竖排字段，控制标签字体统一。
struct WandBoardField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 拖拽类型

let wandBoardTaskDragType = "com.wand.task-board.task-id"
let wandBoardSessionDragType = "com.wand.task-board.session-id"

// MARK: - 卡片

struct WandBoardCard: View {
    let task: WandBoardTask
    let display: WandBoardDisplay
    var busy = false
    var dragging = false
    var dropTarget = false
    let onOpen: () -> Void
    let onOpenSession: (String) -> Void
    let onComplete: () -> Void
    let onPatchStatus: (String) -> Void
    let onDispatch: () -> Void
    let onArchive: () -> Void
    let onRestore: () -> Void
    let onCopyIdentifier: () -> Void
    let onDropSession: (String) -> Void
    let onUnbindSession: (String) -> Void

    private var status: WandBoardStatus {
        WandBoardStatus(rawValue: task.status) ?? .todo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 3)
                Text(task.title.isEmpty ? "未命名任务" : task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if status == .done {
                    Button("完成") { onComplete() }
                        .buttonStyle(WandBoardChipButtonStyle(emphasized: true))
                        .help("确认完成")
                }
            }
            if display.body, !task.description.isEmpty, task.sessions.isEmpty, task.agent == nil {
                Text(task.description)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WandBoardProgressRow(task: task)
            cardMeta
            WandBoardSessionList(
                task: task,
                busy: busy,
                onOpenSession: onOpenSession,
                onUnbind: onUnbindSession
            )
            WandBoardProcessingRow(task: task, onOpenSession: onOpenSession)
            if dropTarget {
                Text("移入此任务 · 运行目录不变")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.wandAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(dropTarget ? Color(nsColor: Theme.wandAccentMuted) : Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(
                    dropTarget
                        ? Theme.wandAccent
                        : (status == .doing ? WandBoardStatus.doing.color.opacity(0.26) : Theme.border),
                    lineWidth: dropTarget ? 1.5 : 1
                )
        )
        .opacity(dragging ? 0 : (busy ? 0.7 : 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .onTapGesture { onOpen() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.identifier) \(task.title)")
        .onDrag { NSItemProvider(item: task.id as NSString, typeIdentifier: wandBoardTaskDragType) }
        .onDrop(of: [wandBoardSessionDragType], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let value = object as? String else { return }
                DispatchQueue.main.async { onDropSession(value) }
            }
            return true
        }
        .contextMenu {
            // 与 Web `TaskBoardContextMenu` 一致：打开 / 复制 ID / 派发 / 归档 / 恢复。
            Button("打开") { onOpen() }
            Button("复制 ID") { onCopyIdentifier() }
            Divider()
            if status == .archived {
                Button("恢复到等待认领") { onRestore() }
            } else {
                Button("派发 Agent") { onDispatch() }
                Button("移入处理中") { onPatchStatus(WandBoardStatus.doing.rawValue) }
                Divider()
                Button("归档") { onArchive() }
            }
        }
        .help(task.title)
    }

    private var cardMeta: some View {
        HStack(spacing: 4) {
            WandBoardProjectChip(name: task.workspace?.name ?? "未归属工作区")
            if let milestone = task.milestone {
                WandBoardMilestoneChip(name: milestone.name)
            }
            WandBoardPriorityChip(priority: task.priority)
            ForEach(Array(task.labels.prefix(2).enumerated()), id: \.offset) { _, label in
                WandBoardLabelChip(label: label)
            }
            if task.labels.count > 2 {
                Text("+\(task.labels.count - 2)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
            if let dueDate = task.dueDate, !dueDate.isEmpty {
                WandBoardDueChip(dueDate: dueDate, status: task.status)
            }
            WandBoardAgentChips(sessions: task.sessions, assigned: task.agent)
            if status != .doing {
                Spacer(minLength: 0)
                WandBoardConversationButton(sessions: task.sessions, onOpen: onOpenSession)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 归档目录

struct WandBoardArchiveFolder<Content: View>: View {
    let count: Int
    let open: Bool
    let onToggle: () -> Void
    let content: Content

    init(count: Int, open: Bool, onToggle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.count = count
        self.open = open
        self.onToggle = onToggle
        self.content = content()
    }

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    onToggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                        Text(WandBoardStatus.archived.label)
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(WandBoardStatus.archived.label)，\(count) 个，\(open ? "已展开" : "已收起")")
                if open { content }
            }
        }
    }
}
