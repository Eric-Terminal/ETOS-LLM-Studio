import SwiftUI

/// 介绍页不持有 JSON 草稿，避免向导读取工具参数或沿用编辑器上下文。
public struct MessageToolCallsHelpView: View {
    public init() {}

    public var body: some View {
        SettingsHelpText(
            NSLocalizedString("使用 JSON 数组编辑调用。每项包含 id、toolName 和 arguments（JSON 对象或包含对象的字符串）；可选 result、resultDisposition 和 providerSpecificFields。新增一项即可添加调用，删除一项可移除调用，[] 表示清空。id 必须唯一，建议保留现有 id 以维持结果关联。result 为字符串，状态可为 completed、failed 或 rejected。修改会同步同轮对话中的关联结果；这些记录会用于后续聊天历史。", value: "Edit calls as a JSON array. Each item contains id, toolName, and arguments (a JSON object or a string containing one). Optional fields are result, resultDisposition, and providerSpecificFields. Add or remove items to add or remove calls; [] clears the list. IDs must be unique; keep existing IDs to preserve result links. result is a string; status can be completed, failed, or rejected. Changes update linked results in the same conversation turn and are used in subsequent chat history.", comment: "工具调用 JSON 完整教程")
            + "\n\n"
            + NSLocalizedString("返回后点击“保存”才会更新消息；保存不会执行工具。", value: "Return and tap Save to update the message. Saving does not execute tools.", comment: "工具调用 JSON 保存规则")
        )
        #if os(iOS)
        .textSelection(.enabled)
        #endif
        .guideSettingsPageContext(
            id: "message-tool-calls-introduction",
            title: NSLocalizedString("编辑说明", value: "Editing guide", comment: "工具调用介绍页标题"),
            documents: [GuideDocumentReference(id: "message-tool-call-editing", title: NSLocalizedString("工具调用 JSON", value: "Tool calls JSON", comment: ""))],
            settings: [.readOnly("read_only", label: NSLocalizedString("编辑说明", value: "Editing guide", comment: "工具调用介绍页只读状态"), value: { .bool(true) })]
        )
    }
}
