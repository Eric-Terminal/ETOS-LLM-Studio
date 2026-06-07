// ============================================================================
// WorldbookModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义世界书、世界书条目、注入设置与 SillyTavern 兼容解码辅助。
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 世界书模型

public enum WorldbookPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case before
    case after
    case anTop
    case anBottom
    case atDepth
    case emTop
    case emBottom
    case outlet

    public init(stRawValue: String) {
        switch stRawValue.lowercased() {
        case "before":
            self = .before
        case "after":
            self = .after
        case "antop":
            self = .anTop
        case "anbottom":
            self = .anBottom
        case "atdepth":
            self = .atDepth
        case "emtop":
            self = .emTop
        case "embottom":
            self = .emBottom
        case "outlet":
            self = .outlet
        default:
            self = .after
        }
    }

    public var stRawValue: String {
        switch self {
        case .before: return "before"
        case .after: return "after"
        case .anTop: return "ANTop"
        case .anBottom: return "ANBottom"
        case .atDepth: return "atDepth"
        case .emTop: return "EMTop"
        case .emBottom: return "EMBottom"
        case .outlet: return "outlet"
        }
    }
}

public enum WorldbookSelectiveLogic: String, Codable, CaseIterable, Hashable, Sendable {
    case andAny = "AND_ANY"
    case notAll = "NOT_ALL"
    case notAny = "NOT_ANY"
    case andAll = "AND_ALL"

    public init(rawOrLegacyValue: String?) {
        let normalized = rawOrLegacyValue?.uppercased() ?? "AND_ANY"
        switch normalized {
        case "AND_ALL":
            self = .andAll
        case "NOT_ALL":
            self = .notAll
        case "NOT_ANY":
            self = .notAny
        default:
            self = .andAny
        }
    }
}

public enum WorldbookEntryRole: String, Codable, CaseIterable, Hashable, Sendable {
    case system = "SYSTEM"
    case user = "USER"
    case assistant = "ASSISTANT"

    public init(rawOrLegacyValue: String?) {
        switch rawOrLegacyValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SYSTEM", "0":
            self = .system
        case "ASSISTANT", "2":
            self = .assistant
        case "USER", "1":
            self = .user
        default:
            self = .user
        }
    }
}

public struct WorldbookTimedEffectState: Codable, Hashable, Sendable {
    public var stickyUntilTurn: Int?
    public var cooldownUntilTurn: Int?
    public var delayUntilTurn: Int?
    public var lastTriggeredTurn: Int?

    public init(
        stickyUntilTurn: Int? = nil,
        cooldownUntilTurn: Int? = nil,
        delayUntilTurn: Int? = nil,
        lastTriggeredTurn: Int? = nil
    ) {
        self.stickyUntilTurn = stickyUntilTurn
        self.cooldownUntilTurn = cooldownUntilTurn
        self.delayUntilTurn = delayUntilTurn
        self.lastTriggeredTurn = lastTriggeredTurn
    }
}

public enum WorldbookMetadataKey {
    public static let selective = "selective"
    public static let etosSecondaryKeysEnabled = "etosSecondaryKeysEnabled"
    public static let sillyTavernSecondaryKeys = "keysecondary"
    public static let characterBookSecondaryKeys = "secondary_keys"
}

public struct WorldbookSettings: Codable, Hashable, Sendable {
    public static let unlimitedInjectedEntries = -1
    public static let unlimitedInjectedCharacters = -1

    public var scanDepth: Int
    public var maxRecursionDepth: Int
    public var maxInjectedEntries: Int
    public var maxInjectedCharacters: Int
    public var fallbackPosition: WorldbookPosition

    public init(
        scanDepth: Int = 4,
        maxRecursionDepth: Int = 2,
        maxInjectedEntries: Int = WorldbookSettings.unlimitedInjectedEntries,
        maxInjectedCharacters: Int = WorldbookSettings.unlimitedInjectedCharacters,
        fallbackPosition: WorldbookPosition = .after
    ) {
        self.scanDepth = max(1, scanDepth)
        self.maxRecursionDepth = max(0, maxRecursionDepth)
        self.maxInjectedEntries = maxInjectedEntries < 0 ? Self.unlimitedInjectedEntries : max(1, maxInjectedEntries)
        self.maxInjectedCharacters = maxInjectedCharacters < 0 ? Self.unlimitedInjectedCharacters : max(1, maxInjectedCharacters)
        self.fallbackPosition = fallbackPosition
    }

