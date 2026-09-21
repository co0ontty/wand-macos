import SwiftUI

// MARK: - 列表视图

/// 列表视图：按状态分组的紧凑行，组头可折叠；归档目录挂在「等你确认」组内。
struct WandBoardListView: View {
    let grouped: [String: [WandBoardTask]]
    let collapsed: Set<String>
    let archiveOpen: Bool
    let onToggle: (String) -> Void
    let onToggleArchive: () -> Void
    let onOpenTask: (String) -> Void
    let onOpenSession: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(WandBoardStatus.columns) { status in
                    group(status)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func group(_ status: WandBoardStatus) -> some View {
        let items = grouped[status.rawValue] ?? []
        let archived = status == .done ? (grouped[WandBoardStatus.archived.rawValue] ?? []) : []
        // 展开归档目录时，「等你确认」组保持打开，否则目录会被折在折叠区里看不见。
        let isCollapsed = status == .done && archiveOpen && !archived.isEmpty
            ? false
            : collapsed.contains(status.rawValue)
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
                if items.isEmpty && !(status == .done && !archived.isEmpty) {
                    Text(status.empty)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                ForEach(items) { task in
                    row(task)
                }
                if status == .done {
                    WandBoardArchiveFolder(count: archived.count, open: archiveOpen, onToggle: onToggleArchive) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(archived) { task in
                                row(task)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func row(_ task: WandBoardTask) -> some View {
        Button {
            onOpenTask(task.id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                WandBoardStatusGlyph(status: WandBoardStatus(rawValue: task.status) ?? .todo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                    Text(task.title.isEmpty ? "未命名任务" : task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
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
        }
        .buttonStyle(WandBoardRowButtonStyle())
        .help(task.title)
    }
}

// MARK: - 概览视图

/// 概览视图：剩余量、五张指标卡、进度折线图与四块分布面板。
struct WandBoardDashboardView: View {
    let projectName: String
    let tasks: [WandBoardTask]
    let onOpenTask: (String) -> Void
    let onOpenSession: (String) -> Void

    var body: some View {
        let stats = wandBoardStats(tasks: tasks)
        let series = wandBoardProgressSeries(tasks: tasks)
        let dueSoon = tasks
            .filter { $0.dueDate?.isEmpty == false && $0.status != WandBoardStatus.done.rawValue }
            .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
            .prefix(6)
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
            ? "\(projectName) 当前没有未完成任务。"
            : "\(projectName) 还有 \(stats.remaining) 项未完成，其中 \(stats.doing) 项正在处理、\(stats.todo) 项等待认领。"

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(projectName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(stats.remaining)")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.wandAccent)
                        Text("未完成")
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
                    metric("处理中", stats.doing, WandBoardStatus.doing.color, stats.total)
                    metric("等你确认", stats.done, WandBoardStatus.done.color, stats.total)
                    metric("等待认领", stats.todo, WandBoardStatus.todo.color, stats.total)
                    metric("已逾期", stats.overdue, Theme.wandAccent, stats.total)
                    metric("高优先级", stats.high, Theme.warning, stats.total)
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
                                dashboardRow(
                                    action: { onOpenTask(task.id) },
                                    glyph: { WandBoardStatusGlyph(status: WandBoardStatus(rawValue: task.status) ?? .todo) },
                                    title: task.title
                                ) {
                                    WandBoardDueChip(dueDate: task.dueDate ?? "", status: task.status)
                                }
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
                legend("已开始", stats.doing + stats.done, WandBoardStatus.doing.color)
                legend("已确认", stats.done, WandBoardStatus.done.color)
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
                    line(\.completed, color: WandBoardStatus.done.color)
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
    let grouped: [String: [WandBoardTask]]
    let zoom: WandBoardGanttZoom
    let hideCompleted: Bool
    let onZoom: (WandBoardGanttZoom) -> Void
    let onHideCompleted: (Bool) -> Void
    let onOpenTask: (String) -> Void

    private let labelWidth: CGFloat = 220
    private let rowHeight: CGFloat = 30

    var body: some View {
        let range = wandBoardGanttRange(zoom: zoom)
        let statuses = hideCompleted ? WandBoardStatus.columns.filter { $0 != .done } : WandBoardStatus.allCases
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Toggle("隐藏已确认", isOn: Binding(get: { hideCompleted }, set: onHideCompleted))
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

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    headRow(range: range)
                    ForEach(statuses) { status in
                        let items = (grouped[status.rawValue] ?? [])
                        if !items.isEmpty { group(status, items: items, range: range) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    private func headRow(range: WandBoardGanttRange) -> some View {
        HStack(spacing: 12) {
            Text("任务")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            let cell = max(8, 520 / CGFloat(range.days))
            HStack(spacing: 0) {
                ForEach(range.columns, id: \.self) { day in
                    Text(String(Int(day.suffix(2)) ?? 0))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: cell)
                }
            }
        }
    }

    private func group(_ status: WandBoardStatus, items: [WandBoardTask], range: WandBoardGanttRange) -> some View {
        let cell = max(8, 520 / CGFloat(range.days))
        let trackWidth = cell * CGFloat(range.days)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                WandBoardStatusGlyph(status: status)
                Text(status.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("\(items.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
            ForEach(items) { task in
                let span = wandBoardGanttSpan(task: task, range: range)
                Button {
                    onOpenTask(task.id)
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                            Text(task.title.isEmpty ? "未命名任务" : task.title)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(width: labelWidth, alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(status.color.opacity(0.12))
                                .frame(width: trackWidth, height: 8)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(status.color)
                                .frame(width: cell * CGFloat(span.length), height: 8)
                                .offset(x: cell * CGFloat(span.offset))
                        }
                    }
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WandBoardRowButtonStyle())
                .help(task.title)
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
