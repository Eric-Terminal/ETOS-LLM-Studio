import ETOSCore
import SwiftUI

struct MacLinuxRecipesView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxRecipesModel()
    @State private var visible = false
    @State private var confirmation: MacLinuxRecipeConfirmation?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section(NSLocalizedString("推荐下载源", comment: "")) {
                MacSettingsIntroCard(id: "linux-recipes", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 常用环境使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: allowed && confirmation == nil && model.terminal == nil)
                if model.isProbing { ProgressView(NSLocalizedString("正在测试下载源…", comment: "")) }
                if let catalog = model.catalog {
                    Label(catalog.mirrorName, systemImage: "network")
                    Text(catalog.mirrorURL).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(catalog.latency).font(.footnote).foregroundStyle(.secondary)
                }
                Button(NSLocalizedString("重新测速", comment: "")) { confirmation = nil; model.probe() }
                    .disabled(model.isProbing || model.isInstalling || model.isStarting)
                Button(NSLocalizedString("刷新", comment: "")) { confirmation = nil; model.reload() }.disabled(model.isLoading || model.isStarting)
            }
            Section {
                if let catalog = model.catalog {
                    ForEach(catalog.rows) { row in
                        Button { confirm(row, catalogID: catalog.id) } label: {
                            VStack(alignment: .leading) {
                                Text(row.recipe.title)
                                Text(row.recipe.detail).font(.caption).foregroundStyle(.secondary)
                                Text(row.recipe.summaryCommand).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let status = row.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain).disabled(!model.canStart)
                    }
                }
            } footer: {
                Text(NSLocalizedString("ETOS 默认不安装任何开发环境。确认下载源后，点击环境即可复制准确命令或直接执行。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if let job = model.job {
                Section(NSLocalizedString("最近结果", comment: "")) {
                    if model.isInstalling {
                        ProgressView(NSLocalizedString("正在安装", comment: ""))
                        Button(NSLocalizedString("查看安装终端", comment: "")) { model.terminal = MacLinuxRecipeTerminalTarget(id: job.id) }
                    }
                    if let result = model.result {
                        Text(result.state)
                        LabeledContent(NSLocalizedString("退出码", comment: ""), value: result.exitCode)
                        if !result.output.isEmpty { Text(result.output).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    NavigationLink { MacLinuxJobDetailView(jobID: job.id, isActive: isActive, runtime: runtime) }
                        label: { Label(NSLocalizedString("任务详情", comment: ""), systemImage: "doc.text") }
                }
            }
            if model.isLoading || model.isStarting { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("安装常用环境", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in confirmation = nil; model.reload() }
        .onChange(of: model.catalog?.id) { _, _ in confirmation = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active, active { model.reload() } }
        .sheet(item: $model.terminal) { target in
            NavigationStack {
                MacLinuxTerminalView(isActive: active, runtime: runtime, initialJobID: target.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { model.terminal = nil } } }
            }.frame(minWidth: 760, minHeight: 560)
        }
        .confirmationDialog(confirmation?.row.recipe.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { target in
            Button(NSLocalizedString("复制命令", comment: "")) { if active { model.copyCommand(target) } }
            Button(NSLocalizedString("执行此命令", comment: "")) { if active { model.start(target) } }.disabled(!configuration.localLinuxEnabled)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { confirmation = nil }
        } message: { target in Text(target.row.confirmation) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-recipes-\(model.lease)-\(model.catalog?.id.uuidString ?? "empty")-\(runtime.epoch)"), title: NSLocalizedString("安装常用环境", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && confirmation == nil && model.terminal == nil && !model.isStarting && !model.isLoading && !model.isProbing,
            settings: [
                .readOnly("catalog", label: NSLocalizedString("安装常用环境", comment: ""), value: { model.catalog?.guide ?? .null }),
                .readOnly("job_id", label: NSLocalizedString("终端", comment: ""), value: { .string(model.job?.id.uuidString ?? "") }),
                .readOnly("running", label: NSLocalizedString("正在安装", comment: ""), value: { .bool(model.isInstalling) }),
                .readOnly("manual_execution_only", label: NSLocalizedString("执行此命令", comment: ""), value: { .bool(true) })
            ])
    }

    private func confirm(_ row: MacLinuxRecipeRow, catalogID: UUID) {
        guard active, model.canStart else { return }
        confirmation = MacLinuxRecipeConfirmation(row: row, lease: model.lease, catalogID: catalogID, revision: LocalLinuxActivityBarrier.shared.revision)
    }
    private func close(clearContent: Bool = true) { confirmation = nil; model.close(clearContent: clearContent) }
}
