import ETOSCore
import Foundation

/// 时间、费用和可见项在消息准备 actor 中生成，聊天行不查询模型列表或格式化数字。
struct MacMessageActionBarPresentation {
    struct Item: Identifiable {
        let id: MessageActionBarItem
        let value: String?
        let help: String
    }

    let items: [Item]
    let alignment: MessageActionBarAlignment
    let showsOuterBorder: Bool
    let fontScale: Double

    init(message: ChatMessage, configuration: MessageActionBarConfiguration, providers: [Provider], hasVersions: Bool) {
        let role: MessageActionBarRole = message.role == .user && message.authorKind == .user ? .user : .assistant
        alignment = configuration.alignment(for: role)
        showsOuterBorder = configuration.showsOuterBorder
        fontScale = configuration.fontScale
        let requestDate = message.responseMetrics?.requestStartedAt ?? message.requestedAt
        let cost = MessageCostResolver.resolvedCost(for: message, providers: providers)
        let retryable = MessageActionBarAvailability.retryableMessageIDs(in: [message], isSending: false).contains(message.id)
        let prepared = configuration.items(for: role).compactMap { item -> Item? in
            var value: String?
            var help = item.macTitle
            switch item {
            case .quickRetry: guard retryable else { return nil }
            case .copyMessage: guard !message.content.isEmpty else { return nil }
            case .readAloud: guard MessageActionBarAvailability.canReadAloud(message) else { return nil }
            case .requestTime:
                guard let requestDate else { return nil }
                value = requestDate.formatted(date: .omitted, time: .shortened)
                help = String(format: NSLocalizedString("请求时间：%@", comment: ""), requestDate.formatted(date: .abbreviated, time: .standard))
            case .inputTokens:
                guard let tokens = message.tokenUsage?.promptTokens else { return nil }
                value = String(tokens)
                help = String(format: NSLocalizedString("输入 Token：%@", comment: ""), String(tokens))
            case .outputTokens:
                guard let tokens = message.tokenUsage?.completionTokens else { return nil }
                value = String(tokens)
                help = String(format: NSLocalizedString("输出 Token：%@", comment: ""), String(tokens))
            case .costEstimate:
                guard let cost else { return nil }
                let formatter = NumberFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 6
                value = cost.totalCost > 0 && cost.totalCost < 0.000001 ? "<0.000001"
                    : formatter.string(from: NSNumber(value: max(0, cost.totalCost)))
                help = String(format: NSLocalizedString(cost.isEstimatedFromCurrentPricing ? "按当前价格估算：%@" : "费用：%@", comment: ""), value ?? "")
            case .versionSwitcher: guard hasVersions else { return nil }
            }
            return Item(id: item, value: value, help: help)
        }
        // 共享设置的第一项靠近指定边缘，因此靠右时保持移动端的反向显示顺序。
        items = alignment == .leading ? prepared : Array(prepared.reversed())
    }
}

extension MessageActionBarItem {
    var macTitle: String {
        switch self {
        case .quickRetry: return NSLocalizedString("快捷重试", comment: "")
        case .copyMessage: return NSLocalizedString("复制消息", comment: "")
        case .readAloud: return NSLocalizedString("朗读消息", comment: "")
        case .requestTime: return NSLocalizedString("请求时间", comment: "")
        case .inputTokens: return NSLocalizedString("输入 Token", comment: "")
        case .outputTokens: return NSLocalizedString("输出 Token", comment: "")
        case .costEstimate: return NSLocalizedString("费用", comment: "")
        case .versionSwitcher: return NSLocalizedString("多版本切换", comment: "")
        }
    }

    var macSymbol: String {
        switch self {
        case .quickRetry: return "arrow.clockwise"
        case .copyMessage: return "doc.on.doc"
        case .readAloud: return "speaker.wave.2"
        case .requestTime: return "clock"
        case .inputTokens: return "arrow.up"
        case .outputTokens: return "arrow.down"
        case .costEstimate: return "dollarsign.circle"
        case .versionSwitcher: return "arrow.left.arrow.right"
        }
    }
}
