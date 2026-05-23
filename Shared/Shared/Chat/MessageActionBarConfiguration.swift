// ============================================================================
// MessageActionBarConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义聊天气泡下方功能栏的共享配置模型。
// ============================================================================

import Foundation

public enum MessageActionBarRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case assistant
    case user

    public var id: String { rawValue }
}

public enum MessageActionBarAlignment: String, CaseIterable, Identifiable, Codable, Sendable {
    case leading
    case trailing

    public var id: String { rawValue }
}

public enum MessageActionBarItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case quickRetry
    case copyMessage
    case requestTime
    case inputTokens
    case outputTokens
    case costEstimate
    case versionSwitcher

    public var id: String { rawValue }

    public static func supportedItems(for role: MessageActionBarRole) -> [MessageActionBarItem] {
        switch role {
        case .assistant:
            return allCases
        case .user:
            return allCases.filter { item in
                item != .quickRetry && item != .versionSwitcher
            }
        }
    }
}

public struct MessageActionBarConfiguration: Codable, Equatable, Sendable {
    public var assistantItems: [MessageActionBarItem]
    public var userItems: [MessageActionBarItem]
    public var assistantAlignment: MessageActionBarAlignment
    public var userAlignment: MessageActionBarAlignment
    public var showsOuterBorder: Bool

    public init(
        assistantItems: [MessageActionBarItem],
        userItems: [MessageActionBarItem],
        assistantAlignment: MessageActionBarAlignment,
        userAlignment: MessageActionBarAlignment,
        showsOuterBorder: Bool = false
    ) {
        self.assistantItems = Self.normalizedItems(assistantItems, for: .assistant)
        self.userItems = Self.normalizedItems(userItems, for: .user)
        self.assistantAlignment = assistantAlignment
        self.userAlignment = userAlignment
        self.showsOuterBorder = showsOuterBorder
    }

    private enum CodingKeys: String, CodingKey {
        case assistantItems
        case userItems
        case assistantAlignment
        case userAlignment
        case showsOuterBorder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let assistantItems = try container.decodeIfPresent([MessageActionBarItem].self, forKey: .assistantItems) ?? []
        let userItems = try container.decodeIfPresent([MessageActionBarItem].self, forKey: .userItems) ?? []
        let assistantAlignment = try container.decodeIfPresent(MessageActionBarAlignment.self, forKey: .assistantAlignment) ?? .trailing
        let userAlignment = try container.decodeIfPresent(MessageActionBarAlignment.self, forKey: .userAlignment) ?? .trailing
        let showsOuterBorder = try container.decodeIfPresent(Bool.self, forKey: .showsOuterBorder) ?? false
        self.init(
            assistantItems: assistantItems,
            userItems: userItems,
            assistantAlignment: assistantAlignment,
            userAlignment: userAlignment,
            showsOuterBorder: showsOuterBorder
        )
    }

    public static let iOSDefaultConfiguration = MessageActionBarConfiguration(
        assistantItems: [.versionSwitcher],
        userItems: [],
        assistantAlignment: .trailing,
        userAlignment: .trailing
    )

    public static let watchOSDefaultConfiguration = MessageActionBarConfiguration(
        assistantItems: [],
        userItems: [],
        assistantAlignment: .trailing,
        userAlignment: .trailing
    )

    public static var defaultConfiguration: MessageActionBarConfiguration {
        #if os(watchOS)
        return watchOSDefaultConfiguration
        #else
        return iOSDefaultConfiguration
        #endif
    }

    public static var defaultConfigurationJSON: String {
        defaultConfiguration.encodedString()
    }

    public static func decoded(from rawValue: String) -> MessageActionBarConfiguration {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MessageActionBarConfiguration.self, from: data) else {
            return .defaultConfiguration
        }
        return decoded.normalized()
    }

    public func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(normalized()),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"assistantItems":["versionSwitcher"],"userItems":[],"assistantAlignment":"trailing","userAlignment":"trailing","showsOuterBorder":false}"#
        }
        return string
    }

    public func items(for role: MessageActionBarRole) -> [MessageActionBarItem] {
        switch role {
        case .assistant:
            return assistantItems
        case .user:
            return userItems
        }
    }

    public func alignment(for role: MessageActionBarRole) -> MessageActionBarAlignment {
        switch role {
        case .assistant:
            return assistantAlignment
        case .user:
            return userAlignment
        }
    }

    public mutating func setItems(_ items: [MessageActionBarItem], for role: MessageActionBarRole) {
        switch role {
        case .assistant:
            assistantItems = Self.normalizedItems(items, for: role)
        case .user:
            userItems = Self.normalizedItems(items, for: role)
        }
    }

    public mutating func setAlignment(_ alignment: MessageActionBarAlignment, for role: MessageActionBarRole) {
        switch role {
        case .assistant:
            assistantAlignment = alignment
        case .user:
            userAlignment = alignment
        }
    }

    private func normalized() -> MessageActionBarConfiguration {
        MessageActionBarConfiguration(
            assistantItems: assistantItems,
            userItems: userItems,
            assistantAlignment: assistantAlignment,
            userAlignment: userAlignment,
            showsOuterBorder: showsOuterBorder
        )
    }

    private static func normalizedItems(_ items: [MessageActionBarItem], for role: MessageActionBarRole) -> [MessageActionBarItem] {
        let supportedItems = MessageActionBarItem.supportedItems(for: role)
        return uniqueItems(items.filter { supportedItems.contains($0) })
    }

    private static func uniqueItems(_ items: [MessageActionBarItem]) -> [MessageActionBarItem] {
        var seen = Set<MessageActionBarItem>()
        return items.filter { seen.insert($0).inserted }
    }
}

public enum MessageActionBarAvailability {
    public static func retryableMessageIDs(in messages: [ChatMessage], isSending: Bool) -> Set<UUID> {
        if isSending {
            guard let lastMessage = messages.last else { return [] }
            var ids: Set<UUID> = [lastMessage.id]
            if let lastUserMessage = messages.last(where: { $0.role == .user }) {
                ids.insert(lastUserMessage.id)
            }
            return ids
        }

        return Set(messages.compactMap { message in
            switch message.role {
            case .user, .assistant, .error:
                return message.id
            case .system, .tool:
                return nil
            @unknown default:
                return nil
            }
        })
    }
}
