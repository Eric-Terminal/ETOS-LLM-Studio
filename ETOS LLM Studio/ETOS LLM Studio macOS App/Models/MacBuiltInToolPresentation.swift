import ETOSCore
import Foundation

struct MacBuiltInToolPresentation: Identifiable, Sendable {
    let state: ToolCatalogBuiltInToolState
    let title: String
    let description: String
    let status: String
    var id: ToolCatalogBuiltInToolKind { state.kind }

    init(state: ToolCatalogBuiltInToolState) {
        self.state = state
        switch state.kind {
        case .memoryWrite:
            title = NSLocalizedString("记忆系统写入", comment: "")
            description = NSLocalizedString("允许模型调用 save_memory，将有长期价值的信息写入记忆。", comment: "")
        case .memorySearch:
            title = NSLocalizedString("记忆系统主动检索", comment: "")
            description = NSLocalizedString("允许模型调用 search_memory，在回答前主动检索记忆。", comment: "")
        case .widgetCard:
            title = NSLocalizedString("显示网页卡片", comment: "")
            description = NSLocalizedString("允许模型调用 show_widget，在对话中渲染 HTML 网页卡片。", comment: "")
        case .askUserInput:
            title = NSLocalizedString("询问用户选项", comment: "")
            description = NSLocalizedString("允许模型调用 ask_user_input，在回答前向用户发起结构化问答。", comment: "")
        case .getSystemTime:
            title = NSLocalizedString("获取系统时间", comment: "")
            description = NSLocalizedString("允许模型调用 get_system_time，免审批获取当前设备时间，解决 KV 缓存时间感知问题。", comment: "")
        @unknown default:
            title = NSLocalizedString("内置工具", comment: "")
            description = NSLocalizedString("该内置工具当前可按配置参与聊天。", comment: "")
        }
        switch state.statusReason {
        case .enabled:
            status = state.kind == .memorySearch
                ? String(format: NSLocalizedString("已允许主动检索，Top K = %d。", comment: ""), state.memoryTopK)
                : NSLocalizedString("已启用", comment: "")
        case .isolatedBySession: status = NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "")
        case .memoryDisabled: status = NSLocalizedString("记忆系统总开关已关闭。", comment: "")
        case .memoryWriteDisabled: status = NSLocalizedString("当前未允许写入新的记忆。", comment: "")
        case .activeRetrievalDisabled: status = NSLocalizedString("当前未允许主动检索。", comment: "")
        case .zeroTopK: status = NSLocalizedString("当前 Top K 为 0，聊天时不会暴露检索工具。", comment: "")
        case .widgetDisabled, .askUserInputDisabled, .getSystemTimeDisabled: status = NSLocalizedString("未启用", comment: "")
        @unknown default: status = NSLocalizedString("未启用", comment: "")
        }
    }

    static func prepare(states: [ToolCatalogBuiltInToolState], query: String, enabledOnly: Bool) -> (
        rows: [MacBuiltInToolPresentation], all: [ToolCatalogBuiltInToolKind: MacBuiltInToolPresentation], guide: JSONValue
    ) {
        let all = states.map(Self.init)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = all.filter { row in
            (!enabledOnly || row.state.isConfiguredEnabled) && (query.isEmpty || row.title.localizedCaseInsensitiveContains(query)
                || row.description.localizedCaseInsensitiveContains(query))
        }
        return (rows, Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }), .array(rows.map { row in .dictionary([
            "id": .string(row.id.rawValue), "name": .string(row.title),
            "configured_enabled": .bool(row.state.isConfiguredEnabled),
            "available_in_session": .bool(row.state.isAvailableInCurrentSession), "status": .string(row.status)
        ]) }))
    }
}

extension ToolCatalogBuiltInToolKind {
    var appToolKind: AppToolKind? {
        switch self {
        case .widgetCard: .showWidget
        case .askUserInput: .askUserInput
        case .getSystemTime: .getSystemTime
        case .memoryWrite, .memorySearch: nil
        @unknown default: nil
        }
    }
}
