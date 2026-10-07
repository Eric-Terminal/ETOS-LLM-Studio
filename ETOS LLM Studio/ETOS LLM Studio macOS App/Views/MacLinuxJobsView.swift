import ETOSCore
import SwiftUI

struct MacLinuxJobsView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    var sessionID: UUID? = nil
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxJobsModel()
    @StateObject private var actions = MacLinuxJobActionModel()
    @State private var visible = false
    @State private var cancellation: MacLinuxJobCancellation?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !runtime.isSuspended }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-jobs", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 任务使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: isActive && workspace.canManageLocalModels && !runtime.isSuspended && cancellation == nil)
                LabeledContent(NSLocalizedString("范围", comment: ""), value: sessionID == nil
                    ? NSLocalizedString("全部任务", comment: "") : NSLocalizedString("当前会话", comment: ""))
                Button(NSLocalizedString("刷新", comment: "")) { model.reload(reset: true) }.disabled(model.isLoading)
            }
            if let catalog = model.catalog {
                if catalog.groups.isEmpty { Text(NSLocalizedString("还没有本地 Agent 任务。", comment: "")).foregroundStyle(.secondary) }
                ForEach(catalog.groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            NavigationLink {
                                MacLinuxJobDetailView(jobID: row.id, isActive: isActive, runtime: runtime)
                            } label: {
                                VStack(alignment: .leading) {
                                    HStack { Text(row.title).font(.body.monospaced()).lineLimit(2); Spacer(); Text(row.state).font(.caption).foregroundStyle(.secondary) }
                                    Text(row.kind).font(.caption).foregroundStyle(.secondary)
                                    Text(row.createdAt).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                if !row.job.state.isTerminal {
                                    Button(NSLocalizedString("停止任务", comment: ""), role: .destructive) {
                                        cancellation = MacLinuxJobCancellation(action: .job(row.id))
                                    }.disabled(actions.isWorking)
                                }
                            }
                        }
                        if group.hasActiveJobs, let runID = group.runID {
                            Button(NSLocalizedString("停止此 Agent", comment: ""), role: .destructive) {
                                cancellation = MacLinuxJobCancellation(action: .agent(runID))
                            }.disabled(actions.isWorking)
                        }
                    } header: { Text(group.title) }
                }
                if catalog.activeCount > 0 {
                    Section(NSLocalizedString("停止范围", comment: "")) {
                        if let sessionID {
                            Button(NSLocalizedString("停止此会话的全部任务", comment: ""), role: .destructive) {
                                cancellation = MacLinuxJobCancellation(action: .session(sessionID))
                            }
                        }
                        Button(NSLocalizedString("停止全部本地任务", comment: ""), role: .destructive) {
                            cancellation = MacLinuxJobCancellation(action: .all)
                        }
                    }.disabled(actions.isWorking)
                }
                if catalog.hasMore {
                    Section {
                        Button(NSLocalizedString("加载更多历史任务", comment: "")) { model.loadMore() }.disabled(model.isLoading)
                    } footer: { Text(NSLocalizedString("活跃任务始终完整显示；已结束任务按需加载。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if model.isLoading || actions.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = actions.error ?? model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("任务与终端", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || runtime.isSuspended)
        .onAppear { visible = true; open() }.onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); open() }
        .onChange(of: sessionID) { _, _ in close(); open() }
        .onChange(of: configuration.appLanguage) { _, _ in if active { model.reload() } }
        .confirmationDialog(NSLocalizedString("停止任务", comment: ""), isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
        ), titleVisibility: .visible, presenting: cancellation) { target in
            Button(target.action.title, role: .destructive) { if active { actions.execute(target) } }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { cancellation = nil }
        } message: { target in Text(target.action.confirmation) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-jobs-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("任务与终端", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && cancellation == nil,
            settings: [
                .readOnly("session_id", label: NSLocalizedString("会话", comment: ""), value: { .string(sessionID?.uuidString ?? "") }),
                .readOnly("jobs", label: NSLocalizedString("任务", comment: ""), value: { model.catalog?.guideRows ?? .array([]) }),
                .readOnly("active_count", label: NSLocalizedString("运行中", comment: ""), value: { .int(model.catalog?.activeCount ?? 0) }),
                .readOnly("history_count", label: NSLocalizedString("历史", comment: ""), value: { .int(model.catalog?.historyCount ?? 0) }),
                .readOnly("has_more", label: NSLocalizedString("加载更多历史任务", comment: ""), value: { .bool(model.catalog?.hasMore ?? false) }),
                .readOnly("manual_stop_only", label: NSLocalizedString("停止范围", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func open() { if active { model.open(sessionID: sessionID) } }
    private func close(clearContent: Bool = true) { cancellation = nil; model.leave(clearContent: clearContent); actions.invalidate() }
}
