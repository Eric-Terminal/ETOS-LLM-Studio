import Foundation

/// 复用消息列表的回复边界，让工具结果与续写共用头像列，而只在整轮顶部绘制头像。
public struct ChatAvatarTurnPresentation: Equatable, Sendable {
    public let role: MessageRole
    public let showsAvatar: Bool

    public init(role: MessageRole, mergesWithPrevious: Bool, mergesWithNext: Bool) {
        switch role {
        case .assistant:
            self.role = .assistant
            showsAvatar = !mergesWithPrevious
        case .tool, .system:
            let belongsToTurn = mergesWithPrevious || mergesWithNext
            self.role = belongsToTurn ? .assistant : role
            showsAvatar = belongsToTurn && !mergesWithPrevious
        default:
            self.role = role
            showsAvatar = role == .user
        }
    }
}
