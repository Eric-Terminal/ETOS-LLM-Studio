import ETOSCore
import SwiftUI

@MainActor
struct MacSlashCommandSettingsGuide: ViewModifier {
    @ObservedObject var model: MacSlashCommandsModel
    let isActive: Bool
    @ObservedObject private var configuration = AppConfigStore.shared
    private var pageID: GuidePageID {
        GuidePageID(rawValue: "mac-slash-commands-\(model.epoch)-\(model.revision)-\(configuration.enableSlashCommands)")
    }
    private var listTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_slash_commands", description: NSLocalizedString("自定义快速指令列表", comment: ""),
            parameters: .dictionary(["type": .string("object"), "properties": .dictionary(["commands": GuideSlashCommandSettingsSupport.schema]),
                "required": .array([.string("commands")]), "additionalProperties": .bool(false)]))
    }
    private var enabledTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_slash_commands_enabled", description: NSLocalizedString("启用快速指令", comment: ""),
            parameters: .dictionary(["type": .string("object"), "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
                "required": .array([.string("enabled")]), "additionalProperties": .bool(false)]))
    }

    func body(content: Content) -> some View {
        content.guidePageContext(
            descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("快速指令", comment: ""),
                documents: [GuideDocumentReference(id: "slash-commands", title: "Quick Commands")],
                tools: [GuidePageTool(definition: listTool, access: .proposeChange), GuidePageTool(definition: enabledTool, access: .proposeChange)]),
            isActive: isActive && model.canWrite,
            snapshot: { GuidePageSnapshot(fields: [
                "enabled": GuideSnapshotField(label: NSLocalizedString("启用快速指令", comment: ""), value: .bool(configuration.enableSlashCommands)),
                "custom_commands": GuideSnapshotField(label: NSLocalizedString("自定义快速指令列表", comment: ""), value: model.catalog?.guideCommands ?? .array([])),
                "built_in_commands": GuideSnapshotField(label: NSLocalizedString("内建快速指令", comment: ""), value: model.catalog?.guideBuiltIn ?? .array([]), access: .readOnly),
                "save_mode": GuideSnapshotField(label: NSLocalizedString("编辑方式", comment: ""), value: .string("immediate_after_native_confirmation"), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard model.canWrite, let catalog = model.catalog else { throw GuideError.pageChanged }
                let expectedPage = pageID, listName = listTool.name, enabledName = enabledTool.name, enabled = configuration.enableSlashCommands
                let proposal = try await Task.detached(priority: .userInitiated) {
                    let arguments = try GuideToolArguments.decode(call.arguments)
                    let label: String, oldValue: JSONValue, newValue: JSONValue, key: String
                    if call.toolName == listName {
                        try GuideToolArguments.requireOnlyKeys(["commands"], in: arguments)
                        guard let value = arguments["commands"] else { throw GuideError.invalidToolArguments }
                        let commands = try MacSlashCommandCatalog.guideReplacement(value, original: catalog.snapshot)
                        label = NSLocalizedString("自定义快速指令列表", comment: ""); oldValue = catalog.guideCommands
                        newValue = GuideSlashCommandSettingsSupport.value(commands); key = "commands"
                    } else if call.toolName == enabledName {
                        try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                        guard case .bool(let value)? = arguments["enabled"] else { throw GuideError.invalidToolArguments }
                        label = NSLocalizedString("启用快速指令", comment: ""); oldValue = .bool(enabled); newValue = .bool(value); key = "enabled"
                    } else { throw GuideError.unsupportedTool(call.toolName) }
                    return GuideActionProposal(pageID: expectedPage, toolCallID: call.id, toolName: call.toolName,
                        summary: label, mutations: [GuideSettingMutation(path: key == "commands" ? "custom_commands" : key,
                            label: label, oldValue: oldValue, newValue: newValue)],
                        arguments: [key: newValue])
                }.value
                guard isActive, model.canWrite, pageID == expectedPage else { throw GuideError.pageChanged }
                return proposal
            },
            execute: { proposal in
                guard isActive, model.canWrite, proposal.pageID == pageID, let original = model.catalog?.snapshot else { throw GuideError.pageChanged }
                if proposal.toolName == enabledTool.name {
                    guard case .bool(let value)? = proposal.arguments["enabled"] else { throw GuideError.invalidToolArguments }
                    configuration.enableSlashCommands = value
                } else if proposal.toolName == listTool.name {
                    guard let value = proposal.arguments["commands"] else { throw GuideError.invalidToolArguments }
                    let expectedEpoch = model.epoch, expectedPage = pageID
                    let commands = try await Task.detached { try MacSlashCommandCatalog.guideReplacement(value, original: original) }.value
                    guard isActive, pageID == expectedPage else { throw GuideError.pageChanged }
                    try await model.replace(commands, original: original, expectedEpoch: expectedEpoch)
                } else { throw GuideError.unsupportedTool(proposal.toolName) }
                return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
            })
    }
}
