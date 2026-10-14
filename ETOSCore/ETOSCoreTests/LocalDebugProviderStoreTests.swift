import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("调试提供商事务")
struct LocalDebugProviderStoreTests {
    @MainActor
    @Test("局部编辑使用事务内最新目录，保留后来添加的提供商及未编辑字段")
    func upsertPreservesLatestCatalog() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let server = LocalDebugServer()
        var original = Provider(name: "原提供商", baseURL: "https://example.invalid/v1", apiKeys: ["fixture-key"], apiFormat: "openai-compatible")
        original.models = [Model(modelName: "fixture-model", displayName: "原模型", isActivated: true)]
        original.apiKeyNotes = ["fixture-key": "保留备注"]
        original.headerOverrides = ["X-Fixture": "保留请求头"]
        original.maximumKeyRetries = 6
        let later = Provider(name: "后来添加", baseURL: "https://later.invalid", apiKeys: [], apiFormat: "openai-compatible")
        try fixture.store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [original, later]) }

        let result = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db) { providers in
                server.upsertDebugProvider(["provider_id": original.id.uuidString, "name": "新名称"], providers: &providers)
            }
        }
        var expected = original
        expected.name = "新名称"
        let saved = try fixture.providers()
        #expect(result.didWrite && result.removedIDs.isEmpty)
        #expect(saved.count == 2)
        #expect(saved.first { $0.id == original.id } == expected)
        #expect(saved.first { $0.id == later.id } == later)
    }

    @Test("校验失败不能把回调中修改过的草稿写入数据库")
    func failedValidationDoesNotWrite() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let original = Provider(name: "保留", baseURL: "", apiKeys: ["fixture"], apiFormat: "openai-compatible")
        try fixture.store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [original]) }
        let result = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db) { providers in
                providers.removeAll()
                return ["status": "error", "error_code": "INVALID_ARGS"]
            }
        }
        #expect(!result.didWrite && result.removedIDs.isEmpty)
        #expect(result.response["error_code"] as? String == "INVALID_ARGS")
        #expect(try fixture.providers() == [original])
    }

    @MainActor
    @Test("模型局部更新保留其他模型及未指定字段，无效模态不能提交")
    func modelUpsertPreservesUnspecifiedFields() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let server = LocalDebugServer()
        let originalModel = Model(modelName: "fixture", displayName: "旧名称", isActivated: false, prompt: "保留提示词")
        let otherModel = Model(modelName: "other", isActivated: true)
        let provider = Provider(name: "提供商", baseURL: "", apiKeys: ["fixture"], apiFormat: "openai-compatible", models: [originalModel, otherModel])
        try fixture.store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [provider]) }
        let response = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db) { providers in
                server.upsertDebugModel(["provider_id": provider.id.uuidString, "model_id": originalModel.id.uuidString,
                    "display_name": "新名称"], providers: &providers)
            }
        }
        var expected = originalModel
        expected.displayName = "新名称"
        #expect(response.didWrite)
        #expect(try fixture.providers().first?.models == [expected, otherModel])
        let invalid = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db) { providers in
                server.upsertDebugModel(["provider_id": provider.id.uuidString, "model_id": originalModel.id.uuidString,
                    "input_modalities": ["invalid"]], providers: &providers)
            }
        }
        #expect(!invalid.didWrite && invalid.response["status"] as? String == "error")
        #expect(try fixture.providers().first?.models == [expected, otherModel])
    }

    @Test("全量替换中途违反唯一约束时回滚，不能只留下部分提供商")
    func failedReplacementRollsBack() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let original = Provider(name: "保留", baseURL: "", apiKeys: ["fixture"], apiFormat: "openai-compatible")
        try fixture.store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [original]) }
        let replacement = Provider(name: "重复标识", baseURL: "", apiKeys: [], apiFormat: "openai-compatible")
        #expect(throws: (any Error).self) {
            try fixture.store.write { db in
                try LocalDebugProviderStore.apply(in: db) { providers in
                    providers = [replacement, replacement]
                    return ["status": "ok"]
                }
            }
        }
        #expect(try fixture.providers() == [original])
    }

    @Test("删除结果只包含这次事务实际移除的标识，供提交后的凭据清理使用")
    func removedIdentifiersComeFromCommittedCatalog() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let keep = Provider(name: "保留", baseURL: "", apiKeys: [], apiFormat: "openai-compatible")
        let remove = Provider(name: "删除", baseURL: "", apiKeys: [], apiFormat: "openai-compatible")
        try fixture.store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [keep, remove]) }
        let result = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db) { providers in
                providers.removeAll { $0.id == remove.id }
                return ["status": "ok"]
            }
        }
        #expect(result.didWrite && result.removedIDs == [remove.id])
        #expect(try fixture.providers() == [keep])
    }

    @Test("旧配置已读出但关系表仍为空时拒绝提交，不能清理尚未迁移的旧文件")
    func missingMigrationDoesNotCommit() throws {
        let fixture = try DebugProviderFixture()
        defer { fixture.close() }
        let replacement = Provider(name: "新配置", baseURL: "", apiKeys: [], apiFormat: "openai-compatible")
        var didMutate = false
        let result = try fixture.store.write { db in
            try LocalDebugProviderStore.apply(in: db, hasLoadedProviders: true) { providers in
                didMutate = true
                providers = [replacement]
                return ["status": "ok"]
            }
        }
        #expect(!didMutate && !result.didWrite && result.removedIDs.isEmpty)
        #expect(result.response["error_code"] as? String == "WRITE_FAILED")
        #expect(try fixture.providers().isEmpty)
    }
}

private struct DebugProviderFixture {
    let directory: URL
    let store: PersistenceAuxiliaryGRDBStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-debug-providers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceAuxiliaryGRDBStore(databaseURL: directory.appendingPathComponent("config-store.sqlite"), loggerCategory: "调试提供商测试")
    }

    func providers() throws -> [Provider] {
        try store.read { try ConfigLoader.loadProvidersFromRelationalStore($0) }
    }

    func close() {
        try? store.dbPool.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
