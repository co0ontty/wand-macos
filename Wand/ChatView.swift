import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private enum ComposerMetrics {
    static let actionVisualSize: CGFloat = 34
    static let actionTouchSize: CGFloat = 44
    static let actionSpacing: CGFloat = 0
}

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在 safeAreaInset(edge: .bottom)。
struct ChatView: View {
    @Environment(\.colorSchemeContrast) private var contrast

    private let sessionId: String
    private let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var attachments: ComposerAttachmentController
    @State private var draft = ""
    @State private var showQuickCommit = false
    @State private var followsLatest = true
    @State private var historyExpanded = false
    @State private var expandedCurrentReplyAbsoluteIndex = -1
    @State private var observedLastUserAbsoluteIndex = Int.min
    @State private var observedLatestAssistantAbsoluteIndex = Int.min
    @State private var showModelThinkingPanel = false
    @State private var showSessionSettingsPanel = false
    @State private var gitStatus: GitStatusResult?
    /// 停止任务二次确认弹窗开关：点停止按钮先弹确认，避免误触中断正在跑的任务。
    @State private var showStopConfirm = false
    @State private var showTroubleshooting = false
    @FocusState private var inputFocused: Bool

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: sessionId, api: api))
        _attachments = StateObject(wrappedValue: ComposerAttachmentController(sessionId: sessionId, api: api))
    }

    var body: some View {
        ZStack {
            WandAmbientBackground()
            if store.loading {
                ProgressView().tint(Theme.brand)
            } else if let error = store.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 30)).foregroundColor(Theme.danger)
                    Text("会话加载失败").font(.headline).foregroundColor(Theme.textPrimary)
                    Text(error).font(.footnote).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("重新加载") { store.retryLoad() }
                            .buttonStyle(.borderedProminent).tint(Theme.brand)
                        Button { showTroubleshooting = true } label: {
                            Label("故障排查", systemImage: "stethoscope")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(32)
            } else if store.messages.isEmpty && !store.isResponding {
                sessionLaunchPanel
            } else {
                messageList
            }
        }
        // 点消息区任意空白处收起键盘；输入栏在 safeAreaInset 里不受影响，
        // 点发送 / 权限按钮不会误收。
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    gitChangesButton
                    if store.isStructured {
                        sessionSettingsMenu
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(
                sessionId: sessionId,
                api: api,
                onRunning: {
                    store.toast = "正在提交 Git 改动…"
                },
                onCompleted: { message in
                    store.toast = message
                    refreshGitStatus()
                },
                onFailed: { message in
                    store.toast = message
                    refreshGitStatus()
                }
            )
        }
        .sheet(isPresented: $showTroubleshooting) {
            TroubleshootingView(
                context: TroubleshootingContext(
                    serverURL: api.baseURL,
                    errorMessage: store.loadError,
                    source: "会话 \(sessionId)"
                ),
                onRetry: store.retryLoad
            )
        }
        .fileImporter(
            isPresented: $attachments.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: attachments.handleFileSelection
        )
        .onAppear {
            attachments.setToastHandler { store.toast = $0 }
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear {
            store.shutdown()
            attachments.cancelPendingUploads()
        }
        .overlay(alignment: .top) {
            toastView
                .padding(.top, 8)
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.canLoadEarlier {
                        Button(action: { store.loadEarlier() }) {
                            loadingEarlierRow(store.loadingEarlier ? "正在加载更早消息…" : "加载更早的消息")
                        }
                        .buttonStyle(.plain)
                        .disabled(store.loadingEarlier)
                    }
                    ForEach(Array(groupedMessageItems.enumerated()), id: \.offset) { _, item in
                        messageItemView(item, proxy: proxy)
                    }
                    if store.isResponding {
                        respondingIndicator
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // 仅用户明确向下拖动、准备查看更早消息时暂停跟随。
                            // 旧逻辑任何轻微拖动都会永久关掉跟随，收键盘或触摸
                            // 列表后，新回复就只能靠右下角按钮才能看到。
                            if value.translation.height > 18 {
                                followsLatest = false
                            }
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        jumpToLatestButton(proxy)
                    }
                }
                .onAppear {
                    syncReplyFoldState(force: true)
                    pinToBottom(proxy)
                }
                .onReceive(store.$messages.dropFirst()) { _ in
                    syncReplyFoldState()
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.isResponding) { _ in
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.loading) { loading in
                    if !loading { pinToBottom(proxy) }
                }
        }
    }

    @ViewBuilder private func messageItemView(_ item: MessageDisplayItem, proxy: ScrollViewProxy) -> some View {
        switch item {
        case .turn(let index, let turn):
            let absoluteIndex = store.loadedOffset + index
            let controlsCurrentReplyExpansion = turn.role != "user"
                && index == latestAssistantTurnIndex
                && absoluteIndex == absoluteLatestAssistantTurnIndex
            TurnView(
                turn: turn,
                baseURL: api.baseURL,
                isLastTurn: index == store.messages.count - 1,
                isResponding: store.isResponding,
                currentReplyExpandedOverride: controlsCurrentReplyExpansion
                    ? (expandedCurrentReplyAbsoluteIndex == absoluteIndex)
                    : nil,
                turnIndex: index,
                historyBoundary: lastUserTurnIndex,
                onUserExpand: {
                    followsLatest = false
                },
                onCurrentReplyExpandedChange: { expanded in
                    if controlsCurrentReplyExpansion {
                        expandedCurrentReplyAbsoluteIndex = expanded ? absoluteIndex : -1
                    }
                },
                onCurrentReplyExpandToBottom: {
                    if controlsCurrentReplyExpansion {
                        expandCurrentReplyToBottom(proxy, absoluteIndex: absoluteIndex)
                    }
                },
                askSelections: store.askUserSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    followsLatest = true
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
        case .explorationGroup(let tools, let lastTurnIndex):
            ExplorationGroupCard(
                tools: tools,
                running: store.isResponding
                    && lastTurnIndex == store.messages.count - 1
                    && tools.contains { $0.result == nil }
            )
        }
    }

    private var groupedMessageItems: [MessageDisplayItem] {
        groupExplorationTurns(store.messages)
    }

    private var lastUserTurnIndex: Int {
        store.messages.lastIndex { $0.role == "user" } ?? -1
    }

    private var absoluteLastUserTurnIndex: Int {
        lastUserTurnIndex >= 0 ? store.loadedOffset + lastUserTurnIndex : -1
    }

    private var latestAssistantTurnIndex: Int {
        store.messages.last?.role == "user" ? -1 : store.messages.indices.last ?? -1
    }

    private var absoluteLatestAssistantTurnIndex: Int {
        latestAssistantTurnIndex >= 0 ? store.loadedOffset + latestAssistantTurnIndex : -1
    }

    private var historyItems: [MessageDisplayItem] {
        guard lastUserTurnIndex > 0 else { return [] }
        return groupedMessageItems.filter { messageItemTurnIndex($0) < lastUserTurnIndex }
    }

    private var currentItems: [MessageDisplayItem] {
        guard lastUserTurnIndex >= 0 else { return groupedMessageItems }
        return groupedMessageItems.filter { messageItemTurnIndex($0) >= lastUserTurnIndex }
    }

    private var unloadedHistoryCount: Int {
        absoluteLastUserTurnIndex > 0 ? min(store.loadedOffset, absoluteLastUserTurnIndex) : 0
    }

    private var hasCollapsedHistory: Bool {
        !historyItems.isEmpty || unloadedHistoryCount > 0
    }

    private var collapsedHistoryCount: Int {
        historyItems.count + unloadedHistoryCount
    }

    private var historyPreview: String {
        guard lastUserTurnIndex > 0 else { return "" }
        for turn in store.messages.prefix(lastUserTurnIndex).reversed() {
            let raw = turn.content.compactMap { block -> String? in
                guard case .text(let value, _) = block else { return nil }
                return value
            }
            .joined(separator: "\n")
            let parsed = parseUserAttachmentMessage(raw)
            let source = !parsed.body.isEmpty ? parsed.body : (parsed.paths.isEmpty ? raw : "\(parsed.paths.count) 个附件")
            let text = source.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsLatest = true
            historyExpanded = false
            pinToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.brand))
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        }
        .accessibilityLabel("回到最新消息并继续跟随")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func toggleHistory(_ proxy: ScrollViewProxy) {
        let next = !historyExpanded
        historyExpanded = next
        if next {
            followsLatest = false
            expandedCurrentReplyAbsoluteIndex = -1
            store.loadEarlier()
        } else {
            followsLatest = true
            pinToBottom(proxy, animated: true)
        }
    }

    private func expandCurrentReplyToBottom(_ proxy: ScrollViewProxy, absoluteIndex: Int) {
        expandedCurrentReplyAbsoluteIndex = absoluteIndex
        historyExpanded = false
        followsLatest = true
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard expandedCurrentReplyAbsoluteIndex == absoluteIndex else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func syncReplyFoldState(force: Bool = false) {
        let boundary = absoluteLastUserTurnIndex
        let latest = absoluteLatestAssistantTurnIndex
        if force || observedLastUserAbsoluteIndex != boundary {
            observedLastUserAbsoluteIndex = boundary
            observedLatestAssistantAbsoluteIndex = latest
            historyExpanded = false
            expandedCurrentReplyAbsoluteIndex = latest
        } else if observedLatestAssistantAbsoluteIndex != latest {
            observedLatestAssistantAbsoluteIndex = latest
            if latest > boundary {
                expandedCurrentReplyAbsoluteIndex = latest
            }
        }
    }

    private func scrollToLatestIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        // 流式更新会原地增高最后一条消息，首个 scrollTo 可能早于
        // LazyVStack 完成新高度布局；补一次短延迟即可稳定贴住底部。
        for delay in [0.0, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    /// 打开会话时把列表钉到底部。LazyVStack 首帧尚未完成布局，单次 scrollTo
    /// 常停在半中间——立即滚一次，再按递增延迟补几次，直到布局稳定。
    private func pinToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private var respondingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.brand)
            Text(store.currentTaskTitle ?? "正在思考…")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func loadingEarlierRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.brand)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 顶部状态

    private var sessionLaunchPanel: some View {
        VStack(spacing: 18) {
            WandBrandMark(size: 52)
            Text(emptySessionTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(emptySessionMessage)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 340)
        .wandGlassCard(cornerRadius: 20)
        .padding(.horizontal, 24)
    }

    private var emptySessionTitle: String {
        if store.sessionEnded { return "会话已结束" }
        return store.isStructured ? "会话尚无消息" : "终端尚无输出"
    }

    private var emptySessionMessage: String {
        if store.sessionEnded {
            return "这个会话没有保存可显示的内容。你可以从输入框继续尝试，或返回列表选择其他会话。"
        }
        return store.isStructured
            ? "在下方输入消息开始对话。"
            : "PTY 会话已经连接；输入命令或消息后，输出会显示在这里。"
    }

    private func modelButton(id: String?, label: String) -> some View {
        Button {
            store.setModel(id)
        } label: {
            if store.selectedModel == id {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: store.snapshot?.provider ?? "claude",
            selectedModel: store.selectedModel,
            defaultModel: store.defaultModel,
            models: store.availableModels
        )
    }

    private func thinkingShortLabel(_ id: String) -> String {
        thinkingLevels.first { $0.id == id }?.shortLabel ?? "关"
    }

    // MARK: - 底部栏（权限卡 + 队列 + 输入框）

    /// 输入栏上方悬浮的待办进度条数据：当前 turn 的 todos，全部完成后隐藏（对齐 Web）。
    /// 同时在会话不再 running（turn 已结束 / idle / exited）时隐藏——模型常忘了发最后
    /// 一条全 completed 的更新，否则进度条会卡在「5/6」干瞪眼（对齐 Web sessionActive）。
    private var visibleTodos: [TodoItem] {
        guard store.status == "running" else { return [] }
        let todos = TodoItem.currentTodos(in: store.messages)
        guard !todos.isEmpty else { return [] }
        let completed = todos.filter { $0.status == "completed" }.count
        return completed == todos.count ? [] : todos
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if !visibleTodos.isEmpty {
                TodoProgressBar(todos: visibleTodos)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if store.pendingEscalation != nil || store.legacyPermissionPrompt != nil {
                PermissionCard(
                    escalation: store.pendingEscalation,
                    legacy: store.legacyPermissionPrompt,
                    onResolve: { store.resolvePermission($0) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !store.queuedMessages.isEmpty {
                QueueBar(store: store)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            inputBar
        }
        .background(
            Theme.background
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.2), value: store.pendingEscalation)
    }

    private var inputBar: some View {
        // macOS 有稳定的桌面空间：输入区始终保持“正文 + 工具栏”两层，
        // 鼠标或键盘聚焦只改变描边颜色，不再触发布局放大/缩小。
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: ComposerMetrics.actionSpacing) {
                composerInputContent
            }
            HStack(spacing: ComposerMetrics.actionSpacing) {
                composerActionsMenu
                if store.isStructured {
                    modelThinkingChip
                }
                Spacer(minLength: 0)
                trailingButtons
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .wandGlass(.panel)
        .overlay(
            shape.stroke(
                inputFocused ? Theme.wandAccent.opacity(contrast == .increased ? 1 : 0.62) : Theme.border,
                lineWidth: contrast == .increased ? 2 : (inputFocused ? 1.35 : 1)
            )
        )
        .shadow(
            color: inputFocused ? Theme.wandAccent.opacity(0.05) : Color.black.opacity(0.025),
            radius: 6,
            x: 0,
            y: 2
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { store.stopResponding() }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerInputContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.attachments.isEmpty {
                PendingAttachmentsPreview(
                    baseURL: api.baseURL,
                    attachments: attachments.attachments,
                    onRemove: attachments.remove
                )
            }
            growingTextField
                .focused($inputFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityHint("可按 Command-V 粘贴剪贴板中的图片")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // macOS 12 尚没有可靠的 SwiftUI 图片粘贴回调。局部事件拦截器只在本输入框
        // 聚焦时处理图片 / Finder 文件 URL，纯文本仍由系统 TextField 原样粘贴。
        .background(
            ComposerPasteInterceptor(
                attachments: attachments,
                isInputFocused: inputFocused
            )
            .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder private var trailingButtons: some View {
        if store.isResponding {
            Button(action: { showStopConfirm = true }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(
                        width: ComposerMetrics.actionVisualSize,
                        height: ComposerMetrics.actionVisualSize
                    )
                    .background(Circle().fill(Theme.danger))
            }
            .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
            .buttonStyle(.plain)
            .accessibilityLabel("停止任务")
        }
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(canSend ? Theme.surface : Theme.textSecondary.opacity(0.55))
                .frame(
                    width: ComposerMetrics.actionVisualSize,
                    height: ComposerMetrics.actionVisualSize
                )
                .background(
                    Circle().fill(canSend ? Theme.textPrimary : Theme.textSecondary.opacity(0.16))
                )
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("发送")
    }

    private var modelThinkingChip: some View {
        Button {
            showModelThinkingPanel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                Text(modelThinkingText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 116)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.65)
            }
            .foregroundColor(thinkingTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Capsule().fill(thinkingTint.opacity(0.10)))
            .overlay(Capsule().stroke(thinkingTint.opacity(0.22), lineWidth: 1))
            .frame(minHeight: ComposerMetrics.actionTouchSize)
        }
        .accessibilityLabel("模型与思考深度")
        .buttonStyle(.plain)
        .popover(isPresented: $showModelThinkingPanel, arrowEdge: .bottom) {
            modelThinkingPanel
        }
    }

    private var modelThinkingText: String {
        "\(shortModelLabel) · \(thinkingShortLabel(store.thinkingEffort))"
    }

    private var shortModelLabel: String {
        guard let selected = store.selectedModel, !selected.isEmpty, selected != "default" else {
            return "默认"
        }
        let full = store.availableModels.first(where: { $0.id == selected })?.label ?? selected
        let base: String
        if let idx = full.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            base = String(full[..<idx]).trimmingCharacters(in: .whitespaces)
        } else {
            base = full
        }
        let leaf = base.split(separator: "/").last.map(String.init) ?? base
        let lower = leaf.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("gpt-5") { return "GPT-5" }
        if lower.contains("gpt-4") { return "GPT-4" }
        return leaf.count > 12 ? String(leaf.prefix(10)) + "…" : leaf
    }

    private var thinkingTint: Color {
        switch store.thinkingEffort {
        case "standard": return .green
        case "deep": return .orange
        case "max": return Theme.danger
        default: return Theme.brand
        }
    }

    private var sessionSettingsMenu: some View {
        Button {
            showSessionSettingsPanel = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.brand)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("会话设置")
        .popover(isPresented: $showSessionSettingsPanel, arrowEdge: .bottom) {
            modelThinkingPanel
        }
    }

    private var modelThinkingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                modelButton(id: nil, label: "默认")
                ForEach(store.availableModels.filter { $0.id != "default" }) { model in
                    modelButton(id: model.id, label: model.label)
                }
            } label: {
                HStack {
                    Label("模型", systemImage: "cpu")
                    Spacer()
                    Text(shortModelLabel).font(.system(.caption, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundColor(Theme.textPrimary)
                .contentShape(Rectangle())
            }
            Divider()
            ThinkingEffortSlider(
                options: thinkingLevels,
                selection: store.thinkingEffort,
                accent: thinkingTint,
                onSelect: store.setThinkingEffort
            )
        }
        .padding(14)
        .frame(width: 286)
    }

    private var gitChangesButton: some View {
        Button {
            showQuickCommit = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text("~\(gitChangeCounts.modified)")
                Text("-\(gitChangeCounts.deleted)")
                    .foregroundColor(Theme.danger)
                Text("+\(gitChangeCounts.added)")
                    .foregroundColor(.green)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel(
            "Git 修改 \(gitChangeCounts.modified)，删除 \(gitChangeCounts.deleted)，新增 \(gitChangeCounts.added)"
        )
    }

    private var gitChangeCounts: (modified: Int, deleted: Int, added: Int) {
        var counts = (modified: 0, deleted: 0, added: 0)
        for file in gitStatus?.files ?? [] {
            let status = file.status.uppercased()
            if status.contains("?") || status.contains("A") {
                counts.added += 1
            } else if status.contains("D") {
                counts.deleted += 1
            } else {
                counts.modified += 1
            }
        }
        return counts
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: sessionId)
        }
    }

    private var composerActionsMenu: some View {
        Menu {
            Button {
                attachments.showFileImporter = true
            } label: {
                Label("选择图片或文件…", systemImage: "paperclip")
            }
            .disabled(attachments.isUploading || attachments.isFull)

            Button {
                _ = attachments.importFromPasteboard(.general)
            } label: {
                Label("粘贴剪贴板中的图片", systemImage: "photo.on.rectangle")
            }
            .disabled(attachments.isUploading || attachments.isFull)

            Divider()

            Text("附件会先上传到当前 Wand 服务，点击发送后才会加入本条消息。")
        } label: {
            if attachments.isUploading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .frame(
                        width: ComposerMetrics.actionVisualSize,
                        height: ComposerMetrics.actionVisualSize
                    )
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(
                        width: ComposerMetrics.actionVisualSize,
                        height: ComposerMetrics.actionVisualSize
                    )
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
        }
        .frame(width: ComposerMetrics.actionTouchSize, height: ComposerMetrics.actionTouchSize)
        .buttonStyle(.plain)
        .accessibilityLabel("添加附件和更多操作")
        .help("选择图片或文件；也可在输入框按 Command-V 粘贴图片")
    }

    /// iOS 16+ / macOS 13+ 用多行自增高输入框；旧系统退化为单行。
    /// Enter 发送(走 onSubmit),Shift+Enter 走 multi-line newline 行为(由 TextField axis
    /// 默认处理:macOS 14+ 区分 Enter 提交 / Shift+Enter 换行,这里再显式做一次修饰键判定,
    /// 避免老系统回车直接清空草稿但没发出去)。
    @ViewBuilder private var growingTextField: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TextField(composerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .onSubmit { handleReturnKey(shift: false) }
        } else {
            TextField(composerPlaceholder, text: $draft)
                .font(.system(size: 16))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .onSubmit { handleReturnKey(shift: false) }
        }
    }

    private var composerPlaceholder: String {
        return "输入消息"
    }

    /// 拦截回车:无修饰键 → 发送;带 Shift → 插入换行(老系统回退路径)。
    /// 用 NSApp.currentEvent 读 modifier,因为 onSubmit 回调里没有直接拿到事件。
    private func handleReturnKey(shift: Bool) {
        if shift {
            // Shift+Enter 期望换行;TextField 在多行模式下默认会插入,这里不进 sendDraft。
            return
        }
        sendDraft()
    }

    private var canSend: Bool {
        !attachments.isUploading && (
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.attachments.isEmpty
        )
    }

    private func sendDraft() {
        guard canSend else { return }
        // 多行 TextField 触发的 onSubmit 可能在草稿末尾多带一个换行(回车字符先于 onSubmit
        // 提交落进 draft),trim 一下避免发出去的消息带尾换行。
        let text = buildAttachmentPrompt(attachments.attachments, body: draft)
        guard !text.isEmpty else { return }
        draft = ""
        attachments.attachments.removeAll()
        followsLatest = true
        expandedCurrentReplyAbsoluteIndex = -1
        store.send(text: text)
    }

    // MARK: - Toast

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }
}

// MARK: - Composer attachments

/// 与网页 / iOS 端一致：服务端保存附件后，客户端只在发送当前消息时把路径协议前缀
/// 拼入 prompt。这样图片、文本和任意一般文件都能被当前会话访问，而不会把绝对路径
/// 直接展示在输入框中。
private func buildAttachmentPrompt(_ attachments: [UploadedFile], body: String) -> String {
    let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !attachments.isEmpty else { return message }
    let paths = attachments.map(\.savedPath).joined(separator: "\n")
    let fallback = message.isEmpty ? "请查看附件。" : message
    return "[附件已上传，请查看以下文件:\n\(paths)\n]\n\n\(fallback)"
}

private struct ParsedUserAttachmentMessage {
    let paths: [String]
    let body: String
}

/// 读取和网页 / iOS 同一份附件协议，避免把服务端绝对路径直接展示在用户气泡中。
private func parseUserAttachmentMessage(_ text: String) -> ParsedUserAttachmentMessage {
    let header = "[附件已上传，请查看以下文件:\n"
    let leading = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    guard leading.hasPrefix(header) else {
        return ParsedUserAttachmentMessage(paths: [], body: text)
    }
    let afterHeader = leading.dropFirst(header.count)
    guard let close = afterHeader.range(of: "]\n") else {
        return ParsedUserAttachmentMessage(paths: [], body: text)
    }
    let paths = afterHeader[..<close.lowerBound]
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let body = String(afterHeader[close.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return ParsedUserAttachmentMessage(paths: paths, body: body)
}

private let composerImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico", "heic", "heif",
]

private func isImageAttachment(_ file: UploadedFile) -> Bool {
    if file.mimeType.lowercased().hasPrefix("image/") { return true }
    let ext = (file.originalName as NSString).pathExtension.lowercased()
    return composerImageExtensions.contains(ext)
}

private func isImageAttachmentPath(_ path: String) -> Bool {
    let clean = path.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? path
    return composerImageExtensions.contains((clean as NSString).pathExtension.lowercased())
}

private func attachmentDisplayName(_ file: UploadedFile) -> String {
    let name = file.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let fallback = (file.savedPath as NSString).lastPathComponent
    return fallback.isEmpty ? "附件" : fallback
}

private func attachmentSizeLabel(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private func pastedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
}

private func pasteboardHasImportableAttachment(_ pasteboard: NSPasteboard) -> Bool {
    !pastedFileURLs(from: pasteboard).isEmpty || NSImage(pasteboard: pasteboard) != nil
}

@MainActor
private final class ComposerAttachmentController: ObservableObject {
    static let maximumAttachments = 5

    @Published var showFileImporter = false
    @Published private(set) var isUploading = false
    @Published var attachments: [UploadedFile] = []

    private let sessionId: String
    private let api: WandAPI
    private var showToast: (String) -> Void = { _ in }
    private var uploadTask: Task<Void, Never>?

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
    }

    var isFull: Bool { attachments.count >= Self.maximumAttachments }

    func setToastHandler(_ handler: @escaping (String) -> Void) {
        showToast = handler
    }

    /// 这里只移出「即将发送的消息」。附件已上传到用户明确选择的 Wand 服务，
    /// 但不会在之后的 prompt 中引用，也不会把本机文件路径暴露到输入框里。
    func remove(_ file: UploadedFile) {
        attachments.removeAll { $0.savedPath == file.savedPath }
    }

    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            upload(urls, cleanupAfterUpload: false)
        case .failure(let error):
            let nsError = error as NSError
            // 用户按取消不是错误，不用用 toast 打断其输入。
            guard nsError.code != NSUserCancelledError else { return }
            showToast("无法选择附件：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func importFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard !isUploading else {
            showToast("正在上传附件，请稍候。")
            return true
        }
        guard !isFull else {
            showToast("每条消息最多添加 \(Self.maximumAttachments) 个附件。")
            return true
        }

        let urls = pastedFileURLs(from: pasteboard)
        if !urls.isEmpty {
            upload(urls, cleanupAfterUpload: false)
            return true
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            showToast("剪贴板中没有可上传的图片或文件。")
            return false
        }
        do {
            let url = try writePastedImage(image)
            upload([url], cleanupAfterUpload: true)
        } catch {
            showToast("无法读取剪贴板中的图片：\(error.localizedDescription)")
        }
        return true
    }

    func cancelPendingUploads() {
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
    }

    private func upload(_ rawURLs: [URL], cleanupAfterUpload: Bool) {
        guard !rawURLs.isEmpty else { return }
        guard !isUploading else {
            showToast("正在上传附件，请稍候。")
            return
        }
        let available = Self.maximumAttachments - attachments.count
        guard available > 0 else {
            showToast("每条消息最多添加 \(Self.maximumAttachments) 个附件。")
            return
        }

        // Finder 可能因为别名 / 多选产生重复 URL；先去重再限额，避免无意义的上传。
        var seen = Set<String>()
        let urls = rawURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let accepted = Array(urls.prefix(available))
        guard !accepted.isEmpty else { return }
        if urls.count > accepted.count {
            showToast("每条消息最多添加 \(Self.maximumAttachments) 个附件，已添加前 \(accepted.count) 个。")
        }

        isUploading = true
        let temporaryURLs = cleanupAfterUpload ? accepted : []
        uploadTask = Task { @MainActor [weak self] in
            defer {
                for url in temporaryURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                if let self {
                    self.isUploading = false
                    self.uploadTask = nil
                }
            }

            guard let self else { return }
            do {
                let uploaded = try await self.api.uploadAttachments(id: self.sessionId, urls: accepted)
                guard !Task.isCancelled else { return }
                guard !uploaded.isEmpty else {
                    self.showToast("未收到已上传的附件，请重试。")
                    return
                }
                let room = Self.maximumAttachments - self.attachments.count
                self.attachments.append(contentsOf: uploaded.prefix(room))
                self.showToast("已添加 \(min(uploaded.count, room)) 个附件；发送后会随本条消息提供给会话。")
            } catch is CancellationError {
                // 视图离开时的主动取消不提示，避免后台页面弹出无关错误。
            } catch {
                guard !Task.isCancelled else { return }
                self.showToast("附件上传失败：\(error.localizedDescription)")
            }
        }
    }

    /// 剪贴板图片先写入 app 的临时目录，上传结束（成功、失败或取消）立即删除。
    /// 不会访问或扫描剪贴板以外的任何本机文件。
    private func writePastedImage(_ image: NSImage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wand-pasted-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID().uuidString.lowercased()
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("clipboard-\(id).png")
            try png.write(to: url, options: .atomic)
            return url
        }
        guard let tiff = image.tiffRepresentation else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = directory.appendingPathComponent("clipboard-\(id).tiff")
        try tiff.write(to: url, options: .atomic)
        return url
    }
}

