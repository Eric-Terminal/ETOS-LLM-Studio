// ============================================================================
// ChatUserMessagePreview.swift
// ============================================================================
// 只用于聊天列表的用户正文预览，不参与消息持久化或模型请求。
// ============================================================================

import Foundation

public struct ChatUserMessagePreview: Sendable, Equatable {
    #if os(watchOS)
    public static let characterLimit = 300
    public static let lineLimit = 8
    #else
    public static let characterLimit = 1_000
    public static let lineLimit = 12
    #endif

    public let content: String
    public let isTruncated: Bool

    /// 在后台准备预览；按完整字符截取，避免拆开 emoji、组合音标或 CRLF。
    /// 同时限制显式换行，防止字符很少但行数很多的消息撑长聊天列表。
    public init(content: String) {
        var end = content.startIndex
        var characterCount = 0
        var lineCount = 1
        while end < content.endIndex, characterCount < Self.characterLimit {
            if content[end].isNewline {
                guard lineCount < Self.lineLimit else { break }
                lineCount += 1
            }
            end = content.index(after: end)
            characterCount += 1
        }
        isTruncated = end < content.endIndex
        self.content = isTruncated ? String(content[..<end]) + "…" : content
    }
}