    enum CodingKeys: String, CodingKey {
        case scanDepth
        case maxRecursionDepth
        case maxInjectedEntries
        case maxInjectedCharacters
        case fallbackPosition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scanDepth: try container.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 4,
            maxRecursionDepth: try container.decodeIfPresent(Int.self, forKey: .maxRecursionDepth) ?? 2,
            maxInjectedEntries: try container.decodeIfPresent(Int.self, forKey: .maxInjectedEntries) ?? Self.unlimitedInjectedEntries,
            maxInjectedCharacters: try container.decodeIfPresent(Int.self, forKey: .maxInjectedCharacters) ?? Self.unlimitedInjectedCharacters,
            fallbackPosition: try container.decodeIfPresent(WorldbookPosition.self, forKey: .fallbackPosition) ?? .after
        )
    }
}

public struct WorldbookEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var uid: Int?
    public var comment: String
    public var content: String
    public var keys: [String]
    public var secondaryKeys: [String]
    public var selectiveLogic: WorldbookSelectiveLogic
    public var isEnabled: Bool
    public var constant: Bool
    public var position: WorldbookPosition
    public var outletName: String?
    public var order: Int
    public var depth: Int?
    public var scanDepth: Int?
    public var caseSensitive: Bool
    public var matchWholeWords: Bool
    public var useRegex: Bool
    public var useProbability: Bool
    public var probability: Double
    public var group: String?
    public var groupOverride: Bool
    public var groupWeight: Double
    public var useGroupScoring: Bool
    public var role: WorldbookEntryRole
    public var sticky: Int?
    public var cooldown: Int?
    public var delay: Int?
    public var excludeRecursion: Bool
    public var preventRecursion: Bool
    public var delayUntilRecursion: Bool
    public var metadata: [String: JSONValue]

    public var secondaryKeysEnabled: Bool {
        if let explicit = metadata.boolValue(for: WorldbookMetadataKey.etosSecondaryKeysEnabled) {
            return explicit
        }
        if let selective = metadata.boolValue(for: WorldbookMetadataKey.selective) {
            return selective
        }
        if metadata[WorldbookMetadataKey.sillyTavernSecondaryKeys] != nil ||
            metadata[WorldbookMetadataKey.characterBookSecondaryKeys] != nil {
            return false
        }
        return !secondaryKeys.isEmpty
    }

    public init(
        id: UUID = UUID(),
        uid: Int? = nil,
        comment: String = "",
        content: String,
        keys: [String],
        secondaryKeys: [String] = [],
        selectiveLogic: WorldbookSelectiveLogic = .andAny,
        isEnabled: Bool = true,
        constant: Bool = false,
        position: WorldbookPosition = .after,
        outletName: String? = nil,
        order: Int = 100,
        depth: Int? = nil,
        scanDepth: Int? = nil,
        caseSensitive: Bool = false,
        matchWholeWords: Bool = false,
        useRegex: Bool = false,
        useProbability: Bool = false,
        probability: Double = 100,
        group: String? = nil,
        groupOverride: Bool = false,
        groupWeight: Double = 1,
        useGroupScoring: Bool = false,
        role: WorldbookEntryRole = .user,
        sticky: Int? = nil,
        cooldown: Int? = nil,
        delay: Int? = nil,
        excludeRecursion: Bool = false,
        preventRecursion: Bool = false,
        delayUntilRecursion: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.uid = uid
        self.comment = comment
        self.content = content
        self.keys = keys
        self.secondaryKeys = secondaryKeys
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.position = position
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.scanDepth = scanDepth
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.useRegex = useRegex
        self.useProbability = useProbability
        self.probability = probability
        self.group = group
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.role = role
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case comment
        case content
        case keys
        case key
        case secondaryKeys
        case keysecondary
        case selective
        case selectiveLogic
        case isEnabled
        case disable
        case constant
        case position
        case outletName
        case outlet
        case order
        case depth
        case scanDepth
        case caseSensitive
        case matchWholeWords
        case useRegex
        case useProbability
        case probability
        case group
        case groupOverride
        case groupWeight
        case useGroupScoring
        case role
        case sticky
        case cooldown
        case delay
        case excludeRecursion
        case preventRecursion
        case delayUntilRecursion
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUID = try container.decodeIfPresent(Int.self, forKey: .uid)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        } else if decodedUID != nil {
            self.id = UUID()
        } else {
            self.id = UUID()
        }
        self.uid = decodedUID
        self.comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.keys = container.decodeStringArrayLossy(forKey: .keys, fallbackKey: .key)
        self.secondaryKeys = container.decodeStringArrayLossy(forKey: .secondaryKeys, fallbackKey: .keysecondary)
        let logicRaw = try container.decodeIfPresent(String.self, forKey: .selectiveLogic)
        self.selectiveLogic = WorldbookSelectiveLogic(rawOrLegacyValue: logicRaw)
        var decodedMetadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        if let selective = container.decodeBoolIfPresentLossy(forKey: .selective) {
            decodedMetadata[WorldbookMetadataKey.selective] = .bool(selective)
            decodedMetadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] = .bool(selective)
        } else if !secondaryKeys.isEmpty,
                  decodedMetadata[WorldbookMetadataKey.selective] == nil,
                  decodedMetadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] == nil,
                  container.contains(.keysecondary),
                  !container.contains(.secondaryKeys) {
            decodedMetadata[WorldbookMetadataKey.etosSecondaryKeysEnabled] = .bool(false)
        }
        let disabled = try container.decodeIfPresent(Bool.self, forKey: .disable) ?? false
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? !disabled
        self.constant = try container.decodeIfPresent(Bool.self, forKey: .constant) ?? false
        if let rawPosition = try container.decodeIfPresent(String.self, forKey: .position) {
            self.position = WorldbookPosition(stRawValue: rawPosition)
        } else {
            self.position = .after
        }
        self.outletName =
            try container.decodeIfPresent(String.self, forKey: .outletName) ??
            container.decodeStringIfPresentLossy(forKey: .outlet)
        self.order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 100
        self.depth = try container.decodeIfPresent(Int.self, forKey: .depth)
        self.scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth)
        self.caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        self.matchWholeWords = try container.decodeIfPresent(Bool.self, forKey: .matchWholeWords) ?? false
        self.useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        self.useProbability = try container.decodeIfPresent(Bool.self, forKey: .useProbability) ?? false
        self.probability = try container.decodeIfPresent(Double.self, forKey: .probability) ?? 100
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.groupOverride = try container.decodeIfPresent(Bool.self, forKey: .groupOverride) ?? false
        self.groupWeight = try container.decodeIfPresent(Double.self, forKey: .groupWeight) ?? 1
        self.useGroupScoring = try container.decodeIfPresent(Bool.self, forKey: .useGroupScoring) ?? false
        self.role = WorldbookEntryRole(rawOrLegacyValue: try container.decodeIfPresent(String.self, forKey: .role))
        self.sticky = try container.decodeIfPresent(Int.self, forKey: .sticky)
        self.cooldown = try container.decodeIfPresent(Int.self, forKey: .cooldown)
        self.delay = try container.decodeIfPresent(Int.self, forKey: .delay)
        self.excludeRecursion = try container.decodeIfPresent(Bool.self, forKey: .excludeRecursion) ?? false
        self.preventRecursion = try container.decodeIfPresent(Bool.self, forKey: .preventRecursion) ?? false
        self.delayUntilRecursion = try container.decodeIfPresent(Bool.self, forKey: .delayUntilRecursion) ?? false
        self.metadata = decodedMetadata
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(uid, forKey: .uid)
        if !comment.isEmpty {
            try container.encode(comment, forKey: .comment)
        }
        try container.encode(content, forKey: .content)
        try container.encode(keys, forKey: .keys)
        if !secondaryKeys.isEmpty {
            try container.encode(secondaryKeys, forKey: .secondaryKeys)
        }
        try container.encode(selectiveLogic.rawValue, forKey: .selectiveLogic)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(constant, forKey: .constant)
        try container.encode(position.stRawValue, forKey: .position)
        try container.encodeIfPresent(outletName, forKey: .outletName)
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(depth, forKey: .depth)
        try container.encodeIfPresent(scanDepth, forKey: .scanDepth)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encode(matchWholeWords, forKey: .matchWholeWords)
        try container.encode(useRegex, forKey: .useRegex)
        try container.encode(useProbability, forKey: .useProbability)
        try container.encode(probability, forKey: .probability)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(groupOverride, forKey: .groupOverride)
        try container.encode(groupWeight, forKey: .groupWeight)
        try container.encode(useGroupScoring, forKey: .useGroupScoring)
        try container.encode(role.rawValue, forKey: .role)
        try container.encodeIfPresent(sticky, forKey: .sticky)
        try container.encodeIfPresent(cooldown, forKey: .cooldown)
        try container.encodeIfPresent(delay, forKey: .delay)
        try container.encode(excludeRecursion, forKey: .excludeRecursion)
        try container.encode(preventRecursion, forKey: .preventRecursion)
        try container.encode(delayUntilRecursion, forKey: .delayUntilRecursion)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

