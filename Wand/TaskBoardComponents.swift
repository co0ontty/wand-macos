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
            case .backlog:
                Circle().strokeBorder(status.color, style: StrokeStyle(lineWidth: 1.4, dash: [2, 2])).frame(width: 10, height: 10)
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
            case .review, .ready, .done:
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

/// 与 Web 看板/列表一致投影已有父任务与子任务数量，不复制一份归类状态。
struct WandBoardRelationshipSummary: View {
    let parent: WandBoardTask?
    let childCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if let parent {
                Label(parent.identifier.isEmpty ? parent.title : parent.identifier, systemImage: "arrow.turn.down.right")
                    .help("归属 \(parent.identifier) · \(parent.title)")
                    .accessibilityLabel("父任务 \(parent.title)")
            }
            if childCount > 0 {
                Label("\(childCount) 个子任务", systemImage: "list.bullet.indent")
            }
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.textSecondary)
        .lineLimit(1)
        .accessibilityIdentifier("task-relationship-summary")
    }
}

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
            Text(wandBoardProviderLabel(agent.provider, engine: agent.engine))
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
        .accessibilityLabel("\(wandBoardProviderLabel(agent.provider, engine: agent.engine))\(running ? "，正在运行" : "")")
    }
}

struct WandBoardAgentChips: View {
    var assignee: WandBoardAssignedExecutor? = nil
    var subject: WandTaskExecutionSubject? = nil
    let sessions: [WandBoardTaskSession]
    let assigned: WandBoardTaskAgent?
    var compact = false
    @State private var showPeople = false

