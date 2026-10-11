import Foundation

/// 调度器只持有进程生命周期，不依赖移动端内核或桌面进程的具体实现。
protocol LocalCommandSession: Sendable {
    func send(_ data: Data) async throws
    func finishInput() throws
    func interrupt() throws
    func cancel() throws
    func result() async -> LocalLinuxBridgeCommandResult
}

protocol LocalTerminalSession: Sendable {
    func send(_ data: Data) async throws
    func finishInput() throws
    func resize(columns: UInt16, rows: UInt16) throws
    func interrupt() throws
    func cancel() throws
    func result() async throws -> LocalLinuxBridgeTerminalResult
}

extension iSHAppleBridgeCommandSession: LocalCommandSession {}
extension iSHAppleBridgeTerminalSession: LocalTerminalSession {}
