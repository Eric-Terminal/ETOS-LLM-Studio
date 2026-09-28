import Combine
import Foundation

/// 提交占位只通知输入组件，避免同步防重使整个聊天页失效。
@MainActor
public final class ChatSendSubmissionState: ObservableObject {
    @Published private var tokensBySessionID: [UUID: UUID] = [:]

    public init() {}

    public func isPending(for sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return tokensBySessionID[sessionID] != nil
    }

    @discardableResult
    public func begin(for sessionID: UUID) -> UUID? {
        guard tokensBySessionID[sessionID] == nil else { return nil }
        let token = UUID()
        tokensBySessionID[sessionID] = token
        return token
    }

    public func finish(for sessionID: UUID, token: UUID) {
        // Core 请求结束可能晚于同会话下一次提交，旧任务只能释放自己持有的占位。
        guard tokensBySessionID[sessionID] == token else { return }
        tokensBySessionID.removeValue(forKey: sessionID)
    }

    public func requestDidStart(for sessionID: UUID) {
        // 保留已有 running 状态接管输入的语义；它不是按提交 token 关联的 Core 回执。
        guard tokensBySessionID[sessionID] != nil else { return }
        tokensBySessionID.removeValue(forKey: sessionID)
    }
}
