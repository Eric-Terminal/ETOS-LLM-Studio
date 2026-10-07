// ============================================================================
// MCPManagerMacStdio.swift
// ============================================================================
// Mac 的按需 stdio 保留元数据缓存，空闲时仅关闭进程。使用身份令牌隔离旧
// 调用与重新连接，避免旧调用返回后把新进程误判为空闲。
// ============================================================================

import Foundation

@MainActor
final class MCPMacStdioUsage {
    var count = 0
    var idleTask: Task<Void, Never>?
}

@MainActor
extension MCPManager {
    func beginMacStdioUse(serverID: UUID) -> MCPMacStdioUsage? {
        #if os(macOS)
        guard let server = servers.first(where: { $0.id == serverID }),
              case .localStdio(let configuration) = server.transport,
              configuration.launchPolicy == .onDemand else { return nil }
        let usage = macStdioUsage[serverID] ?? MCPMacStdioUsage()
        usage.idleTask?.cancel()
        usage.idleTask = nil
        usage.count += 1
        macStdioUsage[serverID] = usage
        return usage
        #else
        return nil
        #endif
    }

    func endMacStdioUse(serverID: UUID, usage: MCPMacStdioUsage?) {
        guard let usage, macStdioUsage[serverID] === usage else { return }
        usage.count -= 1
        guard usage.count == 0,
              let server = servers.first(where: { $0.id == serverID }),
              case .localStdio(let configuration) = server.transport,
              let delay = configuration.idlePolicy.delayNanoseconds,
              let client = clients[serverID] else { return }
        usage.idleTask = Task { @MainActor [weak self, weak usage] in
            do {
                if delay == 0 { await Task.yield() }
                else { try await Task.sleep(nanoseconds: delay) }
                try Task.checkCancellation()
            } catch { return }
            guard let self, let usage,
                  macStdioUsage[serverID] === usage,
                  usage.count == 0,
                  clients[serverID] === client else { return }
            _ = removeConnectionArtifacts(for: serverID)
            // 与手动断开不同，保留路由及工具缓存，下次调用可按需重新握手。
            await client.disconnect()
        }
    }
}
