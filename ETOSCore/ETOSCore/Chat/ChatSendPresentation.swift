import Foundation

/// 仅用于一次发送的画面交接，不写入消息历史或供应商请求。
public enum ChatSendPresentationSource: Hashable, Sendable {
    case text
    case image(UUID)
    case file(UUID)
    case audio(UUID)
}

public struct ChatSendPresentation: Sendable {
    public let sessionID: UUID
    public let messageIDsBySource: [ChatSendPresentationSource: UUID]
    public let responseGroupID: UUID

    public init(
        sessionID: UUID,
        messageIDsBySource: [ChatSendPresentationSource: UUID],
        responseGroupID: UUID
    ) {
        self.sessionID = sessionID
        self.messageIDsBySource = messageIDsBySource
        self.responseGroupID = responseGroupID
    }
}

public typealias ChatSendPresentationHandler = @MainActor @Sendable (ChatSendPresentation) -> Void
