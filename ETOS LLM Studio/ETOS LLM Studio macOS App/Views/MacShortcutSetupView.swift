import ETOSCore
import SwiftUI

struct MacShortcutSetupView: View {
    let isActive: Bool
    @ObservedObject var model: MacShortcutToolsModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.openURL) private var openURL
    @State private var visible = false
    private var active: Bool { isActive && visible && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "shortcut-setup", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 快捷指令导入使用说明", comment: ""), documentID: "shortcut-tools", isActive: isActive && !model.isSuspended)
                TextField(NSLocalizedString("导入快捷指令名称", comment: ""), text: $configuration.shortcutOfficialImportShortcutName)
                Button(NSLocalizedString("下载官方导入快捷指令", comment: "")) {
                    if let url = URL(string: ShortcutToolManager.officialImportShortcutShareURLString) { openURL(url) }
                }
                Button(NSLocalizedString("检测并运行导入快捷指令", comment: "")) {
                    let name = configuration.shortcutOfficialImportShortcutName, token = model.epoch
                    Task {
                        guard active else { return }
                        do { try await model.launchOfficial(name: name, expectedEpoch: token) }
                        catch is CancellationError { }
                        catch { if token == model.epoch { model.error = error.localizedDescription } }
                    }
                }
                if let status = model.officialStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(NSLocalizedString("官方导入快捷指令", comment: "")) }
            footer: {
                Text(String(format: NSLocalizedString("默认名称：%@（可按你的快捷指令名称修改）", comment: ""), ShortcutToolManager.officialImportShortcutDefaultName))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField(NSLocalizedString("桥接快捷指令名称", comment: ""), text: $configuration.shortcutBridgeShortcutName)
            } footer: {
                Text(NSLocalizedString("快捷指令名称自动保存；导出后返回导入页读取清单。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("导入与执行设置", comment: ""))
        .disabled(!active || !model.canWrite)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-shortcut-setup-\(model.epoch)"), title: NSLocalizedString("导入与执行设置", comment: ""),
            documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcuts")], isActive: active && model.canWrite,
            settings: [
                .string("official_import_name", label: NSLocalizedString("导入快捷指令名称", comment: ""),
                        get: { configuration.shortcutOfficialImportShortcutName }, set: { configuration.shortcutOfficialImportShortcutName = $0 }),
                .string("bridge_name", label: NSLocalizedString("桥接快捷指令名称", comment: ""),
                        get: { configuration.shortcutBridgeShortcutName }, set: { configuration.shortcutBridgeShortcutName = $0 }),
                .readOnly("manual_launch_required", label: NSLocalizedString("官方导入快捷指令", comment: ""), value: { .bool(true) })
            ]
        )
    }
}
