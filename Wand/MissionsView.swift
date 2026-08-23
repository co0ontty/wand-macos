import Combine
import Foundation
import SwiftUI

private struct MissionProviderOption: Identifiable {
    let id: String
    let title: String

    static let all = [
        MissionProviderOption(id: "claude", title: "Claude"),
        MissionProviderOption(id: "codex", title: "Codex"),
        MissionProviderOption(id: "opencode", title: "OpenCode"),
        MissionProviderOption(id: "grok", title: "Grok"),
        MissionProviderOption(id: "qoder", title: "Qoder"),
        MissionProviderOption(id: "pi", title: "Pi"),
    ]
}

private struct MissionProviderMark: View {
    let provider: String
    let color: Color
    let size: CGFloat

    var body: some View {
        BrandLogo(provider: provider, color: color)
            .frame(width: size, height: size)
            .accessibilityLabel(provider.capitalized)
    }
}

private struct MissionReviewTarget: Identifiable {
    let filePath: String
    let line: Int?
    let side: String

    var id: String { "\(filePath)-\(side)-\(line ?? 0)" }
}

private struct MissionRenderedDiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    let target: MissionReviewTarget?

    enum Kind { case added, removed, context, metadata }
}

private let missionHunkRegex = try! NSRegularExpression(
    pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
)

