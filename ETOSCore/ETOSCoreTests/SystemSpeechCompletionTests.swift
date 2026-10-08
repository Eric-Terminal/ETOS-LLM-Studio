import Foundation
import Testing
@testable import ETOSCore

struct SystemSpeechCompletionTests {
    @Test("取消先于 continuation 注册时仍立即结束，不启动识别")
    func cancelledBeforeInstallation() async {
        let completion = SystemSpeechCompletion<String>()
        completion.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(!completion.install(continuation))
            }
        }
    }

    @Test("同步成功回调后才返回识别句柄时仍释放句柄")
    func earlyCompletionReleasesLateHandle() async throws {
        let completion = SystemSpeechCompletion<String>()
        let events = SpeechCompletionEvents()
        let result = try await withCheckedThrowingContinuation { continuation in
            #expect(completion.install(continuation))
            completion.finish(.success("已识别"))
            completion.installCancellation { events.append("cancel") }
            completion.finish(.failure(CancellationError()))
        }
        #expect(result == "已识别")
        #expect(events.snapshot == ["cancel"])
    }

    @Test("取消会调用底层清理，清理触发重入回调也不会恢复两次")
    func reentrantCancellation() async {
        let completion = SystemSpeechCompletion<String>()
        let events = SpeechCompletionEvents()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(completion.install(continuation))
                completion.installCancellation {
                    events.append("cancel")
                    completion.finish(.success("迟到的结果"))
                }
                completion.finish(.failure(CancellationError()))
                completion.finish(.failure(CancellationError()))
            }
        }
        #expect(events.snapshot == ["cancel"])
    }

    @Test("两个后台终态回调竞争时只有一个结果和一次清理")
    func concurrentCallbacks() async throws {
        let completion = SystemSpeechCompletion<String>()
        let events = SpeechCompletionEvents()
        let result = try await withCheckedThrowingContinuation { continuation in
            #expect(completion.install(continuation))
            completion.installCancellation { events.append("cancel") }
            DispatchQueue.global().async { completion.finish(.success("first")) }
            DispatchQueue.global().async { completion.finish(.success("second")) }
        }
        #expect(["first", "second"].contains(result))
        #expect(events.snapshot == ["cancel"])
    }
}

private final class SpeechCompletionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}
