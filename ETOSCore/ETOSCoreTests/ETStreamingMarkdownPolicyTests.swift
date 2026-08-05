// ============================================================================
// ETStreamingMarkdownPolicyTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证流式气泡刷新分类和底部跟随的纯策略。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("流式 Markdown UI 策略")
struct ETStreamingMarkdownPolicyTests {
    @Test("连续正文和速度采样变化属于纯文本更新")
    func textAndMetricsGrowthUsesFastPath() {
        let id = UUID()
        var old = ChatMessage(id: id, role: .assistant, content: "你")
        old.responseMetrics = MessageResponseMetrics(tokenPerSecond: 12)
        var new = old
        new.content = "你好"
        new.responseMetrics = MessageResponseMetrics(tokenPerSecond: 18)

        #expect(ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: old, to: new))
    }

    @Test("正文首次出现必须刷新气泡结构")
    func firstVisibleContentIsStructural() {
        let id = UUID()
        let old = ChatMessage(id: id, role: .assistant, content: "")
        let new = ChatMessage(id: id, role: .assistant, content: "首字")

        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: old, to: new))
    }

    @Test("工具调用变化必须刷新气泡结构")
    func toolCallChangeIsStructural() {
        let id = UUID()
        let old = ChatMessage(id: id, role: .assistant, content: "正文")
        var new = old
        new.content = "正文继续"
        new.toolCalls = [InternalToolCall(id: "call", toolName: "tool", arguments: "{}")]

        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: old, to: new))
    }

    @Test("贴底且没有用户交互时维持流式底部")
    func bottomPinRequiresStreamingAndNoInteraction() {
        #expect(ETStreamingBottomPinPolicy.shouldKeepPinned(
            isStreaming: true,
            keepsBottomPinned: true,
            previousDistanceToBottom: 12,
            isUserInteracting: false
        ))
        #expect(!ETStreamingBottomPinPolicy.shouldKeepPinned(
            isStreaming: true,
            keepsBottomPinned: true,
            previousDistanceToBottom: 80,
            isUserInteracting: false
        ))
        #expect(!ETStreamingBottomPinPolicy.shouldKeepPinned(
            isStreaming: true,
            keepsBottomPinned: true,
            previousDistanceToBottom: 0,
            isUserInteracting: true
        ))
    }
}