/// macOS 12 没有能稳定捕获图片粘贴的 SwiftUI API；这个零尺寸 NSView 只在
/// composer 可见时注册本地键盘监听。它不会拦截纯文本，也不会监听全局键盘事件。
private struct ComposerPasteInterceptor: NSViewRepresentable {
    let attachments: ComposerAttachmentController
    let isInputFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(attachments: attachments, isInputFocused: isInputFocused)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(attachments: attachments, isInputFocused: isInputFocused)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private weak var attachments: ComposerAttachmentController?
        private var isInputFocused = false
        private var monitor: Any?

        func update(attachments: ComposerAttachmentController, isInputFocused: Bool) {
            self.attachments = attachments
            self.isInputFocused = isInputFocused
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      self.isInputFocused,
                      Self.isPasteShortcut(event),
                      pasteboardHasImportableAttachment(.general) else {
                    return event
                }
                // 拦截后立即消费图片 / file URL，防止系统把二进制内容或路径意外写进草稿。
                let attachments = self.attachments
                Task { @MainActor in
                    _ = attachments?.importFromPasteboard(.general)
                }
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit { stop() }

        private static func isPasteShortcut(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
                  let characters = event.charactersIgnoringModifiers?.lowercased() else {
                return false
            }
            return characters == "v"
        }
    }
}

