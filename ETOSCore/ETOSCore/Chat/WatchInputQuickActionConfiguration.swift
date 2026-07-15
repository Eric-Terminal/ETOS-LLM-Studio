// ============================================================================
// WatchInputQuickActionConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义 watchOS 聊天输入栏左右快捷功能的共享配置模型。
// ============================================================================

import Foundation

public enum WatchInputQuickActionEdge: String, CaseIterable, Identifiable, Codable, Sendable {
    case leading
    case trailing

    public var id: String { rawValue }
}

public enum WatchInputQuickAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case requestControls
    case sessionHistory
    case contextCompression
    case roleplayScripts
    case addAttachment
    case clearInput
    case settings
    case toolCenter
    case dailyPulse
    case usageAnalytics
    case imageGallery
    case memory
    case mcp
    case agentSkills
    case shortcuts
    case roleplay
    case worldbook
    case extendedFeatures

    public var id: String { rawValue }
}

public struct WatchInputQuickActionConfiguration: Codable, Equatable, Sendable {
    public var leadingActions: [WatchInputQuickAction]
    public var trailingActions: [WatchInputQuickAction]

    public init(
        leadingActions: [WatchInputQuickAction],
        trailingActions: [WatchInputQuickAction]
    ) {
        var seen = Set<WatchInputQuickAction>()
        self.leadingActions = leadingActions.filter { seen.insert($0).inserted }
        self.trailingActions = trailingActions.filter { seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case leadingActions
        case trailingActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            leadingActions: try container.decodeIfPresent(
                [WatchInputQuickAction].self,
                forKey: .leadingActions
            ) ?? [],
            trailingActions: try container.decodeIfPresent(
                [WatchInputQuickAction].self,
                forKey: .trailingActions
            ) ?? []
        )
    }

    public static let defaultConfiguration = WatchInputQuickActionConfiguration(
        leadingActions: [.requestControls, .sessionHistory, .contextCompression],
        trailingActions: [.roleplayScripts, .addAttachment, .clearInput]
    )

    public static var defaultConfigurationJSON: String {
        defaultConfiguration.encodedString()
    }

    public static func decoded(from rawValue: String) -> WatchInputQuickActionConfiguration {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                WatchInputQuickActionConfiguration.self,
                from: data
              ) else {
            return .defaultConfiguration
        }
        return decoded.normalized()
    }

    public func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(normalized()),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"leadingActions":["requestControls","sessionHistory","contextCompression"],"trailingActions":["roleplayScripts","addAttachment","clearInput"]}"#
        }
        return string
    }

    public func actions(for edge: WatchInputQuickActionEdge) -> [WatchInputQuickAction] {
        switch edge {
        case .leading:
            return leadingActions
        case .trailing:
            return trailingActions
        }
    }

    public mutating func setActions(
        _ actions: [WatchInputQuickAction],
        for edge: WatchInputQuickActionEdge
    ) {
        switch edge {
        case .leading:
            self = WatchInputQuickActionConfiguration(
                leadingActions: actions,
                trailingActions: trailingActions
            )
        case .trailing:
            self = WatchInputQuickActionConfiguration(
                leadingActions: leadingActions,
                trailingActions: actions
            )
        }
    }

    private func normalized() -> WatchInputQuickActionConfiguration {
        WatchInputQuickActionConfiguration(
            leadingActions: leadingActions,
            trailingActions: trailingActions
        )
    }
}
