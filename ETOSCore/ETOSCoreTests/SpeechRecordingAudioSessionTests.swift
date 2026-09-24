import Foundation
import Testing
@testable import ETOSCore

@Suite("录音音频会话后台启停")
struct SpeechRecordingAudioSessionTests {
    @Test("未录音时清理不触碰音频会话，启停按顺序离开主线程执行")
    @MainActor
    func sessionOperationsAreBackgroundAndOrdered() async throws {
        let events = SessionEvents()
        let session = SpeechRecordingAudioSession { active in
            #expect(!Thread.isMainThread)
            events.append(active)
        }
        session.deactivate()
        try await session.activate()
        #expect(events.snapshot == [true])
        session.deactivate()
        try await session.activate()
        #expect(events.snapshot == [true, false, true])
        session.deactivate()
    }

    @Test("激活失败会传播错误，后续清理不会停用未取得的会话")
    func activationFailureDoesNotDeactivateAnotherSession() async throws {
        enum ExpectedFailure: Error { case activation }
        let events = SessionEvents()
        let session = SpeechRecordingAudioSession { active in
            events.append(active)
            if active { throw ExpectedFailure.activation }
        }
        await #expect(throws: ExpectedFailure.self) { try await session.activate() }
        session.deactivate()
        // 第二次激活是队列屏障，确保前一次清理已经执行。
        await #expect(throws: ExpectedFailure.self) { try await session.activate() }
        #expect(events.snapshot == [true, true])
    }
}

private final class SessionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [Bool] {
        lock.withLock { values }
    }
}
