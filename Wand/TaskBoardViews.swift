import SwiftUI

// MARK: - 列表视图

/// 列表视图：按状态分组的紧凑行，组头可折叠；归档目录挂在「等你确认」组内。
struct WandBoardListView: View {
    @State private var expandedId = ""
    let grouped: [String: [WandBoardTask]]
    var allTasks: [WandBoardTask] = []
    let collapsed: Set<String>
    let archiveOpen: Bool
    let onToggle: (String) -> Void
    let onToggleArchive: () -> Void
    let onOpenTask: (String) -> Void
    var onOpenComments: (String) -> Void = { _ in }
    let onOpenSession: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(WandBoardStatus.columns) { status in group(status) }
                WandBoardArchiveFolder(count: (grouped["archived"] ?? []).count, open: archiveOpen, onToggle: onToggleArchive) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(grouped["archived"] ?? []) { task in
                            row(task)
                            WandGoalChildren(task: task, tasks: allTasks, onOpen: onOpenTask)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func group(_ status: WandBoardStatus) -> some View {
        let items = grouped[status.rawValue] ?? []
        let isCollapsed = collapsed.contains(status.rawValue)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                onToggle(status.rawValue)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                    WandBoardStatusGlyph(status: status)
                    Text(status.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(items.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(status.label)，\(items.count) 个，\(isCollapsed ? "已收起" : "已展开")")

            if !isCollapsed {
                if items.isEmpty {
                    Text(status.empty)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                ForEach(items) { task in
                    row(task)
                    WandGoalChildren(task: task, tasks: allTasks, onOpen: onOpenTask)
                }
            }
        }
    }

    private func row(_ task: WandBoardTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                WandBoardStatusGlyph(status: WandBoardStatus(rawValue: task.status) ?? .todo)
                Button { expandedId = expandedId == task.id ? "" : task.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    Text(task.title.isEmpty ? "未命名任务" : task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(wandBoardTaskProcessingLabel(task)).font(.caption).foregroundColor(wandBoardHasCurrentHumanAcceptance(task) ? Theme.success : Theme.textSecondary)
                    let parent = wandBoardParent(of: task, in: allTasks)
                    let children = wandBoardChildren(of: task, in: allTasks)
                    if parent != nil || !children.isEmpty {
                        WandBoardRelationshipSummary(parent: parent, childCount: children.count)
                    }
                }
                }.buttonStyle(.plain).accessibilityLabel("\(expandedId == task.id ? "收起" : "展开") \(task.identifier): \(task.title)")
                Spacer(minLength: 12)
                Button("评论 \(task.commentCount)") { onOpenComments(task.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityLabel("查看评论（\(task.commentCount)）")
                HStack(spacing: 4) {
                    WandBoardPriorityChip(priority: task.priority)
                    if let milestone = task.milestone {
                        WandBoardMilestoneChip(name: milestone.name)
                    }
                    ForEach(Array(task.labels.prefix(2).enumerated()), id: \.offset) { _, label in
                        WandBoardLabelChip(label: label)
                    }
                    if let dueDate = task.dueDate, !dueDate.isEmpty {
                        WandBoardDueChip(dueDate: dueDate, status: task.status)
                    }
                    Text(task.workspace?.name ?? "未归属工作区")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    WandBoardConversationButton(sessions: task.sessions, onOpen: onOpenSession)
                    Text(wandBoardFormatStamp(task.updatedAt))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        .help("点击标题展开摘要")
        if expandedId == task.id { WandTaskInlineSummary(task: task, onOpen: { onOpenTask(task.id) }) }
        }
    }

}

// MARK: - 概览视图

/// 概览视图：剩余量、五张指标卡、进度折线图与四块分布面板。
struct WandBoardDashboardView: View {
    let projectName: String
    let tasks: [WandBoardTask]
    var allTasks: [WandBoardTask] = []
    var api: WandAPI? = nil
    var actionWorkspaceId = ""
    var onOpenAcceptance: ((String) -> Void)? = nil
    let onOpenTask: (String) -> Void
    let onOpenSession: (String) -> Void

    var body: some View {
        let stats = wandBoardStats(tasks: tasks)
        let series = wandBoardProgressSeries(tasks: tasks)
        let dueSoon = tasks
            .filter { $0.dueDate?.isEmpty == false && $0.status != WandBoardStatus.ready.rawValue && $0.status != WandBoardStatus.archived.rawValue }
            .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
            .prefix(6)
        let humanQueue = tasks.filter { $0.status == WandBoardStatus.ready.rawValue && wandBoardHasCurrentAIVerification($0) }.prefix(6)
        let priorityRows = WandBoardPriority.allCases.compactMap { priority -> (WandBoardPriority, Int)? in
            let count = tasks.filter { $0.priority == priority.rawValue }.count
            return count > 0 ? (priority, count) : nil
        }
        let labels = wandBoardCollectLabels(tasks: tasks).map { label in
            (label, tasks.filter { $0.labels.contains(label) }.count)
        }
        let recentSessions = tasks.flatMap { task in
            task.sessions.map { (task, $0) }
        }.prefix(6)
        let summary = stats.remaining == 0
            ? "\(projectName) 当前没有已立项的未完成任务。\(stats.backlog > 0 ? "另有 \(stats.backlog) 项待立项。" : "")"
            : "\(projectName) 还有 \(stats.remaining) 项已立项任务未完成，其中 \(stats.doing) 项正在处理、\(stats.todo) 项等待认领。\(stats.backlog > 0 ? "另有 \(stats.backlog) 项待立项。" : "")"

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let api {
                    WandTaskActionsView(api: api, workspaceId: actionWorkspaceId, onOpenSession: onOpenSession,
                        onOpenAcceptance: onOpenAcceptance ?? onOpenTask)
                }
                ForEach(tasks) { task in WandGoalChildren(task: task, tasks: allTasks, onOpen: onOpenTask) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(projectName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(stats.total > 0 ? Int((Double(stats.accepted) / Double(stats.total) * 100).rounded()) : 0)%")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.wandAccent)
                        Text("人工确认完成度")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                .fill(Theme.surface)
                        )
                }

                HStack(alignment: .top, spacing: 12) {
                    metric("待立项", stats.backlog, WandBoardStatus.backlog.color, stats.total)
                    metric("等待认领", stats.todo, WandBoardStatus.todo.color, stats.total)
                    metric("执行中", stats.doing, WandBoardStatus.doing.color, stats.total)
                    metric("待验收", stats.review, WandBoardStatus.review.color, stats.total)
                    metric("待归档", stats.ready, WandBoardStatus.ready.color, stats.total)
                }

                panel("待你确认归档 · \(tasks.filter { $0.status == WandBoardStatus.ready.rawValue && wandBoardHasCurrentAIVerification($0) }.count)") {
                    if humanQueue.isEmpty {
                        emptyPanelText("暂无 AI 已通过、待人工确认的任务")
                    } else {
                        ForEach(humanQueue) { task in
                            HStack(alignment: .top, spacing: 12) {
                                WandTaskSummaryDisclosure(task: task, onOpen: { onOpenTask(task.id) })
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("查看交付") { (onOpenAcceptance ?? onOpenTask)(task.id) }
                                    .buttonStyle(WandSecondaryButtonStyle())
                                    .fixedSize()
                            }
                        }
                    }
                }

                progressPanel(stats: stats, series: series)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                    spacing: 16
                ) {
                    panel("即将到期") {
                        if dueSoon.isEmpty {
                            emptyPanelText("没有设置截止日期的任务")
                        } else {
                            ForEach(dueSoon) { task in
                                WandTaskSummaryDisclosure(task: task, onOpen: { onOpenTask(task.id) })
                            }
                        }
                    }
                    panel("优先级") {
                        if priorityRows.isEmpty {
                            emptyPanelText("还没有优先级分布")
                        } else {
                            ForEach(priorityRows, id: \.0.id) { priority, count in
                                stackRow(
                                    leading: {
                                        Image(systemName: priority.symbolName)
                                            .font(.system(size: 11))
                                            .foregroundColor(priority.color)
                                    },
                                    label: priority.label,
                                    count: count,
                                    ratio: Double(count) / Double(max(1, stats.total)),
                                    color: priority.color
                                )
                            }
                        }
                    }
                    panel("标签") {
                        if labels.isEmpty {
                            emptyPanelText("还没有标签")
                        } else {
                            ForEach(labels, id: \.0) { label, count in
                                HStack(spacing: 8) {
                                    WandBoardLabelChip(label: label)
                                    Spacer(minLength: 0)
                                    Text("\(count)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(Theme.textSecondary)
                                }
                                .frame(height: 24)
                            }
                        }
                    }
                    panel("最近会话") {
                        if recentSessions.isEmpty {
                            emptyPanelText("还没有派发会话")
                        } else {
                            ForEach(Array(recentSessions.enumerated()), id: \.offset) { _, entry in
                                dashboardRow(
                                    action: { onOpenSession(entry.1.id) },
                                    glyph: {
                                        BrandLogo(provider: entry.1.provider, color: Theme.textPrimary)
                                            .frame(width: 12, height: 12)
                                            .wandLogoGlow(status: entry.1.logoGlowStatus, archived: entry.0.status == "archived")
                                    },
                                    title: entry.0.title
                                ) {
                                    Text(wandBoardProviderLabel(entry.1.provider))
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color, _ total: Int) -> some View {
        let ratio = total > 0 ? Double(value) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(value)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color).frame(width: geometry.size.width * ratio)
                }
            }
            .frame(height: 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 1)
        )
    }

    private func progressPanel(stats: WandBoardStats, series: [WandBoardProgressPoint]) -> some View {
        let maxValue = max(1, series.map(\.scope).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("进度")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                legend("范围", stats.total, WandBoardStatus.todo.color)
                legend("已开始", stats.doing + stats.review + stats.ready, WandBoardStatus.doing.color)
                legend("已归档", stats.accepted, WandBoardStatus.ready.color)
            }
            ZStack {
                Canvas { context, size in
                    let baseline = Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height - 4))
                        path.addLine(to: CGPoint(x: size.width, y: size.height - 4))
                    }
                    context.stroke(baseline, with: .color(Color(nsColor: Theme.borderSubtle)), lineWidth: 1)
                    let step = size.width / CGFloat(max(1, series.count - 1))
                    func line(_ key: KeyPath<WandBoardProgressPoint, Int>, color: Color) {
                        var path = Path()
                        for (index, point) in series.enumerated() {
                            let value = CGFloat(point[keyPath: key]) / CGFloat(maxValue)
                            let position = CGPoint(
                                x: CGFloat(index) * step,
                                y: (size.height - 12) * (1 - value) + 6
                            )
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                    line(\.scope, color: WandBoardStatus.todo.color.opacity(0.7))
                    line(\.started, color: WandBoardStatus.doing.color)
                    line(\.completed, color: WandBoardStatus.ready.color)
                }
                .frame(height: 160)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 1)
        )
    }

    private func legend(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text("\(value)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func panel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 1)
        )
    }

    private func emptyPanelText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func dashboardRow<Glyph: View, Trailing: View>(
        action: @escaping () -> Void,
        @ViewBuilder glyph: () -> Glyph,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                glyph()
                Text(title.isEmpty ? "未命名任务" : title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WandBoardRowButtonStyle())
    }

    private func stackRow<Leading: View>(
        @ViewBuilder leading: () -> Leading,
        label: String,
        count: Int,
        ratio: Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                leading()
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color).frame(width: geometry.size.width * ratio)
                }
            }
            .frame(height: 3)
        }
    }
}

