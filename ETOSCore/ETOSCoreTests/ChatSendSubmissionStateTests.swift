import Combine
import Foundation
import Testing
@testable import ETOSCore

@MainActor
struct ChatSendSubmissionStateTests {
    @Test("提交占位同步防重，重复与错误身份操作不发布通知")
    func publishesOnlyActualSubmissionChanges() throws {
        let state = ChatSendSubmissionState()
        let sessionID = UUID()
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        #expect(!state.isPending(for: nil))
        #expect(!state.isPending(for: sessionID))
        let token = try #require(state.begin(for: sessionID))
        #expect(state.isPending(for: sessionID) && changes == 1)
        #expect(state.begin(for: sessionID) == nil)
        state.finish(for: sessionID, token: UUID())
        state.requestDidStart(for: UUID())
        #expect(state.isPending(for: sessionID) && changes == 1)
        state.finish(for: sessionID, token: token)
        #expect(!state.isPending(for: sessionID) && changes == 2)
        state.finish(for: sessionID, token: token)
        state.requestDidStart(for: sessionID)
        #expect(changes == 2)
    }

    @Test("运行状态接管后新提交使用新身份，旧任务收尾不能清除新占位")
    func oldTaskCannotReleaseNewSubmission() throws {
        let state = ChatSendSubmissionState()
        let sessionID = UUID()
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        let oldToken = try #require(state.begin(for: sessionID))
        state.requestDidStart(for: sessionID)
        #expect(!state.isPending(for: sessionID))
        let newToken = try #require(state.begin(for: sessionID))
        #expect(newToken != oldToken && changes == 3)
        state.finish(for: sessionID, token: oldToken)
        #expect(state.isPending(for: sessionID) && changes == 3)
        state.finish(for: sessionID, token: newToken)
        #expect(!state.isPending(for: sessionID) && changes == 4)
    }

    @Test("查询随所选会话切换，后台会话收尾不改变另一会话占位")
    func sessionsKeepIndependentSubmissionOwnership() throws {
        let state = ChatSendSubmissionState()
        let sessionA = UUID(), sessionB = UUID()
        let tokenA = try #require(state.begin(for: sessionA))
        #expect(state.isPending(for: sessionA) && !state.isPending(for: sessionB))
        let tokenB = try #require(state.begin(for: sessionB))
        state.finish(for: sessionB, token: tokenA)
        #expect(state.isPending(for: sessionA) && state.isPending(for: sessionB))
        state.finish(for: sessionA, token: tokenA)
        #expect(!state.isPending(for: sessionA) && state.isPending(for: sessionB))
        state.finish(for: sessionB, token: tokenB)
        #expect(!state.isPending(for: sessionB))
    }
}
