import ETOSCore
import SwiftUI

@MainActor
struct MacStorageManagementView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacStorageReadModel<MacStorageOverview>()
    @StateObject private var actions = MacStorageActionModel()
    @State private var visible = false
    @State private var confirmation: MacStorageConfirmation?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "storage-management", title: NSLocalizedString("存储管理", comment: ""),
                    details: NSLocalizedString("Mac 存储管理说明", comment: ""), documentID: "storage-management", isActive: active)
                if model.isLoading { ProgressView(NSLocalizedString("正在统计", comment: "")) }
                if let value = model.value { LabeledContent(NSLocalizedString("总使用空间", comment: ""), value: value.total) }
                Button(NSLocalizedString("刷新", comment: ""), action: reload).disabled(model.isLoading || actions.isWorking)
            }
            if let value = model.value {
                Section(NSLocalizedString("存储分类", comment: "")) {
                    NavigationLink { MacStorageDirectoryView(location: value.root, isActive: isActive) }
                        label: { Label(value.root.title, systemImage: "folder") }
                    ForEach(value.categories) { category in
                        NavigationLink { MacStorageDirectoryView(location: category.location, isActive: isActive) } label: {
                            LabeledContent { Text(category.size).foregroundStyle(.secondary) }
                                label: { Label(category.title, systemImage: category.symbol) }
                        }
                    }
                    NavigationLink { MacStorageDirectoryView(location: value.other, isActive: isActive) }
                        label: { Label(value.other.title, systemImage: "doc") }
                }
                Section {
                    Button(NSLocalizedString("清理孤立数据", comment: "")) {
                        actions.clear(); confirmation = MacStorageConfirmation(mutation: .orphans, detail: value.orphanDescription)
                    }.disabled(value.orphanCount == 0 || actions.isWorking)
                    Text(value.orphanDescription).font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("清理所有缓存", comment: ""), role: .destructive) {
                        actions.clear(); confirmation = MacStorageConfirmation(mutation: .cache,
                            detail: NSLocalizedString("Mac 媒体缓存清理说明", comment: ""))
                    }.disabled(value.cacheBytes == 0 || actions.isWorking)
                    LabeledContent(NSLocalizedString("缓存", comment: ""), value: value.cache).font(.footnote).foregroundStyle(.secondary)
                } header: { Text(NSLocalizedString("清理工具", comment: "")) }
                footer: {
                    Text(NSLocalizedString("孤立数据包括：幽灵会话（消息文件丢失）、孤立音频/图片文件（无会话引用）、无效音频引用（文件已删除）。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink { MacLinuxMountsView(isActive: isActive, runtime: workspace.linux) }
                    label: { Label(NSLocalizedString("工作区与挂载", comment: ""), systemImage: "externaldrive") }
            }
            if let report = actions.report { Text(report).font(.footnote).textSelection(.enabled) }
            if let error = actions.error ?? model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(NSLocalizedString("存储管理", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || actions.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false; model.close(clearContent: false); if !actions.isWorking { confirmation = nil } }
        .onChange(of: active) { _, active in
            if active { reload() }
            else { model.close(clearContent: visible); if !actions.isWorking { confirmation = nil } }
        }
        .onChange(of: configuration.appLanguage) { _, _ in confirmation = nil; actions.clear(); model.close(clearContent: visible); reload() }
        .onChange(of: actions.isWorking) { _, working in if !working { reload() } }
        .sheet(item: $confirmation) { MacStorageConfirmationView(target: $0, actions: actions) }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-\(model.revision)"), title: NSLocalizedString("存储管理", comment: ""),
            documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")], isActive: active && confirmation == nil,
            settings: [
                .readOnly("loading", label: NSLocalizedString("正在统计", comment: ""), value: { .bool(model.isLoading) }),
                .readOnly("total_bytes", label: NSLocalizedString("总使用空间", comment: ""), value: { .int(Int(clamping: model.value?.totalBytes ?? 0)) }),
                .readOnly("cache_bytes", label: NSLocalizedString("缓存", comment: ""), value: { .int(Int(clamping: model.value?.cacheBytes ?? 0)) }),
                .readOnly("orphan_count", label: NSLocalizedString("孤立数据", comment: ""), value: { .int(model.value?.orphanCount ?? 0) }),
                .readOnly("categories", label: NSLocalizedString("存储分类", comment: ""), value: { model.value?.guideCategories ?? .array([]) })
            ])
    }
    private func reload() {
        guard active else { model.close(clearContent: visible); return }
        guard !model.isLoading else { return }
        model.load(workspace: workspace, operation: MacStorageOverview.load)
    }
}

@MainActor
struct MacStorageConfirmationView: View {
    let target: MacStorageConfirmation
    @ObservedObject var actions: MacStorageActionModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            Form {
                Text(target.detail).textSelection(.enabled)
                Text(NSLocalizedString("Mac 存储清理确认说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                if actions.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            }
            .formStyle(.grouped).navigationTitle(target.mutation.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(actions.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.mutation.title, role: .destructive) {
                        guard !submitted, workspace.canManageLocalModels else { return }
                        submitted = true
                        Task { await actions.perform(target.mutation, workspace: workspace); dismiss() }
                    }.disabled(submitted || actions.isWorking || !workspace.canManageLocalModels)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-confirm-\(target.id)"), title: target.mutation.title,
                documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")],
                isActive: workspace.canManageLocalModels && !submitted, settings: [
                    .readOnly("operation", label: NSLocalizedString("清理工具", comment: ""), value: { .string(target.mutation.kind) }),
                    .readOnly("selected_count", label: NSLocalizedString("文件", comment: ""), value: { .int(target.mutation.count) })
                ])
        }
        .modifier(MacGuideInspector()).frame(minWidth: 520, minHeight: 320)
        .interactiveDismissDisabled(actions.isWorking)
    }
}