private struct PendingAttachmentsPreview: View {
    let baseURL: URL
    let attachments: [UploadedFile]
    let onRemove: (UploadedFile) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments, id: \.savedPath) { file in
                    attachmentItem(file)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待发送附件，共 \(attachments.count) 个")
    }

    @ViewBuilder private func attachmentItem(_ file: UploadedFile) -> some View {
        ZStack(alignment: .topTrailing) {
            if isImageAttachment(file) {
                ComposerAttachmentImage(baseURL: baseURL, path: file.savedPath)
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .accessibilityLabel("图片附件 \(attachmentDisplayName(file))")
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachmentDisplayName(file))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(attachmentSizeLabel(file.size))
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 210, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.surface.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }

            Button {
                onRemove(file)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.background.opacity(0.96)))
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除附件 \(attachmentDisplayName(file))")
            .help("从本条消息移除")
            .offset(x: 5, y: -5)
        }
    }
}

/// 加载服务端已保存的图片缩略图。必须复用 SelfSignedSession 才能带上登录 cookie
/// 并兼容用户自签名的 Wand HTTPS 服务。
private struct ComposerAttachmentImage: View {
    let baseURL: URL
    let path: String
    var fill = true

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else if failed {
                imagePlaceholder(icon: "photo")
            } else {
                ZStack {
                    imagePlaceholder(icon: "photo")
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: path) { await load() }
    }

