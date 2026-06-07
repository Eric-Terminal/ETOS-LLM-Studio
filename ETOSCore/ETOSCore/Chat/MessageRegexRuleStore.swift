// ============================================================================
// MessageRegexRuleStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理聊天消息正则替换规则。
// ============================================================================

import Combine
import Foundation

private final class MessageRegexRuleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [MessageRegexRule]

    init(rules: [MessageRegexRule]) {
        self.rules = rules
    }

    func load() -> [MessageRegexRule] {
        lock.lock()
        let snapshot = rules
        lock.unlock()
        return snapshot
    }

    func store(_ rules: [MessageRegexRule]) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }
}

@MainActor
public final class MessageRegexRuleStore: ObservableObject {
    public static let shared = MessageRegexRuleStore()
    public nonisolated static let didChangeNotification = Notification.Name("com.ETOS.messageRegexRules.didChange")
    private nonisolated static let cache = MessageRegexRuleCache(rules: MessageRegexRuleStore.loadRulesFromStore())

    @Published public private(set) var rules: [MessageRegexRule]

    public init() {
        self.rules = Self.cache.load()
    }

    public func reload(notify: Bool = false) {
        let loaded = Self.loadRulesFromStore()
        Self.cache.store(loaded)
        rules = loaded
        if notify {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    public func save(_ rules: [MessageRegexRule]) {
        let normalized = Self.normalizedRules(rules)
        Self.cache.store(normalized)
        self.rules = normalized
        Self.persist(normalized)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func add(_ rule: MessageRegexRule) {
        save(rules + [rule])
    }

    public func update(_ rule: MessageRegexRule) {
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        save(updated)
    }

    public func delete(id: UUID) {
        save(rules.filter { $0.id != id })
    }

    public nonisolated static func currentRules() -> [MessageRegexRule] {
        cache.load()
    }

    public nonisolated static func loadRules() -> [MessageRegexRule] {
        loadRulesFromStore()
    }

    private nonisolated static func loadRulesFromStore() -> [MessageRegexRule] {
        guard let raw = AppConfigStore.persistentSnapshot()[AppConfigKey.messageRegexRules.rawValue] as? String,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MessageRegexRule].self, from: data) else {
            return []
        }
        return normalizedRules(decoded)
    }

    private nonisolated static func persist(_ rules: [MessageRegexRule]) {
        guard let data = try? JSONEncoder().encode(rules),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        AppConfigStore.persistSynchronously(.text(raw), for: .messageRegexRules)
    }

    private nonisolated static func normalizedRules(_ rules: [MessageRegexRule]) -> [MessageRegexRule] {
        rules.map { rule in
            var normalized = rule
            var seenScopes = Set<MessageRegexRoleScope>()
            normalized.scopes = rule.scopes.filter { seenScopes.insert($0).inserted }
            return normalized
        }
    }
}
