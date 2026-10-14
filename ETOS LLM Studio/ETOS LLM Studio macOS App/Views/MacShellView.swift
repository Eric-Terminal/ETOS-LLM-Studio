import ETOSCore
import SwiftUI

/// Mac 直接使用系统 Shell，不向用户暴露移动端的内核安装和 RootFS 维护。
struct MacShellView: View {
    let isActive: Bool
    @ObservedObject var model: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var title: String { NSLocalizedString("mac.shell.title", value: "Local Shell", comment: "Mac 原生 Shell") }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "native-shell", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("mac.shell.help", value: "Run commands and terminals directly on macOS using the system Shell and file permissions. No Linux system needs to be installed. Environment variables, command rules and output settings apply to new tasks. Interactive terminal input is manual.", comment: "本机 Shell 教程"),
                    documentID: "macos-workspace", isActive: active)
                Toggle(NSLocalizedString("mac.shell.enabled", value: "Enable Local Shell", comment: "本机 Shell 开关"), isOn: $configuration.localLinuxEnabled)
                    .disabled(!model.canOperate)
                NavigationLink { MacLinuxTerminalView(isActive: isActive, runtime: model) }
                    label: { Label(NSLocalizedString("打开用户终端", comment: ""), systemImage: "terminal") }
                    .disabled(!configuration.localLinuxEnabled || !model.canOperate)
                NavigationLink { MacLinuxJobsView(isActive: isActive, runtime: model) }
                    label: { Label(NSLocalizedString("任务与终端", comment: ""), systemImage: "list.bullet.rectangle") }
                NavigationLink { MacLinuxSettingsView(isActive: isActive, model: model) }
                    label: { Label(NSLocalizedString("配置", comment: ""), systemImage: "slider.horizontal.3") }
            }
            Section(NSLocalizedString("当前活动", comment: "")) {
                LabeledContent(NSLocalizedString("命令与浏览器任务", comment: ""), value: "\(model.snapshot.activeJobCount)")
                LabeledContent(NSLocalizedString("终端", comment: ""), value: "\(model.snapshot.activeTerminalCount)")
                if model.isWorking { ProgressView() }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .disabled(!isActive || !workspace.canManageLocalModels)
        .onAppear { visible = true; if active { model.observe() } }
        .onDisappear { visible = false }
        .onChange(of: active) { _, value in if value { model.observe() } }
        .onChange(of: configuration.localLinuxEnabled) { _, _ in if active { model.refresh() } }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-shell-\(model.epoch)"), title: title,
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: active,
            settings: [
                .bool("enabled", label: NSLocalizedString("mac.shell.enabled", value: "Enable Local Shell", comment: ""),
                    get: { configuration.localLinuxEnabled }, set: { configuration.localLinuxEnabled = $0 }),
                .readOnly("native_execution", label: title, value: { .bool(true) }),
                .readOnly("active_jobs", label: NSLocalizedString("当前活动", comment: ""), value: { .int(model.snapshot.activeJobCount) })
            ])
    }
}
