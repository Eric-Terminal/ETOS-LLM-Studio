import Darwin
import Dispatch
import Foundation

/// 接管通知描述符；取消处理与读取在同一队列串行完成，避免 fd 复用竞态。
final class LocalLinuxTerminalActivity: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let source: DispatchSourceRead

    init(descriptor: Int32) {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "ETOS.Linux.TerminalActivity", qos: .utility)
        )
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 256)
            var count: Int
            repeat {
                count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            } while count > 0 || (count < 0 && errno == EINTR)
            let ended = count == 0 || (count < 0 && errno != EAGAIN)
            // EOF 也要让消费者检查失效状态，不能把 runtime 重置误认为正常退出。
            continuation.yield(())
            if ended { continuation.finish() }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        source.resume()
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
