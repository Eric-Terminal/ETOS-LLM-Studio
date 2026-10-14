#if os(macOS)
import Foundation

/// 通知只传递用户意图；Mac 在解锁并完成数据加载后执行，不在通知 delegate 中打开数据库。
public struct DailyPulseNotificationRequest: Sendable {
    public enum Action: Sendable, Equatable { case open, like, save, continueChat, addTask }
    public let action: Action
    public let runID: UUID?
    public let cardID: UUID?
    public let dayKey: String?

    public init(action: Action, runID: UUID?, cardID: UUID?, dayKey: String?) {
        self.action = action; self.runID = runID; self.cardID = cardID; self.dayKey = dayKey
    }
}
#endif
