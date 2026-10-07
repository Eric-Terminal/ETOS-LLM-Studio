// ============================================================================
// MCPManagerPersistence.swift
// ============================================================================
// 页面配置修改在串行后台执行器读写，主线程仅应用准备好的目录和元数据。
// 保存前重新核对原配置，避免编辑器覆盖同步或其他窗口刚写入的内容。
// ============================================================================

import Foundation

struct MCPManagerStoreSnapshot {
    let servers: [MCPServerConfiguration]
    let metadata: [UUID: MCPServerMetadataCache]
    let signature: String
    let chatToolsEnabled: Bool
    let toolCallTitleEnabled: Bool

    static func load(appToolDefaults: [MCPServerConfiguration]) -> Self {
        let deleted = MCPServerStore.deletedBuiltInServerIDs()
        let search = MCPBuiltInSearchServer.prepareServersForManager(MCPServerStore.loadServers(), deletedBuiltInServerIDs: deleted)
        let app = MCPBuiltInAppToolServer.prepareServersForManager(search.servers, deletedBuiltInServerIDs: deleted, defaults: appToolDefaults)
        let personal = MCPBuiltInPersonalDataServer.prepareServersForManager(app.servers, deletedBuiltInServerIDs: deleted)
        for server in app.serversToDelete { MCPServerStore.delete(server) }
        for server in [search.serverToPersist, personal.serverToPersist].compactMap({ $0 }) + app.serversToPersist {
            MCPServerStore.save(server)
        }
        let metadata = Dictionary(uniqueKeysWithValues: personal.servers.compactMap { server in
            MCPServerStore.loadMetadata(for: server.id).map { (server.id, $0) }
        })
        return Self(
            servers: personal.servers, metadata: metadata, signature: MCPServerStore.configurationSnapshotSignature(),
            chatToolsEnabled: AppConfigStore.boolValue(for: .mcpChatToolsEnabled, defaultValue: true),
            toolCallTitleEnabled: AppConfigStore.boolValue(for: .mcpToolCallTitleEnabled, defaultValue: true)
        )
    }
}

public enum MCPConfigurationWriteError: LocalizedError, Equatable {
    case changedExternally
    case persistenceFailed
    case invalidTransport
    public var errorDescription: String? {
        switch self {
        case .changedExternally:
            NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .persistenceFailed:
            NSLocalizedString("无法保存 MCP 配置。", comment: "")
        case .invalidTransport:
            NSLocalizedString("连接配置无效，请检查地址、命令、工作目录和启动超时。", comment: "")
        }
    }
}

struct MCPConfigurationPersistenceResult {
    let revision: UInt64
    let snapshot: MCPManagerStoreSnapshot
}

actor MCPConfigurationPersistenceWorker {
    private let appToolDefaults: [MCPServerConfiguration]
    private var revision: UInt64 = 0

    init(appToolDefaults: [MCPServerConfiguration]) { self.appToolDefaults = appToolDefaults }

    func drain() {}

    func saveMetadata(_ cache: MCPServerMetadataCache, server: MCPServerConfiguration) -> Bool {
        guard MCPServerStore.loadServers().first(where: { $0.id == server.id })?.transport == server.transport else { return false }
        MCPServerStore.saveMetadata(cache, for: server.id)
        return true
    }

    func load() -> MCPConfigurationPersistenceResult {
        revision += 1
        return MCPConfigurationPersistenceResult(revision: revision, snapshot: .load(appToolDefaults: appToolDefaults))
    }

    func save(_ server: MCPServerConfiguration, replacing original: MCPServerConfiguration?) throws -> MCPConfigurationPersistenceResult {
        let existing = MCPServerStore.loadServers()
        guard existing.first(where: { $0.id == server.id }) == original else {
            throw MCPConfigurationWriteError.changedExternally
        }
        guard var materialized = MCPServerConfigurationTransferService.materializeEnvironmentReferences(in: server) else {
            throw MCPConfigurationWriteError.persistenceFailed
        }
        materialized.sortIndex = original?.sortIndex ?? ((existing.map(\.sortIndex).max() ?? -1) + 1)
        MCPServerStore.save(materialized)
        guard MCPServerStore.loadServers().contains(materialized) else {
            throw MCPConfigurationWriteError.persistenceFailed
        }
        if original?.transport != materialized.transport {
            MCPServerStore.saveMetadata(nil, for: materialized.id)
        }
        return load()
    }

    func delete(_ original: MCPServerConfiguration) throws -> MCPConfigurationPersistenceResult {
        guard MCPServerStore.loadServers().first(where: { $0.id == original.id }) == original else {
            throw MCPConfigurationWriteError.changedExternally
        }
        if MCPBuiltInAppToolServer.isBuiltInServer(original) { MCPServerStore.markBuiltInServerDeleted(original.id) }
        MCPServerStore.delete(original)
        guard !MCPServerStore.loadServers().contains(where: { $0.id == original.id }) else {
            throw MCPConfigurationWriteError.persistenceFailed
        }
        return load()
    }

    func setChatToolsEnabled(_ enabled: Bool) throws -> MCPConfigurationPersistenceResult {
        guard AppConfigStore.persistSynchronously(.bool(enabled), for: .mcpChatToolsEnabled) else {
            throw MCPConfigurationWriteError.persistenceFailed
        }
        return load()
    }
}

