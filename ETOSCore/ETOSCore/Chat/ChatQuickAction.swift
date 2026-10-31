import Foundation

/// iOS 与 Mac 共享稳定标识；数据库中的选中顺序决定实际显示顺序。
public enum ChatQuickAction: String, CaseIterable, Identifiable, Sendable {
    case temporaryChat
    case modelPicker
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
        case .modelPicker: return NSLocalizedString("选择模型", comment: "聊天快捷功能标题")
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
        case .localTerminal:
            #if os(macOS)
            return NSLocalizedString("终端", comment: "聊天快捷功能标题")
            #else
            return NSLocalizedString("Linux 终端", comment: "聊天快捷功能标题")
            #endif
        }
    }

    public var systemImage: String {
        switch self {
        case .temporaryChat: return "eye.slash"
        case .modelPicker: return "cpu"
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
        let actions = orderedActions(rawValue.split(separator: ",").compactMap { ChatQuickAction(rawValue: String($0)) })
        return actions.isEmpty ? fallback : actions
    }

    public static func encode(_ actions: [ChatQuickAction]) -> String {
        let normalized = orderedActions(actions)
        return (normalized.isEmpty ? fallback : normalized).map(\.rawValue).joined(separator: ",")
    }

    public static func decodeToolbarActions(_ rawValue: String) -> Set<ChatQuickAction> {
        Set(rawValue.split(separator: ",").compactMap { ChatQuickAction(rawValue: String($0)) })
    }

    /// 工具栏允许为空，此时所有已启用功能都进入更多菜单。
    public static func encodeToolbarActions(_ actions: Set<ChatQuickAction>) -> String {
        ChatQuickAction.allCases.filter(actions.contains).map(\.rawValue).joined(separator: ",")
    }

    private static func orderedActions(_ actions: [ChatQuickAction]) -> [ChatQuickAction] {
        var seen = Set<ChatQuickAction>()
        return actions.filter { seen.insert($0).inserted }
    }
}

public enum ChatQuickActionPlacement: String, CaseIterable, Identifiable, Sendable {
    case toolbar, menu, hidden
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toolbar: NSLocalizedString("chat.quickActions.placement.toolbar", value: "Prefer Toolbar", comment: "快捷功能显示位置")
        case .menu: NSLocalizedString("chat.quickActions.placement.menu", value: "More Menu", comment: "快捷功能显示位置")
        case .hidden: NSLocalizedString("chat.quickActions.placement.hidden", value: "Hidden", comment: "快捷功能显示位置")
        }
    }
}
