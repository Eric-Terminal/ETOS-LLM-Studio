import Foundation

/// 统计是可延迟的派生数据：命令只排队，页面主动刷新可以等待同一份扫描结果。
actor LocalLinuxWorkspaceSizeRefresher {
    private struct Request {
        let workspace: LocalAgentWorkspace
        let directory: URL
    }

    private struct Scan {
        let id = UUID()
        let task: Task<UInt64, Error>
    }

    private let measure: @Sendable (URL) async throws -> UInt64
    private let persist: @Sendable (LocalAgentWorkspace, UInt64) async throws -> Void
    private let coalescingDelay: Duration
    private var pending: [UUID: Request] = [:]
    private var scans: [UUID: Scan] = [:]
    private var isDraining = false

    init(
        coalescingDelay: Duration = .milliseconds(500),
        measure: @escaping @Sendable (URL) async throws -> UInt64,
        persist: @escaping @Sendable (LocalAgentWorkspace, UInt64) async throws -> Void
    ) {
        self.coalescingDelay = coalescingDelay
        self.measure = measure
        self.persist = persist
    }

    func schedule(_ workspace: LocalAgentWorkspace, directory: URL) {
        pending[workspace.id] = Request(workspace: workspace, directory: directory)
        guard !isDraining else { return }
        isDraining = true
        Task { [weak self, coalescingDelay] in
            try? await Task<Never, Never>.sleep(for: coalescingDelay)
            await self?.drain()
        }
    }

    func refresh(_ workspace: LocalAgentWorkspace, directory: URL) async throws -> UInt64 {
        if let scan = scans[workspace.id] { return try await scan.task.value }
        pending.removeValue(forKey: workspace.id)
        // 文件枚举和数据库写入都离开 storage actor，避免它们拖住后续命令的准备工作。
        let task = Task.detached(priority: .utility) { [measure, persist] in
            let size = try await measure(directory)
            try await persist(workspace, size)
            return size
        }
        let scan = Scan(task: task)
        scans[workspace.id] = scan
        defer {
            if scans[workspace.id]?.id == scan.id { scans.removeValue(forKey: workspace.id) }
        }
        return try await task.value
    }

    private func drain() async {
        while let request = pending.first?.value {
            if let scan = scans[request.workspace.id] {
                _ = try? await scan.task.value
                if scans[request.workspace.id]?.id == scan.id { scans.removeValue(forKey: request.workspace.id) }
            }
            // 已在执行的扫描未必包含最新命令的写入；等待它结束后再取合并后的请求。
            guard let next = pending.removeValue(forKey: request.workspace.id) else { continue }
            _ = try? await refresh(next.workspace, directory: next.directory)
            if !pending.isEmpty { try? await Task<Never, Never>.sleep(for: coalescingDelay) }
        }
        isDraining = false
    }
}
