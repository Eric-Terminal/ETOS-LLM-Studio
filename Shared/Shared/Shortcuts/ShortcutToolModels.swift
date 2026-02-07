// ============================================================================
// ShortcutToolModels.swift
// ============================================================================
// 快捷指令工具化的数据模型定义
// ============================================================================

import Foundation

public enum ShortcutRunModeHint: String, Codable, Hashable, Sendable, CaseIterable {
    case direct
    case bridge
}

public enum ShortcutExecutionTransport: String, Codable, Hashable, Sendable {
    case direct
    case bridge
    case relay
}

public struct ShortcutToolImportPayload: Codable, Hashable, Sendable {
    public var name: String
    public var externalID: String?
    public var metadata: [String: JSONValue]
    public var source: String?
    public var runModeHint: ShortcutRunModeHint?

    public init(
        name: String,
        externalID: String? = nil,
        metadata: [String: JSONValue] = [:],
        source: String? = nil,
        runModeHint: ShortcutRunModeHint? = nil
    ) {
        self.name = name
        self.externalID = externalID
        self.metadata = metadata
        self.source = source
        self.runModeHint = runModeHint
    }

    enum CodingKeys: String, CodingKey {
        case name
        case externalID
        case externalId
        case metadata
        case source
        case runModeHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
            ?? container.decodeIfPresent(String.self, forKey: .externalId)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.runModeHint = try container.decodeIfPresent(ShortcutRunModeHint.self, forKey: .runModeHint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(externalID, forKey: .externalID)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(runModeHint, forKey: .runModeHint)
    }
}

public struct ShortcutToolManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var tools: [ShortcutToolImportPayload]

    public init(schemaVersion: Int = 1, tools: [ShortcutToolImportPayload]) {
        self.schemaVersion = schemaVersion
        self.tools = tools
    }
}

public enum ShortcutClipboardImportType: String, Codable, Hashable, Sendable {
    case light
    case deep

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).lowercased()
        guard let type = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported import type: \(rawValue)"
            )
        }
        self = type
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ShortcutLightImportManifest: Codable, Hashable, Sendable {
    public var type: ShortcutClipboardImportType
    public var data: [String]

    public init(type: ShortcutClipboardImportType = .light, data: [String]) {
        self.type = type
        self.data = data
    }
}

public struct ShortcutDeepImportItem: Codable, Hashable, Sendable {
    public var name: String
    public var link: String

    public init(name: String, link: String) {
        self.name = name
        self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case name
        case link
        case url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.link = try container.decodeIfPresent(String.self, forKey: .link)
            ?? container.decode(String.self, forKey: .url)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(link, forKey: .link)
    }
}

public struct ShortcutDeepImportManifest: Codable, Hashable, Sendable {
    public var type: ShortcutClipboardImportType
    public var data: [ShortcutDeepImportItem]

    public init(type: ShortcutClipboardImportType = .deep, data: [ShortcutDeepImportItem]) {
        self.type = type
        self.data = data
    }
}

public struct ShortcutToolDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var externalID: String?
    public var metadata: [String: JSONValue]
    public var source: String?
    public var runModeHint: ShortcutRunModeHint
    public var isEnabled: Bool
    public var userDescription: String?
    public var generatedDescription: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastImportedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        externalID: String? = nil,
        metadata: [String: JSONValue] = [:],
        source: String? = nil,
        runModeHint: ShortcutRunModeHint = .direct,
        isEnabled: Bool = false,
        userDescription: String? = nil,
        generatedDescription: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastImportedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.externalID = externalID
        self.metadata = metadata
        self.source = source
        self.runModeHint = runModeHint
        self.isEnabled = isEnabled
        self.userDescription = userDescription
        self.generatedDescription = generatedDescription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastImportedAt = lastImportedAt
    }

    public var effectiveDescription: String {
        if let userDescription, !userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return userDescription
        }
        if let generatedDescription, !generatedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return generatedDescription
        }
        return "调用快捷指令 \(name) 以执行自动化任务。"
    }

    public var displayName: String {
        if let value = metadata["displayName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return name
    }
}

public struct ShortcutImportSummary: Codable, Hashable, Sendable {
    public var importedCount: Int
    public var skippedCount: Int
    public var conflictNames: [String]
    public var invalidCount: Int

    public init(importedCount: Int, skippedCount: Int, conflictNames: [String], invalidCount: Int) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.conflictNames = conflictNames
        self.invalidCount = invalidCount
    }
}

public struct ShortcutToolExecutionRequest: Codable, Hashable, Sendable {
    public var requestID: String
    public var toolName: String
    public var argumentsJSON: String
    public var preferredTransport: ShortcutExecutionTransport
    public var requestedAt: Date

    public init(
        requestID: String = UUID().uuidString,
        toolName: String,
        argumentsJSON: String,
        preferredTransport: ShortcutExecutionTransport = .direct,
        requestedAt: Date = Date()
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.preferredTransport = preferredTransport
        self.requestedAt = requestedAt
    }
}

public struct ShortcutToolExecutionResult: Codable, Hashable, Sendable {
    public var requestID: String
    public var toolName: String
    public var success: Bool
    public var result: String?
    public var errorMessage: String?
    public var transport: ShortcutExecutionTransport
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        requestID: String,
        toolName: String,
        success: Bool,
        result: String? = nil,
        errorMessage: String? = nil,
        transport: ShortcutExecutionTransport,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.success = success
        self.result = result
        self.errorMessage = errorMessage
        self.transport = transport
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum ShortcutToolError: LocalizedError {
    case unsupportedImportSource
    case clipboardEmpty
    case invalidManifest
    case unsupportedSchema(Int)
    case unknownTool
    case cannotOpenShortcutApp
    case callbackTimeout
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedImportSource:
            return NSLocalizedString("当前设备不支持该导入方式。", comment: "")
        case .clipboardEmpty:
            return NSLocalizedString("剪贴板中没有可导入的快捷指令清单。", comment: "")
        case .invalidManifest:
            return NSLocalizedString("快捷指令清单格式无效。", comment: "")
        case .unsupportedSchema(let version):
            return String(format: NSLocalizedString("暂不支持 schemaVersion=%d 的清单。", comment: ""), version)
        case .unknownTool:
            return NSLocalizedString("未找到匹配的快捷指令工具。", comment: "")
        case .cannotOpenShortcutApp:
            return NSLocalizedString("无法启动快捷指令。", comment: "")
        case .callbackTimeout:
            return NSLocalizedString("等待快捷指令回调超时。", comment: "")
        case .executionFailed(let message):
            return message
        }
    }
}

public enum ShortcutToolNaming {
    public static let toolAliasPrefix = "shortcut_"

    public static func normalizeExecutableName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-." )
        let unicodeScalars = trimmed.unicodeScalars.map { scalar -> String in
            if allowed.contains(scalar) {
                return String(scalar)
            }
            return "_"
        }
        let collapsed = unicodeScalars.joined()
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "tool" : collapsed
    }

    public static func alias(for tool: ShortcutToolDefinition) -> String {
        let prefix = tool.id.uuidString.prefix(8)
        let safeName = sanitize(tool.name)
        return "\(toolAliasPrefix)\(prefix)_\(safeName)"
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
