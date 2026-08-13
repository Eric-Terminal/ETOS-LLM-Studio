// ============================================================================
// ChatJumpTargetSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 把原始消息序号解析为聊天列表中实际存在的气泡，供跨窗口跳转复用。
// ============================================================================

import Foundation

public enum ChatJumpTargetSupport {
    public static func messageID(
        at rawMessageIndex: Int,
        in messages: [ChatMessage],
        hiddenToolCallResultIDs: Set<String>
    ) -> UUID? {
        guard messages.indices.contains(rawMessageIndex) else { return nil }
        let rawTarget = messages[rawMessageIndex]
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)

        let selectedTarget: ChatMessage?
        if visibleMessages.contains(where: { $0.id == rawTarget.id }) {
            selectedTarget = rawTarget
        } else if let groupID = rawTarget.responseGroupID {
            selectedTarget = visibleMessages.first(where: { $0.responseGroupID == groupID })
        } else {
            selectedTarget = nil
        }

        guard let selectedTarget,
              let selectedIndex = visibleMessages.firstIndex(where: { $0.id == selectedTarget.id }) else {
            return nil
        }
        if isRenderedAsBubble(selectedTarget, hiddenToolCallResultIDs: hiddenToolCallResultIDs) {
            return selectedTarget.id
        }

        // 工具结果可能已合并进助手气泡；序号仍应落到离它最近的实际气泡。
        for distance in 1..<visibleMessages.count {
            let previousIndex = selectedIndex - distance
            if visibleMessages.indices.contains(previousIndex) {
                let previous = visibleMessages[previousIndex]
                if isRenderedAsBubble(previous, hiddenToolCallResultIDs: hiddenToolCallResultIDs) {
                    return previous.id
                }
            }

            let nextIndex = selectedIndex + distance
            if visibleMessages.indices.contains(nextIndex) {
                let next = visibleMessages[nextIndex]
                if isRenderedAsBubble(next, hiddenToolCallResultIDs: hiddenToolCallResultIDs) {
                    return next.id
                }
            }
        }
        return nil
    }

    private static func isRenderedAsBubble(
        _ message: ChatMessage,
        hiddenToolCallResultIDs: Set<String>
    ) -> Bool {
        guard message.role == .tool,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return true
        }
        return toolCalls.allSatisfy { !hiddenToolCallResultIDs.contains($0.id) }
    }
}
