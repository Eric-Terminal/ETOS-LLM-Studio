import ETOSCore
import Foundation

extension WorldbookPosition {
    static let macGuideValues = allCases.map(\.rawValue)
    var macLabel: String {
        switch self {
        case .before: return NSLocalizedString("系统前置", comment: "")
        case .after: return NSLocalizedString("系统后置", comment: "")
        case .anTop: return NSLocalizedString("AN 顶部", comment: "")
        case .anBottom: return NSLocalizedString("AN 底部", comment: "")
        case .atDepth: return NSLocalizedString("按深度插入", comment: "")
        case .emTop: return NSLocalizedString("消息顶部", comment: "")
        case .emBottom: return NSLocalizedString("消息底部", comment: "")
        case .outlet: return NSLocalizedString("Outlet", comment: "")
        @unknown default: return NSLocalizedString("系统后置", comment: "")
        }
    }
}

extension WorldbookSelectiveLogic {
    static let macGuideValues = allCases.map(\.rawValue)
    var macLabel: String {
        switch self {
        case .andAny: return NSLocalizedString("AND_ANY（任一命中）", comment: "")
        case .andAll: return NSLocalizedString("AND_ALL（全部命中）", comment: "")
        case .notAny: return NSLocalizedString("NOT_ANY（全部不命中）", comment: "")
        case .notAll: return NSLocalizedString("NOT_ALL（并非全部命中）", comment: "")
        @unknown default: return NSLocalizedString("AND_ANY（任一命中）", comment: "")
        }
    }
}

extension WorldbookEntryRole {
    static let macGuideValues = allCases.map(\.rawValue)
    var macLabel: String {
        switch self {
        case .system: return NSLocalizedString("系统", comment: "")
        case .user: return NSLocalizedString("用户", comment: "")
        case .assistant: return NSLocalizedString("助手", comment: "")
        @unknown default: return NSLocalizedString("用户", comment: "")
        }
    }
}
