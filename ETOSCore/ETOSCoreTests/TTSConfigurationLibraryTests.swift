import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct TTSConfigurationLibraryTests {
    @Test("空数据库的朗读参数与旧设置默认值一致，旧数值按既有范围读取")
    func defaultsAndLegacyBounds() throws {
        #expect(TTSConfigurationStore.settings([:]) == .defaultValue)
        let values: [String: TTSConfigurationValue] = [
            "tts.playbackMode": .init(text: "future-mode"), "tts.providerKind": .init(text: "future-provider"),
            "tts.speechRate": .init(real: 9), "tts.pitch": .init(real: -1),
            "tts.playbackSpeed": .init(real: .infinity), "tts.watchSpeechMaxCharacters": .init(integer: 99),
            "tts.onlyReadQuotedContent": .init(integer: 1), "tts.voice": .init(text: "系统音色标识")
        ]
        let loaded = TTSConfigurationStore.settings(values)
        #expect(loaded.playbackMode == .auto); #expect(loaded.providerKind == .openAICompatible)
        #expect(loaded.speechRate == 3); #expect(loaded.pitch == 0.1)
        #expect(loaded.playbackSpeed == 1); #expect(loaded.watchSpeechMaxCharacters == 500)
        #expect(loaded.onlyReadQuotedContent); #expect(loaded.voice == "系统音色标识")
    }

    @Test("保存沿用十三个设置键及服务 JSON，保留顺序、选择、专有参数与不相关配置")
    func compatibleRoundTrip() throws {
        let db = try database()
        let original = snapshot()
        var draft = original
        draft.settings.playbackMode = .cloud; draft.settings.autoPlayAfterAssistantResponse = true
        draft.settings.watchUseLightweightPreprocess = false; draft.settings.watchSpeechMaxCharacters = 3_000
        draft.settings.pitch = 1.3; draft.settings.playbackSpeed = 1.5
        var first = service(.qwenAudio), second = service(.miniMax)
        first.advanced?.workspaceID = "workspace"; second.advanced?.pronunciationDictionary = ["重/chong2"]
        draft.services = [first, second]; draft.selectedServiceID = second.id
        let saved = try db.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES ('unrelated', 'keep', 'text', 0)")
            return try TTSConfigurationStore.save(draft, replacing: original, in: db)
        }
        #expect(saved.settings == draft.settings)
        #expect(saved.services == [first.normalized, second.normalized]); #expect(saved.selectedServiceID == second.id)
        let raw = try #require(saved.revision[AppConfigKey.ttsServiceConfiguration.rawValue]?.text)
        let payload = try JSONDecoder().decode(TTSServiceStore.Payload.self, from: Data(raw.utf8))
        #expect(payload.didMigrateLegacyModel); #expect(payload.services == saved.services)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config WHERE key LIKE 'tts.%'") } == 14)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT updated_at) FROM app_config WHERE key LIKE 'tts.%'") } == 1)
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'unrelated'") } == "keep")
    }

    @Test("仅服务密钥变化也会拒绝旧草稿，失败不会覆盖新密钥")
    func staleCredentials() throws {
        let db = try database()
        var draft = snapshot(); draft.services = [service(.openAICompatible)]
        let original = try db.write { try TTSConfigurationStore.save(draft, replacing: snapshot(), in: $0) }
        var replacement = original; replacement.services[0].apiKey = "新的秘密"
        let updated = try db.write { try TTSConfigurationStore.save(replacement, replacing: original, in: $0) }
        var stale = original; stale.settings.speechRate = 1.5
        #expect(throws: TTSConfigurationError.self) {
            try db.write { try TTSConfigurationStore.save(stale, replacing: original, in: $0) }
        }
        #expect(try db.read { try TTSConfigurationStore.rows($0) } == updated.revision)
    }

    @Test("删除或只改变存储版本都会使旧草稿失效")
    func rawRevisionDetectsDeletionAndReplacement() throws {
        for delete in [true, false] {
            let db = try database()
            let original = try db.write { try TTSConfigurationStore.save(snapshot(), replacing: snapshot(), in: $0) }
            try db.write { db in
                if delete { try db.execute(sql: "DELETE FROM app_config WHERE key = 'tts.voice'") }
                else { try db.execute(sql: "UPDATE app_config SET updated_at = updated_at + 1 WHERE key = 'tts.voice'") }
            }
            #expect(throws: TTSConfigurationError.self) {
                try db.write { try TTSConfigurationStore.save(original, replacing: original, in: $0) }
            }
        }
    }

    @Test("服务 JSON 写入失败会回滚此前写入的全部朗读设置")
    func atomicRollback() throws {
        let db = try database()
        try db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_service BEFORE INSERT ON app_config WHEN NEW.key = 'tts.serviceConfiguration' BEGIN SELECT RAISE(ABORT, '测试拒绝'); END")
        }
        #expect(throws: DatabaseError.self) {
            try db.write { try TTSConfigurationStore.save(snapshot(), replacing: snapshot(), in: $0) }
        }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config") } == 0)
    }

    @Test("损坏的已有服务数据不能被当作空列表覆盖，旧的无高级参数服务仍可读取")
    func malformedAndLegacyPayloads() throws {
        #expect(throws: DecodingError.self) { try TTSConfigurationStore.validatePayload("{\"services\":\"broken\"}") }
        var legacy = service(.openAICompatible); legacy.advanced = nil
        let raw = try TTSConfigurationStore.encode(.init(services: [legacy], selectedServiceID: legacy.id, didMigrateLegacyModel: true))
        try TTSConfigurationStore.validatePayload(raw)
        let loaded = TTSServiceStore.loadPayload(from: raw, legacySettings: .defaultValue)
        #expect(loaded.payload.services == [legacy.normalized]); #expect(loaded.payload.selectedServiceID == legacy.id)
    }

    @Test("原有不完整服务可保留，新增或编辑后的无效服务不能保存")
    func incompleteLegacyService() throws {
        let db = try database()
        let incomplete = TTSServiceConfiguration.defaultConfiguration(for: .azure).normalized
        let raw = try TTSConfigurationStore.encode(.init(services: [incomplete], selectedServiceID: incomplete.id, didMigrateLegacyModel: true))
        try db.write { try TTSConfigurationStore.write(.init(text: raw), key: AppConfigKey.ttsServiceConfiguration.rawValue, in: $0) }
        let original = TTSConfigurationSnapshot(settings: .defaultValue, services: [incomplete], selectedServiceID: incomplete.id,
            revision: try db.read { try TTSConfigurationStore.rows($0) })
        var draft = original; draft.settings.autoPlayAfterAssistantResponse = true
        let saved = try db.write { try TTSConfigurationStore.save(draft, replacing: original, in: $0) }
        #expect(saved.settings.autoPlayAfterAssistantResponse)
        var invalid = saved; invalid.services[0].name = "修改后的无效服务"
        #expect(throws: TTSConfigurationError.self) {
            try db.write { try TTSConfigurationStore.save(invalid, replacing: saved, in: $0) }
        }
    }

    private func snapshot() -> TTSConfigurationSnapshot {
        .init(settings: .defaultValue, services: [], selectedServiceID: nil, revision: [:])
    }
    private func service(_ kind: TTSProviderKind) -> TTSServiceConfiguration {
        var value = TTSServiceConfiguration.defaultConfiguration(for: kind)
        value.apiKey = "test-key"
        return value
    }
    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER, type_hint TEXT NOT NULL, updated_at REAL NOT NULL)")
        }
        return db
    }
}