    private func imagePlaceholder(icon: String) -> some View {
        Rectangle()
            .fill(Theme.surface)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textSecondary.opacity(0.55))
            )
    }

    private func load() async {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            failed = true
            return
        }
        components.path = "/api/file-raw"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else {
            failed = true
            return
        }
        do {
            let (data, response) = try await SelfSignedSession.shared.session.data(for: URLRequest(url: url))
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = NSImage(data: data) else {
                if !Task.isCancelled { failed = true }
                return
            }
            image = decoded
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

// MARK: - 单条消息

private struct HistorySummaryStrip: View {
    let count: Int
    let preview: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : -90))
                    .foregroundColor(Theme.textSecondary)
                Text("已收起 \(count) 段上文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(expanded ? "收起" : "展开")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 工具调用与结果在渲染层配成一张卡片（对齐 Web 端 buildToolResultMap / Android pairToolBlocks）。
private enum DisplayItem {
    case plain(ContentBlock)
    case tool(
        id: String, name: String, description: String?,
        input: [String: JSONValue], subagent: SubagentMeta?,
        result: ToolResultInfo?
    )
    case explorationGroup([ExplorationToolItem])
}

private struct SubagentSegment {
    let id: String
    let meta: SubagentMeta
    let blocks: [ContentBlock]
}

private enum AssistantContentSegment {
    case parent([ContentBlock])
    case subagent(SubagentSegment)
}

/// 同一个 taskId 在一轮内聚合成一个固定高度角色窗口，父 Agent 内容仍按原来的
/// 活动分组规则展示。这样长任务不会把整段会话无限撑高。
private func splitAssistantContentBySubagent(_ content: [ContentBlock]) -> [AssistantContentSegment] {
    var segments: [AssistantContentSegment] = []
    var subagentIndexByID: [String: Int] = [:]
    var parentBlocks: [ContentBlock] = []

    func flushParent() {
        guard !parentBlocks.isEmpty else { return }
        segments.append(.parent(parentBlocks))
        parentBlocks.removeAll(keepingCapacity: true)
    }

    for block in content {
        guard let meta = blockSubagentMeta(block) else {
            parentBlocks.append(block)
            continue
        }
        flushParent()
        let id = subagentIdentity(meta)
        if let index = subagentIndexByID[id], case .subagent(let existing) = segments[index] {
            segments[index] = .subagent(SubagentSegment(
                id: existing.id,
                meta: existing.meta,
                blocks: existing.blocks + [block]
            ))
        } else {
            subagentIndexByID[id] = segments.count
            segments.append(.subagent(SubagentSegment(id: id, meta: meta, blocks: [block])))
        }
    }
    flushParent()
    return segments
}

private func blockSubagentMeta(_ block: ContentBlock) -> SubagentMeta? {
    switch block {
    case .text(_, let subagent),
         .thinking(_, let subagent),
         .toolUse(_, _, _, _, let subagent),
         .toolResult(_, _, _, _, let subagent):
        return subagent
    case .unknown:
        return nil
    }
}

private func subagentIdentity(_ meta: SubagentMeta) -> String {
    if let taskID = meta.taskId, !taskID.isEmpty { return "task:\(taskID)" }
    if let agentType = meta.agentType, !agentType.isEmpty { return "type:\(agentType)" }
    if let description = meta.taskDescription, !description.isEmpty { return "desc:\(description)" }
    return "__subagent"
}

private struct ActivityGroup: Identifiable {
    let id: String
    let summary: String
    let items: [DisplayItem]
    let running: Bool
}

private enum SegmentRenderItem {
    case item(Int, DisplayItem)
    case activity(ActivityGroup)
}

private enum MessageDisplayItem {
    case turn(index: Int, ConversationTurn)
    case explorationGroup(tools: [ExplorationToolItem], lastTurnIndex: Int)
}

private func messageItemTurnIndex(_ item: MessageDisplayItem) -> Int {
    switch item {
    case .turn(let index, _): return index
    case .explorationGroup(_, let lastTurnIndex): return lastTurnIndex
    }
}

private struct ExplorationToolItem {
    let id: String
    let name: String
    let description: String?
    let input: [String: JSONValue]
    let subagent: SubagentMeta?
    let result: ToolResultInfo?
}

/// 将相邻、且内容完全由只读探索工具组成的 assistant turn 跨消息合并。
/// 用户消息、正式文本、编辑/命令等操作都会立即终止分组。
private func groupExplorationTurns(_ turns: [ConversationTurn]) -> [MessageDisplayItem] {
    var items: [MessageDisplayItem] = []
    var pendingTools: [ExplorationToolItem] = []
    var pendingLastIndex = -1

    func flushPending() {
        guard !pendingTools.isEmpty else { return }
        items.append(.explorationGroup(tools: pendingTools, lastTurnIndex: pendingLastIndex))
        pendingTools.removeAll(keepingCapacity: true)
        pendingLastIndex = -1
    }

    for (index, turn) in turns.enumerated() {
        if let tools = explorationToolsOnly(in: turn) {
            pendingTools.append(contentsOf: tools)
            pendingLastIndex = index
        } else {
            flushPending()
            items.append(.turn(index: index, turn))
        }
    }
    flushPending()
    return items
}

private func explorationToolsOnly(in turn: ConversationTurn) -> [ExplorationToolItem]? {
    guard turn.role == "assistant" else { return nil }
    var tools: [ExplorationToolItem] = []
    for item in pairToolBlocks(turn.content) {
        switch item {
        case .explorationGroup(let group):
            tools.append(contentsOf: group)
        case .tool(let id, let name, let description, let input, let subagent, let result)
            where isExplorationTool(name):
            tools.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        default:
            return nil
        }
    }
    return tools.isEmpty ? nil : tools
}

/// 配对后挂在工具卡上的结果。
struct ToolResultInfo {
    let text: String
    let isError: Bool
    let truncated: Bool
}

/// 优先按 tool_use_id 精确配对（并行工具调用时顺序会交错）；
/// id 缺失时退回「紧随其后的第一个结果」邻接兜底；没配上的 ToolResult 原样透传。
private func pairToolBlocks(_ content: [ContentBlock]) -> [DisplayItem] {
    var paired: [DisplayItem] = []
    var consumed = Set<Int>()
    for (i, block) in content.enumerated() {
        if consumed.contains(i) { continue }
        guard case .toolUse(let id, let name, let description, let input, let subagent) = block else {
            paired.append(.plain(block))
            continue
        }
        var resultIndex = -1
        if !id.isEmpty {
            // 1) 全局按 tool_use_id 精确配对
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolResult(let rid, _, _, _, _) = content[j], rid == id {
                    resultIndex = j
                    break
                }
            }
        }
        if resultIndex < 0 {
            // 2) 邻接兜底：中间隔着下一个 ToolUse 视为无结果；id 双方都有但不匹配时不抢配。
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolUse = content[j] { break }
                if case .toolResult(let rid, _, _, _, _) = content[j] {
                    if rid.isEmpty || id.isEmpty { resultIndex = j }
                    break
                }
            }
        }
        var result: ToolResultInfo?
        if resultIndex >= 0, case .toolResult(_, let text, let isError, let truncated, _) = content[resultIndex] {
            consumed.insert(resultIndex)
            result = ToolResultInfo(text: text, isError: isError, truncated: truncated)
        }
        paired.append(.tool(
            id: id, name: name, description: description,
            input: input, subagent: subagent, result: result
        ))
    }
    return collapseConsecutiveExplorationTools(paired)
}

/// 连续读取、搜索、网页获取通常只是模型探索上下文，不需要逐张占满对话流。
/// 至少连续两次才合并，单次操作仍保留完整工具卡。
private func collapseConsecutiveExplorationTools(_ paired: [DisplayItem]) -> [DisplayItem] {
    var items: [DisplayItem] = []
    var exploration: [ExplorationToolItem] = []

    func flushExploration() {
        if exploration.count >= 2 {
            items.append(.explorationGroup(exploration))
        } else if let tool = exploration.first {
            items.append(.tool(
                id: tool.id, name: tool.name, description: tool.description,
                input: tool.input, subagent: tool.subagent, result: tool.result
            ))
        }
        exploration.removeAll(keepingCapacity: true)
    }

    for item in paired {
        if case .tool(let id, let name, let description, let input, let subagent, let result) = item,
           isExplorationTool(name) {
            exploration.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        } else {
            flushExploration()
            items.append(item)
        }
    }
    flushExploration()
    return items
}

private func isExplorationTool(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.hasPrefix("read")
        || lower.hasPrefix("grep")
        || lower.hasPrefix("glob")
        || lower.hasPrefix("search")
        || lower.hasPrefix("find")
        || lower.contains("websearch")
        || lower.contains("webfetch")
        || lower == "todoread"
}

private func collapseActivityItems(
    _ items: [DisplayItem],
    isLastTurn: Bool,
    isResponding: Bool
) -> [SegmentRenderItem] {
    var renderItems: [SegmentRenderItem] = []
    var pending: [DisplayItem] = []
    var pendingStartIndex = -1

    func flushPending() {
        guard !pending.isEmpty else { return }
        let groupItems = pending
        let running = groupItems.contains { isDisplayItemRunning($0, isLastTurn: isLastTurn, isResponding: isResponding) }
        renderItems.append(.activity(ActivityGroup(
            id: activityGroupKey(groupItems, startIndex: pendingStartIndex),
            summary: activitySummary(groupItems, running: running),
            items: groupItems,
            running: running
        )))
        pending.removeAll(keepingCapacity: true)
        pendingStartIndex = -1
    }

    for (index, item) in items.enumerated() {
        if isCollapsibleActivityItem(item) {
            if pending.isEmpty { pendingStartIndex = index }
            pending.append(item)
        } else {
            flushPending()
            renderItems.append(.item(index, item))
        }
    }
    flushPending()
    return renderItems
}

