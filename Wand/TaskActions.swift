import SwiftUI

/// Navigation facts only. Drafts, authorization and acceptance stay with their existing owners.
struct WandTaskActionSnapshot: Decodable {
    let items: [WandTaskAction]
    let incompleteSources: Int
}

struct WandTaskAction: Decodable, Identifiable {
    struct Source: Decodable {
        let sessionId: String?
        let requestId: String?
        let toolId: String?
        let runId: String?
    }
    let key: String
    let taskId: String
    let identifier: String
    let title: String
    let workspaceId: String?
    let kind: String
    let reason: String
    let source: Source
    var id: String { key }
    var label: String {
        switch kind {
        case "permission": return "待授权"
        case "question": return "待回答"
        case "plan": return "待批准计划"
        case "reply": return "待回复负责人"
        case "review": return "等待你验收"
        case "blocker": return "验收缺口"
        default: return "待核对"
        }
    }
    var actionLabel: String {
        switch kind {
        case "permission": return "查看授权请求"
        case "question": return "定位待答问题"
        case "plan", "reply": return "在 Web 查看指定运行"
        case "review": return "查看交付与验收"
        case "blocker": return "核对交付缺口"
        default: return "查看任务"
        }
    }
}

extension WandAPI {
    func listBoardTaskActions(workspaceId: String) async throws -> WandTaskActionSnapshot {
        let query = workspaceId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await request(WandTaskActionSnapshot.self, method: "GET",
            path: "/api/wand-task-actions" + (workspaceId.isEmpty ? "" : "?workspaceId=\(query)"))
    }
}

