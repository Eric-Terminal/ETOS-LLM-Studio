// ============================================================================
// GuideShortcutSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 快捷指令向导只管理已导入工具的 ETOS 配置，不会自行运行系统快捷指令。
// ============================================================================

import Foundation

public enum GuideShortcutPreferencesSupport {
    private static let restoreToolName = "restore_shortcut_preferences_after_guide_change"
    private static let allowedKeys: Set<String> = [
        "chat_tools_enabled",
        "official_import_shortcut_name",
        "bridge_shortcut_name"
    ]

    @MainActor
    public static func snapshot(
        manager: ShortcutToolManager,
        appConfig: AppConfigStore,
        permissionCenter: ToolPermissionCenter
    ) -> GuidePageSnapshot {
        let tools = manager.tools.map { tool in
            JSONValue.dictionary([
                "id": .string(tool.id.uuidString),
                "name": .string(tool.name),
                "display_name": .string(tool.displayName),
                "description": .string(tool.effectiveDescription),
                "enabled": .bool(tool.isEnabled),
                "run_mode": .string(tool.runModeHint.rawValue)
            ])
        }
        var fields = editableSnapshotFields(manager: manager, appConfig: appConfig)
        fields["tools"] = GuideSnapshotField(
            label: NSLocalizedString("已导入工具", comment: "快捷指令向导快照字段"),
            value: .array(tools),
            access: .readOnly
        )
        fields["auto_approve_enabled"] = GuideSnapshotField(
            label: NSLocalizedString("倒计时自动批准", comment: "快捷指令向导快照字段"),
            value: .bool(permissionCenter.autoApproveEnabled),
            access: .readOnly
        )
        fields["auto_approve_countdown_seconds"] = GuideSnapshotField(
            label: NSLocalizedString("自动批准倒计时", comment: "快捷指令向导快照字段"),
            value: .int(permissionCenter.autoApproveCountdownSeconds),
            access: .readOnly
        )
        fields["disabled_auto_approve_tool_count"] = GuideSnapshotField(
            label: NSLocalizedString("已禁用自动批准工具数量", comment: "快捷指令向导快照字段"),
            value: .int(permissionCenter.disabledAutoApproveTools.count),
            access: .readOnly
        )
        return GuidePageSnapshot(fields: fields)
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateShortcutPreferences.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
        let labels: [String: String] = [
            "chat_tools_enabled": NSLocalizedString("向模型暴露快捷指令工具", comment: "快捷指令向导修改字段"),
            "official_import_shortcut_name": NSLocalizedString("导入快捷指令名称", comment: "快捷指令向导修改字段"),
            "bridge_shortcut_name": NSLocalizedString("桥接快捷指令名称", comment: "快捷指令向导修改字段")
        ]
        var mutations: [GuideSettingMutation] = []
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
            guard let label = labels[key] else { throw GuideError.invalidToolArguments }
            let normalized: JSONValue
            switch key {
            case "chat_tools_enabled":
                guard case .bool = value else { throw GuideError.invalidToolArguments }
                normalized = value
            default:
                guard case .string(let text) = value,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GuideError.invalidToolArguments
                }
                normalized = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let oldValue = snapshot.fields[key]?.value
            guard oldValue != normalized else { continue }
            mutations.append(GuideSettingMutation(
                path: key,
                label: label,
                oldValue: oldValue,
                newValue: normalized
            ))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("修改快捷指令工具箱设置", comment: "快捷指令向导提案摘要"),
            mutations: mutations,
            arguments: arguments
        )
    }

    @MainActor
    public static func execute(
        _ proposal: GuideActionProposal,
        manager: ShortcutToolManager,
        appConfig: AppConfigStore
    ) throws -> GuideActionExecution {
        guard proposal.toolName == GuideToolCatalog.updateShortcutPreferences.name
                || proposal.toolName == restoreToolName else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: proposal.arguments)
        let previous = currentArguments(manager: manager, appConfig: appConfig, keys: Set(proposal.arguments.keys))
        for (key, value) in proposal.arguments {
            switch (key, value) {
            case ("chat_tools_enabled", .bool(let enabled)):
                manager.setChatToolsEnabled(enabled)
            case ("official_import_shortcut_name", .string(let name)):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw GuideError.invalidToolArguments }
                manager.officialImportShortcutName = trimmed
            case ("bridge_shortcut_name", .string(let name)):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw GuideError.invalidToolArguments }
                appConfig.shortcutBridgeShortcutName = trimmed
            default:
                throw GuideError.invalidToolArguments
            }
        }
        let undo = proposal.toolName == restoreToolName ? nil : GuideActionProposal(
            pageID: proposal.pageID,
            toolCallID: "undo-\(proposal.toolCallID)",
            toolName: restoreToolName,
            summary: NSLocalizedString("撤销快捷指令工具箱设置修改", comment: "快捷指令向导撤销摘要"),
            mutations: [],
            arguments: previous
        )
        return GuideActionExecution(
            message: NSLocalizedString("已更新快捷指令工具箱设置。", comment: "快捷指令向导执行结果"),
            undoProposal: undo
        )
    }

    @MainActor
    private static func editableSnapshotFields(
        manager: ShortcutToolManager,
        appConfig: AppConfigStore
    ) -> [String: GuideSnapshotField] {
        [
            "chat_tools_enabled": GuideSnapshotField(
                label: NSLocalizedString("向模型暴露快捷指令工具", comment: "快捷指令向导快照字段"),
                value: .bool(manager.chatToolsEnabled)
            ),
            "official_import_shortcut_name": GuideSnapshotField(
                label: NSLocalizedString("导入快捷指令名称", comment: "快捷指令向导快照字段"),
                value: .string(manager.officialImportShortcutName)
            ),
            "bridge_shortcut_name": GuideSnapshotField(
                label: NSLocalizedString("桥接快捷指令名称", comment: "快捷指令向导快照字段"),
                value: .string(appConfig.shortcutBridgeShortcutName)
            )
        ]
    }

    @MainActor
    private static func currentArguments(
        manager: ShortcutToolManager,
        appConfig: AppConfigStore,
        keys: Set<String>
    ) -> [String: JSONValue] {
        let fields = editableSnapshotFields(manager: manager, appConfig: appConfig)
        return keys.reduce(into: [String: JSONValue]()) { result, key in
            result[key] = fields[key]?.value
        }
    }
}

