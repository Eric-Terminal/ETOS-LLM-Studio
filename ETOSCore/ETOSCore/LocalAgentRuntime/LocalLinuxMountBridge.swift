import Foundation

/// 挂载管理只依赖这些内核操作，使失败路径可以在不启动真实 Linux 的情况下复验。
protocol LocalLinuxMountBridge: Sendable {
    func runtimePhase() async -> Int32
    func addMount(_ mount: LocalLinuxBridgeMount) async throws
    func removeMount(id: UUID, force: Bool) async throws
    func mounts() async throws -> [LocalLinuxBridgeMountInfo]
    func acquireMountLease(id: UUID) async throws -> iSHAppleBridgeMountLease
}

extension iSHAppleBridgeAdapter: LocalLinuxMountBridge {}
