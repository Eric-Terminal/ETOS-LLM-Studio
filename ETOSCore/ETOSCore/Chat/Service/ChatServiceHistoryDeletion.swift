import Foundation

public enum MessageHistoryDeletionKind: String, Sendable {
    case message, currentVersion, allVersions
}

extension ChatService {
    /// 原生确认框持有来源会话和原消息；确认期间切换或更新历史不能改变删除目标。
    @discardableResult
    public func deleteHistoryMessage(_ original: ChatMessage, sessionID: UUID, kind: MessageHistoryDeletionKind) -> Bool {
        guard !hasActiveRequestContext(for: sessionID), conversationSession(withID: sessionID) != nil else { return false }
        let source = messagesSnapshot(for: sessionID)
        guard let position = source.firstIndex(where: { $0.id == original.id }), source[position] == original else { return false }
        let groupID = original.responseGroupID ?? (source.contains(where: { $0.responseGroupID == original.id }) ? original.id : nil)
        if kind != .message, let groupID, let originalAttempt = original.responseAttemptID {
            guard ChatResponseAttemptSupport.selectedAttemptID(for: groupID, in: source) == originalAttempt else { return false }
        }
        switch kind {
        case .message:
            deleteMessage(original, targetSessionID: sessionID)
        case .allVersions:
            deleteAllVersions(of: original, targetSessionID: sessionID)
        case .currentVersion:
            if let groupID {
                let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: source)
                guard let selected = ChatResponseAttemptSupport.selectedAttemptID(for: groupID, in: source),
                      let index = attempts.firstIndex(of: selected),
                      let updated = ChatResponseAttemptSupport.deleteAttempt(at: index, groupID: groupID, in: source) else { return false }
                let retainedIDs = Set(updated.map(\.id))
                let deleted = source.filter { !retainedIDs.contains($0.id) }
                for message in deleted { invalidateAttachmentCache(for: message) }
                persistAndPublishMessages(updated, for: sessionID)
                scheduleStoredAttachmentCleanup(for: deleted, excludingSessionIDs: [sessionID], retainedMessages: updated)
            } else if original.hasMultipleVersions {
                var updated = source
                guard updated[position].removeVersionAndReturnCurrentIndex(at: original.getCurrentVersionIndex()) != nil else { return false }
                updateMessages(updated, for: sessionID)
            } else { deleteMessage(original, targetSessionID: sessionID) }
        }
        return true
    }
}