private func activityGroupKey(_ items: [DisplayItem], startIndex: Int) -> String {
    let first = items.first.map(displayItemStableKey) ?? "empty"
    return "\(startIndex):\(first)"
}

private func displayItemStableKey(_ item: DisplayItem) -> String {
    switch item {
    case .tool(let id, let name, _, _, _, _):
        return "tool:\(id.isEmpty ? name : id)"
    case .explorationGroup(let tools):
        return "explore:\(tools.first?.id ?? "\(tools.count)")"
    case .plain(let block):
        switch block {
        case .thinking(let text, let subagent):
            return "thinking:\(subagent?.taskId ?? String(text.prefix(24)))"
        case .toolResult(let id, let text, _, _, _):
            return "result:\(id.isEmpty ? String(text.prefix(24)) : id)"
        case .text(let text, _):
            return "text:\(String(text.prefix(24)))"
        case .toolUse(let id, let name, _, _, _):
            return "plain-tool:\(id.isEmpty ? name : id)"
        case .unknown:
            return "unknown"
        }
    }
}

private func isCollapsibleActivityItem(_ item: DisplayItem) -> Bool {
    switch item {
    case .plain(let block):
        if case .text = block { return false }
        if case .unknown = block { return false }
        return true
    case .explorationGroup:
        return true
    case .tool(_, let name, _, _, _, _):
        return name != "AskUserQuestion"
    }
}

private func isDisplayItemRunning(_ item: DisplayItem, isLastTurn: Bool, isResponding: Bool) -> Bool {
    guard isLastTurn && isResponding else { return false }
    switch item {
    case .tool(_, _, _, _, _, let result):
        return result == nil
    case .explorationGroup(let tools):
        return tools.contains { $0.result == nil }
    case .plain(let block):
        if case .thinking = block { return true }
        return false
    }
}

private func activityTools(_ items: [DisplayItem]) -> [ExplorationToolItem] {
    items.flatMap { item -> [ExplorationToolItem] in
        switch item {
        case .tool(let id, let name, let description, let input, let subagent, let result):
            return [ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            )]
        case .explorationGroup(let tools):
            return tools
        case .plain:
            return []
        }
    }
}

private func activitySummary(_ items: [DisplayItem], running: Bool) -> String {
    let tools = activityTools(items)
    if items.count == 1, let tool = tools.first, tools.count == 1 {
        let prefix = running && tool.result == nil ? "正在" : "已"
        let detail = toolInputSummary(tool.description, tool.input)
        let label = activityVerb(tool.name)
        return detail.isEmpty ? "\(prefix)\(label)" : "\(prefix)\(label) \(detail)"
    }
    if items.count == 1, case .plain(let block)? = items.first {
        switch block {
        case .thinking:
            return running ? "正在思考" : "已思考"
        case .toolResult(_, _, let isError, _, _):
            return isError ? "有 1 条执行错误" : "已生成 1 条执行结果"
        default:
            return "已完成 1 项活动"
        }
    }

    let readCount = tools.filter { activityKind($0.name) == "read" }.count
    let commandCount = tools.filter { activityKind($0.name) == "command" }.count
    let searchCount = tools.filter { activityKind($0.name) == "search" }.count
    let editCount = tools.filter { activityKind($0.name) == "edit" }.count
    let webCount = tools.filter { activityKind($0.name) == "web" }.count
    let todoCount = tools.filter { activityKind($0.name) == "todo" }.count
    let otherToolCount = tools.count - readCount - commandCount - searchCount - editCount - webCount - todoCount
    let thinkingCount = items.filter {
        if case .plain(.thinking(_, _)) = $0 { return true }
        return false
    }.count
    let resultCount = items.filter {
        if case .plain(.toolResult(_, _, _, _, _)) = $0 { return true }
        return false
    }.count

    var parts: [String] = []
    if readCount > 0 { parts.append("浏览 \(readCount) 个文件") }
    if commandCount > 0 { parts.append("运行 \(commandCount) 条命令") }
    if searchCount > 0 { parts.append("搜索 \(searchCount) 次") }
    if editCount > 0 { parts.append("修改 \(editCount) 个文件") }
    if webCount > 0 { parts.append("访问 \(webCount) 个网页") }
    if todoCount > 0 { parts.append("更新 \(todoCount) 次待办") }
    if thinkingCount > 0 { parts.append("思考 \(thinkingCount) 段") }
    if resultCount > 0 { parts.append("生成 \(resultCount) 条结果") }
    if otherToolCount > 0 { parts.append("调用 \(otherToolCount) 个工具") }

    let prefix = running ? "正在" : "已"
    return parts.isEmpty ? "\(prefix)完成 \(items.count) 项活动" : prefix + parts.joined(separator: "，")
}

private func activityVerb(_ name: String) -> String {
    switch activityKind(name) {
    case "read": return "浏览"
    case "command": return "运行"
    case "search": return "搜索代码"
    case "edit": return "修改"
    case "web": return "访问网页"
    case "todo": return "更新待办"
    default: return toolLabel(name)
    }
}

private func activityKind(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.hasPrefix("read") || lower.contains("notebook") { return "read" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "command" }
    if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("find") { return "search" }
    if lower.contains("edit") || lower.contains("write") { return "edit" }
    if lower.contains("web") || lower.contains("fetch") || lower.contains("http") { return "web" }
    if lower.contains("todo") { return "todo" }
    return "other"
}

private func toolInputSummary(_ description: String?, _ input: [String: JSONValue]) -> String {
    if let description, !description.isEmpty { return description }
    for key in ["command", "file_path", "path", "pattern", "query", "prompt", "url", "description"] {
        if let value = input[key] {
            let text = value.summaryText
            if !text.isEmpty { return text }
        }
    }
    if let first = input.first {
        return "\(first.key): \(first.value.summaryText)"
    }
    return ""
}

private struct AssistantReplyHeader: View {
    let collapsed: Bool
    let preview: String
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.brand.opacity(0.14))
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.brand)
                    }
                    .frame(width: 24, height: 24)
                    Text("Wand")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if collapsed, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 180))
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(Theme.border.opacity(0.65))
                .frame(height: 0.5)
        }
    }
}

private func replyPreview(_ content: [ContentBlock]) -> String {
    let text = content.compactMap { block -> String? in
        guard case .text(let value, _) = block else { return nil }
        return value
    }
    .joined(separator: " ")
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    if !text.isEmpty { return text }
    let toolCount = content.reduce(0) { total, block in
        if case .toolUse = block { return total + 1 }
        return total
    }
    return toolCount > 0 ? "\(toolCount) 个工具调用" : ""
}

private struct ActivitySummaryRow: View {
    let group: ActivityGroup
    let onClick: () -> Void

    var body: some View {
        Button {
            onClick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: activityIconName(group.items))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(group.running ? Theme.brand : Theme.textSecondary)
                    .frame(width: 18)
                Text(group.summary)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activityIconName(_ items: [DisplayItem]) -> String {
        if let first = activityTools(items).first {
            let lower = first.name.lowercased()
            if lower.contains("bash") || lower.contains("command") { return "terminal" }
            if lower.contains("edit") || lower.contains("write") { return "pencil" }
            if lower.contains("read") { return "doc.text.magnifyingglass" }
            if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
            if lower.contains("web") || lower.contains("fetch") { return "globe" }
            if lower.contains("task") || lower.contains("agent") { return "person.2" }
            return "wrench.and.screwdriver"
        }
        if case .plain(.thinking(_, _))? = items.first {
            return "brain"
        }
        return "doc.text"
    }
}

private struct ActivityDetailSheet<Content: View>: View {
    let group: ActivityGroup
    @ViewBuilder let itemView: (DisplayItem) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("执行详情")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(group.summary)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surface))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.background)
    }
}

private let subagentWindowContentHeight: CGFloat = 280

private struct SubagentRoleWindow<Content: View>: View {
    let meta: SubagentMeta
    let items: [DisplayItem]
    let running: Bool
    @ViewBuilder let itemView: (DisplayItem) -> Content

    private var title: String {
        let raw = meta.agentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return "猫猫子 Agent" }
        return raw.hasPrefix("猫猫") ? raw : "猫猫 \(raw)"
    }

    private var subtitle: String {
        let text = meta.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "子 Agent 输出" : text
    }

    private var tailAnchorID: String {
        "subagent-tail:\(subagentIdentity(meta))"
    }

    var body: some View {
        let refreshToken = subagentTailRefreshToken(items)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(running ? "处理中" : "\(items.count) 条内容")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.codex)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.codex.opacity(0.10)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Theme.border.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if items.isEmpty {
                            Text("等待子 Agent 输出…")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                itemView(item)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(tailAnchorID)
                    }
                    .padding(10)
                }
                .frame(height: subagentWindowContentHeight)
                .background(Theme.background.opacity(0.45))
                .onAppear {
                    scrollToTail(proxy)
                }
                .onChange(of: refreshToken) { _ in
                    scrollToTail(proxy)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.codex.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(subtitle)")
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(tailAnchorID, anchor: .bottom)
        }
    }
}

/// 数量不变的流式文本/工具结果也必须触发窗口跟尾。
private func subagentTailRefreshToken(_ items: [DisplayItem]) -> Int {
    var hasher = Hasher()
    hasher.combine(items.count)
    for item in items {
        switch item {
        case .tool(let id, let name, _, _, _, let result):
            hasher.combine(id)
            hasher.combine(name)
            hasher.combine(result?.text)
            hasher.combine(result?.isError)
            hasher.combine(result?.truncated)
        case .explorationGroup(let tools):
            for tool in tools {
                hasher.combine(tool.id)
                hasher.combine(tool.result?.text)
                hasher.combine(tool.result?.isError)
                hasher.combine(tool.result?.truncated)
            }
        case .plain(let block):
            switch block {
            case .text(let text, _), .thinking(let text, _):
                hasher.combine(text)
            case .toolUse(let id, let name, _, _, _):
                hasher.combine(id)
                hasher.combine(name)
            case .toolResult(let id, let text, let isError, let truncated, _):
                hasher.combine(id)
                hasher.combine(text)
                hasher.combine(isError)
                hasher.combine(truncated)
            case .unknown:
                hasher.combine("unknown")
            }
        }
    }
    return hasher.finalize()
}

