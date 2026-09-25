import Foundation

extension ChatService {
    @discardableResult
    func prepareThinkingSweepAppearance(
        for model: RunnableModel,
        messageID: UUID,
        sessionID: UUID
    ) async -> Bool {
        let modelKey = model.id
        let controls = model.model.requestBodyControls
        // 档位状态来自数据库，判定还会解析滑块描述；两者都不能进入 UI 渲染链路。
        let usesRainbow = await Task.detached(priority: .userInitiated) {
            ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(
                controls: controls,
                state: ModelRequestBodyControlRuntimeStore.state(forModelKey: modelKey, controls: controls)
            )
        }.value
        guard !Task.isCancelled else { return false }
        setMessageThinkingSweep(usesRainbow: usesRainbow, messageID: messageID, sessionID: sessionID)
        return usesRainbow
    }

    func setMessageThinkingSweep(usesRainbow: Bool, messageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant,
              messages[index].usesRainbowThinkingSweep != usesRainbow else { return }
        messages[index].usesRainbowThinkingSweep = usesRainbow
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }

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
