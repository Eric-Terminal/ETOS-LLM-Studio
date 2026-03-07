// ============================================================================
// ProviderCredentialStore.swift
// ============================================================================
// 使用共享 Keychain 保存 Provider API Key
//
// 功能特性:
// - 将敏感凭据与普通 JSON 配置分离
// - 默认使用可同步的 Keychain 项，供 iCloud 钥匙串跨设备同步
// - 提供测试替身注入点，便于验证迁移与清理逻辑
// ============================================================================

import Foundation
import os.log
#if canImport(Security)
import Security
#endif

private let providerCredentialLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "ProviderCredentialStore"
)

protocol ProviderCredentialBackingStore {
    func loadAPIKeys(for providerID: UUID) -> [String]
    func saveAPIKeys(_ apiKeys: [String], for providerID: UUID) -> Bool
    func deleteAPIKeys(for providerID: UUID) -> Bool
}

public final class ProviderCredentialStore {
    public static let shared = ProviderCredentialStore()

    static var testingOverrideStore: ProviderCredentialStore?

    private let backingStore: any ProviderCredentialBackingStore

    init(backingStore: some ProviderCredentialBackingStore = KeychainProviderCredentialBackingStore()) {
        self.backingStore = backingStore
    }

    public func loadAPIKeys(for providerID: UUID) -> [String] {
        if let overrideStore = Self.testingOverrideStore, overrideStore !== self {
            return overrideStore.loadAPIKeys(for: providerID)
        }
        return Self.normalizeAPIKeys(backingStore.loadAPIKeys(for: providerID))
    }

    @discardableResult
    public func saveAPIKeys(_ apiKeys: [String], for providerID: UUID) -> Bool {
        if let overrideStore = Self.testingOverrideStore, overrideStore !== self {
            return overrideStore.saveAPIKeys(apiKeys, for: providerID)
        }
        let normalized = Self.normalizeAPIKeys(apiKeys)
        guard !normalized.isEmpty else {
            return deleteAPIKeys(for: providerID)
        }
        return backingStore.saveAPIKeys(normalized, for: providerID)
    }

    @discardableResult
    public func deleteAPIKeys(for providerID: UUID) -> Bool {
        if let overrideStore = Self.testingOverrideStore, overrideStore !== self {
            return overrideStore.deleteAPIKeys(for: providerID)
        }
        return backingStore.deleteAPIKeys(for: providerID)
    }

    static func normalizeAPIKeys(_ apiKeys: [String]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for key in apiKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }
}

#if canImport(Security)
private struct KeychainProviderCredentialBackingStore: ProviderCredentialBackingStore {
    private static let service = "com.ericterminal.els.provider-credentials"
    private static let sharedGroupSuffix = "com.ericterminal.els.shared"
    private static let resolvedAccessGroup = resolveAccessGroup()

    func loadAPIKeys(for providerID: UUID) -> [String] {
        var query = makeBaseQuery(for: providerID, synchronizable: kSecAttrSynchronizableAny)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return [] }
            return decodeAPIKeys(from: data)
        case errSecItemNotFound:
            return []
        default:
            providerCredentialLogger.error("读取 Provider API Key 失败: \(status)")
            return []
        }
    }

    func saveAPIKeys(_ apiKeys: [String], for providerID: UUID) -> Bool {
        guard let payload = try? JSONEncoder().encode(apiKeys) else {
            providerCredentialLogger.error("编码 Provider API Key 失败。")
            return false
        }

        _ = deleteAPIKeys(for: providerID)

        var query = makeBaseQuery(for: providerID, synchronizable: kCFBooleanTrue)
        query[kSecValueData as String] = payload
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            providerCredentialLogger.error("保存 Provider API Key 到 Keychain 失败: \(status)")
            return false
        }
        return true
    }

    func deleteAPIKeys(for providerID: UUID) -> Bool {
        let query = makeBaseQuery(for: providerID, synchronizable: kSecAttrSynchronizableAny)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            providerCredentialLogger.error("删除 Provider API Key 失败: \(status)")
            return false
        }
        return true
    }

    private func makeBaseQuery(for providerID: UUID, synchronizable: CFTypeRef) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecAttrSynchronizable as String: synchronizable
        ]
        if let accessGroup = Self.resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func decodeAPIKeys(from data: Data) -> [String] {
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            providerCredentialLogger.error("解析 Keychain 中的 Provider API Key 失败。")
            return []
        }
        return ProviderCredentialStore.normalizeAPIKeys(decoded)
    }

    private static func resolveAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let entitlementValue = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) as? [String] else {
            return nil
        }
        return entitlementValue.first(where: { $0.hasSuffix(sharedGroupSuffix) }) ?? entitlementValue.first
    }
}
#else
private struct KeychainProviderCredentialBackingStore: ProviderCredentialBackingStore {
    func loadAPIKeys(for providerID: UUID) -> [String] {
        []
    }

    func saveAPIKeys(_ apiKeys: [String], for providerID: UUID) -> Bool {
        providerCredentialLogger.error("当前平台不支持 Security 框架，无法保存 Provider API Key。")
        return false
    }

    func deleteAPIKeys(for providerID: UUID) -> Bool {
        true
    }
}
#endif
