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
    @Published public private(set) var roleplayHTML: RoleplayHTMLExtraction?
    public let streamingMarkdownState: ETStreamingMarkdownRenderState
    
    public init(message: ChatMessage) {
        self.id = message.id
        self.message = message
        self.visualMessage = message
        self.roleplayHTML = nil
        self.streamingMarkdownState = ETStreamingMarkdownRenderState()
    }
    
    public func update(with message: ChatMessage) {
        guard self.message != message else { return }
        objectWillChange.send()
        self.message = message
    }

    /// 流式纯文本增长只更新业务真值，由独立 Markdown 状态负责局部刷新。
    public func updateWithoutPublishing(with message: ChatMessage) {
        guard self.message != message else { return }
        self.message = message
    }

    public func updateVisualMessage(_ message: ChatMessage) {
        guard visualMessage != message else { return }
        visualMessage = message
    }

    public func updateRoleplayHTML(_ extraction: RoleplayHTMLExtraction?) {
        guard roleplayHTML != extraction else { return }
        roleplayHTML = extraction
    }
}
