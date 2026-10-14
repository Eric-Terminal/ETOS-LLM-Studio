// ============================================================================
// ChatUserMessagePreview.swift
// ============================================================================
// 只用于聊天列表的用户正文预览，不参与消息持久化或模型请求。
// ============================================================================

import Foundation

public struct ChatUserMessagePreview: Sendable, Equatable {
    #if os(watchOS)
    public static let defaultCharacterLimit = 300
    #else
    public static let defaultCharacterLimit = 1_000
    #endif
    public static let characterLimitRange = 1...100_000

    /// 消息队列只读取内存设置，流式更新不能反复查询配置数据库。
    public static var configuredCharacterLimit: Int {
        guard case .integer(let value) = AppConfigStore.cachedValue(for: .userMessagePreviewCharacterLimit) else {
            return defaultCharacterLimit
        }
        return value
    }

    public let content: String
    public let isTruncated: Bool
    public let fontSnapshot: ETTextFontSnapshot

    /// 在后台准备预览；按完整字符截取，避免拆开 emoji、组合音标或 CRLF。
    public init(content: String, characterLimit: Int = ChatUserMessagePreview.defaultCharacterLimit) {
        let end = content.index(
            content.startIndex,
            offsetBy: characterLimit,
            limitedBy: content.endIndex
        ) ?? content.endIndex
        isTruncated = end < content.endIndex
        self.content = isTruncated ? String(content[..<end]) + "…" : content
        // 字体和实际预览使用相同内容，在消息进入列表前完成整段回退。
        fontSnapshot = ETTextFontSnapshot.prepare(for: self.content)
    }
}
