// ============================================================================
// MCPManagerLocalStdio.swift
// ============================================================================
// ETOS LLM Studio
//
// Agent 调用的本地 MCP 以服务器、工作区和冻结环境为实例边界。实例持有外部
// 挂载租约；工具调用只取得轻量使用租约，不限制实例或并发调用数量。
// ============================================================================

import Foundation

struct MCPLocalStdioInstanceKey: Hashable, Sendable {
    let serverID: UUID
    let workspaceID: UUID
    let environmentSnapshotHash: String
    let configurationHash: Int
}

final class MCPLocalStdioInstance: @unchecked Sendable {
    let client: MCPClient
    let relay: MCPServerNotificationRelay
    let idlePolicy: MCPLocalStdioIdlePolicy
    var activeUseCount = 0
    var idleTask: Task<Void, Never>?

    init(
        client: MCPClient,
        relay: MCPServerNotificationRelay,
        idlePolicy: MCPLocalStdioIdlePolicy
    ) {
        self.client = client
        self.relay = relay
        self.idlePolicy = idlePolicy
    }
}

@MainActor
extension MCPManager {
    func acquireLocalStdioClient(
        server: MCPServerConfiguration,
        context: AgentRuntimeContext,
        approvedCommandRuleIDs: Set<UUID>
    ) async throws -> (key: MCPLocalStdioInstanceKey, client: MCPClient) {
        guard context.selectedMCPServerIDs.contains(server.id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("该本地 MCP 不在当前 Agent Run 的冻结配置中。", comment: "Local stdio MCP not selected by Agent run")
            )
        }
        let frozenServer = context.selectedMCPServerConfigurations?
            .first(where: { $0.id == server.id }) ?? server
        guard case .localStdio(var configuration) = frozenServer.transport else {
            throw MCPClientError.notConnected
        }

        let environmentSnapshot = try await LocalLinuxProcessEnvironmentProvider.shared.snapshot(
            referenceIDs: configuration.environmentVariableIDs,
            inheritGlobalEnvironment: configuration.inheritLocalLinuxEnvironment,
            additional: configuration.environment,
            frozenGlobalValues: context.environmentValues,
            frozenReferences: context.environmentReferenceSnapshots,
            frozenRedactionValues: context.environmentRedactionValues
        )
        let workspaceID = configuration.workspaceID ?? context.workspaceID
        let workspace = try await LocalLinuxStorageManager.shared.workspace(id: workspaceID)
        let allowedMountIDs = Set(context.mountIDs)
        let mountIDs = configuration.mountIDs.filter(allowedMountIDs.contains)
        let key = MCPLocalStdioInstanceKey(
            serverID: server.id,
            workspaceID: workspace.id,
            environmentSnapshotHash: environmentSnapshot.hash,
            configurationHash: configuration.hashValue
        )
        if let instance = localStdioInstances[key] {
            instance.idleTask?.cancel()
            instance.idleTask = nil
            instance.activeUseCount += 1
            return (key, instance.client)
        }
        if let task = localStdioConnectionTasks[key] {
            let instance = try await task.value
            instance.idleTask?.cancel()
            instance.idleTask = nil
            instance.activeUseCount += 1
            return (key, instance.client)
        }

        configuration.environment = environmentSnapshot.values
        configuration.environmentVariableIDs = []
        configuration.inheritLocalLinuxEnvironment = false
        configuration.workingDirectory = workspace.guestPath
        let task = Task<MCPLocalStdioInstance, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.createLocalStdioInstance(
                server: frozenServer,
                configuration: configuration,
                frozenRedactionValues: environmentSnapshot.redactionValues,
                context: context,
                workspace: workspace,
                mountIDs: mountIDs,
                approvedCommandRuleIDs: approvedCommandRuleIDs
            )
        }
        localStdioConnectionTasks[key] = task
        do {
            let instance = try await task.value
            localStdioConnectionTasks[key] = nil
            localStdioInstances[key] = instance
            instance.activeUseCount += 1
            return (key, instance.client)
        } catch {
            localStdioConnectionTasks[key] = nil
            throw error
        }
    }

    func releaseLocalStdioClient(key: MCPLocalStdioInstanceKey) {
        guard let instance = localStdioInstances[key] else { return }
        instance.activeUseCount = max(0, instance.activeUseCount - 1)
        guard instance.activeUseCount == 0,
              let delay = instance.idlePolicy.delayNanoseconds else { return }
        instance.idleTask?.cancel()
        instance.idleTask = Task { @MainActor [weak self, weak instance] in
            if delay == 0 {
                await Task.yield()
            } else {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self,
                  let instance,
                  instance.activeUseCount == 0,
                  self.localStdioInstances[key] === instance else { return }
            self.localStdioInstances[key] = nil
            await instance.client.disconnect()
        }
    }

    func removeLocalStdioInstances(for serverID: UUID) {
        let taskKeys = localStdioConnectionTasks.keys.filter { $0.serverID == serverID }
        for key in taskKeys {
            localStdioConnectionTasks[key]?.cancel()
            localStdioConnectionTasks[key] = nil
        }
        let instanceKeys = localStdioInstances.keys.filter { $0.serverID == serverID }
        let clients = instanceKeys.compactMap { key -> MCPClient? in
            let instance = localStdioInstances.removeValue(forKey: key)
            instance?.idleTask?.cancel()
            return instance?.client
        }
        Task {
            for client in clients {
                await client.disconnect()
            }
        }
    }

    private func createLocalStdioInstance(
        server: MCPServerConfiguration,
        configuration: MCPLocalStdioConfiguration,
        frozenRedactionValues: [String],
        context: AgentRuntimeContext,
        workspace: LocalAgentWorkspace,
        mountIDs: [UUID],
        approvedCommandRuleIDs: Set<UUID>
    ) async throws -> MCPLocalStdioInstance {
        _ = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .localMCP)
        var resolvedConfiguration = configuration
        resolvedConfiguration.mountIDs = mountIDs
        let transport = MCPLocalStdioTransport(
            serverID: server.id,
            configuration: resolvedConfiguration,
            frozenRedactionValues: frozenRedactionValues,
            context: context,
            workspace: workspace,
            approvedCommandRuleIDs: approvedCommandRuleIDs
        )
        let relay = MCPServerNotificationRelay(serverID: server.id, manager: self)
        let client = MCPClient(
            transport: transport,
            notificationDelegate: relay,
            samplingHandler: samplingHandler,
            elicitationHandler: elicitationHandler,
            capabilities: clientCapabilitiesForCurrentHandlers()
        )
        do {
            _ = try await initializeLocalStdioClient(
                client,
                timeout: configuration.startupTimeoutSeconds
            )
            await transport.updateProtocolVersion(client.negotiatedProtocolVersion)
            return MCPLocalStdioInstance(
                client: client,
                relay: relay,
                idlePolicy: configuration.idlePolicy
            )
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func initializeLocalStdioClient(
        _ client: MCPClient,
        timeout: TimeInterval
    ) async throws -> MCPServerInfo {
        guard timeout > 0 else {
            return try await client.initialize(capabilities: clientCapabilitiesForCurrentHandlers())
        }
        let capabilities = clientCapabilitiesForCurrentHandlers()
        return try await withThrowingTaskGroup(of: MCPServerInfo.self) { group in
            group.addTask {
                try await client.initialize(capabilities: capabilities)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPClientError.requestTimedOut(method: "initialize", timeout: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw MCPClientError.invalidResponse
            }
            return first
        }
    }
}
