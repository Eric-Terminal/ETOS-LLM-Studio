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
    let toolbarRawValue: String
    let rows: [Row]
    let selectedRows: [Row]
    let selected: Set<ChatQuickAction>
    let toolbar: Set<ChatQuickAction>
    let toolbarRows: [Row]
    let menuRows: [Row]
    let guideValue: JSONValue
    let guideSchema: JSONValue

    init(rawValue: String, toolbarRawValue: String = "temporaryChat,modelPicker") {
        self.rawValue = rawValue
        self.toolbarRawValue = toolbarRawValue
        let actions = ChatQuickActionSelection.decode(rawValue)
        let selected = Set(actions)
        self.selected = selected
        let toolbar = ChatQuickActionSelection.decodeToolbarActions(toolbarRawValue)
        self.toolbar = toolbar
        rows = (actions + ChatQuickAction.allCases.filter { !selected.contains($0) })
            .map { Row(action: $0, title: $0.title, systemImage: $0.systemImage) }
        let selectedRows = Array(rows.prefix(actions.count))
        self.selectedRows = selectedRows
        toolbarRows = selectedRows.filter { toolbar.contains($0.action) }
        menuRows = selectedRows.filter { !toolbar.contains($0.action) }
        guideValue = .array(actions.map { .string($0.rawValue) })
        guideSchema = GuideChatQuickActionSettingsSupport.actionsSchema
    }

    /// 向导输入是外部边界；拒绝未知、重复及空集合，不把错误提案当作重置全部。
    static func guideActions(_ value: JSONValue) throws -> [ChatQuickAction] {
        try GuideChatQuickActionSettingsSupport.actions(from: value)
    }
}