public struct GuideShortcutToolApplication: Sendable {
    public let enabled: Bool
    public let runMode: ShortcutRunModeHint
    public let userDescription: String
    public let execution: GuideActionExecution

    public init(
        enabled: Bool,
        runMode: ShortcutRunModeHint,
        userDescription: String,
        execution: GuideActionExecution
    ) {
        self.enabled = enabled
        self.runMode = runMode
        self.userDescription = userDescription
        self.execution = execution
    }
}

public enum GuideShortcutToolSettingsSupport {
    private static let restoreToolName = "restore_shortcut_tool_after_guide_change"
    private static let allowedKeys: Set<String> = ["enabled", "run_mode", "user_description"]

    public static func snapshot(_ tool: ShortcutToolDefinition) -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "tool_id": GuideSnapshotField(
                label: NSLocalizedString("工具 ID", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.id.uuidString),
                access: .readOnly
            ),
            "shortcut_name": GuideSnapshotField(
                label: NSLocalizedString("快捷指令名称", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.name),
                access: .readOnly
            ),
            "display_name": GuideSnapshotField(
                label: NSLocalizedString("显示名称", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.displayName),
                access: .readOnly
            ),
            "generated_description": GuideSnapshotField(
                label: NSLocalizedString("自动生成描述", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.generatedDescription ?? ""),
                access: .readOnly
            ),
            "enabled": GuideSnapshotField(
                label: NSLocalizedString("启用", comment: "快捷指令工具向导快照字段"),
                value: .bool(tool.isEnabled)
            ),
            "run_mode": GuideSnapshotField(
                label: NSLocalizedString("运行模式", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.runModeHint.rawValue)
            ),
            "user_description": GuideSnapshotField(
                label: NSLocalizedString("自定义描述", comment: "快捷指令工具向导快照字段"),
                value: .string(tool.userDescription ?? "")
            ),
            "metadata": GuideSnapshotField(
                label: NSLocalizedString("导入元数据", comment: "快捷指令工具向导快照字段"),
                value: .dictionary(tool.metadata),
                access: .readOnly
            )
        ])
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        tool: ShortcutToolDefinition
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateShortcutTool.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let resolved = try values(arguments, tool: tool)
        var mutations: [GuideSettingMutation] = []
        if resolved.enabled != tool.isEnabled {
            mutations.append(GuideSettingMutation(
                path: "enabled",
                label: NSLocalizedString("启用", comment: "快捷指令工具向导修改字段"),
                oldValue: .bool(tool.isEnabled),
                newValue: .bool(resolved.enabled)
            ))
        }
        if resolved.runMode != tool.runModeHint {
            mutations.append(GuideSettingMutation(
                path: "run_mode",
                label: NSLocalizedString("运行模式", comment: "快捷指令工具向导修改字段"),
                oldValue: .string(tool.runModeHint.rawValue),
                newValue: .string(resolved.runMode.rawValue)
            ))
        }
        let oldDescription = tool.userDescription ?? ""
        if resolved.userDescription != oldDescription {
            mutations.append(GuideSettingMutation(
                path: "user_description",
                label: NSLocalizedString("自定义描述", comment: "快捷指令工具向导修改字段"),
                oldValue: .string(oldDescription),
                newValue: .string(resolved.userDescription)
            ))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: String(
                format: NSLocalizedString("修改快捷指令工具“%@”", comment: "快捷指令工具向导提案摘要"),
                tool.displayName
            ),
            mutations: mutations,
            arguments: arguments
        )
    }

    public static func apply(
        _ proposal: GuideActionProposal,
        tool: ShortcutToolDefinition
    ) throws -> GuideShortcutToolApplication {
        guard proposal.toolName == GuideToolCatalog.updateShortcutTool.name
                || proposal.toolName == restoreToolName else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        let resolved = try values(proposal.arguments, tool: tool)
        let undo = proposal.toolName == restoreToolName ? nil : GuideActionProposal(
            pageID: proposal.pageID,
            toolCallID: "undo-\(proposal.toolCallID)",
            toolName: restoreToolName,
            summary: NSLocalizedString("撤销快捷指令工具修改", comment: "快捷指令工具向导撤销摘要"),
            mutations: [],
            arguments: [
                "enabled": .bool(tool.isEnabled),
                "run_mode": .string(tool.runModeHint.rawValue),
                "user_description": .string(tool.userDescription ?? "")
            ]
        )
        return GuideShortcutToolApplication(
            enabled: resolved.enabled,
            runMode: resolved.runMode,
            userDescription: resolved.userDescription,
            execution: GuideActionExecution(
                message: String(
                    format: NSLocalizedString("已更新快捷指令工具“%@”。", comment: "快捷指令工具向导执行结果"),
                    tool.displayName
                ),
                undoProposal: undo
            )
        )
    }

    private static func values(
        _ arguments: [String: JSONValue],
        tool: ShortcutToolDefinition
    ) throws -> (enabled: Bool, runMode: ShortcutRunModeHint, userDescription: String) {
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
        let enabled = try GuideToolArguments.optionalBool("enabled", in: arguments) ?? tool.isEnabled
        let runMode: ShortcutRunModeHint
        if let raw = try GuideToolArguments.optionalString("run_mode", in: arguments) {
            guard let resolved = ShortcutRunModeHint(rawValue: raw) else {
                throw GuideError.invalidToolArguments
            }
            runMode = resolved
        } else {
            runMode = tool.runModeHint
        }
        let description = try GuideToolArguments.optionalString("user_description", in: arguments)
            ?? tool.userDescription
            ?? ""
        return (enabled, runMode, description.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
