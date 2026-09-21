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
    let display: WandBoardDisplay
    let loading: Bool
    let busyId: String
    let archiveOpen: Bool
    let onToggleArchive: () -> Void
    let onCreateInColumn: (String) -> Void
    let onOpenTask: (String) -> Void
    let onOpenSession: (String) -> Void
    let onCompleteTask: (WandBoardTask) -> Void
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
        WandBoardStatus.columns.filter { !display.mainStatuses.contains($0.rawValue) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(mainColumns) { status in
                    column(status)
                        .frame(minWidth: 240, maxWidth: .infinity)
                }
                if !otherColumns.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(otherColumns) { status in
                            column(status)
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 列

    private func column(_ status: WandBoardStatus) -> some View {
        let items = grouped[status.rawValue] ?? []
        let archived = status == .done ? (grouped[WandBoardStatus.archived.rawValue] ?? []) : []
        let isDropTarget = dropStatus == status.rawValue
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                WandBoardStatusGlyph(status: status)
                Text(items.isEmpty ? status.label : "\(status.label) \(items.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    onCreateInColumn(status.rawValue)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(WandIconButtonStyle())
                .help("在\(status.label)中新建任务")
                .accessibilityLabel("在\(status.label)中新建任务")
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
                    if !loading && items.isEmpty && !(status == .done && !archived.isEmpty) {
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
                    if status == .done {
                        archiveZone(archived: archived)
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
        WandBoardCard(
            task: task,
            display: display,
            busy: busyId == task.id,
            dropTarget: sessionDropTarget == task.id,
            onOpen: { onOpenTask(task.id) },
            onOpenSession: onOpenSession,
            onComplete: { onCompleteTask(task) },
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
        .onDrag {
            NSItemProvider(item: task.id as NSString, typeIdentifier: wandBoardTaskDragType)
        }
    }

    // MARK: 归档区

    private func archiveZone(archived: [WandBoardTask]) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            WandBoardArchiveFolder(count: archived.count, open: archiveOpen, onToggle: onToggleArchive) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(archived) { task in
                        card(task)
                    }
                }
            }
            Text(archiveDrop ? "松开鼠标，归档此任务" : "拖到这里归档：侧栏隐藏，终端与记录保留")
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
