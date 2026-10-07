import ETOSCore
import SwiftUI

struct MacLinuxWorkspacesView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxStorageModel()
    @State private var visible = false
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-workspaces", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 工作区使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed)
                Picker(NSLocalizedString("会话删除后的工作区", comment: ""), selection: $configuration.localLinuxWorkspaceCleanupPolicy) {
                    Text(NSLocalizedString("保留并手动清理", comment: "")).tag("manual")
                    Text(NSLocalizedString("随会话自动删除", comment: "")).tag("automatic")
                }
            } footer: {
                Text(NSLocalizedString("自动删除只作用于以后删除的会话；本地 MCP 的独立工作区仍需手动处理。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
                Button(NSLocalizedString("重新统计", comment: "")) { measure() }.disabled(model.isWorking)
            }
            Section(NSLocalizedString("工作区", comment: "")) {
                if let catalog = model.catalog {
                    if catalog.workspaces.isEmpty { Text(NSLocalizedString("还没有 Linux 工作区。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(catalog.workspaces) { row in
                        NavigationLink {
                            MacLinuxWorkspaceDetailView(workspaceID: row.id, isActive: isActive, runtime: runtime)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.title)
                                Text(row.workspace.guestPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(row.size).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if model.isWorking || model.isLoading { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("工作区", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; model.close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { model.close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in model.close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-workspaces-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("工作区", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && !model.isWorking,
            settings: [
                .string("cleanup_policy", label: NSLocalizedString("会话删除后的工作区", comment: ""), allowedValues: ["manual", "automatic"],
                    get: { configuration.localLinuxWorkspaceCleanupPolicy }, set: { configuration.localLinuxWorkspaceCleanupPolicy = $0 }),
                .readOnly("workspaces", label: NSLocalizedString("工作区", comment: ""), value: { model.catalog?.guideWorkspaces ?? .array([]) }),
                .readOnly("manual_file_operations", label: NSLocalizedString("工作区详情", comment: ""), value: { .bool(true) })
            ])
    }

    private func measure() {
        let lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            _ = try? await model.perform(expectedLease: lease, revision: revision) { services in
                for record in await services.storage.workspaces() {
                    try Task.checkCancellation()
                    _ = try await services.storage.refreshWorkspaceSize(record)
                }
            }
        }
    }
}

struct MacLinuxWorkspaceDetailView: View {
    let workspaceID: UUID
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxStorageModel()
    @State private var visible = false
    @State private var exportURL: URL?
    @State private var deleting: MacLinuxWorkspaceRemoval?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "linux-workspace-detail", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 工作区使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed && deleting == nil)
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
            }
            if let row = model.catalog?.workspaceByID[workspaceID] {
                Section(NSLocalizedString("工作区", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: ""), value: row.title)
                    LabeledContent(NSLocalizedString("Linux 路径", comment: ""), value: row.workspace.guestPath).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("大小", comment: ""), value: row.size)
                    LabeledContent(NSLocalizedString("活动任务", comment: ""), value: "\(row.activeJobCount)")
                    if let id = row.workspace.sessionID { LabeledContent(NSLocalizedString("会话", comment: ""), value: id.uuidString) }
                    if let id = row.workspace.profileID { LabeledContent(NSLocalizedString("配置", comment: ""), value: id.uuidString) }
                }
                Section {
                    Button(NSLocalizedString("重新统计", comment: "")) { act(row.workspace, exporting: false) }
                    Button(NSLocalizedString("准备工作区导出", comment: "")) { act(row.workspace, exporting: true) }
                    if let exportURL { ShareLink(item: exportURL) { Label(NSLocalizedString("共享导出文件", comment: ""), systemImage: "square.and.arrow.up") } }
                }.disabled(model.isWorking)
                Section {
                    Button(NSLocalizedString("删除工作区…", comment: ""), role: .destructive) {
                        deleting = MacLinuxWorkspaceRemoval(record: row.workspace, lease: model.lease)
                    }.disabled(model.isWorking)
                }
            }
            if model.isWorking || model.isLoading { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("工作区详情", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: workspaceID) { _, _ in close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .confirmationDialog(NSLocalizedString("删除这个工作区？", comment: ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { target in
            Button(NSLocalizedString("停止相关任务并删除", comment: ""), role: .destructive) { remove(target) }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleting = nil }
        } message: { _ in Text(NSLocalizedString("工作区文件与其中的完整输出将被删除，RootFS、Home、Shared 和外部挂载不受影响。", comment: "")) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-workspace-\(workspaceID)-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("工作区详情", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && deleting == nil && !model.isWorking,
            settings: [
                .readOnly("workspace_id", label: NSLocalizedString("工作区", comment: ""), value: { .string(workspaceID.uuidString) }),
                .readOnly("active_jobs", label: NSLocalizedString("活动任务", comment: ""), value: { .int(model.catalog?.workspaceByID[workspaceID]?.activeJobCount ?? 0) }),
                .readOnly("export_ready", label: NSLocalizedString("共享导出文件", comment: ""), value: { .bool(exportURL != nil) }),
                .readOnly("read_only", label: NSLocalizedString("工作区详情", comment: ""), value: { .bool(true) })
            ])
    }

    private func act(_ expected: LocalAgentWorkspace, exporting: Bool) {
        let lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            do {
                let url: URL? = try await model.perform(expectedLease: lease, revision: revision) { services in
                    let current = try await MacLinuxStorageModel.current(expected, services: services)
                    try Task.checkCancellation()
                    if exporting { return try await services.storage.exportWorkspace(current) }
                    _ = try await services.storage.refreshWorkspaceSize(current)
                    return nil
                }
                if exporting { exportURL = url }
            } catch { }
        }
    }

    private func remove(_ target: MacLinuxWorkspaceRemoval) {
        guard active else { return }
        Task {
            do {
                try await model.perform(expectedLease: target.lease, revision: target.revision) { services in
                    let current = try await MacLinuxStorageModel.current(target.record, services: services)
                    try Task.checkCancellation()
                    try await services.storage.deleteWorkspace(current)
                }
                exportURL = nil; dismiss()
            } catch { }
        }
    }

    private func close(clearContent: Bool = true) { deleting = nil; exportURL = nil; model.close(clearContent: clearContent) }
}

private struct MacLinuxWorkspaceRemoval: Identifiable, Sendable {
    let id = UUID()
    let record: LocalAgentWorkspace
    let lease: UUID
    let revision = LocalLinuxActivityBarrier.shared.revision
}
