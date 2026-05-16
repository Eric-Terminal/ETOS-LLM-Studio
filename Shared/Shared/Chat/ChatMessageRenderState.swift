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
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则流式更新 message 时不会稳定触发 SwiftUI 刷新。
    @Published public private(set) var message: ChatMessage
    @Published public private(set) var visualMessage: ChatMessage
    
    public init(message: ChatMessage) {
        self.id = message.id
        self.message = message
        self.visualMessage = message
    }
    
    public func update(with message: ChatMessage) {
        guard self.message != message else { return }
        self.message = message
    }

    public func updateVisualMessage(_ message: ChatMessage) {
        guard visualMessage != message else { return }
        visualMessage = message
    }
}