struct WandTaskActionsView: View {
    let api: WandAPI
    let workspaceId: String
    let onOpenSession: (String) -> Void
    let onOpenAcceptance: (String) -> Void
    @State private var snapshot: WandTaskActionSnapshot?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var tab = "handle"
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ticker = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    private var items: [WandTaskAction] { snapshot?.items ?? [] }
    private var handle: [WandTaskAction] { items.filter { $0.kind != "review" && $0.kind != "blocker" } }
    private var review: [WandTaskAction] { items.filter { $0.kind == "review" } }
    private var blockers: [WandTaskAction] { items.filter { $0.kind == "blocker" } }
    private var incomplete: Bool { errorMessage != nil || (snapshot?.incompleteSources ?? 0) > 0 }
    private func count(_ value: Int) -> String { snapshot == nil ? "—" : incomplete ? "\(value) · 未确认" : "\(value)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("先看看需要你做什么").font(.headline)
                    Text(snapshot == nil ? "正在读取授权、待答与验收事实" : "\(incomplete ? "已发现 " : "")\(handle.count) 项处理请求 · \(review.count) 项待验收\(incomplete ? " · 数量未确认" : "")")
                        .font(.caption).foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Text("\(workspaceId.isEmpty ? "所有工作区" : "当前工作区") · 含子任务").font(.caption).foregroundColor(Theme.textSecondary)
            }
            Picker("行动分流", selection: $tab) {
                Text("等我处理 \(count(handle.count))").tag("handle")
                Text("待我验收 \(count(review.count))").tag("review")
            }.pickerStyle(.segmented).frame(maxWidth: 420).labelsHidden()
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot == nil ? "行动读取失败，不代表没有待办" : "行动刷新失败 · 以下为上次快照，数量未确认").foregroundColor(Theme.danger)
                    Text(errorMessage).font(.caption).foregroundColor(Theme.textSecondary)
                    Button("重新读取") { Task { await reload() } }.disabled(loading)
                }
            }
            if (snapshot?.incompleteSources ?? 0) > 0 {
                HStack {
                    Text("部分运行来源暂时无法确认，数量可能不完整；已知事项仍可回原入口核对。")
                        .font(.caption).foregroundColor(Theme.warning)
                    Button("重新读取") { Task { await reload() } }.disabled(loading)
                }
            }
            if snapshot == nil && (loading || errorMessage == nil) {
                HStack { ProgressView().controlSize(.small); Text("正在读取行动事实…").foregroundColor(Theme.textSecondary) }
            } else if snapshot != nil {
                VStack(alignment: .leading, spacing: 12) {
                    rows(tab == "handle" ? handle : review)
                    if tab == "handle", !blockers.isEmpty {
                        Divider()
                        Text("阻塞记录 \(blockers.count) · 先核对归属，不等同于在等你操作").font(.subheadline.weight(.semibold))
                        rows(blockers)
                    }
                }
                .id(tab)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .opacity.animation(Theme.Motion.feedback)))
                .wandMotion(value: tab, layout: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .accessibilityElement(children: .contain).accessibilityLabel("我的行动")
        .task(id: workspaceId) { generation += 1; loading = false; snapshot = nil; errorMessage = nil; expanded.removeAll(); await reload() }
        .onReceive(ticker) { _ in if !loading { Task { await reload() } } }
        .onChange(of: tab) { _ in expanded.removeAll() }
        .onExitCommand { expanded.removeAll() }
    }

    @ViewBuilder private func rows(_ values: [WandTaskAction]) -> some View {
        if values.isEmpty {
            Text(incomplete ? "暂未发现可确认的事项，部分来源仍待核对。" : tab == "handle"
                 ? "暂时没有需要你处理的请求；需要授权、回答或批准计划时会出现在这里。"
                 : "暂时没有待验收的任务；打开或已读不会自动验收。")
                .font(.subheadline).foregroundColor(Theme.textSecondary).padding(.vertical, 12)
        } else {
            ForEach(values) { item in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(item.id) }, set: { open in
                    if open { expanded.insert(item.id) } else { expanded.remove(item.id) }
                })) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.reason).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let id = item.source.sessionId {
                            Text("源会话 \(id)\(item.source.requestId.map { " · 请求 \($0)" } ?? "")\(item.source.toolId.map { " · 提问 \($0)" } ?? "")")
                                .font(.caption).foregroundColor(Theme.textSecondary).textSelection(.enabled)
                            Button(item.actionLabel) { onOpenSession(id) }.buttonStyle(WandSecondaryButtonStyle())
                        } else if let runId = item.source.runId {
                            Text("原生端尚不支持团队审批；在 Web 定位这一次运行，仍需登录相应服务器。")
                                .font(.caption).foregroundColor(Theme.textSecondary)
                            if let url = DesktopPageLink.url(base: api.baseURL, parameters: ["view": "teamchat", "run": runId]) {
                                Link(item.actionLabel, destination: url).buttonStyle(WandSecondaryButtonStyle())
                            }
                        } else {
                            Text(item.kind == "blocker" ? "原记录未明确处理人，请先核对归属；不提供自动解除或重新执行。" : "打开只供核对交付证据，不会自动验收。")
                                .font(.caption).foregroundColor(Theme.textSecondary)
                            Button(item.actionLabel) { onOpenAcceptance(item.taskId) }.buttonStyle(WandSecondaryButtonStyle())
                        }
                    }.padding(.vertical, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.identifier) · \(item.label)").font(.caption).foregroundColor(Theme.textSecondary)
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(item.reason).font(.caption).foregroundColor(Theme.textSecondary).lineLimit(2)
                    }.padding(.vertical, 8)
                }
                .wandMotion(value: expanded, layout: true)
                if item.id != values.last?.id { Divider() }
            }
        }
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        generation += 1
        let captured = generation
        loading = true
        do {
            let next = try await api.listBoardTaskActions(workspaceId: workspaceId)
            guard !Task.isCancelled, generation == captured else { return }
            guard next.incompleteSources >= 0 else { throw WandAPI.APIError.server(status: 502, message: "行动事实响应无效。") }
            snapshot = next; errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == captured else { return }
            if case WandAPI.APIError.unauthorized = error { snapshot = nil }
            if case WandAPI.APIError.server(status: 403, message: _) = error { snapshot = nil }
            errorMessage = error.localizedDescription
        }
        if generation == captured { loading = false }
    }
}