// MARK: - 甘特视图

/// 甘特视图：状态分组 + 时间轴条，支持日 / 周 / 月尺度与隐藏已确认。
struct WandBoardGanttView: View {
    @State private var anchor = Date()
    @State private var expandedWeeks: Set<String> = []
    let selectedStatuses: Set<String>
    let onStatuses: (Set<String>) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let grouped: [String: [WandBoardTask]]
    var allTasks: [WandBoardTask] = []
    let zoom: WandBoardGanttZoom
    let hideCompleted: Bool
    let onZoom: (WandBoardGanttZoom) -> Void
    let onHideCompleted: (Bool) -> Void
    let onOpenTask: (String) -> Void

    private let labelWidth: CGFloat = 100
    private let rowHeight: CGFloat = 56
    private var cellWidth: CGFloat { zoom == .day ? 580 : zoom == .week ? 220 : 180 }
    private let quickStatuses: [WandBoardStatus] = [.backlog, .todo, .review, .ready]
    private func label(_ status: WandBoardStatus) -> String {
        status == .backlog ? "待排期" : status == .todo ? "待认领" : status.label
    }
    private func participants(_ task: WandBoardTask) -> [WandBoardAssignedExecutor] {
        var seen = Set<String>()
        return task.sessions.compactMap { session in
            guard let person = wandBoardEmployeeIdentity(session, sessions: task.sessions, assignee: task.assignedExecutor), seen.insert(person.id).inserted else { return nil }
            return person
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            timeline(today: context.date)
        }
    }

