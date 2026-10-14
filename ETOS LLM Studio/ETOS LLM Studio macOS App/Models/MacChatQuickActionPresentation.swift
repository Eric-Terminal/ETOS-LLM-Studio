import ETOSCore
import Foundation

/// 本地化目录、选中集合与向导值在后台生成，菜单不解码配置。
struct MacChatQuickActionPresentation: Sendable {
    struct Row: Identifiable, Sendable {
        let action: ChatQuickAction
        let title: String
        let systemImage: String
        var id: String { action.rawValue }
    }

    let rawValue: String
    let rows: [Row]
    let selectedRows: [Row]
    let selected: Set<ChatQuickAction>
    let guideValue: JSONValue
    let guideSchema: JSONValue

    init(rawValue: String) {
        self.rawValue = rawValue
        let actions = ChatQuickActionSelection.decode(rawValue)
        let selected = Set(actions)
        self.selected = selected
        rows = ChatQuickAction.allCases.map { Row(action: $0, title: $0.title, systemImage: $0.systemImage) }
        selectedRows = rows.filter { selected.contains($0.action) }
        guideValue = .array(actions.map { .string($0.rawValue) })
        guideSchema = .dictionary([
            "type": .string("array"), "minItems": .int(1), "maxItems": .int(ChatQuickAction.allCases.count),
            "uniqueItems": .bool(true), "items": .dictionary([
                "type": .string("string"), "enum": .array(ChatQuickAction.allCases.map { .string($0.rawValue) })
            ])
        ])
    }

    /// 向导输入是外部边界；拒绝未知、重复及空集合，不把错误提案当作重置全部。
    static func guideActions(_ value: JSONValue) throws -> [ChatQuickAction] {
        guard case .array(let items) = value, !items.isEmpty, items.count <= ChatQuickAction.allCases.count else {
            throw GuideError.invalidToolArguments
        }
        var actions = Set<ChatQuickAction>()
        for item in items {
            guard case .string(let id) = item, let action = ChatQuickAction(rawValue: id), actions.insert(action).inserted else {
                throw GuideError.invalidToolArguments
            }
        }
        return ChatQuickAction.allCases.filter { actions.contains($0) }
    }
}
