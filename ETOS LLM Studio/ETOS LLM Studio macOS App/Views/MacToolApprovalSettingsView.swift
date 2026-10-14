import ETOSCore
import SwiftUI

struct MacToolApprovalSettingsView: View {
    let isActive: Bool
    @ObservedObject var model: MacToolApprovalModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var clearing = false
    private var active: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-tool-approval-\(model.epoch)") }
    private var tool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_tool_approval", description: NSLocalizedString("审批自动化", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary([
                "enabled": .dictionary(["type": .string("boolean")]),
                "countdown": .dictionary(["type": .string("integer"), "minimum": .int(1), "maximum": .int(30)])
            ]), "additionalProperties": .bool(false), "minProperties": .int(1)
        ]))
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "tool-approval", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 工具审批使用说明", comment: ""), documentID: "settings-tools", isActive: active)
                Toggle(NSLocalizedString("启用倒计时自动批准", comment: ""), isOn: Binding(get: { model.enabled }, set: { update(.enabled($0)) }))
                Stepper(value: Binding(get: { model.countdown }, set: { update(.countdown($0)) }), in: 1...30) {
                    Text(String(format: NSLocalizedString("倒计时：%ds", comment: ""), model.countdown))
                }.disabled(!model.enabled)
                if model.isWorking || !model.isLoaded { ProgressView(NSLocalizedString("处理中", comment: "")) }
            } footer: {
                Text(NSLocalizedString("强制确认的工具仍需手动批准，修改倒计时会重新开始当前计时。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(String(format: NSLocalizedString("已禁用自动批准工具：%d", comment: ""), model.disabledTools.count))
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(model.disabledTools, id: \.self) { name in Text(name).textSelection(.enabled) }
                Button(NSLocalizedString("清空禁用列表", comment: ""), role: .destructive) { clearing = true }
                    .disabled(model.disabledTools.isEmpty)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("审批自动化", comment: ""))
        .disabled(!active || !model.canWrite)
        .task { await model.start() }
        .confirmationDialog(NSLocalizedString("清空禁用列表", comment: ""), isPresented: $clearing) {
            Button(NSLocalizedString("清空禁用列表", comment: ""), role: .destructive) { update(.clearDisabledTools) }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: { Text(NSLocalizedString("清空后，这些工具会重新使用全局自动批准设置。", comment: "")) }
        .onChange(of: model.epoch) { _, _ in clearing = false; model.error = nil }
        .onChange(of: isActive) { _, value in if !value { clearing = false } }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("审批自动化", comment: ""),
                documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center")],
                tools: [GuidePageTool(definition: tool, access: .proposeChange)]),
            isActive: active && model.canWrite && !clearing,
            snapshot: { GuidePageSnapshot(fields: [
                "enabled": GuideSnapshotField(label: NSLocalizedString("启用倒计时自动批准", comment: ""), value: .bool(model.enabled)),
                "countdown": GuideSnapshotField(label: NSLocalizedString("倒计时自动批准", comment: ""), value: .int(model.countdown)),
                "disabled_count": GuideSnapshotField(label: NSLocalizedString("工具", comment: ""), value: .int(model.disabledTools.count), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["enabled", "countdown"], in: arguments)
                var changes: [GuideSettingMutation] = []
                if let raw = arguments["enabled"] {
                    guard case .bool(let enabled) = raw else { throw GuideError.invalidToolArguments }
                    if enabled != model.enabled { changes.append(GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用倒计时自动批准", comment: ""), oldValue: .bool(model.enabled), newValue: raw)) }
                }
                if let raw = arguments["countdown"] {
                    guard case .int(let count) = raw, (1...30).contains(count) else { throw GuideError.invalidToolArguments }
                    if count != model.countdown { changes.append(GuideSettingMutation(path: "countdown", label: NSLocalizedString("倒计时自动批准", comment: ""), oldValue: .int(model.countdown), newValue: raw)) }
                }
                guard !changes.isEmpty else { throw GuideError.invalidToolArguments }
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                                           summary: NSLocalizedString("审批自动化", comment: ""), mutations: changes, arguments: arguments)
            },
            execute: { proposal in
                guard active, proposal.pageID == pageID else { throw GuideError.pageChanged }
                var enabled: Bool?, countdown: Int?
                for change in proposal.mutations {
                    switch (change.path, change.newValue) {
                    case ("enabled", .bool(let value)):
                        guard change.oldValue == .bool(model.enabled) else { throw GuideError.invalidToolArguments }
                        enabled = value
                    case ("countdown", .int(let value)):
                        guard change.oldValue == .int(model.countdown) else { throw GuideError.invalidToolArguments }
                        countdown = value
                    default: throw GuideError.invalidToolArguments
                    }
                }
                // 同一次确认可以设置两个字段，后台以单个事务提交，避免只保存一半。
                try await model.update(.automation(enabled: enabled, countdown: countdown), expectedEpoch: model.epoch)
                return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
            }
        )
    }

    private func update(_ change: ToolApprovalPreferenceChange) {
        let token = model.epoch
        Task {
            do { try await model.update(change, expectedEpoch: token) }
            catch { if token == model.epoch { model.error = error.localizedDescription } }
        }
    }
}
