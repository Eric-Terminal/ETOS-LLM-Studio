import ETOSCore
import Foundation

/// 其余四种入口分别使用原生临时聊天菜单、Settings 窗口和已有脉冲/压缩工作表。
enum MacChatQuickActionPage: String, CaseIterable, Identifiable, Sendable {
    case toolCenter, usageAnalytics, memory, mcp, agentSkills, shortcuts
    case roleplay, worldbook, extendedFeatures, browser, localTerminal
    var id: String { rawValue }
    var requiresSession: Bool { self == .browser }

    var action: ChatQuickAction {
        switch self {
        case .toolCenter: .toolCenter
        case .usageAnalytics: .usageAnalytics
        case .memory: .memory
        case .mcp: .mcp
        case .agentSkills: .agentSkills
        case .shortcuts: .shortcuts
        case .roleplay: .roleplay
        case .worldbook: .worldbook
        case .extendedFeatures: .extendedFeatures
        case .browser: .browser
        case .localTerminal: .localTerminal
        }
    }
}

struct MacChatQuickActionDestination: Identifiable {
    let id = UUID()
    let page: MacChatQuickActionPage
    let sessionID: UUID?
    let isTemporary: Bool
}
