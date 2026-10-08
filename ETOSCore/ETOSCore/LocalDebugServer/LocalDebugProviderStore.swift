import Foundation
import GRDB

enum LocalDebugProviderStore {
    struct Result {
        let response: [String: Any]
        let removedIDs: Set<UUID>
        let didWrite: Bool
    }

    static func perform(_ mutate: (inout [Provider]) -> [String: Any]) -> [String: Any] {
        // 旧格式迁移在事务外完成；事务内重新读取最新目录，不能拿迁移前的快照覆盖并发修改。
        let hasLoadedProviders = !ConfigLoader.loadProviders().isEmpty
        guard let result = Persistence.withConfigDatabaseWrite({
            try apply(in: $0, hasLoadedProviders: hasLoadedProviders, mutate: mutate)
        }) else { return writeFailure }
        if result.didWrite {
            ConfigLoader.removeLegacyProviderBlobs()
            ConfigLoader.cleanupLegacyProviderFiles()
            for id in result.removedIDs { _ = ProviderCredentialStore.shared.deleteAPIKeys(for: id) }
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            NotificationCenter.default.post(name: .providerConfigurationDidChange, object: nil)
        }
        return result.response
    }

    static func apply(in db: Database, hasLoadedProviders: Bool = false, mutate: (inout [Provider]) -> [String: Any]) throws -> Result {
        let rawOrder = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
            arguments: [AppConfigKey.providerOrderIDs.rawValue])
        let order = rawOrder.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var providers = try ConfigLoader.loadProvidersFromRelationalStore(db, storedProviderOrderIDs: order)
        // loadProviders 可能在迁移写入失败后返回旧文件内容；不能把空关系表当作迁移成功再清理旧文件。
        // 若期间其他写入者清空了目录，本次也拒绝提交，由调用方重新读取后重试。
        guard !hasLoadedProviders || !providers.isEmpty else {
            return Result(response: writeFailure, removedIDs: [], didWrite: false)
        }
        let previousIDs = Set(providers.map(\.id))
        let response = mutate(&providers)
        guard response["status"] as? String == "ok" else {
            return Result(response: response, removedIDs: [], didWrite: false)
        }
        try ConfigLoader.replaceProvidersInRelationalStore(db, providers: providers)
        return Result(response: response, removedIDs: previousIDs.subtracting(providers.map(\.id)), didWrite: true)
    }

    private static var writeFailure: [String: Any] {
        ["status": "error", "error_code": "WRITE_FAILED",
            "message": NSLocalizedString("The provider configuration could not be saved.", comment: "调试提供商事务失败")]
    }
}
