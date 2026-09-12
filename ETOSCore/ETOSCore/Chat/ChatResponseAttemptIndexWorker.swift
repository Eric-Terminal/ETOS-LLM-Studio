import Foundation

/// 正文流式增长不改变版本结构；比较和建索引均留在后台，UI 不保存正文副本用于比对。
public actor ChatResponseAttemptIndexWorker {
    public struct Snapshot: Sendable {
        public let entries: [UUID: ChatResponseAttemptVersionInfo]
        public let revision: Int
    }
    private struct Identity: Equatable {
        let id: UUID
        let role: MessageRole
        let group: UUID?
        let attempt: UUID?
        let index: Int?
        let selected: UUID?
    }

    private var sessionID: UUID?
    private var identities: [Identity] = []
    private var index: [UUID: ChatResponseAttemptVersionInfo] = [:]
    private(set) var preparationCount = 0

    public init() {}

    public func prepare(messages: [ChatMessage], sessionID: UUID?) -> Snapshot {
        let identities = messages.map {
            Identity(id: $0.id, role: $0.role, group: $0.responseGroupID, attempt: $0.responseAttemptID, index: $0.responseAttemptIndex, selected: $0.selectedResponseAttemptID)
        }
        guard self.sessionID != sessionID || self.identities != identities else {
            return Snapshot(entries: index, revision: preparationCount)
        }
        self.sessionID = sessionID
        self.identities = identities
        index = ChatResponseAttemptSupport.versionInfoByMessageID(in: messages)
        preparationCount += 1
        return Snapshot(entries: index, revision: preparationCount)
    }
}
