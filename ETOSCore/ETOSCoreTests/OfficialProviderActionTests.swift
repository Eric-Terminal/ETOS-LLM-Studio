// ============================================================================
// OfficialProviderActionTests.swift
// ============================================================================
// 验证官方 Provider 配方的三方合并与动作状态表迁移。
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("官方 Provider 数据库操作测试")
struct OfficialProviderActionTests {
    private let providerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let officialModelID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @Test("三方合并更新官方字段并保留用户凭据、代理、停用状态和自建模型")
    func mergePreservesUserOwnedFields() {
        let previous = Provider(
            id: providerID,
            name: "Official v1",
            baseURL: "https://example.com/v1",
            apiKeys: ["official-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    id: officialModelID,
                    modelName: "official-chat",
                    displayName: "Official Chat v1",
                    isActivated: true
                )
            ]
        )
        let userModel = Model(modelName: "my-local-model", isActivated: true)
        var local = previous
        local.apiKeys = ["my-secret-key"]
        local.proxyConfiguration = NetworkProxyConfiguration(
            isEnabled: true,
            host: "127.0.0.1",
            port: 7890
        )
        local.models[0].isActivated = false
        local.models.append(userModel)

        var incoming = previous
        incoming.name = "Official v2"
        incoming.models[0].displayName = "Official Chat v2"
        incoming.models.append(Model(modelName: "official-image", kind: .image))

        let result = OfficialProviderThreeWayMerger.merge(
            local: local,
            previousOfficial: previous,
            incoming: incoming,
            policy: conservativePolicy,
            trigger: .manualSync,
            actionID: "official-provider.test"
        )

        #expect(result.outcome == .updated)
        #expect(result.provider?.name == "Official v2")
        #expect(result.provider?.apiKeys == ["my-secret-key"])
        #expect(result.provider?.proxyConfiguration == local.proxyConfiguration)
        #expect(result.provider?.models.first { $0.id == officialModelID }?.displayName == "Official Chat v2")
        #expect(result.provider?.models.first { $0.id == officialModelID }?.isActivated == false)
        #expect(result.provider?.models.contains { $0.id == userModel.id } == true)
        #expect(result.provider?.models.contains { $0.modelName == "official-image" } == true)
        #expect(result.preview.modelNamesToAdd == ["official-image"])
        #expect(result.preview.preservesLocalCredentials)
        #expect(result.preview.preservesLocalProxy)
        #expect(result.preview.preservesLocalModelActivation)
    }

    @Test("用户删除过官方提供商时自动同步保持删除，手动同步可恢复")
    func deletedProviderRespectsManualRestorePolicy() {
        let provider = Provider(
            id: providerID,
            name: "Official",
            baseURL: "https://example.com/v1",
            apiKeys: [],
            apiFormat: "openai-compatible"
        )

        let automatic = OfficialProviderThreeWayMerger.merge(
            local: nil,
            previousOfficial: provider,
            incoming: provider,
            policy: conservativePolicy,
            trigger: .initialSync,
            actionID: "official-provider.test"
        )
        let manual = OfficialProviderThreeWayMerger.merge(
            local: nil,
            previousOfficial: provider,
            incoming: provider,
            policy: conservativePolicy,
            trigger: .manualSync,
            actionID: "official-provider.test"
        )

        #expect(automatic.outcome == .skipped)
        #expect(automatic.provider == nil)
        #expect(manual.outcome == .restored)
        #expect(manual.provider == provider)
    }

    @Test("配置数据库包含官方操作状态表和提供商唯一索引")
    func migrationCreatesOfficialActionStateTable() throws {
        let schema = try #require(Persistence.withConfigDatabaseRead { db in
            let tableExists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'official_data_action_state'"
            ) ?? 0
            let indexExists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_official_data_action_provider'"
            ) ?? 0
            return (tableExists, indexExists)
        })

        #expect(schema.0 == 1)
        #expect(schema.1 == 1)
    }

    @Test("官方操作在既有数据库事务中直接读取 Provider 顺序")
    func providerOrderReadReusesCurrentDatabase() throws {
        let database = try DatabaseQueue()
        let expected = [providerID.uuidString, officialModelID.uuidString]
        try database.write { db in
            try db.create(table: "app_config") { table in
                table.column("key", .text).primaryKey()
                table.column("value_text", .text)
            }
            let encoded = String(
                data: try JSONSerialization.data(withJSONObject: expected),
                encoding: .utf8
            )!
            try db.execute(
                sql: "INSERT INTO app_config (key, value_text) VALUES (?, ?)",
                arguments: [AppConfigKey.providerOrderIDs.rawValue, encoded]
            )
        }

        let loaded = try database.read { db in
            try OfficialProviderActionApplier.providerOrderIDs(in: db)
        }
        #expect(loaded == expected)
    }

    private var conservativePolicy: OfficialProviderMergePolicy {
        OfficialProviderMergePolicy(
            providerFields: .updateIfUnmodified,
            apiKeys: .preserveLocalIfNonempty,
            headerOverrides: .updateIfUnmodified,
            proxyConfiguration: .preserveLocal,
            models: OfficialProviderModelMergePolicy(
                fields: .updateIfUnmodified,
                isActivated: .preserveLocal,
                onMissing: .insert,
                onRemoved: .deleteIfUnmodified,
                userModels: .preserve
            ),
            ifUserDeleted: .restoreOnManualSync
        )
    }
}
