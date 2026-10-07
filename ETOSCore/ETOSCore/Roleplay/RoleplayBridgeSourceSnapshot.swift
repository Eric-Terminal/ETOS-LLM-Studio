import Foundation

/// 网页持有生成时的消息索引和角色来源；追加消息不改变旧索引，编辑、删除和改绑会使它失效。
public struct RoleplayBridgeSourceSnapshot: Sendable {
    let sessionID: UUID
    let binding: SessionRoleplayBinding?
    let characters: [RoleplayCharacter]
    let messages: [ChatMessage]

    public func isCurrent(service: ChatService, store: RoleplayStore = .shared) -> Bool {
        guard service.chatSessionsSubject.value.contains(where: { $0.id == sessionID }),
              store.binding(sessionID: sessionID) == binding,
              characters.allSatisfy({ store.character(id: $0.id) == $0 }) else { return false }
        let current = service.messagesSnapshot(for: sessionID)
        guard current.count >= messages.count else { return false }
        return zip(messages, current).allSatisfy { original, current in
            if original.isReceivingStream {
                return original.id == current.id && original.getCurrentVersionIndex() == current.getCurrentVersionIndex()
            }
            return original == current
        }
    }
}
