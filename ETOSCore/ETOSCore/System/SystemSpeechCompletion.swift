import Foundation

/// 语音权限和识别回调都可能迟于取消；先占有结果再调用系统取消，保证只恢复一次。
final class SystemSpeechCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelOperation: (() -> Void)?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installCancellation(_ operation: @escaping () -> Void) {
        lock.lock()
        if result != nil {
            lock.unlock()
            operation()
        } else {
            cancelOperation = operation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation, cancelOperation = cancelOperation
        self.continuation = nil; self.cancelOperation = nil
        lock.unlock()
        cancelOperation?()
        continuation?.resume(with: result)
    }
}
