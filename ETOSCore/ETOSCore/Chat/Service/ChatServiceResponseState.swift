import Foundation

extension ChatService {
    /// 只更新对应请求的消息，避免错误替换占位后把历史回复当作正在流式生成。
    func setMessageReceivingStream(_ receiving: Bool, messageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant,
              messages[index].isReceivingStream != receiving else { return }
        messages[index].isReceivingStream = receiving
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }
}
