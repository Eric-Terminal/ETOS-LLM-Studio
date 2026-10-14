import Foundation
import Combine

extension ChatService {
    /// 编辑器保存是一次历史修改事务；后台准备关联记录，回到主线程时拒绝覆盖期间到达的新消息。
    @MainActor
    public func updateEditedMessage(_ edited: ChatMessage, original: ChatMessage, targetSessionID: UUID? = nil) async throws {
        guard let session = currentSessionSubject.value,
              targetSessionID == nil || targetSessionID == session.id,
              messagesForSessionSubject.value.first(where: { $0.id == original.id }) == original else {
            throw MessageToolCallEditingError.messageChanged
        }
        let messages = messagesForSessionSubject.value
        let updated = try await Task.detached(priority: .userInitiated) {
            let revised = try MessageToolCallEditingSupport.applying(edited, to: messages)
            return revised.flatMap { message in
                message.id == edited.id ? ChatMessageAtomicContentSupport.atomized(message) : [message]
            }
        }.value
        guard currentSessionSubject.value?.id == session.id, messagesForSessionSubject.value == messages else {
            throw MessageToolCallEditingError.messageChanged
        }
        publishMessages(updated)
        persistMessages(updated, for: session.id)
        // 图片相册也使用编辑事务；只清理已经没有任何会话引用的旧附件。
        if original.imageFileNames != edited.imageFileNames {
            invalidateAttachmentCache(for: original)
            scheduleStoredAttachmentCleanup(for: [original], excludingSessionIDs: [session.id], retainedMessages: updated)
        }
    }
}
