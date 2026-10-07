import Foundation

/// 后台完成排序与别名映射后，管理器只发布已准备好的状态。
struct ShortcutToolInitialState: Sendable {
    let chatToolsEnabled: Bool
    let tools: [ShortcutToolDefinition]
    let routes: [String: ShortcutToolDefinition]

    init(chatToolsEnabled: Bool, tools: [ShortcutToolDefinition]) {
        self.chatToolsEnabled = chatToolsEnabled
        self.tools = tools.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        var routes: [String: ShortcutToolDefinition] = [:]
        for tool in self.tools {
            routes[ShortcutToolNaming.alias(for: tool)] = tool
            routes["\(ShortcutToolManager.toolNamePrefix)\(tool.id.uuidString)"] = tool
        }
        self.routes = routes
    }
}
