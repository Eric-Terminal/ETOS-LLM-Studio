import Foundation

public extension DailyPulseManager {
    /// 桌面归档先在后台创建会话，已接受的归档须等到关联卡片也落库后才能恢复数据库或退出。
    func saveCardAsSessionInBackground(cardID: UUID, runID: UUID) async -> ChatSession? {
        await waitForPersistedStateLoad()
        guard !Task.isCancelled, let run = runs.first(where: { $0.id == runID }),
              let card = card(cardID: cardID, runID: runID) else { return nil }
        let service = chatService
        if let id = card.savedSessionID,
           let existing = service.chatSessionsSubject.value.first(where: { $0.id == id }) { return existing }
        let archive = await Task.detached(priority: .userInitiated) {
            let session = service.createSavedSession(name: card.title,
                initialMessages: [ChatMessage(role: .assistant, content: Self.archivedChatContent(for: card))],
                activate: false)
            return (session: session, topic: Self.topicText(for: card))
        }.value
        let session = archive.session
        // 取消只阻止后续导航；已经创建的会话仍需与卡片关联，避免再次保存生成重复会话。
        runs = Self.markingCardSaved(sessionID: session.id, cardID: cardID, runID: runID, in: runs)
        persistRuns()
        if card.savedSessionID == nil {
            appendFeedbackEvent(.init(dayKey: run.dayKey, topicHint: archive.topic,
                cardTitle: card.title, action: .saved))
        }
        await Self.flushPendingPersistence()
        return session
    }
}