extension MCPManager {
    public func waitForInitialLoadIfNeeded() async {
        await initialLoadTask?.value
    }

    public func reloadServersInBackground() async {
        guard !isRestoringDatabase else { return }
        applyBackgroundStoreResult(await configurationPersistenceWorker.load())
    }

    public func saveServerInBackground(_ server: MCPServerConfiguration, replacing original: MCPServerConfiguration?) async throws {
        guard !isRestoringDatabase else { throw MCPConfigurationWriteError.changedExternally }
        let result = try await configurationPersistenceWorker.save(server, replacing: original)
        applyBackgroundStoreResult(result)
    }

    public func deleteServerInBackground(_ server: MCPServerConfiguration) async throws {
        guard !isRestoringDatabase else { throw MCPConfigurationWriteError.changedExternally }
        let result = try await configurationPersistenceWorker.delete(server)
        applyBackgroundStoreResult(result)
    }

    public func setChatToolsEnabledInBackground(_ enabled: Bool) async throws {
        guard !isRestoringDatabase else { throw MCPConfigurationWriteError.changedExternally }
        applyBackgroundStoreResult(try await configurationPersistenceWorker.setChatToolsEnabled(enabled))
        if chatToolsEnabled { connectSelectedServersIfNeeded() }
    }

    func applyBackgroundStoreResult(_ result: MCPConfigurationPersistenceResult) {
        // 数据库任务的完成顺序与主执行器恢复顺序不一定一致；旧结果不能回退界面。
        guard !isRestoringDatabase, result.revision > backgroundStoreRevision else { return }
        backgroundStoreRevision = result.revision
        applyStoreSnapshot(result.snapshot)
    }

    public func prepareForDatabaseRestore() async {
        isRestoringDatabase = true
        configObservationCancellable?.cancel()
        configObservationCancellable = nil
        cancelAllAutoConnectRetries(resetAttempts: true)
        let connections = Array(inFlightConnections.values)
        connections.forEach { $0.cancel() }
        inFlightConnections.removeAll()
        inFlightConnectionTokens.removeAll()
        for server in servers {
            cancelTrackedToolCalls(for: server.id, reason: NSLocalizedString("服务器已断开", comment: ""))
            removeLocalStdioInstances(for: server.id)
            let client = removeConnectionArtifacts(for: server.id)
            await client?.disconnect()
        }
        for connection in connections { _ = await connection.result }
        await configurationPersistenceWorker.drain()
        serverStatuses.removeAll()
        rebuildAggregates()
    }

    public func finishDatabaseRestore() async {
        isRestoringDatabase = false
        await reloadServersInBackground()
        startConfigObservationIfNeeded()
        connectSelectedServersIfNeeded()
    }
}