private struct TurnView: View {
    let turn: ConversationTurn
    var baseURL: URL?
    var isLastTurn: Bool
    var isResponding: Bool
    var currentReplyExpandedOverride: Bool?
    var turnIndex: Int
    var historyBoundary: Int
    var showHeader: Bool
    var showContent: Bool
    var onUserExpand: () -> Void
    var onCurrentReplyExpandedChange: (Bool) -> Void
    var onCurrentReplyExpandToBottom: () -> Void
    var askSelections: [String: AskUserSelectionState]
    var onAskToggle: (String, Int, Int, Bool) -> Void
    var onAskSubmit: (String, String) -> Void

    @State private var localCollapsed: Bool
    @State private var openActivityGroup: ActivityGroup?

    init(
        turn: ConversationTurn,
        baseURL: URL? = nil,
        isLastTurn: Bool = false,
        isResponding: Bool = false,
        currentReplyExpandedOverride: Bool? = nil,
        turnIndex: Int = -1,
        historyBoundary: Int = -1,
        showHeader: Bool = true,
        showContent: Bool = true,
        onUserExpand: @escaping () -> Void = {},
        onCurrentReplyExpandedChange: @escaping (Bool) -> Void = { _ in },
        onCurrentReplyExpandToBottom: @escaping () -> Void = {},
        askSelections: [String: AskUserSelectionState] = [:],
        onAskToggle: @escaping (String, Int, Int, Bool) -> Void = { _, _, _, _ in },
        onAskSubmit: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.turn = turn
        self.baseURL = baseURL
        self.isLastTurn = isLastTurn
        self.isResponding = isResponding
        self.currentReplyExpandedOverride = currentReplyExpandedOverride
        self.turnIndex = turnIndex
        self.historyBoundary = historyBoundary
        self.showHeader = showHeader
        self.showContent = showContent
        self.onUserExpand = onUserExpand
        self.onCurrentReplyExpandedChange = onCurrentReplyExpandedChange
        self.onCurrentReplyExpandToBottom = onCurrentReplyExpandToBottom
        self.askSelections = askSelections
        self.onAskToggle = onAskToggle
        self.onAskSubmit = onAskSubmit
        _localCollapsed = State(initialValue: turnIndex >= 0 && historyBoundary >= 0 && turnIndex < historyBoundary)
        _openActivityGroup = State(initialValue: nil)
    }

    var body: some View {
        if turn.role == "user" {
            userBubble
        } else {
            assistantReply
        }
    }

