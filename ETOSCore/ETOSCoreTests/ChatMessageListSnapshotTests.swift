import Foundation
import Testing
@testable import ETOSCore

struct ChatMessageListSnapshotTests {
    @Test("首个快照带齐长短用户消息预览，编辑和改变阈值后不复用旧正文")
    func preparesUserPreviewBeforePublishing() async {
        await Task.detached {
            let short = ChatMessage(role: .user, content: "你好")
            let long = ChatMessage(role: .user, content: "A👨‍👩‍👧‍👦e\u{301}Z")
            let assistant = ChatMessage(role: .assistant, content: "回复")
            let initial = ChatMessageListSnapshot(
                messages: [short, long, assistant], sessionID: nil, previewCharacterLimit: 3
            )
            #expect(initial.userContentPreviews[short.id]?.content == "你好")
            #expect(initial.userContentPreviews[short.id]?.isTruncated == false)
            #expect(initial.userContentPreviews[long.id]?.content == "A👨‍👩‍👧‍👦e\u{301}…")
            #expect(initial.userContentPreviews[long.id]?.isTruncated == true)
            #expect(initial.userContentPreviews[assistant.id] == nil)
            var edited = long
            edited.content = "改短"
            let updated = ChatMessageListSnapshot(
                messages: [short, edited, assistant], sessionID: nil, previous: initial, previewCharacterLimit: 3
            )
            #expect(updated.userContentPreviews[edited.id]?.content == "改短")
            #expect(updated.userContentPreviews[edited.id]?.isTruncated == false)
            let enlarged = ChatMessageListSnapshot(
                messages: initial.messages, sessionID: nil, previous: initial, previewCharacterLimit: 10
            )
            #expect(enlarged.userContentPreviews[long.id]?.content == long.content)
            #expect(enlarged.userContentPreviews[long.id]?.isTruncated == false)
            let rule = MessageRegexRule(pattern: "你好", replacement: "已替换", mode: .visualOnly)
            let transformed = ChatMessageListSnapshot(
                messages: initial.messages, sessionID: nil, previous: initial,
                previewCharacterLimit: 3, visualRules: [rule]
            )
            #expect(transformed.userContentPreviews[short.id]?.content == "已替换")
            #expect(transformed.messages.first?.content == "你好")
        }.value
    }

