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
    @Test("纯流式追加不会反复重建气泡，结构变化会推进布局版本")
    @MainActor
    func layoutRevisionOnlyTracksStructuralChanges() {
        let id = UUID()
        let initial = ChatMessage(id: id, role: .assistant, content: "你")
        let state = ChatMessageRenderState(message: initial)
        var streamingUpdate = initial
        streamingUpdate.content = "你好"

        state.updateWithoutPublishing(with: streamingUpdate)
        #expect(state.layoutRevision == 0)

        var structuralUpdate = streamingUpdate
        structuralUpdate.toolCalls = [InternalToolCall(id: "call", toolName: "tool", arguments: "{}")]
        state.update(with: structuralUpdate)
        #expect(state.layoutRevision == 1)
    }

    @Test("静态渲染器交接会主动使旧行高失效")
    @MainActor
    func rendererHandoffAdvancesLayoutRevision() {
        let state = ChatMessageRenderState(
            message: ChatMessage(role: .assistant, content: "静态正文")
        )

        state.invalidateLayoutAfterRendererHandoff()

        #expect(state.layoutRevision == 1)
    }

    @Test("静态 Markdown 准备完成前保留本次流式交接状态")
    @MainActor
    func staticMarkdownHandoffTracksChannels() {
        let state = ETStreamingMarkdownRenderState()
        let messageID = UUID()
        state.apply(ETStreamingMarkdownSnapshot(
            messageID: messageID,
            sourceText: "# 标题",
            revision: 1,
            committedBlocks: [],
            activeBlock: nil,
            isFinal: false
        ))

        state.beginStaticHandoff(channel: .content)

        #expect(state.isAwaitingStaticHandoff(channel: .content))
        #expect(!state.isAwaitingStaticHandoff(channel: .reasoning))
        #expect(state.snapshot(for: .content)?.sourceText == "# 标题")

        state.completeStaticHandoff(channel: .content)
        #expect(!state.isAwaitingStaticHandoff(channel: .content))

        state.beginStaticHandoff(channel: .content)
        state.clear(.content)
        #expect(!state.isAwaitingStaticHandoff(channel: .content))

        state.beginStaticHandoff(channel: .reasoning)
        state.apply(ETStreamingMarkdownSnapshot(
            messageID: messageID,
            channel: .reasoning,
            sourceText: "继续思考",
            revision: 2,
            committedBlocks: [],
            activeBlock: nil,
            isFinal: false
        ))
        #expect(!state.isAwaitingStaticHandoff(channel: .reasoning))
    }

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

    @Test("贴底且没有用户交互时维持内容底部")
    func bottomPinRequiresPinnedStateAndNoInteraction() {
        #expect(ETScrollBottomPinPolicy.shouldKeepPinned(
            keepsBottomPinned: true,
            previousDistanceToBottom: 12,
            isUserInteracting: false
        ))
        #expect(!ETScrollBottomPinPolicy.shouldKeepPinned(
            keepsBottomPinned: true,
            previousDistanceToBottom: 80,
            isUserInteracting: false
        ))
        #expect(!ETScrollBottomPinPolicy.shouldKeepPinned(
            keepsBottomPinned: true,
            previousDistanceToBottom: 0,
            isUserInteracting: true
        ))
    }
}