    private func timeline(today: Date) -> some View {
        let range = wandBoardGanttRange(zoom: zoom, today: anchor)
        let tasks = grouped.values.flatMap { $0 }.filter { !hideCompleted || $0.status != "archived" || wandBoardHasOpenDescendant($0, in: allTasks) }
            .filter { wandBoardGanttSpan(task: $0, range: range, today: today).length > 0 }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(quickStatuses) { status in
                    Button(label(status)) { onStatuses(selectedStatuses == [status.rawValue] ? [] : [status.rawValue]) }
                        .buttonStyle(WandBoardSegmentButtonStyle(active: selectedStatuses == [status.rawValue]))
                }
                Toggle("隐藏已归档",  isOn: Binding(get: { hideCompleted }, set: onHideCompleted))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(WandBoardGanttZoom.allCases) { entry in
                        Button(entry.label) { onZoom(entry) }
                            .buttonStyle(WandBoardSegmentButtonStyle(active: entry == zoom))
                    }
                }
            }
            .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button("上一时段") { navigate(-1, range: range) }
                Text(range.start + (range.days > 1 ? " — " + (range.columns.last ?? "") : ""))
                    .font(.system(size: 13, weight: .semibold))
                Button("下一时段") { navigate(1, range: range) }
                Button("回到今天") { anchor = Date() }
                Spacer()
                Text("\(tasks.count) 个任务 · 时长为创建至今").font(.caption).foregroundColor(Theme.textSecondary)
            }.padding(.horizontal, 28)

            if zoom == .month {
                monthGrid(tasks: tasks, range: range, today: today)
            } else {
            ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    headRow(range: range)
                    if tasks.isEmpty { Text("这个时段没有匹配的任务，可切换日期或筛选").foregroundColor(Theme.textSecondary).padding() }
                    group(items: tasks, range: range, today: today)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .onAppear { proxy.scrollTo("gantt-today", anchor: .trailing) }
            .onChange(of: zoom) { _ in proxy.scrollTo("gantt-today", anchor: .trailing) }
            }
            }
        }
    }

    private func monthWeeks(_ range: WandBoardGanttRange) -> [WandBoardGanttRange] {
        guard let first = wandBoardDay(fromDueDate: range.start) else { return [] }
        let calendar = Calendar.current
        let offset = calendar.component(.weekday, from: first) - 1
        let origin = calendar.date(byAdding: .day, value: -offset, to: first) ?? first
        return (0..<((offset + range.days + 6) / 7)).map { week in
            let columns = (0..<7).map { day in wandBoardIsoDate(calendar.date(byAdding: .day, value: week * 7 + day, to: origin) ?? origin) }
            return WandBoardGanttRange(start: columns[0], days: 7, columns: columns)
        }
    }

    private func monthGrid(tasks: [WandBoardTask], range: WandBoardGanttRange, today: Date) -> some View {
        GeometryReader { geometry in
            let width = max(840, geometry.size.width - 56)
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(["周日", "周一", "周二", "周三", "周四", "周五", "周六"], id: \.self) { day in
                            Text(day).font(.system(size: 12)).foregroundColor(Theme.textSecondary).frame(width: width / 7, height: 36)
                        }
                    }
                    ForEach(monthWeeks(range), id: \.start) { week in
                        monthWeek(tasks: tasks, week: week, month: String(range.start.prefix(7)), today: today, width: width)
                    }
                }
                .frame(width: width)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
    }

    private func monthWeek(tasks: [WandBoardTask], week: WandBoardGanttRange, month: String, today: Date, width: CGFloat) -> some View {
        let items = tasks.filter { wandBoardGanttSpan(task: $0, range: week, today: today).length > 0 }
        let expanded = expandedWeeks.contains(week.start)
        let visible = expanded ? items : Array(items.prefix(4))
        let cell = width / 7
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(week.columns, id: \.self) { day in
                    Text(day.hasSuffix("-01") ? String(day.suffix(5)) : String(Int(day.suffix(2)) ?? 1))
                        .font(.system(size: 12, weight: day == wandBoardIsoDate(today) ? .bold : .regular))
                        .foregroundColor(day == wandBoardIsoDate(today) ? Theme.accentSolid : Theme.textSecondary)
                        .opacity(String(day.prefix(7)) == month ? 1 : 0.5)
                        .frame(width: cell - 12, height: 34, alignment: .trailing).padding(.trailing, 12)
                }
            }
            ForEach(visible) { task in
                let span = wandBoardGanttSpan(task: task, range: week, today: today)
                HStack(spacing: 0) {
                    if span.offset > 0 { Color.clear.frame(width: cell * CGFloat(span.offset), height: 56) }
                    monthEvent(task: task, today: today, span: span.length)
                        .frame(width: cell * CGFloat(span.length) - 8, height: 56).padding(.horizontal, 4)
                    Spacer(minLength: 0)
                }
            }
            if items.count > 4 {
                Button(expanded ? "收起本周任务" : "展开其余 \(items.count - 4) 个任务") {
                    if expanded { expandedWeeks.remove(week.start) } else { expandedWeeks.insert(week.start) }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(8)
            }
            Spacer(minLength: 8)
        }
        .frame(width: width, alignment: .topLeading).frame(minHeight: 156)
        .background(HStack(spacing: 0) {
            ForEach(week.columns, id: \.self) { day in
                Rectangle().fill(Theme.border.opacity(String(day.prefix(7)) != month ? 0.2 : weekend(day) ? 0.12 : 0))
                    .frame(width: cell).overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        })
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func monthEvent(task: WandBoardTask, today: Date, span: Int) -> some View {
        let status = WandBoardStatus(rawValue: task.status) ?? .backlog
        let people = participants(task)
        return Button { onOpenTask(task.id) } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(label(status)).font(.system(size: 10, weight: .medium)).fixedSize()
                        .foregroundColor(status.color).padding(.horizontal, 4).padding(.vertical, 2)
                        .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Text(task.title).font(.system(size: 12)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(wandBoardTaskAge(task.createdAt, now: today)).font(.system(size: 11)).foregroundColor(Theme.textSecondary).fixedSize()
                    HStack(spacing: -6) {
                        ForEach(Array(people.prefix(span == 1 ? 1 : 3)), id: \.id) { person in
                            ContactAvatar(id: person.id, avatar: person.avatar ?? "", name: person.name, size: 22)
                        }
                        let remaining = people.count - (span == 1 ? 1 : 3)
                        if remaining > 0 { Text("+\(remaining)").font(.system(size: 10)).padding(.leading, 6) }
                    }.help("历史参与者：" + people.map(\.name).joined(separator: "、"))
                }
            }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(reduceTransparency ? AnyShapeStyle(Theme.surfaceSoft) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
        }.buttonStyle(.plain).help(task.identifier + " · " + task.title + " · 已创建 " + wandBoardTaskAge(task.createdAt, now: today))
    }

    private func navigate(_ direction: Int, range: WandBoardGanttRange) {
        guard let start = wandBoardDay(fromDueDate: range.start) else { return }
        anchor = Calendar.current.date(byAdding: zoom == .month ? .month : .day, value: direction * (zoom == .month ? 1 : range.days), to: start) ?? start
    }

    private func weekend(_ day: String) -> Bool {
        guard let date = wandBoardDay(fromDueDate: day) else { return false }
        return Calendar.current.isDateInWeekend(date)
    }

    private func dayLabel(_ day: String) -> String {
        guard let date = wandBoardDay(fromDueDate: day) else { return day }
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        return String(day.suffix(5)) + " · " + (day == wandBoardIsoDate(Date()) ? "今天" : "周" + ["日", "一", "二", "三", "四", "五", "六"][weekday])
    }

    private func headRow(range: WandBoardGanttRange) -> some View {
        HStack(spacing: 12) {
            Text("任务")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            let cell = cellWidth
            HStack(spacing: 0) {
                ForEach(range.columns, id: \.self) { day in
                    Text(dayLabel(day))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: cell, height: 32)
                        .background(weekend(day) ? Theme.border.opacity(0.15) : Color.clear)
                        .id(day == wandBoardIsoDate(Date()) ? "gantt-today" : day)
                }
            }
        }
    }

    private func group(items: [WandBoardTask], range: WandBoardGanttRange, today: Date) -> some View {
        let cell = cellWidth
        let trackWidth = cell * CGFloat(range.days)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { task in
                let status = WandBoardStatus(rawValue: task.status) ?? .backlog
                let span = wandBoardGanttSpan(task: task, range: range, today: today)
                Button {
                    onOpenTask(task.id)
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)

                        }
                        .frame(width: labelWidth, alignment: .leading)
                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(range.columns, id: \.self) { day in
                                    Rectangle().fill(weekend(day) ? Theme.border.opacity(0.15) : Color.clear).frame(width: cell, height: rowHeight)
                                }
                            }
                            Rectangle().fill(Theme.border.opacity(0.3)).frame(width: trackWidth, height: 1)
                            if span.length > 0 {
                                let people = participants(task)
                                HStack(spacing: 8) {
                                    Text(label(status)).font(.system(size: 11, weight: .medium))
                                        .foregroundColor(status.color).padding(.horizontal, 5).padding(.vertical, 3)
                                        .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                        .fixedSize()
                                    Text(task.title.isEmpty ? "未命名任务" : task.title)
                                        .font(.system(size: 12)).foregroundColor(Theme.textPrimary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(wandBoardTaskAge(task.createdAt, now: today))
                                        .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textSecondary).fixedSize()
                                        .help("已创建 " + wandBoardTaskAge(task.createdAt, now: today))
                                    HStack(spacing: -6) {
                                        ForEach(Array(people.prefix(span.length == 1 ? 1 : 3)), id: \.id) { person in
                                            ContactAvatar(id: person.id, avatar: person.avatar ?? "", name: person.name, size: 24)
                                                .background(Theme.surfaceSoft, in: Circle())
                                                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                                        }
                                        let remaining = people.count - (span.length == 1 ? 1 : 3)
                                        if remaining > 0 { Text("+\(remaining)").font(.system(size: 10)).padding(.leading, 8) }
                                    }.help("历史参与者：" + people.map(\.name).joined(separator: "、"))
                                }
                                .padding(.horizontal, 8)
                                .frame(width: cell * CGFloat(span.length), height: 36)
                                .background(reduceTransparency ? AnyShapeStyle(Theme.surfaceSoft) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
                                .offset(x: cell * CGFloat(span.offset))
                            } else {
                                Text(task.title + " · 添加或归档时间缺失")
                                    .font(.caption).foregroundColor(Theme.textSecondary)
                            }
                            if let index = range.columns.firstIndex(of: wandBoardIsoDate(today)) {
                                Rectangle().fill(Theme.accentSolid.opacity(0.5)).frame(width: 1, height: rowHeight)
                                    .offset(x: cell * (CGFloat(index) + 0.5))
                            }
                        }.frame(width: trackWidth)
                    }
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WandBoardRowButtonStyle())
                .help(task.dueDate?.isEmpty == false ? "截止 \(task.dueDate ?? "")" : "添加 \(task.createdAt) → \(task.status == "archived" ? task.archivedAt ?? "归档时间缺失" : "现在")")
            }
        }
    }
}

/// 甘特尺度切换 / 视图切换用的小分段按钮。
struct WandBoardSegmentButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(active ? Theme.surfaceElevated : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(active ? Theme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
