// ============================================================================
// ChatMessageRenderState.swift
// ============================================================================
// ChatMessageRenderState 共享模块
// - 提供跨平台复用的核心能力
// - 支撑 iOS 与 watchOS 的业务一致性
// ============================================================================

import Combine
import Foundation

@MainActor
public final class ChatMessageRenderState: ObservableObject, Identifiable {
    public let id: UUID
    public private(set) var message: ChatMessage
    @Published public private(set) var visualMessage: ChatMessage
    public private(set) var isUserContentTruncated = false
    @Published public private(set) var roleplayHTML: RoleplayHTMLExtraction?
    public private(set) var layoutRevision: UInt = 0
    public private(set) var rendererHandoffRevision: UInt = 0
    public private(set) var lastRendererHandoffAt: Date?
    /// 流式气泡一旦占用稳定宽度便不再释放，直到该消息的渲染状态被销毁。
    public private(set) var retainsStreamingAssistantWidth: Bool
    public let streamingMarkdownState: ETStreamingMarkdownRenderState
    
    public init(message: ChatMessage, defersUserContentPreparation: Bool = false) {
        self.id = message.id
        self.message = message
        var initialVisualMessage = message
        // 列表首次展示时也不能把全文交给渲染器；导出等完整展示场景不启用此占位。
        if defersUserContentPreparation, message.role == .user, !message.content.isEmpty {
            initialVisualMessage.content = "…"
        }
        self.visualMessage = initialVisualMessage
        self.roleplayHTML = nil
        self.lastRendererHandoffAt = nil
        self.retainsStreamingAssistantWidth = Self.isAssistantLoadingPlaceholder(message)
        self.streamingMarkdownState = ETStreamingMarkdownRenderState()
    }
    
    public func update(with message: ChatMessage) {
        guard self.message != message else { return }
        objectWillChange.send()
        self.message = message
        layoutRevision &+= 1
    }

    /// 流式纯文本增长只更新业务真值，由独立 Markdown 状态负责局部刷新。
    public func updateWithoutPublishing(with message: ChatMessage) {
        guard self.message != message else { return }
        self.message = message
    }

    public func updateVisualMessage(_ message: ChatMessage, isUserContentTruncated: Bool = false) {
        guard visualMessage != message || self.isUserContentTruncated != isUserContentTruncated else { return }
        layoutRevision &+= 1
        self.isUserContentTruncated = isUserContentTruncated
        visualMessage = message
    }

    public func updateRoleplayHTML(_ extraction: RoleplayHTMLExtraction?) {
        guard roleplayHTML != extraction else { return }
        layoutRevision &+= 1
        roleplayHTML = extraction
    }

    /// UIKit Markdown 与 SwiftUI 静态视图完成交接后，强制刷新气泡的测量身份。
    /// 这里不改变消息内容，只用于让懒加载容器丢弃交接期间可能缓存的旧高度。
    public func invalidateLayoutAfterRendererHandoff() {
        objectWillChange.send()
        layoutRevision &+= 1
        rendererHandoffRevision &+= 1
        lastRendererHandoffAt = Date()
    }

    public func retainStreamingAssistantWidth() {
        retainsStreamingAssistantWidth = true
    }

    private static func isAssistantLoadingPlaceholder(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && message.responseAttemptID != nil
            && message.content.isEmpty
            && (message.reasoningContent?.isEmpty ?? true)
            && (message.toolCalls?.isEmpty ?? true)
    }
}
