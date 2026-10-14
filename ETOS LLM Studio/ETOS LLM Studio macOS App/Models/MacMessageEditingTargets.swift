import ETOSCore
import Foundation

struct MacMessageDeletionTarget {
    let message: ChatMessage
    let sessionID: UUID
    let kind: MessageHistoryDeletionKind
}

struct MacMessageEditTarget: Identifiable, Sendable {
    let message: ChatMessage
    let sessionID: UUID
    var id: String { "\(sessionID)-\(message.id)" }
}
