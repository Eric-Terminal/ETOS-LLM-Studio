// ============================================================================
// MessageRegexRuleStoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证消息正则规则存储优先读取 AppConfig 快照缓存，而不是每次回读数据库。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("消息正则规则存储测试", .serialized)
struct MessageRegexRuleStoreTests {
    @MainActor
    @Test("currentRules 读取快照缓存而不是回读数据库")
    func currentRulesUsesAppConfigSnapshotCache() throws {
        let key = AppConfigKey.messageRegexRules.rawValue
        let backupSnapshotValue = AppConfigStore.shared.snapshot(includeLocalOnly: true)[key] as? String
        let backupDBValue = Persistence.readAppConfigText(key: key)

        defer {
            AppConfigStore.shared.apply(snapshot: [key: backupSnapshotValue ?? AppConfigKey.messageRegexRules.defaultValue.anyValue])
            if let backupDBValue {
                Persistence.writeAppConfig(key: key, text: backupDBValue, typeHint: AppConfigKey.messageRegexRules.typeHint)
            } else {
                Persistence.deleteAppConfig(key: key)
            }
            MessageRegexRuleStore.shared.reload()
        }

        let cachedRules = [
            MessageRegexRule(
                name: "快照规则",
                pattern: "cached",
                replacement: "snapshot",
                scopes: [.user],
                mode: .persist
            )
        ]
        let cachedRaw = String(data: try JSONEncoder().encode(cachedRules), encoding: .utf8)
        guard let cachedRaw else {
            Issue.record("无法编码测试规则")
            return
        }

        let cachedSnapshot: [String: Any] = [key: cachedRaw]
        AppConfigStore.shared.apply(snapshot: cachedSnapshot)
        MessageRegexRuleStore.shared.reload()
        Persistence.writeAppConfig(
            key: key,
            text: "[]",
            typeHint: AppConfigKey.messageRegexRules.typeHint
        )

        let loaded = MessageRegexRuleStore.currentRules()

        #expect(loaded == cachedRules)
    }
}
