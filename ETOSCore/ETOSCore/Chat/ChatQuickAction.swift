import Foundation

/// iOS 与 Mac 共享稳定标识和显示顺序，继续读写 ui.chatQuickActionIDs。
public enum ChatQuickAction: String, CaseIterable, Identifiable, Sendable {
    case temporaryChat
    case contextCompression
    case settings
    case toolCenter
    case dailyPulse
    case usageAnalytics
    case memory
    case mcp
    case agentSkills
    case shortcuts
    case roleplay
    case worldbook
    case extendedFeatures
    case browser
    case localTerminal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .temporaryChat: return NSLocalizedString("临时对话", comment: "聊天快捷功能标题")
        case .contextCompression: return NSLocalizedString("压缩为续聊", comment: "聊天快捷功能标题")
        case .settings: return NSLocalizedString("设置", comment: "聊天快捷功能标题")
        case .toolCenter: return NSLocalizedString("工具中心", comment: "聊天快捷功能标题")
        case .dailyPulse: return NSLocalizedString("每日脉冲", comment: "聊天快捷功能标题")
        case .usageAnalytics: return NSLocalizedString("用量统计", comment: "聊天快捷功能标题")
        case .memory: return NSLocalizedString("记忆系统", comment: "聊天快捷功能标题")
        case .mcp: return NSLocalizedString("MCP 工具集成", comment: "聊天快捷功能标题")
        case .agentSkills: return NSLocalizedString("Agent Skills", comment: "聊天快捷功能标题")
        case .shortcuts: return NSLocalizedString("快捷指令工具集成", comment: "聊天快捷功能标题")
        case .roleplay: return NSLocalizedString("角色扮演与酒馆兼容", comment: "聊天快捷功能标题")
        case .worldbook: return NSLocalizedString("世界书", comment: "聊天快捷功能标题")
        case .extendedFeatures: return NSLocalizedString("拓展功能", comment: "聊天快捷功能标题")
        case .browser: return NSLocalizedString("浏览器", comment: "聊天快捷功能标题")
        case .localTerminal: return NSLocalizedString("Linux 终端", comment: "聊天快捷功能标题")
        }
    }

    public var systemImage: String {
        switch self {
        case .temporaryChat: return "eye.slash"
        case .contextCompression: return "rectangle.compress.vertical"
        case .settings: return "gearshape"
        case .toolCenter: return "wrench"
        case .dailyPulse: return "sparkles"
        case .usageAnalytics: return "chart.bar"
        case .memory: return "brain"
        case .mcp: return "network"
        case .agentSkills: return "star"
        case .shortcuts: return "bolt"
        case .roleplay: return "theatermasks"
        case .worldbook: return "book"
        case .extendedFeatures: return "ellipsis.circle"
        case .browser: return "safari"
        case .localTerminal: return "terminal"
        }
    }

    public func systemImage(isTemporaryChatEnabled: Bool, memoryMode: TemporaryChatMemoryMode = .enabled) -> String {
        guard self == .temporaryChat else { return systemImage }
        guard isTemporaryChatEnabled else { return "eye" }
        return memoryMode == .isolated ? "eye.slash.fill" : "eye.slash"
    }
}

public enum ChatQuickActionSelection {
    public static let fallback = ChatQuickAction.allCases

    public static func decode(_ rawValue: String) -> [ChatQuickAction] {
        let selectedIDs = Set(rawValue.split(separator: ",").map(String.init))
        let actions = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return actions.isEmpty ? fallback : actions
    }

    public static func encode(_ actions: [ChatQuickAction]) -> String {
        let selectedIDs = Set(actions.map(\.rawValue))
        let normalized = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return (normalized.isEmpty ? fallback : normalized).map(\.rawValue).joined(separator: ",")
    }
}
