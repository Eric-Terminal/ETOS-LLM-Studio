import ETOSCore
import SwiftUI

struct MacLinuxView: View {
    let isActive: Bool
    @ObservedObject var model: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    @State private var tab = 0
    @State private var deleteUserData = false
    @State private var confirmation: Confirmation?
    private enum Confirmation: Equatable { case restart, reset }
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section {
                    MacSettingsIntroCard(id: "linux", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 本地 Linux 使用说明", comment: ""), documentID: "macos-workspace",
                        isActive: isActive && workspace.canManageLocalModels && !model.isSuspended && confirmation == nil)
                    Toggle(NSLocalizedString("启用本地 Linux", comment: ""), isOn: $configuration.localLinuxEnabled)
                        .disabled(!model.canOperate)
                    NavigationLink {
                        MacLinuxTerminalView(isActive: isActive, runtime: model)
                    } label: { Label(NSLocalizedString("打开用户终端", comment: ""), systemImage: "terminal") }
                    .disabled(!configuration.localLinuxEnabled || !model.canOperate)
                    NavigationLink {
                        MacLinuxJobsView(isActive: isActive, runtime: model)
                    } label: { Label(NSLocalizedString("任务与终端", comment: ""), systemImage: "list.bullet.rectangle") }
                    NavigationLink {
                        MacLinuxMountsView(isActive: isActive, runtime: model)
                    } label: { Label(NSLocalizedString("工作区与挂载", comment: ""), systemImage: "externaldrive") }
                    NavigationLink {
                        MacLinuxFilesView(isActive: isActive, runtime: model)
                    } label: { Label(NSLocalizedString("Linux 文件", comment: ""), systemImage: "folder") }
                    .disabled(!configuration.localLinuxEnabled || !model.canOperate)
                    NavigationLink {
                        MacLinuxSettingsView(isActive: isActive, model: model)
                    } label: { Label(NSLocalizedString("配置", comment: ""), systemImage: "slider.horizontal.3") }
                }
                Section(NSLocalizedString("当前活动", comment: "")) {
                    LabeledContent(NSLocalizedString("运行时", comment: ""), value: model.snapshot.phase.displayName)
                    LabeledContent(NSLocalizedString("命令与浏览器任务", comment: ""), value: "\(model.snapshot.activeJobCount)")
                    LabeledContent(NSLocalizedString("终端", comment: ""), value: "\(model.snapshot.activeTerminalCount)")
                    LabeledContent(NSLocalizedString("本地 MCP", comment: ""), value: "\(model.snapshot.activeMCPProcessCount)")
                }
                feedback
            }.formStyle(.grouped)
                .tabItem { Label(NSLocalizedString("运行", comment: ""), systemImage: "terminal") }.tag(0)
            Form {
                Section {
                    LabeledContent(NSLocalizedString("运行时", comment: ""), value: model.snapshot.phase.displayName)
                    if let fraction = model.snapshot.installProgress?.fractionCompleted { ProgressView(value: fraction) }
                    if let version = model.snapshot.seedVersion { LabeledContent(NSLocalizedString("Alpine", comment: ""), value: version) }
                    if let architecture = model.snapshot.capabilities?.guestArchitecture {
                        LabeledContent(NSLocalizedString("架构", comment: ""), value: architecture)
                    }
                    Button(NSLocalizedString("准备本地 Linux", comment: "")) { model.prepare() }
                        .disabled(!model.canOperate || !configuration.localLinuxEnabled || model.snapshot.phase == .ready)
                    if model.isWorking {
                        Button(NSLocalizedString("取消", comment: "")) { model.cancelPreparation() }
                    }
                    Button(NSLocalizedString("重启本地 Linux", comment: "")) { confirmation = .restart }
                        .disabled(!model.canOperate || !configuration.localLinuxEnabled)
                }
                Section(NSLocalizedString("存储", comment: "")) {
                    LabeledContent(NSLocalizedString("本地 Linux", comment: ""), value: model.storageSize)
                    Button(NSLocalizedString("重新统计", comment: "")) { model.refresh() }.disabled(model.isWorking || model.isSuspended)
                    Toggle(NSLocalizedString("同时删除用户数据", comment: ""), isOn: $deleteUserData).disabled(!model.canOperate)
                    Button(NSLocalizedString("重置本地 Linux", comment: ""), role: .destructive) { confirmation = .reset }
                        .disabled(!model.canOperate || !configuration.localLinuxEnabled)
                }
                feedback
            }.formStyle(.grouped)
                .tabItem { Label(NSLocalizedString("系统", comment: ""), systemImage: "cpu") }.tag(1)
        }
        .navigationTitle(NSLocalizedString("本地 Linux", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels)
        .onAppear { visible = true; if active { model.observe() } }
        .onDisappear { visible = false; confirmation = nil }
        .onChange(of: active) { _, value in if value { model.observe() } else { confirmation = nil } }
        .onChange(of: model.epoch) { _, _ in confirmation = nil }
        .onChange(of: configuration.localLinuxEnabled) { _, _ in if active { model.refresh() } }
        .onChange(of: configuration.appLanguage) { _, _ in if active { model.refresh() } }
        .confirmationDialog(NSLocalizedString("本地 Linux", comment: ""), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            Button(action == .reset ? NSLocalizedString("删除系统并重新准备", comment: "") : NSLocalizedString("重启本地 Linux", comment: ""), role: .destructive) {
                guard active else { return }
                if action == .reset { model.reset(deleteUserData: deleteUserData) } else { model.restart() }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action == .restart ? NSLocalizedString("Mac Linux 重启确认", comment: "") : deleteUserData
                 ? NSLocalizedString("将同时删除 Home、Shared 与全部工作区。此操作无法撤销。", comment: "")
                 : NSLocalizedString("只删除可重建的系统；Home、Shared 与工作区会保留。运行中的 Linux 会在 App 内停止并重新启动。", comment: ""))
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-\(tab)-\(model.epoch)"), title: NSLocalizedString("本地 Linux", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && model.canOperate && confirmation == nil,
            settings: tab == 0 ? [
                .bool("enabled", label: NSLocalizedString("启用本地 Linux", comment: ""), get: { configuration.localLinuxEnabled }, set: { configuration.localLinuxEnabled = $0 }),
                .readOnly("phase", label: NSLocalizedString("运行时", comment: ""), value: { .string(model.snapshot.phase.rawValue) }),
                .readOnly("jobs_require_navigation", label: NSLocalizedString("任务与终端", comment: ""), value: { .bool(true) }),
                .readOnly("storage_requires_navigation", label: NSLocalizedString("工作区与挂载", comment: ""), value: { .bool(true) }),
                .readOnly("files_require_navigation", label: NSLocalizedString("Linux 文件", comment: ""), value: { .bool(true) }),
                .readOnly("terminal_count", label: NSLocalizedString("终端", comment: ""), value: { .int(model.snapshot.activeTerminalCount) }),
                .readOnly("job_count", label: NSLocalizedString("命令与浏览器任务", comment: ""), value: { .int(model.snapshot.activeJobCount) }),
                .readOnly("mcp_count", label: NSLocalizedString("本地 MCP", comment: ""), value: { .int(model.snapshot.activeMCPProcessCount) })
            ] : [
                .readOnly("phase", label: NSLocalizedString("运行时", comment: ""), value: { .string(model.snapshot.phase.rawValue) }),
                .readOnly("storage", label: NSLocalizedString("存储", comment: ""), value: { .string(model.storageSize) }),
                .readOnly("delete_user_data", label: NSLocalizedString("同时删除用户数据", comment: ""), value: { .bool(deleteUserData) }),
                .readOnly("manual_operations_only", label: NSLocalizedString("系统", comment: ""), value: { .bool(true) })
            ]
        )
    }

    @ViewBuilder private var feedback: some View {
        if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
        if let error = model.error ?? model.snapshot.lastError {
            Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if model.isSuspended, workspace.canManageLocalModels {
            Button(NSLocalizedString("重试", comment: "")) { model.retryResume() }
        }
    }
}
