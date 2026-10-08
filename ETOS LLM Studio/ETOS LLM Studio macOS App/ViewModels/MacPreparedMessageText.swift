import Foundation
@preconcurrency import MarkdownUI

/// MarkdownContent 在后台构造后只读。跨执行器传递不允许重新解析或修改内部内容。
struct MacPreparedMessageText: @unchecked Sendable {
    let id = UUID()
    let source: String
    let plain: AttributedString
    let markdown: MarkdownContent?

    init(_ source: String, markdown: Bool) {
        self.source = source
        plain = AttributedString(source)
        self.markdown = markdown ? MarkdownContent(source) : nil
    }
}

/// 角色脚本可能要求重建展示行；正文未变时仍复用解析结果，避免重复解析整个历史。
struct MacMessageTextCache {
    private struct Key: Hashable {
        let messageID: UUID
        let reasoning: Bool
    }
    private var values: [Key: MacPreparedMessageText] = [:]

    mutating func prepare(_ source: String, messageID: UUID, reasoning: Bool = false,
                          markdown: Bool) -> MacPreparedMessageText {
        let key = Key(messageID: messageID, reasoning: reasoning)
        if let value = values[key], value.source == source, (value.markdown != nil) == markdown { return value }
        let value = MacPreparedMessageText(source, markdown: markdown)
        values[key] = value
        return value
    }

    mutating func retain(_ messageIDs: Set<UUID>) {
        values = values.filter { messageIDs.contains($0.key.messageID) }
    }
}