public struct Worldbook: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [WorldbookEntry]
    public var settings: WorldbookSettings
    public var sourceFileName: String?
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        entries: [WorldbookEntry],
        settings: WorldbookSettings = WorldbookSettings(),
        sourceFileName: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
        self.settings = settings
        self.sourceFileName = sourceFileName
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isEnabled
        case createdAt
        case updatedAt
        case entries
        case settings
        case sourceFileName
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.entries = try container.decodeIfPresent([WorldbookEntry].self, forKey: .entries) ?? []
        self.settings = try container.decodeIfPresent(WorldbookSettings.self, forKey: .settings) ?? WorldbookSettings()
        self.sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(description, forKey: .description)
        }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(entries, forKey: .entries)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(sourceFileName, forKey: .sourceFileName)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

public extension Worldbook {
    var contentHash: String {
        let canonicalEntries = entries
            .sorted {
                if $0.order == $1.order {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.order < $1.order
            }
            .map { entry in
                [
                    normalizeWorldbookContent(entry.content),
                    entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|"),
                    entry.secondaryKeys.map { $0.lowercased() }.sorted().joined(separator: "|"),
                    entry.position.rawValue,
                    String(entry.order),
                    String(entry.depth ?? -1),
                    entry.role.rawValue
                ].joined(separator: "||")
            }
            .joined(separator: "\n")
        let enrichedPayload = "\(name.lowercased())\n\(description.lowercased())\n\(canonicalEntries)"
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(enrichedPayload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return String(enrichedPayload.hashValue)
#endif
    }

    var enabledEntries: [WorldbookEntry] {
        entries.filter { $0.isEnabled && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private func normalizeWorldbookContent(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private extension Dictionary where Key == String, Value == JSONValue {
    func boolValue(for key: String) -> Bool? {
        switch self[key] {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }
}

private extension KeyedDecodingContainer where K == WorldbookEntry.CodingKeys {
    func decodeStringIfPresentLossy(forKey key: K) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let numberValue = try? decodeIfPresent(Double.self, forKey: key) {
            return String(numberValue)
        }
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return String(intValue)
        }
        if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }
        return nil
    }

    func decodeBoolIfPresentLossy(forKey key: K) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return nil
    }

    func decodeStringArrayLossy(forKey key: K, fallbackKey: K) -> [String] {
        if let value = try? decode([String].self, forKey: key) {
            return value.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let value = try? decode([String].self, forKey: fallbackKey) {
            return value.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let stringValue = try? decode(String.self, forKey: fallbackKey) {
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

/// 内部工具定义，与服务商无关。
public struct InternalToolDefinition: Codable, Hashable {
    public let name: String
    public let description: String
    public let parameters: JSONValue // 使用已有的 JSONValue 来定义参数结构
    public let isBlocking: Bool // 此工具是否需要阻塞主流程并等待返回结果

    public init(name: String, description: String, parameters: JSONValue, isBlocking: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.isBlocking = isBlocking
    }
}

/// 内部工具调用，与服务商无关。
public struct InternalToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let toolName: String
    public let arguments: String // 参数通常是JSON字符串
    public var result: String? // 工具执行结果（用于展示）
    public let providerSpecificFields: [String: JSONValue]? // 服务商专有字段（例如 Gemini thought_signature）

    public init(
        id: String,
        toolName: String,
        arguments: String,
        result: String? = nil,
        providerSpecificFields: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.providerSpecificFields = providerSpecificFields
    }
}

/// 内部工具调用的返回结果，与服务商无关。
public struct InternalToolResult: Codable, Hashable {
    public let toolCallId: String
    public let toolName: String
    public let content: String
}