    private var userText: String {
        var pieces: [String] = []
        for block in turn.content {
            if case .text(let text, _) = block { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    private var parsedUserMessage: ParsedUserAttachmentMessage {
        parseUserAttachmentMessage(userText)
    }

    private var userBubble: some View {
        let parsed = parsedUserMessage
        return VStack(alignment: .trailing, spacing: 6) {
            if !parsed.paths.isEmpty {
                userAttachmentPreviews(parsed.paths)
            }
            if !parsed.body.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    Text(parsed.body)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.brand)
                        )
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func userAttachmentPreviews(_ paths: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                if let baseURL, isImageAttachmentPath(path) {
                    ComposerAttachmentImage(baseURL: baseURL, path: path, fill: false)
                        .frame(maxWidth: 240, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .accessibilityLabel("图片附件 \((path as NSString).lastPathComponent)")
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "doc")
                            .font(.system(size: 13, weight: .medium))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand.opacity(0.88))
                    )
                    .accessibilityLabel("文件附件 \((path as NSString).lastPathComponent)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var defaultCollapsed: Bool {
        turnIndex >= 0 && historyBoundary >= 0 && turnIndex < historyBoundary
    }

    private var shouldFoldCurrentReply: Bool {
        isLastTurn && turnIndex > historyBoundary
    }

    private var collapsed: Bool {
        if let currentReplyExpandedOverride {
            return !currentReplyExpandedOverride
        }
        return localCollapsed
    }

    private func setCollapsed(_ next: Bool) {
        if currentReplyExpandedOverride == nil {
            localCollapsed = next
        }
        onCurrentReplyExpandedChange(!next)
    }

    private var assistantReply: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader {
                AssistantReplyHeader(
                    collapsed: collapsed,
                    preview: replyPreview(turn.content),
                    onToggle: {
                        let next = !collapsed
                        setCollapsed(next)
                        if !next {
                            if shouldFoldCurrentReply {
                                onCurrentReplyExpandToBottom()
                            } else {
                                onUserExpand()
                            }
                        }
                    }
                )
            }
            if showContent && (!showHeader || !collapsed) {
                assistantBlocks
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: collapsed)
        .onChange(of: historyBoundary) { _ in
            if currentReplyExpandedOverride == nil {
                localCollapsed = defaultCollapsed
            }
        }
    }

    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(assistantSegments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .parent(let blocks):
                    parentBlocksView(blocks)
                case .subagent(let subagent):
                    let items = pairToolBlocks(subagent.blocks)
                    SubagentRoleWindow(
                        meta: subagent.meta,
                        items: items,
                        running: isLastTurn && isResponding && items.contains {
                            isDisplayItemRunning($0, isLastTurn: true, isResponding: true)
                        }
                    ) { item in
                        itemView(item, showSubagentTags: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $openActivityGroup) { group in
            ActivityDetailSheet(group: group) { item in
                itemView(item)
            }
        }
    }

    private var assistantSegments: [AssistantContentSegment] {
        splitAssistantContentBySubagent(turn.content)
    }

    @ViewBuilder private func parentBlocksView(_ blocks: [ContentBlock]) -> some View {
        let items = collapseActivityItems(
            pairToolBlocks(blocks),
            isLastTurn: isLastTurn,
            isResponding: isResponding
        )
        ForEach(Array(items.enumerated()), id: \.offset) { _, renderItem in
            switch renderItem {
            case .item(_, let item):
                itemView(item)
            case .activity(let group):
                ActivitySummaryRow(group: group) {
                    openActivityGroup = group
                }
            }
        }
    }

    @ViewBuilder private func itemView(_ item: DisplayItem, showSubagentTags: Bool = true) -> some View {
        switch item {
        case .plain(let block):
            BlockView(block: block, showSubagentTag: showSubagentTags)
        case .tool(let id, let name, let description, let input, let subagent, let result):
            VStack(alignment: .leading, spacing: 4) {
                if showSubagentTags {
                    subagentTag(subagent)
                }
                toolView(
                    id: id, name: name, description: description,
                    input: input, result: result
                )
            }
        case .explorationGroup(let tools):
            ExplorationGroupCard(
                tools: tools,
                running: isLastTurn && isResponding && tools.contains { $0.result == nil }
            )
        }
    }

    /// 工具卡分流（对齐 Web 端 renderToolUseCard）：
    /// AskUserQuestion → 交互卡；Edit/Write/MultiEdit → diff 卡；Bash → 终端卡；其余 → 通用卡。
    @ViewBuilder private func toolView(
        id: String, name: String, description: String?,
        input: [String: JSONValue], result: ToolResultInfo?
    ) -> some View {
        let questions = name == "AskUserQuestion" ? AskUserQuestion.parse(input: input) : []
        if !questions.isEmpty {
            AskUserQuestionCard(
                toolUseId: id,
                questions: questions,
                result: result,
                selection: askSelections[id] ?? AskUserSelectionState(),
                onToggle: { qIdx, optIdx, multi in onAskToggle(id, qIdx, optIdx, multi) },
                onSubmit: { answerText in onAskSubmit(id, answerText) }
            )
        } else if name == "Edit" || name == "Write" || name == "MultiEdit" {
            DiffCard(toolName: name, input: input, result: result)
        } else if name == "Bash" {
            TerminalCard(input: input, result: result, running: result == nil && isLastTurn && isResponding)
        } else {
            ToolUseCard(
                name: name, description: description, input: input,
                result: result, running: result == nil && isLastTurn && isResponding
            )
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

// MARK: - 内容块渲染

private struct BlockView: View {
    let block: ContentBlock
    var showSubagentTag = true

    var body: some View {
        switch block {
        case .text(let text, let subagent):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if showSubagentTag {
                        subagentTag(subagent)
                    }
                    MarkdownText(text: text)
                }
            }
        case .thinking(let thinking, _):
            if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CollapsibleSection(
                    icon: "brain",
                    title: "思考过程",
                    tint: Theme.textSecondary
                ) {
                    Text(thinking)
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        case .toolUse(_, let name, let description, let input, let subagent):
            // 兜底：正常路径已在 TurnView 配对分流，这里处理极端的落单 ToolUse。
            VStack(alignment: .leading, spacing: 4) {
                if showSubagentTag {
                    subagentTag(subagent)
                }
                ToolUseCard(name: name, description: description, input: input, result: nil, running: false)
            }
        case .toolResult(_, let text, let isError, let truncated, _):
            if !text.isEmpty {
                CollapsibleSection(
                    icon: isError ? "xmark.octagon" : "doc.text",
                    title: isError ? "执行出错" : "执行结果",
                    tint: isError ? Theme.danger : Theme.textSecondary
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text.count > 4000 ? String(text.prefix(4000)) + "\n…（已截断）" : text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if truncated {
                        Text("内容过长，已截断")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

/// 原生 Markdown 渲染：块级结构独立布局，内联标记交给 AttributedString。
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case listItem(marker: String, text: String, indent: Int, checked: Bool?)
        case quote(String)
        case code(String, String?)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            inlineText(content, size: 16)
        case .heading(let level, let content):
            inlineText(content, size: headingSize(level), weight: .semibold)
                .padding(.top, level <= 2 ? 3 : 1)
        case .listItem(let marker, let content, let indent, let checked):
            HStack(alignment: .top, spacing: 7) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(checked == true ? .green : Theme.brand)
                    .padding(.top, 2)
                inlineText(content, size: 16)
            }
            .padding(.leading, CGFloat(indent * 14))
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.brand)
                    .frame(width: 3)
                inlineText(content, size: 15, color: Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
        case .code(let content, let language):
            VStack(alignment: .leading, spacing: 2) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        case .table(let headers, let rows):
            markdownTable(headers: headers, rows: rows)
        case .divider:
            Divider().overlay(Theme.border).padding(.vertical, 3)
        }
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(normalizedRow(row, count: headers.count), header: false)
                        .background(index.isMultiple(of: 2) ? Theme.surface : Theme.background.opacity(0.45))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(attributed(cell))
                    .font(.system(size: header ? 13 : 12, weight: header ? .semibold : .regular))
                    .foregroundColor(header ? Theme.textPrimary : Theme.textSecondary)
                    .tint(Theme.brand)
                    .textSelection(.enabled)
                    .frame(minWidth: 110, maxWidth: 190, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(header ? Theme.brand.opacity(0.09) : Color.clear)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    private func normalizedRow(_ row: [String], count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private func inlineText(
        _ content: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = Theme.textPrimary
    ) -> some View {
        Text(attributed(content))
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
            .tint(Theme.brand)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 19
        case 3: return 17
        default: return 16
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var language: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            paragraph.removeAll()
        }
        func flushCode() {
            result.append(.code(code.joined(separator: "\n").trimmingCharacters(in: .newlines), language))
            code.removeAll()
            fence = nil
            language = nil
        }

        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence {
                if trimmed.hasPrefix(fence) { flushCode() } else { code.append(rawLine) }
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = suffix.isEmpty ? nil : suffix
                lineIndex += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }
            if lineIndex + 1 < lines.count,
               let headers = tableCells(rawLine),
               isTableSeparator(lines[lineIndex + 1], columnCount: headers.count) {
                flushParagraph()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count, let row = tableCells(lines[lineIndex]), !row.isEmpty {
                    rows.append(row)
                    lineIndex += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                flushParagraph()
                result.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                lineIndex += 1
                continue
            }
            let rule = trimmed.replacingOccurrences(of: " ", with: "")
            if ["---", "***", "___"].contains(rule) {
                flushParagraph()
                result.append(.divider)
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                lineIndex += 1
                continue
            }
            if let item = listItem(rawLine) {
                flushParagraph()
                result.append(item)
                lineIndex += 1
                continue
            }
            paragraph.append(rawLine)
            lineIndex += 1
        }
        if fence != nil { flushCode() } else { flushParagraph() }
        return result
    }

    private func tableCells(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == columnCount else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.replacingOccurrences(of: ":", with: "")
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private func listItem(_ rawLine: String) -> Block? {
        let leading = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let indent = leading / 2
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        var marker: String?
        var content: String?
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            marker = "•"
            content = String(trimmed.dropFirst(2))
        }
        if marker == nil, let end = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let digits = trimmed[..<end]
            let after = trimmed.index(after: end)
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), after < trimmed.endIndex, trimmed[after] == " " {
                marker = String(trimmed[...end])
                content = String(trimmed[trimmed.index(after: after)...])
            }
        }
        guard let marker, var content else { return nil }
        var checked: Bool?
        if content.lowercased().hasPrefix("[x] ") {
            checked = true
            content = String(content.dropFirst(4))
        } else if content.hasPrefix("[ ] ") {
            checked = false
            content = String(content.dropFirst(4))
        }
        return .listItem(marker: marker, text: content, indent: indent, checked: checked)
    }

    private func attributed(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

/// 工具名 → 中文标签；未识别的工具显示原名（对齐 Web 端 toolDisplayName）。
private func toolLabel(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("todo") { return "更新待办" }
    if lower.contains("websearch") { return "网页搜索" }
    if lower.contains("webfetch") || lower.contains("fetch") { return "网页获取" }
    if lower.contains("notebook") { return "编辑笔记本" }
    if lower.hasPrefix("multiedit") || lower.hasPrefix("edit") { return "编辑文件" }
    if lower.hasPrefix("write") { return "写入文件" }
    if lower.hasPrefix("read") { return "读取文件" }
    if lower.hasPrefix("grep") { return "搜索内容" }
    if lower.hasPrefix("glob") { return "查找文件" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "执行命令" }
    if lower.hasPrefix("task") || lower.contains("agent") { return "子任务" }
    return name
}

/// 连续只读探索操作的紧凑进度卡。默认折叠，避免探索阶段淹没对话。
private struct ExplorationGroupCard: View {
    let tools: [ExplorationToolItem]
    let running: Bool

    @State private var expanded = false

    private var completedCount: Int { tools.filter { $0.result != nil }.count }
    private var failedCount: Int { tools.filter { $0.result?.isError == true }.count }
    private var progress: Double {
        guard !tools.isEmpty else { return 0 }
        return Double(completedCount) / Double(tools.count)
    }
    private var tint: Color {
        if failedCount > 0 { return Theme.danger }
        if running { return Theme.brand }
        return chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.11))
                        if running {
                            ProgressView()
                                .controlSize(.small)
                                .tint(tint)
                        } else {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(tint)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("探索上下文")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Spacer(minLength: 8)
                            Text("\(completedCount)/\(tools.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(tint)
                        }
                        Text(activitySummary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        ProgressView(value: progress)
                            .tint(tint)
                    }

                    if failedCount > 0 {
                        Text("失败 \(failedCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.danger.opacity(0.10)))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        HStack(spacing: 8) {
                            Image(systemName: toolStatusIcon(tool))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(toolStatusColor(tool))
                                .frame(width: 14)
                            Text(toolLabel(tool.name))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                                .frame(width: 54, alignment: .leading)
                            Text(toolSummary(tool))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(failedCount > 0 ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activitySummary: String {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[activityLabel(tool.name), default: 0] += 1
        }
        return ["读取", "搜索", "网页", "待办"]
            .compactMap { label in counts[label].map { "\(label) \($0)" } }
            .joined(separator: " · ")
    }

    private func activityLabel(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("web") { return "网页" }
        if lower == "todoread" { return "待办" }
        if lower.hasPrefix("read") { return "读取" }
        return "搜索"
    }

    private func toolSummary(_ tool: ExplorationToolItem) -> String {
        for key in ["file_path", "path", "pattern", "query", "url", "file", "filename"] {
            if let value = tool.input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        return tool.description
            ?? tool.input.first.map { "\($0.key): \($0.value.summaryText)" }
            ?? "无参数"
    }

    private func toolStatusIcon(_ tool: ExplorationToolItem) -> String {
        if tool.result?.isError == true { return "xmark.circle.fill" }
        if tool.result != nil { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private func toolStatusColor(_ tool: ExplorationToolItem) -> Color {
        if tool.result?.isError == true { return Theme.danger }
        if tool.result != nil { return chatSuccess }
        return Theme.brand
    }
}

/// 工具调用卡片：图标 + 中文工具名 + 参数摘要 + 可折叠结果区。
/// 三态对齐 Web：运行中（转圈）/ 成功（左侧绿竖线）/ 失败（红弱底 + 红边框）。
private struct ToolUseCard: View {
    let name: String
    let description: String?
    let input: [String: JSONValue]
    var result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var isError: Bool { result?.isError == true }
    private var isSuccess: Bool { result != nil && !isError }
    private var hasBody: Bool { !(result?.text.isEmpty ?? true) }
    private var statusColor: Color {
        if isError { return Theme.danger }
        if running { return Theme.brand }
        if isSuccess { return chatSuccess }
        return Theme.textSecondary
    }
    private var statusText: String {
        if isError { return "失败" }
        if running { return "处理中" }
        if isSuccess { return "完成" }
        return "待执行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, let result, hasBody {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                ToolResultBody(result: result)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(isError ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        Button {
            guard hasBody else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                if running {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(0.12))
                        ProgressView()
                            .controlSize(.small)
                            .tint(statusColor)
                    }
                    .frame(width: 34, height: 34)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(isSuccess ? 0.10 : 0.12))
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                    .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(toolLabel(name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
                if hasBody {
                    ZStack {
                        Circle().fill(Theme.background)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        let lower = name.lowercased()
        if lower.contains("bash") || lower.contains("command") { return "terminal" }
        if lower.contains("edit") || lower.contains("write") { return "pencil" }
        if lower.contains("read") { return "doc.text.magnifyingglass" }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        if lower.contains("task") || lower.contains("agent") { return "person.2" }
        return "wrench.and.screwdriver"
    }

    /// 摘要优先级：description > 常见关键参数 > 第一个参数。
    private var summary: String {
        if let d = description, !d.isEmpty { return d }
        let preferredKeys = ["command", "file_path", "path", "pattern", "query", "prompt", "url", "description"]
        for key in preferredKeys {
            if let value = input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        if let first = input.first {
            return "\(first.key): \(first.value.summaryText)"
        }
        return ""
    }
}

/// 工具结果正文：次级底色代码框 + 4000 字截断。
private struct ToolResultBody: View {
    let result: ToolResultInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(result.isError ? Theme.danger : Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.background.opacity(0.6))
            )
            if result.truncated {
                Text("内容过长，已截断")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

/// 可折叠区块（thinking / tool_result 共用），默认折叠。
private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(tint)
            }
            .buttonStyle(.plain)
            if expanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - 权限审批卡片

private struct PermissionCard: View {
    let escalation: EscalationRequest?
    let legacy: PermissionRequestInfo?
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.background)
                    )
            }
            HStack(spacing: 8) {
                Button { onResolve("approve_once") } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .primary))
                if escalation != nil {
                    Button { onResolve("approve_turn") } label: {
                        Text("本轮均允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                }
                Button { onResolve("deny") } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .destructive))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1.5)
        )
    }

    private var title: String {
        if let esc = escalation { return esc.scopeTitle }
        return "权限请求"
    }

    private var detail: String {
        if let esc = escalation { return esc.reason }
        return legacy?.prompt ?? ""
    }

    private var target: String? {
        escalation?.target ?? legacy?.target
    }
}

// MARK: - 共享语义色（Web 端 --success 同款 #4F7A58）

private let chatSuccess = Color(red: 0.310, green: 0.478, blue: 0.345)

// MARK: - AskUserQuestion 交互卡片（对齐 Web 端 ask-user 卡）

/// 提问卡：头部「? 提问 · header」，body 是题目 + 选项列表 + 确认提交。
/// 未答可交互（单选/多选），已答（配对到 tool_result）转只读并高亮用户选过的项。
private struct AskUserQuestionCard: View {
    let toolUseId: String
    let questions: [AskUserQuestion]
    let result: ToolResultInfo?
    let selection: AskUserSelectionState
    let onToggle: (Int, Int, Bool) -> Void
    let onSubmit: (String) -> Void

    @State private var expanded = true

    private var isAnswered: Bool { result != nil }
    /// 已答时按行拆答案：每道题一行，行内 ", " 分隔多选 label（对齐 Web 的解析）。
    private var answerLines: [String] {
        guard let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }
    private var headerLabel: String? {
        questions.first(where: { !($0.header ?? "").isEmpty })?.header
    }
    private var allAnswered: Bool {
        (0..<questions.count).allSatisfy { !(selection.selected[$0] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                        questionGroup(qIdx: qIdx, question: question)
                    }
                    if !isAnswered {
                        submitRow
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isAnswered ? chatSuccess.opacity(0.55) : Theme.brand.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { expanded = !isAnswered }
        .onChange(of: isAnswered) { answered in
            // 回答送达后自动折叠（对齐 Web 已答默认折叠）。
            if answered { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var headerView: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAnswered ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isAnswered ? chatSuccess : Theme.brand)
                    .frame(width: 22)
                Text("提问")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let headerLabel {
                    Text(headerLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                if isAnswered {
                    Text(answerLines.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(chatSuccess)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func questionGroup(qIdx: Int, question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.question.isEmpty {
                Text(question.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optIdx, option in
                    optionRow(qIdx: qIdx, optIdx: optIdx, option: option, multiSelect: question.multiSelect)
                }
            }
        }
    }

    @ViewBuilder private func optionRow(
        qIdx: Int, optIdx: Int, option: AskUserQuestion.Option, multiSelect: Bool
    ) -> some View {
        let chosen: Bool = {
            if isAnswered {
                // 只读态：答案第 qIdx 行（缺行回落第一行），按 "," 拆出已选 label。
                let line = qIdx < answerLines.count ? answerLines[qIdx] : (answerLines.first ?? "")
                return line.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(option.label)
            }
            return (selection.selected[qIdx] ?? []).contains(optIdx)
        }()

        Button {
            guard !isAnswered, !selection.submitted else { return }
            onToggle(qIdx, optIdx, multiSelect)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                indicator(chosen: chosen, multiSelect: multiSelect)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(optionFill(chosen: chosen))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(optionBorder(chosen: chosen), lineWidth: chosen ? 1.5 : 1)
            )
            .opacity(isAnswered && !chosen ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || selection.submitted)
    }

    private func optionFill(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess.opacity(0.08) : Theme.surface
        }
        return chosen ? Theme.brand.opacity(0.16) : Theme.surface
    }

    private func optionBorder(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess : Theme.border
        }
        return chosen ? Theme.brand : Theme.border
    }

    /// 单选圆形 / 多选圆角方形 indicator，选中实底白点/白勾（对齐 Web）。
    @ViewBuilder private func indicator(chosen: Bool, multiSelect: Bool) -> some View {
        let tint = isAnswered ? chatSuccess : Theme.brand
        ZStack {
            if multiSelect {
                RoundedRectangle(cornerRadius: 3)
                    .fill(chosen ? tint : Color.clear)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
            } else {
                Circle().fill(chosen ? tint : Color.clear)
                Circle().stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button {
                guard allAnswered, !selection.submitted else { return }
                var lines: [String] = []
                for (qIdx, question) in questions.enumerated() {
                    let chosen = (selection.selected[qIdx] ?? []).sorted()
                    lines.append(chosen.map { question.options[$0].label }.joined(separator: ", "))
                }
                onSubmit(lines.joined(separator: "\n"))
            } label: {
                Text(selection.submitted ? "已提交…" : "确认提交")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((allAnswered && !selection.submitted) ? Theme.brand : Theme.brand.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!allAnswered || selection.submitted)
        }
    }
}

// MARK: - Diff 卡片（Edit / Write / MultiEdit，对齐 Web 端 inline-diff）

private struct DiffCard: View {
    let toolName: String
    let input: [String: JSONValue]
    let result: ToolResultInfo?

    @State private var expanded = false
    @State private var initialized = false

    private var path: String {
        input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
    }
    private var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    private var isWrite: Bool { toolName == "Write" || toolName == "MultiEdit" }
    private var oldText: String { input["old_string"]?.stringValue ?? "" }
    private var newText: String {
        input["new_string"]?.stringValue ?? input["content"]?.stringValue ?? ""
    }

    private var statusText: String {
        guard let result else { return "执行中" }
        if result.isError {
            let text = result.text
            return (text.contains("haven't granted") || text.contains("permission")) ? "等待授权" : "失败"
        }
        return "已修改"
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !isWrite && !oldText.isEmpty {
                        diffColumn(label: "旧", text: oldText, prefix: "- ", tint: Theme.danger)
                    }
                    if !newText.isEmpty {
                        diffColumn(label: isWrite ? "" : "新", text: newText, prefix: "+ ", tint: chatSuccess)
                    }
                    if let result, result.isError, !result.text.isEmpty {
                        Text(result.text.count > 600 ? String(result.text.prefix(600)) + "…" : result.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.danger)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            // 默认展开态对齐 Web：执行中展开，已完成折叠。只在首次出现时定初值。
            if !initialized {
                expanded = result == nil
                initialized = true
            }
        }
        .onChange(of: result != nil) { hasResult in
            // 结果到达后自动收起（对齐 Android / Web 行为；手动点开不受影响）。
            if hasResult { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 22)
                Text(fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func diffColumn(label: String, text: String, prefix: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(prefix + (text.count > 2000 ? String(text.prefix(2000)) + "\n…（已截断）" : text))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(tint)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
        }
    }
}

// MARK: - 终端卡片（Bash，对齐 Web 端 inline-terminal）

private struct TerminalCard: View {
    let input: [String: JSONValue]
    let result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var command: String {
        input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? ""
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }
    // 终端卡固定深色，亮暗主题一致（对齐 Web）。
    private let termBg = Color(red: 0.118, green: 0.118, blue: 0.118)
    private let termText = Color(red: 0.85, green: 0.85, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text("$ " + command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(termText)
                            .textSelection(.enabled)
                    }
                    if let result, !result.text.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(result.isError ? Color(red: 0.95, green: 0.55, blue: 0.5) : termText.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(termBg))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text("$ " + (command.count > 80 ? String(command.prefix(77)) + "…" : command))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(termText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(termText.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办进度条（TodoWrite，对齐 Web 端 todo-progress）

/// 输入栏上方的悬浮进度条：环形进度 + N/M + 当前任务，点击展开任务列表。
struct TodoProgressBar: View {
    let todos: [TodoItem]

    @State private var expanded = false

    private var completed: Int { todos.filter { $0.status == "completed" }.count }
    /// 1-indexed「正在干第 N 个」：completed+1 封顶（对齐 Web currentStep）。
    private var currentStep: Int { min(completed + 1, todos.count) }
    /// 右侧当前步骤描述：优先取首个 in_progress 的 activeForm / content；
    /// 没有进行中项时（模型已标完上一步、还没标下一步 in_progress，此时 N/M 靠
    /// completed+1 仍显示「正在干第 N 个」），回退到首个 pending 任务的描述；
    /// 都没有再兜底「准备中…」——保证右侧空白区始终有内容（对齐 Web fallback）。
    private var activeTask: String {
        if let active = todos.first(where: { $0.status == "in_progress" }) {
            let label = (active.activeForm?.isEmpty == false) ? active.activeForm! : active.content
            if !label.isEmpty { return label }
        }
        if let pending = todos.first(where: { $0.status == "pending" }) {
            let label = (pending.activeForm?.isEmpty == false) ? pending.activeForm! : pending.content
            if !label.isEmpty { return label }
        }
        return "准备中…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    progressRing
                    Text("\(currentStep)/\(todos.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.brand)
                    Text(activeTask)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        todoRow(todo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Theme.border, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(currentStep) / CGFloat(max(todos.count, 1)))
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch todo.status {
                case "completed":
                    Text("✓").foregroundColor(chatSuccess)
                case "in_progress":
                    Text("›").foregroundColor(Theme.brand)
                default:
                    Text("○").foregroundColor(Theme.textSecondary)
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .frame(width: 14)
            Text(todo.content)
                .font(.system(size: 12))
                .foregroundColor(todo.status == "in_progress" ? Theme.textPrimary : Theme.textSecondary)
                .strikethrough(todo.status == "completed", color: Theme.textSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct QueueBar: View {
    @ObservedObject var store: ChatStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 12, weight: .semibold))
                    Text("已排队 \(store.queuedMessages.count) 条消息")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(store.queuedMessages.enumerated()), id: \.offset) { index, text in
                        QueueItemRow(
                            index: index,
                            text: text,
                            onPromote: { store.promoteQueued(index: index) },
                            onDelete: { store.deleteQueued(index: index) }
                        )
                    }
                    HStack {
                        Spacer()
                        Button {
                            store.clearQueued()
                        } label: {
                            Label("全部清空", systemImage: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.16), value: expanded)
    }
}

private struct QueueItemRow: View {
    let index: Int
    let text: String
    let onPromote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.brand)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: onPromote) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("立即发送")
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.danger)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.background.opacity(0.55))
        )
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(kind == .primary ? .white : (kind == .destructive ? Theme.danger : Theme.textPrimary))
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(kind == .primary ? Theme.brand : Theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(kind == .primary ? Color.clear : Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
