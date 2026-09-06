// ============================================================================
// GuideDeclarativeSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 设置页只声明自己公开的字段；这里统一生成受限工具、确认预览与撤销操作。
// ============================================================================

import Foundation

public struct GuidePageSetting: @unchecked Sendable {
    public let key: String
    public let label: String
    public let access: GuideSnapshotAccess
    public let schema: JSONValue

    fileprivate let readValue: @MainActor @Sendable () -> JSONValue
    fileprivate let normalizeValue: @MainActor @Sendable (JSONValue) throws -> JSONValue
    fileprivate let writeValue: (@MainActor @Sendable (JSONValue) throws -> Void)?

    public static func readOnly(
        _ key: String,
        label: String,
        value: @escaping @MainActor @Sendable () -> JSONValue
    ) -> GuidePageSetting {
        GuidePageSetting(
            key: key,
            label: label,
            access: .readOnly,
            schema: .dictionary(["type": .string("string")]),
            readValue: value,
            normalizeValue: { $0 },
            writeValue: nil
        )
    }

    public static func bool(
        _ key: String,
        label: String,
        get: @escaping @MainActor @Sendable () -> Bool,
        set: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> GuidePageSetting {
        GuidePageSetting(
            key: key,
            label: label,
            access: .readWrite,
            schema: .dictionary([
                "type": .string("boolean"),
                "description": .string(label)
            ]),
            readValue: { .bool(get()) },
            normalizeValue: { value in
                guard case .bool = value else { throw GuideError.invalidToolArguments }
                return value
            },
            writeValue: { value in
                guard case .bool(let resolved) = value else { throw GuideError.invalidToolArguments }
                set(resolved)
            }
        )
    }

    public static func integer(
        _ key: String,
        label: String,
        range: ClosedRange<Int>? = nil,
        get: @escaping @MainActor @Sendable () -> Int,
        set: @escaping @MainActor @Sendable (Int) -> Void
    ) -> GuidePageSetting {
        var schema: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(label)
        ]
        if let range {
            schema["minimum"] = .int(range.lowerBound)
            schema["maximum"] = .int(range.upperBound)
        }
        return GuidePageSetting(
            key: key,
            label: label,
            access: .readWrite,
            schema: .dictionary(schema),
            readValue: { .int(get()) },
            normalizeValue: { value in
                guard case .int(let resolved) = value,
                      range?.contains(resolved) != false else {
                    throw GuideError.invalidToolArguments
                }
                return .int(resolved)
            },
            writeValue: { value in
                guard case .int(let resolved) = value else { throw GuideError.invalidToolArguments }
                set(resolved)
            }
        )
    }

    public static func double(
        _ key: String,
        label: String,
        range: ClosedRange<Double>? = nil,
        get: @escaping @MainActor @Sendable () -> Double,
        set: @escaping @MainActor @Sendable (Double) -> Void
    ) -> GuidePageSetting {
        var schema: [String: JSONValue] = [
            "type": .string("number"),
            "description": .string(label)
        ]
        if let range {
            schema["minimum"] = .double(range.lowerBound)
            schema["maximum"] = .double(range.upperBound)
        }
        return GuidePageSetting(
            key: key,
            label: label,
            access: .readWrite,
            schema: .dictionary(schema),
            readValue: { .double(get()) },
            normalizeValue: { value in
                let resolved: Double
                switch value {
                case .double(let number): resolved = number
                case .int(let number): resolved = Double(number)
                default: throw GuideError.invalidToolArguments
                }
                guard resolved.isFinite, range?.contains(resolved) != false else {
                    throw GuideError.invalidToolArguments
                }
                return .double(resolved)
            },
            writeValue: { value in
                switch value {
                case .double(let resolved): set(resolved)
                case .int(let resolved): set(Double(resolved))
                default: throw GuideError.invalidToolArguments
                }
            }
        )
    }

    public static func string(
        _ key: String,
        label: String,
        allowedValues: [String]? = nil,
        allowsEmpty: Bool = true,
        get: @escaping @MainActor @Sendable () -> String,
        set: @escaping @MainActor @Sendable (String) -> Void
    ) -> GuidePageSetting {
        var schema: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(label)
        ]
        if let allowedValues {
            schema["enum"] = .array(allowedValues.map(JSONValue.string))
        }
        return GuidePageSetting(
            key: key,
            label: label,
            access: .readWrite,
            schema: .dictionary(schema),
            readValue: { .string(get()) },
            normalizeValue: { value in
                guard case .string(let resolved) = value,
                      allowsEmpty || !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      allowedValues?.contains(resolved) != false else {
                    throw GuideError.invalidToolArguments
                }
                return .string(resolved)
            },
            writeValue: { value in
                guard case .string(let resolved) = value else { throw GuideError.invalidToolArguments }
                set(resolved)
            }
        )
    }

    public static func writeOnlyString(
        _ key: String,
        label: String,
        isConfigured: @escaping @MainActor @Sendable () -> Bool,
        set: @escaping @MainActor @Sendable (String) -> Void
    ) -> GuidePageSetting {
        GuidePageSetting(
            key: key,
            label: label,
            access: .writeOnly,
            schema: .dictionary([
                "type": .string("string"),
                "description": .string(label)
            ]),
            readValue: {
                .string(isConfigured() ? GuideSnapshotField.hiddenValue : "")
            },
            normalizeValue: { value in
                guard case .string(let resolved) = value else {
                    throw GuideError.invalidToolArguments
                }
                return .string(resolved)
            },
            writeValue: { value in
                guard case .string(let resolved) = value else {
                    throw GuideError.invalidToolArguments
                }
                set(resolved)
            }
        )
    }

    /// 用于页面自身已经有明确 JSON 数据结构的复杂设置，例如自定义命令列表。
    /// 校验与写入仍由页面负责，向导只能触及这里显式声明的单个字段。
    public static func json(
        _ key: String,
        label: String,
        schema: JSONValue,
        get: @escaping @MainActor @Sendable () -> JSONValue,
        normalize: @escaping @MainActor @Sendable (JSONValue) throws -> JSONValue,
        set: @escaping @MainActor @Sendable (JSONValue) throws -> Void
    ) -> GuidePageSetting {
        GuidePageSetting(
            key: key,
            label: label,
            access: .readWrite,
            schema: schema,
            readValue: get,
            normalizeValue: normalize,
            writeValue: set
        )
    }
}

