import Combine
import Foundation

public enum GuideNavigationDestination: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case providerManagement, conversationSettings, promptSettings, outputSettings, appearanceSettings
    case syncAndBackup, dataImport, roleplayAndTavern, worldbook, memorySystem, dailyPulse, toolCenter
    case mcpTools, shortcutTools, agentSkills, speechInput, ttsSettings, localLinux
    case networkProxy, connectionExceptions, feedbackCenter, feedbackCompose, aboutAndLogs

    public var id: String { rawValue }

    // 复用各端现有菜单的本地化键；同一目标在功能地图中可有不同的上级菜单。
    var menu: (key: String, english: String, symbol: String) {
        switch self {
        case .providerManagement: ("模型管理", "Model Management", "shippingbox")
        case .conversationSettings: ("会话", "Sessions", "bubble.left.and.bubble.right")
        case .promptSettings: ("提示词", "Prompt", "text.bubble")
        case .outputSettings: ("输出", "Output", "slider.horizontal.3")
        case .appearanceSettings: ("背景与视觉", "Background & visuals", "paintpalette")
        case .syncAndBackup: ("同步与备份", "Sync & Backup", "arrow.triangle.2.circlepath")
        case .dataImport: ("导入数据", "Import Data", "square.and.arrow.down")
        case .roleplayAndTavern: ("角色扮演与酒馆兼容", "Roleplay & Tavern Compatibility", "person.text.rectangle")
        case .worldbook: ("世界书", "Worldbook", "book.closed")
        case .memorySystem: ("记忆系统", "Memory System", "brain.head.profile")
        case .dailyPulse: ("每日脉冲", "Daily Pulse", "sparkles")
        case .toolCenter: ("工具中心", "Tool Center", "wrench.and.screwdriver")
        case .mcpTools: ("MCP 工具集成", "MCP Tool Integration", "puzzlepiece.extension")
        case .shortcutTools: ("快捷指令工具集成", "Shortcuts Tool Integration", "square.stack.3d.up")
        case .agentSkills: ("Agent Skills", "Agent Skills", "books.vertical")
        case .speechInput: ("语音输入", "Voice input", "mic")
        case .ttsSettings: ("语音朗读（TTS）", "Text-to-Speech (TTS)", "speaker.wave.2")
        case .localLinux: ("本地 Linux", "Local Linux", "terminal")
        case .networkProxy: ("全局代理设置", "Global Proxy Settings", "network")
        case .connectionExceptions: ("连接例外", "Connection Exceptions", "lock.shield")
        case .feedbackCenter: ("反馈助手", "Feedback", "bubble.left")
        case .feedbackCompose: ("新建反馈", "New Feedback", "square.and.pencil")
        case .aboutAndLogs: ("关于", "About", "info.circle")
        }
    }

    public var localizedTitle: String {
        NSLocalizedString(menu.key, value: menu.english, comment: "向导跳转目标")
    }

    public var systemImage: String { menu.symbol }

    public func isAvailable(on platform: String) -> Bool {
        switch platform {
        case "iOS", "watchOS": true
        case "macOS": self != .localLinux
        default: false
        }
    }
}

public enum GuideNavigationSupport {
    static let limit = 4

    static func destinations(in arguments: String, platform: String) throws -> [GuideNavigationDestination] {
        guard let fields = try? GuideToolArguments.decode(arguments),
              case .array(let values)? = fields["destinations"] else { throw GuideError.invalidToolArguments }
        var destinations: [GuideNavigationDestination] = []
        for case let .string(id) in values {
            guard let target = GuideNavigationDestination(rawValue: id),
                  target.isAvailable(on: platform), !destinations.contains(target) else { continue }
            destinations.append(target)
            if destinations.count == limit { break }
        }
        guard !destinations.isEmpty else { throw GuideError.invalidToolArguments }
        return destinations
    }

    static func completedDestinations(in call: InternalToolCall, platform: String) -> [GuideNavigationDestination] {
        guard call.toolName == GuideToolCatalog.suggestSettingsNavigation.name,
              call.resultDisposition == .completed else { return [] }
        return (try? destinations(in: call.arguments, platform: platform)) ?? []
    }

    /// 消息或平台变化时在后台准备按钮列表，渲染时只消费结果。
    public static func suggestedDestinations(
        in message: GuideConversationMessage, platform: String = GuidePromptBuilder.platformName
    ) -> [GuideNavigationDestination] {
        var result: [GuideNavigationDestination] = []
        for call in message.toolCalls {
            for target in completedDestinations(in: call, platform: platform) where !result.contains(target) {
                result.append(target)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

@MainActor
public final class GuideNavigationCoordinator: ObservableObject {
    public static let shared = GuideNavigationCoordinator()
    private let requests = PassthroughSubject<GuideNavigationDestination, Never>()

    /// 只广播用户当下的点击；订阅、重开面板或恢复历史均不会重放导航。
    public var navigationRequests: AnyPublisher<GuideNavigationDestination, Never> { requests.eraseToAnyPublisher() }

    public func request(_ destination: GuideNavigationDestination) {
        guard destination.isAvailable(on: GuidePromptBuilder.platformName) else { return }
        requests.send(destination)
    }
}
