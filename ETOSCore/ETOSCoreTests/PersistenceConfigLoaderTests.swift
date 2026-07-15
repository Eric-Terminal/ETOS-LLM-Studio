// ============================================================================
// PersistenceConfigLoaderTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 Provider 配置加载、SQLite 迁移与修复测试。
// ============================================================================

import Testing
import Foundation
import GRDB
@testable import ETOSCore

extension PersistenceTests {
    private struct LegacyProviderSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiKeys: [String]
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }

    private struct LegacyProviderWithoutAPIKeysSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }

    private func cleanup(providers: [Provider]) {
        for provider in providers {
            ConfigLoader.deleteProvider(provider)
        }
    }

    @Test("可选采样参数与思考摘要默认关闭")
    func testOptionalGenerationSettingsDefaultToDisabled() {
        #expect(AppConfigKey.aiTemperatureEnabled.defaultValue == .bool(false))
        #expect(AppConfigKey.aiTopPEnabled.defaultValue == .bool(false))
        #expect(AppConfigKey.enableReasoningSummary.defaultValue == .bool(false))
    }

    @Test("AppConfig 迁移标记已存在时仍补写缺失的专用模型键")
    @MainActor
    func testAppConfigBootstrapBackfillsMissingSpecializedModelKey() async throws {
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        let suiteName = "AppConfigBackfill-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let key = AppConfigKey.titleGenerationModelIdentifier
        let migrationFlagKey = "appConfig.migratedFromUserDefaults.v1"
        let legacyIdentifier = "legacy-title-model-\(UUID().uuidString)"
        let previousConfigValues = Dictionary(
            uniqueKeysWithValues: Persistence.loadAllAppConfigs().map { ($0.key, $0.value) }
        )
        let previousMigrationFlag = Persistence.readAppConfigInteger(key: migrationFlagKey)
        let previousSnapshot = AppConfigStore.shared.snapshot(includeLocalOnly: true)

        defer {
            for key in AppConfigKey.allCases {
                if let value = previousConfigValues[key.rawValue] {
                    restoreAppConfigValue(value, for: key)
                } else {
                    Persistence.deleteAppConfig(key: key.rawValue)
                }
            }
            if let previousMigrationFlag {
                Persistence.writeAppConfig(
                    key: migrationFlagKey,
                    integer: previousMigrationFlag,
                    typeHint: "integer"
                )
            } else {
                Persistence.deleteAppConfig(key: migrationFlagKey)
            }
            AppConfigStore.shared.apply(snapshot: previousSnapshot)
            defaults.removePersistentDomain(forName: suiteName)
        }

        Persistence.deleteAppConfig(key: key.rawValue)
        Persistence.writeAppConfig(key: migrationFlagKey, integer: 1, typeHint: "integer")
        defaults.set(legacyIdentifier, forKey: key.rawValue)

        let store = AppConfigStore(userDefaults: defaults)
        await store.waitForPersistentStoreLoaded()

        #expect(Persistence.readAppConfigText(key: key.rawValue) == legacyIdentifier)
    }

    @Test("延迟发送秒数默认立即发送且会归一化负值")
    @MainActor
    func testChatSendDelaySecondsDefaultAndNormalization() {
        let key = AppConfigKey.chatSendDelaySeconds
        let previousSnapshot = AppConfigStore.shared.snapshot(includeLocalOnly: true)

        defer {
            AppConfigStore.shared.apply(snapshot: previousSnapshot)
        }

        #expect(key.defaultValue == .real(0.0))

        AppConfigStore.shared.apply(snapshot: [key.rawValue: -0.5])

        #expect(AppConfigStore.shared.chatSendDelaySeconds == 0)
        #expect(AppConfigStore.shared.snapshot(includeLocalOnly: true)[key.rawValue] as? Double == 0)
    }

    private func restoreAppConfigValue(_ value: Any, for key: AppConfigKey) {
        switch key.defaultValue {
        case .bool:
            guard let value = value as? Bool else { return }
            Persistence.writeAppConfig(key: key.rawValue, integer: value ? 1 : 0, typeHint: key.typeHint)
        case .integer:
            guard let value = value as? Int else { return }
            Persistence.writeAppConfig(key: key.rawValue, integer: value, typeHint: key.typeHint)
        case .real:
            guard let value = value as? Double else { return }
            Persistence.writeAppConfig(key: key.rawValue, real: value, typeHint: key.typeHint)
        case .text:
            guard let value = value as? String else { return }
            Persistence.writeAppConfig(key: key.rawValue, text: value, typeHint: key.typeHint)
        }
    }

    private var providersDirectory: URL {
        StorageUtility.documentsDirectory
            .appendingPathComponent("Providers")
    }

    private func providerFileURL(for providerID: UUID) -> URL {
        providersDirectory.appendingPathComponent("\(providerID.uuidString).json")
    }

    private func writeLegacyProviderFile(_ provider: Provider, fileName: String) throws {
        ConfigLoader.setupInitialProviderConfigs()
        let fileURL = providersDirectory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let snapshot = LegacyProviderSnapshot(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiKeys: provider.apiKeys,
            apiFormat: provider.apiFormat,
            models: provider.models,
            headerOverrides: provider.headerOverrides
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private func writeLegacyProviderFileWithoutAPIKeys(_ provider: Provider, fileName: String) throws {
        ConfigLoader.setupInitialProviderConfigs()
        let fileURL = providersDirectory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let snapshot = LegacyProviderWithoutAPIKeysSnapshot(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiFormat: provider.apiFormat,
            models: provider.models,
            headerOverrides: provider.headerOverrides
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    @Test("保存并加载提供商时将 API Key 写入 SQLite 主存储")
    func testSaveAndLoadProvider() throws {
        let provider = Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://test.com",
            apiKeys: ["key1", "key2"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "test-model")]
        )

        ConfigLoader.saveProvider(provider)
        defer { cleanup(providers: [provider]) }

        let loadedProviders = ConfigLoader.loadProviders()
        let foundProvider = loadedProviders.first(where: { $0.id == provider.id })

        #expect(foundProvider != nil)
        #expect(foundProvider?.name == "Test Provider")
        #expect(foundProvider?.apiKeys == ["key1", "key2"])
        #expect(foundProvider?.models.first?.modelName == "test-model")
        #expect(!Persistence.auxiliaryBlobExists(forKey: "providers"))
    }

    @Test("更新提供商 API 地址时会覆盖 SQLite 旧快照")
    func testSaveProviderUpdatesBaseURLWithStaleChildRows() throws {
        var provider = Provider(
            id: UUID(),
            name: "URL Update Provider",
            baseURL: "https://old.example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "chat-model", isActivated: true)]
        )

        ConfigLoader.saveProvider(provider)
        defer { ConfigLoader.deleteProvider(provider) }

        let configDatabaseURL = Persistence.auxiliaryStoreDatabaseURL(for: .config)
        let queue = try DatabaseQueue(
            path: configDatabaseURL.path,
            configuration: Persistence.makeDatabaseConfiguration(qos: .userInitiated, mmapSize: 67_108_864)
        )
        let preparedStaleRows = try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [provider.id.uuidString])
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            return true
        }
        #expect(preparedStaleRows)

        provider.baseURL = "https://new.example.com/v1"
        ConfigLoader.saveProvider(provider)

        let loadedProvider = ConfigLoader.loadProviders().first { $0.id == provider.id }
        #expect(loadedProvider?.baseURL == "https://new.example.com/v1")
        #expect(loadedProvider?.models.map(\.modelName) == ["chat-model"])
    }

    @Test("Provider SQLite 保存失败时不会写入旧版 JSON")
    func testSaveProviderDoesNotFallbackToLegacyJSONWhenSQLiteFails() throws {
        let duplicateModelID = UUID()
        let provider = Provider(
            id: UUID(),
            name: "Invalid Duplicate Model Provider",
            baseURL: "https://invalid.example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [
                Model(id: duplicateModelID, modelName: "duplicate-a", isActivated: true),
                Model(id: duplicateModelID, modelName: "duplicate-b", isActivated: true)
            ]
        )
        let fileURL = providerFileURL(for: provider.id)
        try? FileManager.default.removeItem(at: fileURL)
        defer {
            ConfigLoader.deleteProvider(provider)
            try? FileManager.default.removeItem(at: fileURL)
        }

        ConfigLoader.saveProvider(provider)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(ConfigLoader.loadProviders().first { $0.id == provider.id } == nil)
    }

    @Test("旧 SQLite 模型没有能力记录时保留默认聊天能力")
    func testLegacySQLiteModelWithoutCapabilityRowsKeepsChatDefaults() throws {
        let providerID = UUID()
        let modelID = UUID()
        let providerName = "legacy-sqlite-\(providerID.uuidString)"

        let inserted = Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO providers (id, name, base_url, api_format, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    providerID.uuidString,
                    providerName,
                    "https://legacy-sqlite.example.com/v1",
                    "openai-compatible",
                    Date().timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO provider_api_keys (provider_id, key_index, api_key)
                VALUES (?, ?, ?)
                """,
                arguments: [providerID.uuidString, 0, "key"]
            )
            try db.execute(
                sql: """
                INSERT INTO provider_models (
                    id, provider_id, model_name, display_name, is_activated,
                    request_body_override_mode, raw_request_body_json, sort_index, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    modelID.uuidString,
                    providerID.uuidString,
                    "legacy-chat",
                    "legacy-chat",
                    1,
                    Model.RequestBodyOverrideMode.expression.rawValue,
                    nil,
                    0,
                    Date().timeIntervalSince1970
                ]
            )
            return true
        }
        #expect(inserted == true)
        defer {
            if let loaded = ConfigLoader.loadProviders().first(where: { $0.id == providerID }) {
                ConfigLoader.deleteProvider(loaded)
            }
        }

        let loadedModel = ConfigLoader.loadProviders()
            .first(where: { $0.id == providerID })?
            .models
            .first(where: { $0.id == modelID })

        #expect(loadedModel?.kind == .chat)
        #expect(loadedModel?.supportsToolCalling == true)
    }

    @Test("同步包编码会包含 Provider JSON 中的 API Key")
    func testSyncPackageEncodingContainsAPIKeys() throws {
        let package = SyncPackage(
            options: [.providers],
            providers: [
                Provider(
                    id: UUID(),
                    name: "sync-provider",
                    baseURL: "https://sync.example.com",
                    apiKeys: ["sync-key"],
                    apiFormat: "openai-compatible",
                    models: [Model(modelName: "sync-model")]
                )
            ]
        )
        let data = try JSONEncoder().encode(package)
        let payload = try #require(String(data: data, encoding: .utf8))
        #expect(payload.contains("\"apiKeys\""))
        #expect(payload.contains("sync-key"))
    }

    @Test("加载旧版无 apiKeys 字段的 Provider 文件时会迁移到 SQLite")
    func testLoadProvidersMigratesLegacyCredentialStoreToSQLite() throws {
        #expect(ConfigLoader.saveProvidersToSQLite([]))
        let provider = Provider(
            id: UUID(),
            name: "legacy-\(UUID().uuidString)",
            baseURL: "https://legacy.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "legacy-model", isActivated: true)]
        )
        let fileName = "\(provider.id.uuidString).json"

        _ = ProviderCredentialStore.shared.saveAPIKeys(["legacy-key-1", "legacy-key-2"], for: provider.id)
        try writeLegacyProviderFileWithoutAPIKeys(provider, fileName: fileName)
        defer {
            cleanup(providers: [provider])
            try? FileManager.default.removeItem(at: providerFileURL(for: provider.id))
        }

        let firstLoad = ConfigLoader.loadProviders().first(where: { $0.id == provider.id })
        #expect(firstLoad?.apiKeys == ["legacy-key-1", "legacy-key-2"])
        #expect(!Persistence.auxiliaryBlobExists(forKey: "providers"))
        #expect(ProviderCredentialStore.shared.loadAPIKeys(for: provider.id).isEmpty)

        let secondLoad = ConfigLoader.loadProviders().first(where: { $0.id == provider.id })
        #expect(secondLoad?.apiKeys == ["legacy-key-1", "legacy-key-2"])
    }

    @Test("加载提供商时会修复重复 ID 并规范化文件")
    func testLoadProvidersRepairDuplicateIDsAndNormalizeFiles() throws {
        #expect(ConfigLoader.saveProvidersToSQLite([]))
        let token = "repair-\(UUID().uuidString)"
        let duplicateProviderID = UUID()
        let duplicateModelID = UUID()

        let providerA = Provider(
            id: duplicateProviderID,
            name: "\(token)-A",
            baseURL: "https://example-a.com",
            apiKeys: ["key-a"],
            apiFormat: "openai-compatible",
            models: [
                Model(id: duplicateModelID, modelName: "a-1", isActivated: true),
                Model(id: duplicateModelID, modelName: "a-2", isActivated: false)
            ]
        )
        let providerB = Provider(
            id: duplicateProviderID,
            name: "\(token)-B",
            baseURL: "https://example-b.com",
            apiKeys: ["key-b"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "b-1", isActivated: true)]
        )

        let rawFileA = "\(token)-manual-a.json"
        let rawFileB = "\(token)-manual-b.json"
        defer {
            let createdProviders = ConfigLoader.loadProviders().filter { $0.name.hasPrefix(token) }
            cleanup(providers: createdProviders)
            try? FileManager.default.removeItem(at: providersDirectory.appendingPathComponent(rawFileA))
            try? FileManager.default.removeItem(at: providersDirectory.appendingPathComponent(rawFileB))
        }

        try writeLegacyProviderFile(providerA, fileName: rawFileA)
        try writeLegacyProviderFile(providerB, fileName: rawFileB)

        let firstLoad = ConfigLoader.loadProviders().filter { $0.name.hasPrefix(token) }
        #expect(firstLoad.count == 2)
        #expect(Set(firstLoad.map(\.id)).count == 2)
        if let repairedA = firstLoad.first(where: { $0.name == "\(token)-A" }) {
            #expect(Set(repairedA.models.map(\.id)).count == repairedA.models.count)
            #expect(repairedA.apiKeys == ["key-a"])
        } else {
            Issue.record("未找到 \(token)-A")
        }
        if let repairedB = firstLoad.first(where: { $0.name == "\(token)-B" }) {
            #expect(repairedB.apiKeys == ["key-b"])
        } else {
            Issue.record("未找到 \(token)-B")
        }

        let secondLoad = ConfigLoader.loadProviders().filter { $0.name.hasPrefix(token) }
        #expect(secondLoad.count == 2)
        #expect(Set(secondLoad.map(\.id)).count == 2)

    }
}