    var body: some View {
        let assignee = self.assignee ?? subject.flatMap { subject in
            subject.type == "cli" ? nil : WandBoardAssignedExecutor(id: subject.id,
                name: subject.type == "employee" ? "已指派员工（资料不可用）" : "已指派团队", avatar: nil)
        }
        let people = Dictionary(grouping: sessions.filter { $0.employeeId != nil || $0.employeeName != nil }, by: { $0.employeeId ?? $0.employeeName ?? $0.id })
        let direct = sessions.filter { $0.employeeId == nil && $0.employeeName == nil }
        let orderedKeys = people.keys.sorted { left, right in
            if left == assignee?.id { return right != assignee?.id }
            if right == assignee?.id { return false }
            return left < right
        }
        let tools = wandBoardListAgents(sessions: direct, assigned: people.isEmpty && assignee == nil ? assigned : nil)
        let unstarted = assignee != nil && !sessions.contains { $0.employeeId == assignee?.id }
        if compact {
            HStack(spacing: 5) {
                if unstarted, let assignee {
                    ContactAvatar(id: assignee.id, avatar: assignee.avatar ?? "", name: assignee.name, size: 20)
                    Text(assignee.name).lineLimit(1)
                    Text("已指派").foregroundColor(Theme.textSecondary).font(.caption2)
                } else if let key = orderedKeys.first, let first = people[key]?.first,
                    let identity = wandBoardEmployeeIdentity(first, sessions: sessions, assignee: self.assignee) {
                    ContactAvatar(id: identity.id, avatar: identity.avatar ?? "", name: identity.name, size: 20)
                    Text(identity.name).lineLimit(1)
                    Text(people[key]?.contains(where: { $0.isRunning }) == true ? "执行中" : "历史执行")
                        .foregroundColor(Theme.textSecondary).font(.caption2)
                } else if let tool = tools.first {
                    WandBoardAgentChip(agent: tool, running: direct.contains { $0.isRunning })
                } else {
                    Text("待指派").foregroundColor(Theme.textSecondary)
                }
                let count = people.count + tools.count + (unstarted ? 1 : 0)
                if count > 1 {
                    Button("+\(count - 1)") { showPeople.toggle() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看全部 \(count) 位执行者")
                        .popover(isPresented: $showPeople) {
                            WandBoardAgentChips(assignee: self.assignee, subject: subject, sessions: sessions, assigned: assigned)
                                .padding(16)
                        }
                }
            }
            .font(.caption)
        } else {
        VStack(alignment: .leading, spacing: 4) {
            if let assignee, !sessions.contains(where: { $0.employeeId == assignee.id }) {
                HStack(spacing: 6) {
                    ContactAvatar(id: assignee.id, avatar: assignee.avatar ?? "", name: assignee.name, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assignee.name + " · 已指派 · 未启动")
                        if let assigned {
                            Text(wandBoardProviderLabel(assigned.provider, engine: assigned.engine)).foregroundColor(Theme.textSecondary)
                        }
                    }
                }.font(.caption)
            }
            ForEach(people.keys.sorted { left, right in
                if left == assignee?.id { return right != assignee?.id }
                if right == assignee?.id { return false }
                return left < right
            }, id: \.self) { key in
                if let first = people[key]?.first, let identity = wandBoardEmployeeIdentity(first, sessions: sessions, assignee: self.assignee) {
                    HStack(spacing: 6) {
                        ContactAvatar(id: identity.id, avatar: identity.avatar ?? "", name: identity.name, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(identity.name)
                                Text(people[key]?.contains(where: { $0.isRunning }) == true ? "执行中" : "历史执行").foregroundColor(Theme.textSecondary)
                            }
                            Text(wandBoardListAgents(sessions: people[key] ?? [], assigned: nil)
                                .map { wandBoardProviderLabel($0.provider, engine: $0.engine) }.joined(separator: " · "))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }.font(.caption)
                }
            }
            ForEach(wandBoardListAgents(sessions: direct, assigned: people.isEmpty && assignee == nil ? assigned : nil), id: \.toolKey) { agent in
                WandBoardAgentChip(agent: agent, running: direct.contains { $0.provider == agent.provider && $0.toolEngine == (agent.engine ?? "cli") && $0.isRunning })
            }
            if sessions.isEmpty && assigned == nil && assignee == nil { Text("待指派").font(.caption).foregroundColor(Theme.textSecondary) }
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
                        Text("\(wandBoardProviderLabel(session.provider, engine: session.engine)) · \(session.title.isEmpty ? session.id : session.title)")
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

/// 处理中卡片的底部真实执行状态；不从空闲推断暂停或验收。
struct WandBoardProcessingRow: View {
    let task: WandBoardTask
    let onOpenSession: (String) -> Void

    var body: some View {
        if task.status == WandBoardStatus.doing.rawValue {
            let running = task.executionStatus == "running" || task.sessions.contains(where: \.isRunning)
            let label = wandBoardTaskProcessingLabel(task)
            HStack(spacing: 6) {
                if running { WandBoardProcessingGlyph() }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(running ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                if task.pendingExecutionCount > 0 {
                    Text("· \(task.pendingExecutionCount) 条待执行")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
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
                                    .wandLogoGlow(status: session.logoGlowStatus, archived: task.status == "archived")
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

/// 任务详情中的真实会话汇总；结束、失败和未知状态不被误报为验收通过。
struct WandBoardSessionSummaryView: View {
    let sessions: [WandBoardTaskSession]

    var body: some View {
        let summary = WandBoardSessionActivitySummary(sessions: sessions)
        if summary.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("执行会话")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("共 \(summary.total) 个")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                HStack(spacing: 6) {
                    summaryChip("运行", summary.running, Theme.wandAccent)
                    summaryChip("等待输入", summary.waitingInput, Theme.warning)
                    summaryChip("等待授权", summary.waitingAuthorization, Theme.warning)
                    summaryChip("排队", summary.queued, Theme.textSecondary)
                }
                HStack(spacing: 6) {
                    summaryChip("空闲", summary.idle, Theme.textSecondary)
                    summaryChip("结束/失败", summary.endedOrFailed, Theme.textTertiary)
                    summaryChip("归档", summary.archived, Theme.textSecondary)
                    summaryChip("未知", summary.unknown, Theme.warning)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("执行会话，共 \(summary.total) 个；运行 \(summary.running)，等待输入 \(summary.waitingInput)，排队 \(summary.queued)，空闲 \(summary.idle)，结束或失败 \(summary.endedOrFailed)，未知 \(summary.unknown)")
        }
    }

    private func summaryChip(_ label: String, _ count: Int, _ color: Color) -> some View {
        Text("\(label) \(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(count > 0 ? color : Theme.textMuted)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(count > 0 ? color.opacity(0.12) : Theme.surfaceElevated))
    }
}

/// 详情页的「已指派的 Agent」列表：按 CLI 工具分组，组头带模型 / 思考深度 / 工作模式。
struct WandBoardAgentSessionList: View {
    var assignee: WandBoardAssignedExecutor? = nil
    let sessions: [WandBoardTaskSession]
    let assigned: WandBoardTaskAgent?
    let onOpenSession: (String) -> Void
    /// 模型目录：把 `default` 哨兵换成服务端默认模型的名字；没加载到就只省掉模型段。
    var catalog: ModelsResponse?

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
                WandBoardAgentChips(assignee: assignee, sessions: sessions, assigned: assigned)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            BrandLogo(provider: group.agent?.provider ?? group.provider, color: Theme.textPrimary)
                                .frame(width: 14, height: 14)
                            Text(wandBoardProviderLabel(group.agent?.provider ?? group.provider, engine: group.agent?.engine))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            if let agent = group.agent {
                                Text(wandBoardAgentSummary(agent, catalog))
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
                            Text("已保存配置，尚未派发")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                                .padding(.leading, 21)
                        } else {
                            ForEach(group.sessions) { session in
                                Button {
                                    onOpenSession(session.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(session.isRunning ? Theme.wandAccent : Theme.textMuted)
                                                .frame(width: 6, height: 6)
                                            Text(session.displayPurpose.isEmpty ? wandBoardProviderLabel(session.provider, engine: session.engine) : session.displayPurpose)
                                                .font(.system(size: 13))
                                                .foregroundColor(Theme.textPrimary)
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Text(session.activityLabel)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(session.isRunning ? Theme.wandAccent : Theme.textMuted)
                                                .lineLimit(1)
                                            Image(systemName: "arrow.up.right")
                                                .font(.system(size: 10))
                                                .foregroundColor(Theme.textMuted)
                                        }
                                        Text([session.employeeName,
                                              session.cwd.isEmpty ? nil : session.cwd,
                                              wandModelDisplayName(provider: session.provider, model: session.model, catalog: catalog)]
                                            .compactMap { value in value?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                            .filter { !$0.isEmpty }
                                            .joined(separator: " · "))
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textMuted)
                                            .lineLimit(1)
                                        Text(session.taskCommentId == nil ? "原记录 · 继续此会话" : "评论执行 · 继续此会话")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(Theme.wandAccent)
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

/// 组头的「模型 · 思考深度 · 工作模式」：`default` 哨兵换成服务端默认模型的名字。
func wandBoardAgentSummary(_ agent: WandBoardTaskAgent, _ catalog: ModelsResponse? = nil) -> String {
    let model = wandModelDisplayName(provider: agent.provider, model: agent.model, catalog: catalog)
    return [model.isEmpty ? nil : model,
            wandBoardEffortLabel(agent.thinkingEffort),
            WandBoardAgentMode.label(forValue: agent.mode)].compactMap { $0 }.joined(separator: " · ")
}

/// 会话行的「模型 · 状态」：同上，拿不到模型名就只留状态，不写「默认模型」。
func wandBoardSessionSummary(_ session: WandBoardTaskSession, _ catalog: ModelsResponse? = nil) -> String {
    let model = wandModelDisplayName(provider: session.provider, model: session.model, catalog: catalog)
    return [model.isEmpty ? nil : model, wandBoardSessionStatusLabel(session.status)]
        .compactMap { $0 }
        .joined(separator: " · ")
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
    @State private var expanded = false
    let task: WandBoardTask
    let display: WandBoardDisplay
    var parent: WandBoardTask? = nil
    var childCount = 0
    var showWorkspace = true
    var busy = false
    var dragging = false
    var dropTarget = false
    let onOpen: () -> Void
    var onOpenComments: () -> Void = {}
    let onOpenSession: (String) -> Void
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
            HStack(spacing: 6) {
                Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                WandBoardPriorityChip(priority: task.priority)
                Spacer(minLength: 0)
            }
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(task.title.isEmpty ? "未命名任务" : task.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(3)
                        .frame(height: 54, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "收起" : "展开") \(task.identifier): \(task.title)")
            if display.body {
                Text(task.description.isEmpty ? "尚未填写说明" : task.description)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(height: 32, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(wandBoardTaskProcessingLabel(task))
                .font(.caption)
                .foregroundColor(wandBoardHasCurrentHumanAcceptance(task) ? Theme.success : Theme.textSecondary)
                .lineLimit(1)
                .frame(height: 24, alignment: .leading)
            cardMeta
                .frame(height: 24, alignment: .topLeading)
                .clipped()
            HStack(spacing: 6) {
                WandBoardAgentChips(assignee: task.assignedExecutor, subject: task.executionSubject, sessions: task.sessions, assigned: task.agent, compact: true)
                Spacer(minLength: 0)
                Group {
                    if task.sessions.isEmpty {
                        Button {} label: { Image(systemName: "bubble.left").font(.system(size: 11)) }
                            .buttonStyle(WandBoardChipButtonStyle())
                            .disabled(true)
                            .accessibilityLabel("暂无关联会话")
                    } else {
                        WandBoardConversationButton(sessions: task.sessions, onOpen: onOpenSession)
                    }
                }
                .frame(width: 44, height: 24, alignment: .trailing)
                Button("评论 \(task.commentCount)") { onOpenComments() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .monospacedDigit()
                    .frame(minWidth: 58, alignment: .trailing)
                    .accessibilityLabel("查看评论（\(task.commentCount)）")
            }
            .frame(height: 28)
            .padding(.top, 8)
            .overlay(alignment: .top) { Divider() }
            if expanded {
                WandTaskInlineSummary(task: task, onOpen: onOpen)
            WandBoardSessionList(
                task: task,
                busy: busy,
                onOpenSession: onOpenSession,
                onUnbind: onUnbindSession
            )
            WandBoardProcessingRow(task: task, onOpenSession: onOpenSession)
            }
            Text(dropTarget ? "移入此任务 · 运行目录不变" : "")
                .font(.system(size: 11))
                .foregroundColor(Theme.wandAccent)
                .lineLimit(1)
                .frame(height: 16)
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
        .wandMotion(value: expanded, layout: true)

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
        Group {
            if #available(macOS 13.0, *) {
                ViewThatFits(in: .horizontal) {
                    cardProperties
                    stackedCardProperties
                }
            } else {
                cardProperties
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stackedCardProperties: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            cardProperties.fixedSize(horizontal: true, vertical: false)
        }
    }

    private var cardProperties: some View {
        HStack(spacing: 4) {
            if showWorkspace { WandBoardProjectChip(name: task.workspace?.name ?? "未归属工作区") }
            if let milestone = task.milestone, milestone.name != "默认迭代" {
                WandBoardMilestoneChip(name: milestone.name)
            }
            cardLabels
        }
    }

    @ViewBuilder private var cardLabels: some View {
            if childCount > 0 {
                Text("子任务 \(childCount)").font(.caption).foregroundColor(Theme.textSecondary)
            }
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


struct WandGoalChildren: View {
    let task: WandBoardTask
    let tasks: [WandBoardTask]
    let onOpen: (String) -> Void
    var body: some View {
        let children = wandBoardChildren(of: task, in: tasks)
        if !children.isEmpty {
            DisclosureGroup {
                Text("\(children.filter { wandBoardHasCurrentHumanAcceptance($0) }.count)/\(children.count) 个人工已确认 · \(wandBoardHasCurrentHumanAcceptance(task) ? "主目标已确认" : "主目标待整体验收")")
                    .font(.caption).foregroundColor(Theme.textSecondary)
                ForEach(children) { child in
                    VStack(alignment: .leading, spacing: 4) {
                        WandTaskSummaryDisclosure(task: child, onOpen: { onOpen(child.id) })
                        if !wandBoardChildren(of: child, in: tasks).isEmpty { Text("历史深层关系保留，可进入详情查看；调整前需确认").font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                HStack(spacing: 8) {
                    Text("子任务 \(children.count)")
                    Spacer(minLength: 0)
                    Text("\(children.filter { wandBoardHasCurrentHumanAcceptance($0) }.count)/\(children.count) 已确认")
                        .foregroundColor(Theme.textSecondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 6)
        }
    }
}


@MainActor private enum TaskAcceptanceDrafts {
    static var values: [String: (evidence: String, blocker: String)] = [:]
    static var requests: [String: String] = [:]
}

struct WandTaskAcceptanceEditor: View {
    let task: WandBoardTask
    let children: [WandBoardTask]
    let busy: Bool
    let onWorkflow: ([String: Any]) async -> Bool
    @State private var evidence: String
    @State private var blocker: String
    @State private var pendingAction: String?
    @State private var receiptAction: String?
    @State private var receiptSucceeded = false

    init(task: WandBoardTask, children: [WandBoardTask], busy: Bool, onWorkflow: @escaping ([String: Any]) async -> Bool) {
        self.task = task; self.children = children; self.busy = busy; self.onWorkflow = onWorkflow
        let draft = TaskAcceptanceDrafts.values[task.id]
        _evidence = State(initialValue: draft?.evidence ?? task.acceptance?.evidence ?? task.verification?.evidence ?? "")
        _blocker = State(initialValue: draft?.blocker ?? task.acceptance?.blocker ?? task.verification?.blocker ?? "")
    }
    private var cleanEvidence: String { evidence.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanBlocker: String { blocker.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var childGaps: Bool { children.contains { !wandBoardHasCurrentAIVerification($0) } }
    private var actions: [(String, String, Bool)] { [
        ("submit", "提交 AI 验收", task.status == "doing" && !cleanEvidence.isEmpty && cleanBlocker.isEmpty),
        ("pass", "记录 AI 通过", task.status == "review" && !cleanEvidence.isEmpty && cleanBlocker.isEmpty && children.allSatisfy { ["review", "ready", "archived"].contains($0.status) && ($0.acceptance?.blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
        ("fail", "验收失败并退回", task.status == "review" && !cleanBlocker.isEmpty),
        ("accept", "确认并归档", task.status == "ready" && wandBoardHasCurrentAIVerification(task) && !childGaps && !cleanEvidence.isEmpty && cleanBlocker.isEmpty),
        ("return", "退回执行", task.status == "ready" && !cleanBlocker.isEmpty)
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("交付与验收").font(.headline)
            Text("AI 通过后仍需你确认归档；会话结束和旧验收日期不等于本轮完成。").font(.caption).foregroundColor(Theme.textSecondary)
            TextField("交付证据、产物版本或源会话", text: $evidence).textFieldStyle(.roundedBorder).disabled(busy || pendingAction != nil || task.status == "archived")
            TextField("失败、无法验证或退回原因", text: $blocker).textFieldStyle(.roundedBorder).disabled(busy || pendingAction != nil || task.status == "archived")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], alignment: .leading, spacing: 8) {
                ForEach(actions, id: \.0) { entry in
                    Button { workflow(entry.0) } label: {
                        HStack(spacing: 6) {
                            ZStack { if pendingAction == entry.0 { ProgressView().controlSize(.mini) } }.frame(width: 14, height: 14)
                            ZStack {
                                ForEach([entry.1, "提交中…", "未确认，请核对", successTitle(entry.0)], id: \.self) { copy in Text(copy).hidden().accessibilityHidden(true) }
                                Text(buttonTitle(entry.0, entry.1))
                            }.frame(maxWidth: .infinity)
                        }
                    }.buttonStyle(.bordered).disabled(busy || pendingAction != nil || !entry.2)
                }
            }
            if task.legacyReview { Text("历史记录待核对；不会自动认定 AI 或人工已通过。").font(.caption).foregroundColor(Theme.warning) }
            if wandBoardHasCurrentAIVerification(task) { Text("AI 已通过当前交付，等待人工确认。").font(.caption).foregroundColor(Theme.success) }
            if receiptAction != nil { Text(receiptSucceeded ? "动作已由服务端确认；下一步以当前任务阶段为准。" : "动作未确认，草稿与请求标识已保留，请核对任务及服务版本后重试。").font(.caption).foregroundColor(receiptSucceeded ? Theme.textSecondary : Theme.warning) }
        }
        .onChange(of: evidence) { _ in cacheDraft(); if pendingAction == nil { receiptAction = nil } }
        .onChange(of: blocker) { _ in cacheDraft(); if pendingAction == nil { receiptAction = nil } }
    }
    private func buttonTitle(_ action: String, _ fallback: String) -> String {
        if pendingAction == action { return "提交中…" }
        guard receiptAction == action else { return fallback }
        if !receiptSucceeded { return "未确认，请核对" }
        return successTitle(action)
    }
    private func successTitle(_ action: String) -> String {
        ["submit": "已提交 AI 验收", "pass": "已进入待归档", "fail": "已退回执行", "accept": "已确认并归档", "return": "已退回执行"][action] ?? "动作已确认"
    }
    private func cacheDraft() {
        if TaskAcceptanceDrafts.values.count >= 100, let oldest = TaskAcceptanceDrafts.values.keys.first { TaskAcceptanceDrafts.values.removeValue(forKey: oldest) }
        TaskAcceptanceDrafts.values[task.id] = (evidence, blocker)
    }
    private func workflow(_ action: String) {
        guard pendingAction == nil else { return }
        cacheDraft()
        let proof = cleanEvidence, gap = cleanBlocker
        let key = (try? JSONSerialization.data(withJSONObject: [task.id, action, task.updatedAt, proof, gap]).base64EncodedString()) ?? UUID().uuidString
        let requestId = TaskAcceptanceDrafts.requests[key] ?? UUID().uuidString
        if TaskAcceptanceDrafts.requests.count >= 100, let oldest = TaskAcceptanceDrafts.requests.keys.first { TaskAcceptanceDrafts.requests.removeValue(forKey: oldest) }
        TaskAcceptanceDrafts.requests[key] = requestId
        let payload: [String: Any] = ["workflow": ["action": action, "requestId": requestId, "expectedUpdatedAt": task.updatedAt, "evidence": proof, "blocker": gap]]
        pendingAction = action; receiptAction = nil
        Task {
            let accepted = await onWorkflow(payload)
            pendingAction = nil; receiptAction = action; receiptSucceeded = accepted
        }
    }
}

/// All board surfaces distinguish reading a summary from opening the inspector.
struct WandTaskInlineSummary: View {
    let task: WandBoardTask
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作：\(wandBoardTaskWorkLabel(task)) · 验收：\(wandBoardTaskReviewLabel(task))")
                .font(.caption).foregroundColor(Theme.textSecondary)
            if let blocker = task.acceptance?.blocker, !blocker.isEmpty {
                Text("阻塞：\(blocker)").font(.callout).foregroundColor(Theme.warning).textSelection(.enabled)
            }
            if !task.description.isEmpty { Text(task.description).font(.callout).lineLimit(5).textSelection(.enabled) }
            Text("\(task.assignedExecutor?.name ?? "未指派") · \(task.sessions.count) 个执行会话 · 评论 \(task.commentCount)")
                .font(.caption).foregroundColor(Theme.textSecondary)
            Button("查看详情", action: onOpen).buttonStyle(WandSecondaryButtonStyle())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

struct WandTaskSummaryDisclosure: View {
    let task: WandBoardTask
    let onOpen: () -> Void
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            WandTaskInlineSummary(task: task, onOpen: onOpen)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? "未命名任务" : task.title).font(.callout).fontWeight(.medium)
                Text(task.identifier).font(.caption).foregroundColor(Theme.textSecondary)
            }
        }.padding(.vertical, 4)
    }
}
