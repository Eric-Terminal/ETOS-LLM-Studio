#if os(macOS)
import Foundation

/// 客户端可先从连接缓存移除再异步断开；退出收尾必须覆盖这些仍在运行的进程。
actor MCPMacStdioProcessLifetime {
    static let shared = MCPMacStdioProcessLifetime()
    private var processes: [ObjectIdentifier: MCPMacStdioProcess] = [:]
    private var shutdownTask: Task<Void, Never>?

    func register(_ process: MCPMacStdioProcess) throws {
        guard shutdownTask == nil, processes[ObjectIdentifier(process)] == nil else { throw CancellationError() }
        processes[ObjectIdentifier(process)] = process
    }

    func remove(_ id: ObjectIdentifier) { processes[id] = nil }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let active = Array(processes.values)
        // 在首次挂起前封闭启动入口；环境变量读取或握手稍后恢复也不能启动新进程。
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for process in active { group.addTask { await process.stop() } }
            }
        }
        shutdownTask = task
        await task.value
        processes.removeAll()
    }
}
#endif
