import Combine
import ETOSCore
import Foundation

/// 发送身份仅存活于当前窗口；过期或离屏消息不会在稍后阅读历史时重新飞入。
struct MacSendMotionBatch: Sendable {
    let id: UUID
    let sessionID: UUID
    let origin: CGPoint
    let deadline: Date
    var messageIDs: Set<UUID> = []

    mutating func claim(_ messageID: UUID, sessionID: UUID?, target: CGRect, viewport: CGRect, now: Date) -> CGSize? {
        guard self.sessionID == sessionID, now < deadline, messageIDs.contains(messageID),
              target.height > 0, viewport.height > 0, target.intersects(viewport) else { return nil }
        messageIDs.remove(messageID)
        // 整屏以上的长消息直接落位，避免大面积文字经过视口产生眩晕。
        guard target.height <= viewport.height else { return nil }
        return CGSize(width: origin.x - target.midX, height: origin.y - target.midY)
    }
}

@MainActor
final class MacSendMotionModel: ObservableObject {
    @Published private(set) var revision = UUID()
    private(set) var batch: MacSendMotionBatch?
    private var preparation: Task<Void, Never>?

    func begin(sessionID: UUID, origin: CGPoint, now: Date = .now) -> UUID {
        cancel()
        let id = UUID()
        batch = .init(id: id, sessionID: sessionID, origin: origin, deadline: now.addingTimeInterval(3))
        revision = UUID()
        return id
    }

    func accept(_ presentation: ChatSendPresentation, for id: UUID) {
        guard batch?.id == id, batch?.sessionID == presentation.sessionID else { return }
        preparation?.cancel()
        preparation = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { Set(presentation.messageIDsBySource.values) }.value
            guard let self, !Task.isCancelled, batch?.id == id, batch?.sessionID == presentation.sessionID else { return }
            batch?.messageIDs = ids
            revision = UUID()
            preparation = nil
        }
    }

    func claim(_ messageID: UUID, sessionID: UUID?, target: CGRect, viewport: CGRect) -> CGSize? {
        batch?.claim(messageID, sessionID: sessionID, target: target, viewport: viewport, now: .now)
    }

    func cancel() {
        guard batch != nil || preparation != nil else { return }
        preparation?.cancel(); preparation = nil; batch = nil
        revision = UUID()
    }
}