    @Test("长会话流式增长只产生一条差异，复用版本和历史窗口索引")
    func streamingGrowthReusesStructure() async {
        await Task.detached {
            let sessionID = UUID()
            var messages = (0..<1_000).map {
                ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "消息 \($0)")
            }
            messages[999].isReceivingStream = true
            let initial = ChatMessageListSnapshot(messages: messages, sessionID: sessionID)
            messages[999].content += "继续生成"
            let updated = ChatMessageListSnapshot(messages: messages, sessionID: sessionID, previous: initial)

            #expect(updated.baseRevision == initial.revision)
            #expect(updated.changes.count == 1)
            #expect(updated.changes.first?.message.id == messages[999].id)
            #expect(updated.changes.first?.isTextOnly == true)
            #expect(!updated.historyStructureChanged)
            #expect(!updated.forceRendering)
            #expect(updated.versionRevision == initial.versionRevision)
            #expect(updated.historyIndex.positions == initial.historyIndex.positions)
            #expect(updated.visibleMessages.last?.content == messages[999].content)
        }.value
    }

    @Test("选择另一版本后同步更新可见消息、工具摘要、重试入口和历史位置")
    func selectingAttemptRebuildsAllDerivedState() {
        let sessionID = UUID()
        let firstAttempt = UUID()
        let secondAttempt = UUID()
        let user = ChatMessage(role: .user, content: "问题", selectedResponseAttemptID: firstAttempt)
        let first = ChatMessage(
            role: .assistant, content: "成功版本",
            toolCalls: [.init(id: "工具", toolName: "tool", arguments: "{}", result: "完成")],
            responseGroupID: user.id, responseAttemptID: firstAttempt, responseAttemptIndex: 0
        )
        let second = ChatMessage(
            role: .error, content: "失败版本",
            responseGroupID: user.id, responseAttemptID: secondAttempt, responseAttemptIndex: 1
        )
        let initial = ChatMessageListSnapshot(messages: [user, first, second], sessionID: sessionID)
        let selected = ChatResponseAttemptSupport.selectAttempt(
            attemptID: secondAttempt, groupID: user.id, in: initial.messages
        )
        let updated = ChatMessageListSnapshot(messages: selected, sessionID: sessionID, previous: initial)

        #expect(initial.toolCallResultIDs == ["工具"])
        #expect(updated.visibleMessages.map(\.id) == [user.id, second.id])
        #expect(updated.toolCallResultIDs.isEmpty)
        #expect(updated.agentToolPreview == nil)
        #expect(updated.canQuickRetry)
        #expect(updated.historyStructureChanged)
        #expect(updated.versionRevision > initial.versionRevision)
        #expect(updated.historyIndex.positions[first.id] == nil)
        #expect(updated.historyIndex.positions[second.id] == 1)
    }

    @Test("工具结果与错误占位变化分别刷新摘要和窗口结构")
    func toolCompletionAndFailureUpdateMetadata() {
        let sessionID = UUID()
        let user = ChatMessage(role: .user, content: "问题")
        var assistant = ChatMessage(
            role: .assistant, content: "",
            toolCalls: [.init(id: "工具", toolName: "tool", arguments: "{}")]
        )
        let initial = ChatMessageListSnapshot(messages: [user, assistant], sessionID: sessionID)
        assistant.toolCalls?[0].result = "完成"
        let finished = ChatMessageListSnapshot(messages: [user, assistant], sessionID: sessionID, previous: initial)
        #expect(finished.toolCallResultIDs == ["工具"])
        #expect(finished.agentToolPreview?.state == .completed)
        #expect(!finished.historyStructureChanged)
        #expect(finished.changes.first?.isTextOnly == false)

        let error = ChatMessage(id: assistant.id, role: .error, content: "HTTP 400")
        let failed = ChatMessageListSnapshot(messages: [user, error], sessionID: sessionID, previous: finished)
        #expect(failed.historyStructureChanged)
        #expect(failed.latestAssistantMessage == nil)
        #expect(failed.canQuickRetry)
    }

    @Test("角色渲染设置和显式刷新使缓存失效，切换会话不沿用旧差异")
    func renderingChangesAndSessionSwitchInvalidateCachedState() {
        let messages = [ChatMessage(role: .assistant, content: "<div>正文</div>")]
        let sessionID = UUID()
        let initial = ChatMessageListSnapshot(messages: messages, sessionID: sessionID)
        let refreshed = ChatMessageListSnapshot(
            messages: messages, sessionID: sessionID, previous: initial, forceRendering: true
        )
        let configured = ChatMessageListSnapshot(
            messages: messages, sessionID: sessionID, previous: refreshed,
            renderConfiguration: .init(hasRoleplay: true, rendersHTML: true)
        )
        #expect(refreshed.forceRendering)
        #expect(configured.forceRendering)
        #expect(!configured.historyStructureChanged)
        let switched = ChatMessageListSnapshot(messages: messages, sessionID: UUID(), previous: configured)
        #expect(switched.baseRevision == nil)
        #expect(!switched.hasSameMessageIdentity)
        #expect(switched.historyStructureChanged)
    }

    @Test("预计算历史索引保留工具与错误消息权重、定位及双向翻页行为")
    func preparedHistoryIndexPreservesWindowSemantics() {
        let messages: [ChatMessage] = (0..<12).flatMap { index in
            [
                ChatMessage(role: .user, content: "问题 \(index)"),
                ChatMessage(role: .assistant, content: "回复"),
                ChatMessage(role: .tool, content: "工具结果"),
                ChatMessage(role: .error, content: "中断")
            ]
        }
        let index = ChatHistoryWindowIndex(messages: messages)
        let initial = ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 3, index: index)
        #expect(initial == ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 3))
        let earlier = ChatHistoryWindowSupport.expandingEarlier(
            initial, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9, index: index
        )
        #expect(earlier == ChatHistoryWindowSupport.expandingEarlier(
            initial, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9
        ))
        #expect(ChatHistoryWindowSupport.expandingLater(
            earlier, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9, index: index
        ) == ChatHistoryWindowSupport.expandingLater(
            earlier, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9
        ))
        for messageID in [messages[0].id, messages[24].id, messages[47].id, UUID()] {
            #expect(ChatHistoryWindowSupport.position(of: messageID, in: messages, window: earlier, index: index)
                == ChatHistoryWindowSupport.position(of: messageID, in: messages, window: earlier))
            #expect(ChatHistoryWindowSupport.centered(on: messageID, in: messages, maximumWeightedCount: 9, index: index)
                == ChatHistoryWindowSupport.centered(on: messageID, in: messages, maximumWeightedCount: 9))
        }
        let appended = messages + [ChatMessage(role: .user, content: "追加问题")]
        let readingWindow = ChatHistoryWindow(lowerBound: 8, upperBound: 24)
        #expect(ChatHistoryWindowSupport.rebased(
            readingWindow, from: messages, to: appended, previousIndex: index, index: .init(messages: appended)
        ) == readingWindow)
    }
}
