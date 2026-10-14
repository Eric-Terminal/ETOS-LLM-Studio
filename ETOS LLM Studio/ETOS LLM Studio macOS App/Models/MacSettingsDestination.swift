import Foundation

enum MacSettingsDestination: String, Identifiable {
    case models, conversation, prompts, output, display, sync
    case tools, pulse, usage, memory, mcp, skills, shortcuts, roleplay, worldbook, speech, tts, browser, extended
    case general, security, guide, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .models: NSLocalizedString("模型管理", comment: "")
        case .conversation: NSLocalizedString("会话", comment: "")
        case .prompts: NSLocalizedString("提示词", comment: "")
        case .output: NSLocalizedString("输出", comment: "")
        case .display: NSLocalizedString("背景与视觉", comment: "")
        case .sync: NSLocalizedString("同步与备份", comment: "")
        case .tools: NSLocalizedString("工具中心", comment: "")
        case .pulse: NSLocalizedString("每日脉冲", comment: "")
        case .usage: NSLocalizedString("用量统计", comment: "")
        case .memory: NSLocalizedString("记忆系统", comment: "")
        case .mcp: NSLocalizedString("MCP 工具集成", comment: "")
        case .skills: NSLocalizedString("Agent Skills", comment: "")
        case .shortcuts: NSLocalizedString("快捷指令工具集成", comment: "")
        case .roleplay: NSLocalizedString("角色扮演与酒馆兼容", comment: "")
        case .worldbook: NSLocalizedString("世界书", comment: "")
        case .speech: NSLocalizedString("语音输入", comment: "")
        case .tts: NSLocalizedString("语音输出", comment: "")
        case .browser: NSLocalizedString("Browser Agent", comment: "")
        case .extended: NSLocalizedString("拓展功能", comment: "")
        case .general: NSLocalizedString("通用", comment: "")
        case .security: NSLocalizedString("安全", comment: "")
        case .guide: NSLocalizedString("页面向导", comment: "")
        case .about: NSLocalizedString("关于 ETOS LLM Studio", comment: "")
        }
    }
    var symbol: String {
        switch self {
        case .models: "shippingbox"
        case .conversation: "bubble.left.and.bubble.right"
        case .prompts: "text.bubble"
        case .output: "slider.horizontal.3"
        case .display: "paintpalette"
        case .sync: "arrow.triangle.2.circlepath"
        case .tools: "wrench.and.screwdriver"
        case .pulse: "rectangle.stack"
        case .usage: "chart.bar"
        case .memory: "brain.head.profile"
        case .mcp: "puzzlepiece.extension"
        case .skills: "books.vertical"
        case .shortcuts: "square.stack.3d.up"
        case .roleplay: "person.text.rectangle"
        case .worldbook: "book.closed"
        case .speech: "mic"
        case .tts: "speaker.wave.2"
        case .browser: "safari"
        case .extended: "square.grid.2x2"
        case .general: "gearshape"
        case .security: "lock.shield"
        case .guide: "sparkles"
        case .about: "info.circle"
        }
    }
}
