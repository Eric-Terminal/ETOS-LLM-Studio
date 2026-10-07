import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacMessageActivityTests {
    @Test("等待首包与非流式请求显示真实请求占位，历史空消息不显示思考中")
    func pendingRequiresActiveRequest() {
        let message = ChatMessage(role: .assistant, content: "")
        let active = MacMessageActivity(message: message, activeResponseID: message.id)
        #expect(active.isActive)
        #expect(active.pendingText != nil)
        #expect(!active.animatesReasoning)
        #expect(MacMessageActivity(message: message, activeResponseID: nil).pendingText == nil)
        #expect(MacMessageActivity(message: message, activeResponseID: UUID()).pendingText == nil)
    }

    @Test("思考流式期间复用核心正文抑制策略，结束后可展开并显示固定耗时")
    func reasoningTransitionAndSummary() {
        let start = Date(timeIntervalSince1970: 100)
        var message = ChatMessage(role: .assistant, content: "")
        message.reasoningContent = "正在分析"
        message.isReceivingStream = true
        message.usesRainbowThinkingSweep = true
        message.responseMetrics = .init(requestStartedAt: start, reasoningStartedAt: start)
        let streaming = MacMessageActivity(message: message, activeResponseID: message.id)
        #expect(streaming.animatesReasoning)
        #expect(streaming.suppressesReasoningContent)
        #expect(streaming.reasoningLiveSince == start)
        #expect(streaming.usesRainbow)
        #expect(streaming.pendingText == nil)
        message.responseMetrics?.reasoningCompletedAt = start.addingTimeInterval(2.9)
        message.responseMetrics?.reasoningSummary = "结论"
        let finishedReasoning = MacMessageActivity(message: message, activeResponseID: message.id)
        #expect(!finishedReasoning.animatesReasoning)
        #expect(finishedReasoning.reasoningLiveSince == nil)
        #expect(finishedReasoning.suppressesReasoningContent)
        #expect(finishedReasoning.reasoningHeader == String(format: NSLocalizedString("%ds: %@", comment: ""), 2, "结论"))
        // 服务结束标记优先于残留的 isReceivingStream，历史不持续播放动画。
        let completed = MacMessageActivity(message: message, activeResponseID: nil)
        #expect(!completed.isActive)
        #expect(!completed.suppressesReasoningContent)
        #expect(completed.reasoningHeader == finishedReasoning.reasoningHeader)
        message.responseMetrics?.responseCompletedAt = start.addingTimeInterval(3)
        #expect(!MacMessageActivity(message: message, activeResponseID: message.id).isActive)
    }

    @Test("自动重试提示随等待位置切换，停止后隐藏倒计时")
    func retriesUseCurrentMessage() {
        var message = ChatMessage(role: .assistant, content: "")
        message.requestRetryStatus = .init(attempt: 1, maximumAttempts: 3, remainingSeconds: 2)
        let pending = MacMessageActivity(message: message, activeResponseID: message.id)
        #expect(pending.pendingText == message.requestRetryStatus?.thinkingText)
        #expect(pending.retryText == nil)
        message.content = "部分正文"
        let partial = MacMessageActivity(message: message, activeResponseID: message.id)
        #expect(partial.pendingText == nil)
        #expect(partial.retryText == message.requestRetryStatus?.thinkingText)
        #expect(MacMessageActivity(message: message, activeResponseID: nil).retryText == nil)
    }

    @Test("只有请求来源变化时也更新缓存行，彩虹快照不从持久化历史恢复")
    func sourceChangeInvalidatesCachedActivity() async throws {
        let store = MacMessagePresentationStore()
        var first = ChatMessage(role: .assistant, content: "")
        first.usesRainbowThinkingSweep = true
        let second = ChatMessage(role: .assistant, content: "")
        let waiting = try await store.prepare([first, second], markdown: false, language: "en", activeResponseID: first.id)
        #expect(waiting[0].activity.isActive)
        #expect(waiting[0].activity.usesRainbow)
        #expect(!waiting[1].activity.isActive)
        let switched = try await store.prepare([first, second], markdown: false, language: "en", activeResponseID: second.id)
        #expect(!switched[0].activity.isActive)
        #expect(switched[1].activity.isActive)
        let stopped = try await store.prepare([first, second], markdown: false, language: "en")
        #expect(stopped.allSatisfy { !$0.activity.isActive })
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(first))
        #expect(!MacMessageActivity(message: restored, activeResponseID: nil).usesRainbow)
    }

    @Test("滑块展示数据在后台准备配色与最高档开关，并按实际端点判定最高档")
    func sliderAppearanceIsPreparedWithRows() throws {
        let control = ModelRequestBodyControl(id: "slider", title: "预算", kind: .optionGroup, defaultOptionID: "high", isSliderEnabled: true,
            sliderStartColorHex: "112233", sliderEndColorHex: "AABBCC", usesRainbowAtMaximum: true,
            options: [.init(id: "low", title: "低", payload: ["budget": .int(1)]), .init(id: "high", title: "高", payload: ["budget": .int(2)])])
        let provider = Provider(name: "测试", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible")
        let source = MacRequestRuntimeSource(model: .init(provider: provider, model: .init(modelName: "测试", requestBodyControls: [control])), sessionID: UUID())
        let row = try #require(MacRequestRuntimePresentation(source: source, state: .init()).rows.first)
        #expect(row.usesRainbowAtMaximum)
        #expect(row.slider?.isMaximumPosition(row.position) == true)
        #expect(row.slider?.isMaximumPosition(0.9) == false)
        #expect(ChatAppearanceColorCodec.hexRGBA(from: row.palette.color(at: 1)) == "AABBCCFF")
    }
}