public enum GuideDeclarativeSettingsSupport {
    public static let toolName = "propose_current_page_settings"
    private static let restoreToolName = "restore_current_page_settings_after_guide_change"

    public static func toolDefinition(
        pageTitle: String,
        settings: [GuidePageSetting]
    ) -> InternalToolDefinition {
        let editable = settings.filter { $0.writeValue != nil }
        return InternalToolDefinition(
            name: toolName,
            description: "提出当前“\(pageTitle)”页面中已声明设置的修改。只填写确实需要变化的字段，客户端确认后才会写入。",
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary(Dictionary(uniqueKeysWithValues: editable.map { ($0.key, $0.schema) })),
                "additionalProperties": .bool(false)
            ])
        )
    }

    @MainActor
    public static func snapshot(settings: [GuidePageSetting]) -> GuidePageSnapshot {
        GuidePageSnapshot(fields: Dictionary(uniqueKeysWithValues: settings.map { setting in
            (
                setting.key,
                GuideSnapshotField(
                    label: setting.label,
                    value: setting.readValue(),
                    access: setting.access
                )
            )
        }))
    }

    @MainActor
    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        pageTitle: String,
        settings: [GuidePageSetting],
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        guard call.toolName == toolName else { throw GuideError.unsupportedTool(call.toolName) }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let editable = Dictionary(uniqueKeysWithValues: settings.compactMap { setting in
            setting.writeValue == nil ? nil : (setting.key, setting)
        })
        try GuideToolArguments.requireOnlyKeys(Set(editable.keys), in: arguments)

        var normalizedArguments: [String: JSONValue] = [:]
        var mutations: [GuideSettingMutation] = []
        // 页面声明顺序也是依赖顺序，例如先切换协议类型，再填写该协议的地址与参数。
        for setting in settings {
            guard let value = arguments[setting.key] else { continue }
            let key = setting.key
            guard editable[key] != nil else { throw GuideError.invalidToolArguments }
            let normalized = try setting.normalizeValue(value)
            normalizedArguments[key] = normalized
            let oldValue = snapshot.fields[key]?.value
            guard oldValue != normalized else { continue }
            mutations.append(GuideSettingMutation(
                path: key,
                label: setting.label,
                oldValue: oldValue,
                newValue: normalized,
                isSensitive: setting.access == .writeOnly
            ))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: toolName,
            summary: String(
                format: NSLocalizedString("修改“%@”中的 %d 项设置", comment: "通用页面向导提案摘要"),
                pageTitle,
                mutations.count
            ),
            mutations: mutations,
            arguments: normalizedArguments
        )
    }

    @MainActor
    public static func execute(
        proposal: GuideActionProposal,
        pageID: GuidePageID,
        pageTitle: String,
        settings: [GuidePageSetting]
    ) throws -> GuideActionExecution {
        let editable = Dictionary(uniqueKeysWithValues: settings.compactMap { setting in
            setting.writeValue == nil ? nil : (setting.key, setting)
        })
        guard proposal.pageID == pageID,
              proposal.toolName == toolName || proposal.toolName == restoreToolName else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        try GuideToolArguments.requireOnlyKeys(Set(editable.keys), in: proposal.arguments)

        var normalized: [(GuidePageSetting, JSONValue)] = []
        var previous: [String: JSONValue] = [:]
        var canUndo = true
        // 与提案预览使用相同的声明顺序，避免协议切换等字段覆盖随后应写入的草稿。
        for setting in settings {
            guard let value = proposal.arguments[setting.key] else { continue }
            let key = setting.key
            guard editable[key] != nil else { throw GuideError.invalidToolArguments }
            normalized.append((setting, try setting.normalizeValue(value)))
            if setting.access == .writeOnly {
                canUndo = false
            } else {
                previous[key] = setting.readValue()
            }
        }
        guard !normalized.isEmpty else { throw GuideError.invalidToolArguments }
        for (setting, value) in normalized {
            try setting.writeValue?(value)
        }

        let undo: GuideActionProposal?
        if proposal.toolName == toolName, canUndo {
            undo = GuideActionProposal(
                pageID: pageID,
                toolCallID: "undo-\(proposal.toolCallID)",
                toolName: restoreToolName,
                summary: String(
                    format: NSLocalizedString("撤销“%@”中的设置修改", comment: "通用页面向导撤销摘要"),
                    pageTitle
                ),
                mutations: [],
                arguments: previous
            )
        } else {
            undo = nil
        }
        return GuideActionExecution(
            message: String(
                format: NSLocalizedString("已更新“%@”中的设置。", comment: "通用页面向导执行结果"),
                pageTitle
            ),
            undoProposal: undo
        )
    }
}
