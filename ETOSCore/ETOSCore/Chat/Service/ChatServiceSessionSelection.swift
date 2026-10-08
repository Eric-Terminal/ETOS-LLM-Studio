import Combine
import Foundation

extension ChatService {
    /// 用户切换会话时先在后台读取历史；连续点选只提交最后一次选择。
    @MainActor
    public func selectSession(_ session: ChatSession?, isSelectionAllowed: @MainActor () -> Bool = { true }) async {
        guard isSelectionAllowed() else { return }
        let token = UUID()
        let sourceSessionID = currentSessionSubject.value?.id
        sessionSelectionLock.withLock { sessionSelectionToken = token }
        if currentSessionSubject.value?.id == session?.id {
            setCurrentSession(session)
            return
        }

        let messages = await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, let session else { return [ChatMessage]() }
            return self.messagesForSessionActivation(session.id)
        }.value
        // 后台读盘期间窗口可能锁定；调用方在实际发布前再次核对生命周期。
        guard !Task.isCancelled, isSelectionAllowed() else { return }
        sessionSelectionLock.withLock {
            guard sessionSelectionToken == token,
                  currentSessionSubject.value?.id == sourceSessionID else { return }
            // 后台会话可能在读盘期间继续输出，激活时采用最新运行期快照。
            let latestMessages: [ChatMessage]
            if let session, hasActiveRequestContext(for: session.id),
               let snapshot = runtimeMessagesSnapshot(for: session.id) {
                latestMessages = snapshot
            } else {
                latestMessages = messages
            }
            applyCurrentSession(session, preparedMessages: latestMessages)
        }
    }
}
