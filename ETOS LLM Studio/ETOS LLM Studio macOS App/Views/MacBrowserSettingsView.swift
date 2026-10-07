import ETOSCore
import SwiftUI

struct MacBrowserSettingsView: View {
    @ObservedObject var model: MacBrowserModel
    let lease: UUID
    let isActive: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    private var active: Bool { visible && isActive && model.isLoaded && model.lease == lease && !model.isSuspended }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-browser-settings-\(lease)-\(model.epoch)") }
    private var tool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_browser_profile", description: NSLocalizedString("保留网站登录状态", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
            "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "browser", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 浏览器使用说明", comment: ""), documentID: "browser-agent", isActive: active)
                    Toggle(NSLocalizedString("保留网站登录状态", comment: ""), isOn: Binding(
                        get: { model.profile == .persistentShared }, set: { value in
                            let original = model.profile
                            Task {
                                guard active else { return }
                                do { try await model.saveProfile(value ? .persistentShared : .sessionIsolated, expected: original, expectedLease: lease) }
                                catch { if active { model.error = error.localizedDescription } }
                            }
                        }
                    )).disabled(!model.canEditProfile)
                    if !model.canPersistProfile { Text(NSLocalizedString("临时对话使用临时网站数据，不保存浏览器偏好。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    if model.isSaving { ProgressView(NSLocalizedString("处理中", comment: "")) }
                } footer: {
                    Text(NSLocalizedString("关闭时，新标签页使用当前会话的临时网站数据；切换只影响之后创建的标签页和新的 Agent Run。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped).disabled(!active)
            .navigationTitle(NSLocalizedString("浏览器设置", comment: ""))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("完成", comment: "")) { dismiss() }.disabled(model.isSaving) } }
            .guidePageContext(
                descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("浏览器设置", comment: ""),
                    documents: [GuideDocumentReference(id: "browser-agent", title: "Browser Agent")],
                    tools: model.canPersistProfile ? [GuidePageTool(definition: tool, access: .proposeChange)] : []),
                isActive: active && !model.isSaving,
                snapshot: { GuidePageSnapshot(fields: [
                    "persistent_profile": GuideSnapshotField(label: NSLocalizedString("保留网站登录状态", comment: ""), value: .bool(model.profile == .persistentShared), access: model.canPersistProfile ? .readWrite : .readOnly),
                    "temporary_session": GuideSnapshotField(label: NSLocalizedString("临时对话", comment: ""), value: .bool(!model.canPersistProfile), access: .readOnly),
                    "affects_new_tabs_only": GuideSnapshotField(label: NSLocalizedString("标签页", comment: ""), value: .bool(true), access: .readOnly)
                ]) },
                buildProposal: { call, _ in
                    guard call.toolName == tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                    let arguments = try GuideToolArguments.decode(call.arguments)
                    try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                    guard case .bool(let enabled)? = arguments["enabled"], enabled != (model.profile == .persistentShared) else { throw GuideError.invalidToolArguments }
                    return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                        summary: NSLocalizedString("保留网站登录状态", comment: ""), mutations: [
                            GuideSettingMutation(path: "persistent_profile", label: NSLocalizedString("保留网站登录状态", comment: ""), oldValue: .bool(model.profile == .persistentShared), newValue: .bool(enabled))
                        ], arguments: arguments)
                },
                execute: { proposal in
                    guard active, proposal.pageID == pageID,
                          proposal.mutations.first?.oldValue == .bool(model.profile == .persistentShared),
                          case .bool(let enabled)? = proposal.arguments["enabled"] else { throw GuideError.invalidToolArguments }
                    try await model.saveProfile(enabled ? .persistentShared : .sessionIsolated, expected: model.profile, expectedLease: lease)
                    return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
                }
            )
        }
        .frame(minWidth: 520, minHeight: 300)
        .onAppear { visible = true }.onDisappear { visible = false }
        .interactiveDismissDisabled(model.isSaving)
    }
}
