import ETOSCore
import Foundation
@preconcurrency import MarkdownUI

/// MarkdownContent 在后台构造后只读。跨执行器传递不允许重新解析或修改内部内容。
struct MacPreparedMessageText: @unchecked Sendable {
    let id: UUID
    let source: String
    let plain: AttributedString
    let markdown: MarkdownContent?
    let lightRules: AttributedString?
    let darkRules: AttributedString?
    let typography: MacTextTypography
    let advanced: ETAdvancedMarkdownSource?
    let advancedEnabled: Bool
    let stream: MacStreamingMarkdownSnapshot?

    init(_ source: String, markdown: Bool, advanced: Bool = false) {
        id = UUID()
        self.source = source
        plain = AttributedString(source)
        self.markdown = markdown ? MarkdownContent(source) : nil
        lightRules = nil; darkRules = nil
        typography = .system
        advancedEnabled = advanced
        let rich = markdown && advanced ? ETAdvancedMarkdownSource(source) : nil
        self.advanced = rich?.requiresWebRenderer == true ? rich : nil
        stream = nil
    }

    init(_ source: String, stream: MacStreamingMarkdownSnapshot) {
        id = UUID(); self.source = source; plain = AttributedString(source)
        markdown = nil; lightRules = nil; darkRules = nil; typography = .system
        advanced = nil; advancedEnabled = false; self.stream = stream
    }

    init(base: MacPreparedMessageText, lightRules: AttributedString?, darkRules: AttributedString?, typography: MacTextTypography = .system) {
        id = base.id; source = base.source; plain = base.plain; markdown = base.markdown
        self.lightRules = lightRules; self.darkRules = darkRules
        self.typography = typography
        advanced = base.advanced; advancedEnabled = base.advancedEnabled; stream = base.stream
    }
}

/// 角色脚本可能要求重建展示行；正文未变时仍复用解析结果，避免重复解析整个历史。
struct MacMessageTextCache {
    private struct Key: Hashable {
        let messageID: UUID
        let reasoning: Bool
        let preview: Bool
    }
    private var values: [Key: MacPreparedMessageText] = [:]

    mutating func prepare(_ source: String, messageID: UUID, reasoning: Bool = false, preview: Bool = false,
                          markdown: Bool, advanced: Bool = false) -> MacPreparedMessageText {
        let key = Key(messageID: messageID, reasoning: reasoning, preview: preview)
        if let value = values[key], value.source == source, (value.markdown != nil) == markdown,
           value.advancedEnabled == advanced { return value }
        let value = MacPreparedMessageText(source, markdown: markdown, advanced: advanced)
        values[key] = value
        return value
    }

    mutating func retain(_ messageIDs: Set<UUID>) {
        values = values.filter { messageIDs.contains($0.key.messageID) }
    }
}

struct MacColoredTextCacheEntry {
    let light: ChatAppearanceTextStyleColors
    let dark: ChatAppearanceTextStyleColors
    let fontRevision: String
    let lineSpacing: Double
    let appliesRules: Bool
    let text: MacPreparedMessageText
}