private func renderMissionDiff(_ patch: String) -> [MissionRenderedDiffLine] {
    var oldFile: String?
    var newFile: String?
    var oldLine = 0
    var newLine = 0
    return patch.components(separatedBy: "\n").prefix(5_000).enumerated().map { index, text in
        if text.hasPrefix("--- ") {
            let path = String(text.dropFirst(4)).replacingOccurrences(of: "a/", with: "", options: .anchored)
            oldFile = path == "/dev/null" ? nil : path
        }
        if text.hasPrefix("+++ ") {
            let path = String(text.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored)
            newFile = path == "/dev/null" ? nil : path
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = missionHunkRegex.firstMatch(in: text, range: range),
           let oldRange = Range(match.range(at: 1), in: text),
           let newRange = Range(match.range(at: 2), in: text) {
            oldLine = Int(text[oldRange]) ?? 0
            newLine = Int(text[newRange]) ?? 0
            return MissionRenderedDiffLine(id: index, text: text, kind: .metadata, target: nil)
        }
        if text.hasPrefix("+") && !text.hasPrefix("+++") {
            defer { newLine += 1 }
            let target = (newFile ?? oldFile).map { MissionReviewTarget(filePath: $0, line: newLine, side: "new") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .added, target: target)
        }
        if text.hasPrefix("-") && !text.hasPrefix("---") {
            defer { oldLine += 1 }
            let target = (oldFile ?? newFile).map { MissionReviewTarget(filePath: $0, line: oldLine, side: "old") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .removed, target: target)
        }
        if text.hasPrefix(" ") {
            defer {
                oldLine += 1
                newLine += 1
            }
            let target = (newFile ?? oldFile).map { MissionReviewTarget(filePath: $0, line: newLine, side: "new") }
            return MissionRenderedDiffLine(id: index, text: text, kind: .context, target: target)
        }
        return MissionRenderedDiffLine(id: index, text: text, kind: .metadata, target: nil)
    }
}

private func missionStatePresentation(_ state: String) -> (String, String, Color) {
    switch state {
    case "needs_input": return ("等待输入", "questionmark.bubble.fill", Theme.warning)
    case "needs_permission": return ("等待权限", "lock.trianglebadge.exclamationmark.fill", Theme.warning)
    case "working", "running": return ("执行中", "bolt.horizontal.circle.fill", Theme.info)
    case "queued", "dispatching": return ("准备中", "clock.fill", Theme.textMuted)
    case "done", "completed": return ("已完成", "checkmark.circle.fill", Theme.success)
    case "failed": return ("失败", "exclamationmark.circle.fill", Theme.danger)
    case "archived": return ("已归档", "archivebox.fill", Theme.textMuted)
    default: return (state, "circle.fill", Theme.textMuted)
    }
}

struct MissionsView: View {
    let api: WandAPI
    let onOpenSession: (String) -> Void
    let onDismiss: () -> Void

    @State private var missions: [MissionInfo] = []
    @State private var selectedMissionId: String?
    @State private var selectedAttemptId: String?
    @State private var diff: MissionDiff?
    @State private var comments: [MissionReviewComment] = []
    @State private var loading = true
    @State private var diffLoading = false
    @State private var sendingReview = false
    @State private var showCreate = false
    @State private var reviewTarget: MissionReviewTarget?
    @State private var errorMessage: String?
    @State private var confirmArchive = false

    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var selectedMission: MissionInfo? {
        missions.first { $0.id == selectedMissionId }
    }

    private var selectedAttempt: MissionAttempt? {
        selectedMission?.attempts.first { $0.id == selectedAttemptId }
    }

    private var pendingComments: [MissionReviewComment] {
        comments.filter { $0.status == "pending" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.35)
            Group {
                if loading && missions.isEmpty {
                    ProgressView().tint(Theme.wandAccent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    missionsWorkspace
                }
            }
        }
        .frame(minWidth: 960, minHeight: 660)
        .background(WandAmbientBackground())
        .sheet(isPresented: $showCreate) {
            MissionCreateView(api: api) { mission in
                missions.removeAll { $0.id == mission.id }
                missions.insert(mission, at: 0)
                selectMission(mission)
            }
        }
        .sheet(item: $reviewTarget) { target in
            MissionReviewComposer(target: target) { body in
                await addReview(target: target, body: body)
            }
        }
        .task { await refresh(showProgress: true) }
        .onReceive(refreshTimer) { _ in
            Task { await refresh(showProgress: false) }
        }
        .alert("任务操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("归档这个任务？", isPresented: $confirmArchive) {
            Button("归档", role: .destructive) { Task { await archiveSelectedMission() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任务会从列表隐藏，但会话和 worktree 不会被删除。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(Theme.textSecondary)
                Text("并行任务")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer()
            Button {
                Task { await refresh(showProgress: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(WandIconButtonStyle())
            .help("刷新并行任务")
            Button {
                showCreate = true
            } label: {
                Label("新建任务", systemImage: "plus")
            }
            .buttonStyle(WandPrimaryButtonStyle())
            Button("关闭", action: onDismiss)
                .buttonStyle(.borderless)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.workspaceBackground)
    }

    @ViewBuilder private var missionsWorkspace: some View {
        if missions.isEmpty {
            MissionEmptyState(
                icon: "point.3.connected.trianglepath.dotted",
                title: "还没有并行任务",
                detail: "把同一个目标分派给多个 Agent，在独立 worktree 中并行推进。"
            )
        } else {
            HSplitView {
                missionSidebar
                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 340)
                missionDetail
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var missionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("\(missions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(missions) { mission in
                        Button { selectMission(mission) } label: {
                            MissionSidebarRow(mission: mission, selected: mission.id == selectedMissionId)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.surface.opacity(0.48))
    }

    @ViewBuilder private var missionDetail: some View {
        if let mission = selectedMission {
            VStack(spacing: 0) {
                missionHeader(mission)
                Divider().opacity(0.3)
                attemptStrip(mission)
                Divider().opacity(0.3)
                diffWorkspace
            }
        } else {
            MissionEmptyState(icon: "cursorarrow.click", title: "选择一个任务", detail: "查看各 Agent 的进度、完整 Diff 和审阅意见。")
        }
    }

    private func missionHeader(_ mission: MissionInfo) -> some View {
        let presentation = missionStatePresentation(mission.status)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(mission.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Label(presentation.0, systemImage: presentation.1)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(presentation.2)
                Spacer()
                Menu {
                    Button { Task { await refresh(showProgress: false) } } label: {
                        Label("刷新任务", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { confirmArchive = true } label: {
                        Label("归档任务", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            Text(mission.prompt)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Label(mission.cwd, systemImage: "folder")
                if let base = mission.worktree.baseRef {
                    Label(base, systemImage: "arrow.triangle.branch")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Theme.textMuted)
            .lineLimit(1)
        }
        .padding(16)
    }

    private func attemptStrip(_ mission: MissionInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mission.attempts) { attempt in
                    Button { selectAttempt(attempt, in: mission) } label: {
                        MissionAttemptChip(attempt: attempt, selected: attempt.id == selectedAttemptId)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private var diffWorkspace: some View {
        if let attempt = selectedAttempt {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let sessionId = attempt.sessionId {
                        Button {
                            onOpenSession(sessionId)
                            onDismiss()
                        } label: {
                            Label("打开会话", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(WandSecondaryButtonStyle())
                    }
                    if let diff {
                        Label("\(diff.files.count) 个文件", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        Text(String(diff.baseRef.prefix(12)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                        if diff.truncated {
                            Label("已截断", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.warning)
                        }
                    }
                    Spacer()
                    if !pendingComments.isEmpty {
                        Button {
                            Task { await sendReview() }
                        } label: {
                            Label("发送 \(pendingComments.count) 条 Review", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(sendingReview)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                Divider().opacity(0.3)
                if diffLoading {
                    ProgressView().tint(Theme.wandAccent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff {
                    diffBody(diff)
                } else {
                    MissionEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "没有可显示的 Diff",
                        detail: attempt.error ?? "Agent 尚未产生文件变更。"
                    )
                }
            }
        } else {
            MissionEmptyState(icon: "person.2", title: "选择一个 Attempt", detail: "不同 Agent 的改动保持在各自独立的 worktree 中。")
        }
    }

    private func diffBody(_ diff: MissionDiff) -> some View {
        let lines = renderMissionDiff(diff.patch)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Button {
                        if let target = line.target { reviewTarget = target }
                    } label: {
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(line.kind == .metadata ? Theme.textMuted : Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .frame(minWidth: 900, maxWidth: .infinity, alignment: .leading)
                            .background(diffLineBackground(line.kind))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(line.target == nil)
                    .help(line.target == nil ? "" : "添加行级 Review")
                }
            }
        }
    }

    private func diffLineBackground(_ kind: MissionRenderedDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.success.opacity(0.13)
        case .removed: return Theme.danger.opacity(0.12)
        case .metadata: return Theme.info.opacity(0.08)
        case .context: return .clear
        }
    }

    private func selectMission(_ mission: MissionInfo) {
        selectedMissionId = mission.id
        if let currentAttemptId = selectedAttemptId,
           mission.attempts.contains(where: { $0.id == currentAttemptId }) {
            return
        }
        if let attempt = mission.attempts.first {
            selectAttempt(attempt, in: mission)
        } else {
            selectedAttemptId = nil
            diff = nil
            comments = []
        }
    }

    private func selectAttempt(_ attempt: MissionAttempt, in mission: MissionInfo) {
        selectedAttemptId = attempt.id
        diff = nil
        comments = mission.comments.filter { $0.attemptId == attempt.id }
        Task { await loadDiff(missionId: mission.id, attemptId: attempt.id) }
    }

    private func loadDiff(missionId: String, attemptId: String) async {
        diffLoading = true
        do {
            let loaded = try await api.missionDiff(missionId: missionId, attemptId: attemptId)
            guard selectedMissionId == missionId, selectedAttemptId == attemptId else { return }
            diff = loaded
        } catch {
            guard selectedMissionId == missionId, selectedAttemptId == attemptId else { return }
            diff = nil
            if selectedAttempt?.state == "done" || selectedAttempt?.state == "failed" {
                errorMessage = error.localizedDescription
            }
        }
        if selectedMissionId == missionId, selectedAttemptId == attemptId { diffLoading = false }
    }

    private func addReview(target: MissionReviewTarget, body: String) async -> Bool {
        guard let mission = selectedMission, let attempt = selectedAttempt else { return false }
        do {
            let comment = try await api.addMissionReviewComment(
                missionId: mission.id,
                attemptId: attempt.id,
                filePath: target.filePath,
                line: target.line,
                side: target.side,
                body: body
            )
            comments.append(comment)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func sendReview() async {
        guard let mission = selectedMission, let attempt = selectedAttempt else { return }
        sendingReview = true
        do {
            comments = try await api.sendMissionReview(missionId: mission.id, attemptId: attempt.id)
            await refresh(showProgress: false)
        } catch {
            errorMessage = error.localizedDescription
        }
        sendingReview = false
    }

    private func archiveSelectedMission() async {
        guard let mission = selectedMission else { return }
        do {
            _ = try await api.archiveMission(id: mission.id)
            missions.removeAll { $0.id == mission.id }
            selectedMissionId = missions.first?.id
            if let next = missions.first { selectMission(next) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh(showProgress: Bool) async {
        if showProgress { loading = true }
        do {
            missions = try await api.missions()
            if let selectedMissionId,
               let refreshed = missions.first(where: { $0.id == selectedMissionId }) {
                comments = refreshed.comments.filter { $0.attemptId == selectedAttemptId }
            } else if let first = missions.first {
                selectMission(first)
            } else {
                selectedMissionId = nil
                selectedAttemptId = nil
                diff = nil
            }
            errorMessage = nil
        } catch {
            if showProgress || missions.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        loading = false
    }
}

private struct MissionSidebarRow: View {
    let mission: MissionInfo
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        let presentation = missionStatePresentation(mission.status)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(mission.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: presentation.1)
                    .foregroundColor(presentation.2)
            }
            Text(mission.prompt)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Text("\(mission.attempts.count) Agents · \(presentation.0)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(presentation.2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wandSelectionSurface(isSelected: selected, isHovered: hovered, cornerRadius: 8)
        .onHover { hovered = $0 }
    }
}

private struct MissionAttemptChip: View {
    let attempt: MissionAttempt
    let selected: Bool

    var body: some View {
        let presentation = missionStatePresentation(attempt.state)
        HStack(spacing: 7) {
            MissionProviderMark(provider: attempt.provider, color: presentation.2, size: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(attempt.provider.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(presentation.0)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(presentation.2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.textPrimary.opacity(0.07) : Theme.surfaceElevated.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.border : Theme.border.opacity(0.55), lineWidth: 0.75)
        )
    }
}

private struct MissionReviewComposer: View {
    let target: MissionReviewTarget
    let onSubmit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reviewText = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加 Review")
                        .font(.system(size: 16, weight: .semibold))
                    Text(target.line.map { "\(target.filePath):\($0) · \(target.side)" } ?? target.filePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(WandIconButtonStyle())
            }
            TextEditor(text: $reviewText)
                .font(.system(size: 13))
                .frame(minHeight: 170)
                .padding(6)
                .background(Theme.surfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WandSecondaryButtonStyle())
                Button("保存") {
                    Task {
                        submitting = true
                        if await onSubmit(reviewText.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                        submitting = false
                    }
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
            }
        }
        .padding(20)
        .frame(width: 560, height: 330)
        .background(WandAmbientBackground())
    }
}

private struct MissionCreateView: View {
    let api: WandAPI
    let onCreated: (MissionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var cwd = ""
    @State private var baseRef = ""
    @State private var sharedPaths = ""
    @State private var copyPaths = ""
    @State private var providers: Set<String> = ["claude", "codex"]
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建并行任务")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(WandIconButtonStyle())
            }
            .padding(18)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MissionFormField(title: "标题", detail: "可选；留空时取提示词第一行") {
                        TextField("例如：重构上传流程", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }
                    MissionFormField(title: "任务目标", detail: "写清约束和验收方式") {
                        TextEditor(text: $prompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 130)
                            .padding(6)
                            .background(Theme.surfaceElevated)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                    }
                    MissionFormField(title: "并行 Agent", detail: "每个 Agent 使用独立 worktree") {
                        HStack(spacing: 8) {
                            ForEach(MissionProviderOption.all) { provider in
                                Button {
                                    if providers.contains(provider.id) { providers.remove(provider.id) }
                                    else { providers.insert(provider.id) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: providers.contains(provider.id) ? "checkmark.circle.fill" : "circle")
                                        Text(provider.title)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(providers.contains(provider.id) ? Theme.textPrimary : Theme.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(providers.contains(provider.id) ? Theme.textPrimary.opacity(0.07) : Theme.surfaceElevated)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        MissionFormField(title: "工作目录", detail: "服务端可访问的 Git 仓库") {
                            TextField("/path/to/repository", text: $cwd).textFieldStyle(.roundedBorder)
                        }
                        MissionFormField(title: "基线", detail: "分支、Tag 或 commit；可选") {
                            TextField("例如 main", text: $baseRef).textFieldStyle(.roundedBorder)
                        }
                    }
                    DisclosureGroup("高级 worktree 路径") {
                        VStack(spacing: 12) {
                            MissionFormField(title: "共享目录", detail: "gitignored 目录，逗号分隔；以符号链接接入") {
                                TextField("node_modules, .cache", text: $sharedPaths).textFieldStyle(.roundedBorder)
                            }
                            MissionFormField(title: "复制路径", detail: "gitignored 路径，逗号分隔；每个 Agent 独立副本") {
                                TextField(".env.local", text: $copyPaths).textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .padding(20)
            }
            Divider().opacity(0.3)
            HStack {
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WandSecondaryButtonStyle())
                Button("创建任务") { Task { await create() } }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(!canCreate || submitting)
            }
            .padding(16)
        }
        .frame(width: 760, height: 660)
        .background(WandAmbientBackground())
        .task {
            if cwd.isEmpty { cwd = (try? await api.serverConfig().defaultCwd) ?? "" }
        }
        .alert("无法创建任务", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var canCreate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !providers.isEmpty
    }

    private func paths(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func create() async {
        submitting = true
        do {
            let mission = try await api.createMission(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                providers: MissionProviderOption.all.map(\.id).filter { providers.contains($0) },
                baseRef: baseRef.trimmingCharacters(in: .whitespacesAndNewlines),
                sharedDirectories: paths(sharedPaths),
                copyPaths: paths(copyPaths)
            )
            onCreated(mission)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        submitting = false
    }
}

private struct MissionFormField<Content: View>: View {
    let title: String
    let detail: String
    let content: Content

    init(title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
            content
            Text(detail).font(.system(size: 10)).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MissionEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(WandPrimaryButtonStyle())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
