import Foundation

extension ChatService {
    public func roleplayDataDraft(sessionID: UUID, target: RoleplayDataTarget) throws -> RoleplayDataDraft {
        try roleplayStore.dataDraft(sessionID: sessionID, target: target)
    }

    @discardableResult
    public func saveRoleplayDataDraft(_ original: RoleplayDataDraft, values: [String: JSONValue], matching message: ChatMessage? = nil) throws -> RoleplayDataDraft {
        guard chatSessionsSubject.value.contains(where: { $0.id == original.sessionID }) else { throw RoleplayDraftWriteError.changedExternally }
        if case .variables(.message, let messageID, let versionIndex) = original.target {
            // 版本索引会随删除/重排而变化，必须同时校验打开编辑器时的完整消息。
            guard let message, message.id == messageID, message.getCurrentVersionIndex() == versionIndex,
                  messagesSnapshot(for: original.sessionID).first(where: { $0.id == message.id }) == message else {
                throw RoleplayDraftWriteError.changedExternally
            }
        }
        return try roleplayStore.saveDataDraft(original, values: values)
    }
}
