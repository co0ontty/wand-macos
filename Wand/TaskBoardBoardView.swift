import SwiftUI

/**
 * 看板视图：三列 Kanban（等待认领 / 处理中 / 等你确认）+「等你确认」列内的归档目录。
 * 拖拽语义对齐 Web：
 *   - 卡片拖到另一列 → 改状态；拖进「处理中」且该卡还没派发过 → 顺手完成首次指派；
 *   - 卡片拖到归档区 → 归档（软删除，会话与记录保留）；
 *   - 会话行拖到另一张卡片 → 改会话归属，运行目录不变。
 */
struct WandBoardBoardView: View {
    let grouped: [String: [WandBoardTask]]
    var allTasks: [WandBoardTask] = []
    let display: WandBoardDisplay
    let loading: Bool
    let busyId: String
    let archiveOpen: Bool
    let onToggleArchive: () -> Void
    let onCreateInColumn: (String) -> Void
    let onOpenTask: (String) -> Void
    var onOpenComments: (String) -> Void = { _ in }
    let onOpenSession: (String) -> Void
    let onPatchStatus: (WandBoardTask, String) -> Void
    let onDispatchTask: (WandBoardTask) -> Void
    let onArchiveTask: (WandBoardTask) -> Void
    let onRestoreTask: (WandBoardTask) -> Void
    let onCopyIdentifier: (WandBoardTask) -> Void
    let onMoveSession: (WandBoardTask, String) -> Void
    let onUnbindSession: (WandBoardTask, String) -> Void
    let onDropTask: (String, String) -> Void

    @State private var dropStatus = ""
    @State private var archiveDrop = false
    @State private var sessionDropTarget = ""

    private var mainColumns: [WandBoardStatus] {
        WandBoardStatus.columns.filter { display.mainStatuses.contains($0.rawValue) }
    }

    private var otherColumns: [WandBoardStatus] {
        WandBoardStatus.columns.filter { $0 != .backlog && !display.mainStatuses.contains($0.rawValue) }
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(1260, geometry.size.width)
            let columnCount = CGFloat(max(1, mainColumns.count))
            let columnWidth = min(360, max(280, (contentWidth - 56 - CGFloat(max(0, mainColumns.count - 1)) * 24) / columnCount))
            let sideWidth: CGFloat = otherColumns.isEmpty ? 0 : min(320, columnWidth)
            let naturalWidth = CGFloat(mainColumns.count) * columnWidth
                + (mainColumns.isEmpty || otherColumns.isEmpty ? 0 : 24)
                + sideWidth + 56
            VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(mainColumns) { status in
                        column(status)
                            .frame(width: columnWidth)
                    }
                    if !otherColumns.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(otherColumns) { status in
                                column(status)
                            }
                        }
                        .frame(width: sideWidth)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                .frame(width: max(contentWidth, naturalWidth), alignment: .topLeading)
            }
            .frame(maxWidth: contentWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            archiveZone(archived: grouped[WandBoardStatus.archived.rawValue] ?? [])
                .padding(.horizontal, 28)
            }
        }
    }

    // MARK: 列

    private func column(_ status: WandBoardStatus) -> some View {
        let items = grouped[status.rawValue] ?? []
        let isDropTarget = dropStatus == status.rawValue
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                WandBoardStatusGlyph(status: status)
                Text(items.isEmpty ? status.label : "\(status.label) \(items.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                if status != .review && status != .ready {
                    Button {
                        onCreateInColumn(status.rawValue)
                    } label: {
                        Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WandIconButtonStyle())
                    .help("在「\(status.label)」中新建任务")
                    .accessibilityLabel("在「\(status.label)」中新建任务")
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 36)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(status.color.opacity(status == .doing ? 0.15 : 0.1))
                    .frame(height: 2)
            }
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if loading && items.isEmpty {
                        WandBoardSkeletonCard()
                        WandBoardSkeletonCard()
                    }
                    if !loading && items.isEmpty {
                        Text(status.empty)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                    .strokeBorder(
                                        Color(nsColor: Theme.borderSubtle),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                                    )
                            )
                    }
                    ForEach(items) { task in
                        card(task)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isDropTarget ? Color(nsColor: Theme.wandAccentMuted) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(isDropTarget ? Theme.wandAccent.opacity(0.45) : Color.clear, lineWidth: 1.5)
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onDrop(
            of: [wandBoardTaskDragType],
            isTargeted: Binding(
                get: { dropStatus == status.rawValue },
                set: { targeted in
                    if targeted {
                        dropStatus = status.rawValue
                    } else if dropStatus == status.rawValue {
                        dropStatus = ""
                    }
                }
            )
        ) { providers in
            guard let provider = providers.first else { return false }
            dropStatus = ""
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String, !id.isEmpty else { return }
                DispatchQueue.main.async {
                    archiveDrop = false
                    onDropTask(status.rawValue, id)
                }
            }
            return true
        }
    }

    private func card(_ task: WandBoardTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
        WandBoardCard(
            task: task,
            display: display,
            parent: wandBoardParent(of: task, in: allTasks),
            childCount: wandBoardChildren(of: task, in: allTasks).count,
            busy: busyId == task.id,
            dropTarget: sessionDropTarget == task.id,
            onOpen: { onOpenTask(task.id) },
            onOpenComments: { onOpenComments(task.id) },
            onOpenSession: onOpenSession,
            onPatchStatus: { onPatchStatus(task, $0) },
            onDispatch: { onDispatchTask(task) },
            onArchive: { onArchiveTask(task) },
            onRestore: { onRestoreTask(task) },
            onCopyIdentifier: { onCopyIdentifier(task) },
            onDropSession: { sessionId in
                sessionDropTarget = ""
                onMoveSession(task, sessionId)
            },
            onUnbindSession: { onUnbindSession(task, $0) }
        )
        WandGoalChildren(task: task, tasks: allTasks, onOpen: onOpenTask)
        }
        .onDrag {
            NSItemProvider(item: task.id as NSString, typeIdentifier: wandBoardTaskDragType)
        }
    }

    // MARK: 归档区

    private func archiveZone(archived: [WandBoardTask]) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            WandBoardArchiveFolder(count: archived.count, open: archiveOpen, onToggle: onToggleArchive) {
                ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(archived) { task in card(task) }
                } }.frame(maxHeight: 280)
            }
            Text("归档独立收纳；请先查看 AI 验收证据，再由人工确认并归档。")
                .font(.system(size: 11))
                .foregroundColor(archiveDrop ? Theme.wandAccent : Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(archiveDrop ? Color(nsColor: Theme.wandAccentMuted) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(
                    archiveDrop ? Theme.wandAccent : Color(nsColor: Theme.borderSubtle),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
        .onDrop(
            of: [wandBoardTaskDragType],
            isTargeted: Binding(get: { archiveDrop }, set: { archiveDrop = $0 })
        ) { providers in
            guard let provider = providers.first else { return false }
            archiveDrop = false
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String, !id.isEmpty else { return }
                DispatchQueue.main.async {
                    dropStatus = ""
                    onDropTask(WandBoardStatus.archived.rawValue, id)
                }
            }
            return true
        }
        .accessibilityLabel("归档区，\(archived.count) 个任务")
    }
}

/// 加载态骨架卡片。
struct WandBoardSkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .fill(Theme.surfaceElevated)
            .frame(height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 1)
            )
            .redacted(reason: .placeholder)
    }
}
