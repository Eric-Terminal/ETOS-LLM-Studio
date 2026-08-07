// ============================================================================
// ChatViewModelStreamingMarkdown.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 负责把 watchOS 合并后的流式正文送入后台 Block 管线。
// ============================================================================

import ETOSCore
import Foundation

extension ChatViewModel {
    func isActivelyStreaming(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && isSendingMessage
            && latestAssistantMessageID == message.id
    }

    func canUseStreamingMarkdownFastPath(for message: ChatMessage) -> Bool {
        guard isActivelyStreaming(message) else { return false }
        let rules = MessageRegexRuleStore.shared.rules
        guard !Self.hasVisualRegexRule(in: rules, for: message) else { return false }
        guard let sessionID = currentSession?.id else { return true }
        return RoleplayStore.shared.binding(sessionID: sessionID)?.htmlRenderingEnabled != true
    }

    func scheduleStreamingMarkdownPreparation(
        for state: ChatMessageRenderState,
        sourceText: String,
        channel: ETStreamingMarkdownChannel,
        isFinal: Bool = false
    ) {
        let streamID = ETStreamingMarkdownStreamID(messageID: state.id, channel: channel)
        let generation = (streamingMarkdownPrepareGenerations[streamID] ?? 0) &+ 1
        streamingMarkdownPrepareGenerations[streamID] = generation
        streamingMarkdownPrepareTasks[streamID]?.cancel()
        streamingMarkdownPrepareTasks[streamID] = Task(priority: .userInitiated) { [weak self, weak state] in
            let snapshot = await ETStreamingMarkdownPipeline.shared.prepare(
                messageID: streamID.messageID,
                channel: channel,
                sourceText: sourceText,
                isFinal: isFinal
            )
            guard !Task.isCancelled, let self, let state else { return }
            guard self.streamingMarkdownPrepareGenerations[streamID] == generation else { return }
            state.streamingMarkdownState.apply(snapshot)
            if !isFinal {
                self.streamingScrollAnchorVersion &+= 1
            }
            self.streamingMarkdownPrepareTasks[streamID] = nil
        }
    }

    func scheduleStreamingMarkdownPreparationIfEligible(
        for state: ChatMessageRenderState,
        message: ChatMessage
    ) {
        guard canUseStreamingMarkdownFastPath(for: message) else {
            state.streamingMarkdownState.clear()
            cancelStreamingMarkdownPreparation(for: message.id)
            return
        }
        scheduleStreamingMarkdownPreparation(
            for: state,
            sourceText: message.content,
            channel: .content
        )
        scheduleStreamingMarkdownPreparation(
            for: state,
            sourceText: message.reasoningContent ?? "",
            channel: .reasoning
        )
    }

    func finalizeStreamingMarkdownIfNeeded() {
        guard let messageID = latestAssistantMessageID,
              let state = messageStateByID[messageID] else { return }
        let message = state.message
        state.streamingMarkdownState.beginStaticHandoff(channel: .content)
        state.streamingMarkdownState.beginStaticHandoff(channel: .reasoning)
        scheduleStreamingMarkdownPreparation(
            for: state,
            sourceText: message.content,
            channel: .content,
            isFinal: true
        )
        scheduleStreamingMarkdownPreparation(
            for: state,
            sourceText: message.reasoningContent ?? "",
            channel: .reasoning,
            isFinal: true
        )
        state.update(with: message)
        scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
        scheduleReasoningMarkdownPreparationIfNeeded(for: message)
    }

    func cancelStreamingMarkdownPreparation(for messageID: UUID) {
        let streamIDs = streamingMarkdownPrepareTasks.keys.filter { $0.messageID == messageID }
        for streamID in streamIDs {
            streamingMarkdownPrepareTasks[streamID]?.cancel()
            streamingMarkdownPrepareTasks.removeValue(forKey: streamID)
            streamingMarkdownPrepareGenerations.removeValue(forKey: streamID)
        }
        Task {
            await ETStreamingMarkdownPipeline.shared.remove(messageID: messageID)
        }
    }

    func cleanupStreamingMarkdownPreparation(validIDs: Set<UUID>) {
        let streamIDs = streamingMarkdownPrepareTasks.keys.filter { !validIDs.contains($0.messageID) }
        for streamID in streamIDs {
            streamingMarkdownPrepareTasks[streamID]?.cancel()
            streamingMarkdownPrepareTasks.removeValue(forKey: streamID)
            streamingMarkdownPrepareGenerations.removeValue(forKey: streamID)
        }
        Task {
            await ETStreamingMarkdownPipeline.shared.retain(messageIDs: validIDs)
        }
    }

}
