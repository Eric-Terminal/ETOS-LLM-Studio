// ============================================================================
// ConfigLoaderProviderStoreSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 ConfigLoader 的提供商持久化、迁移、归并与旧文件兼容逻辑。
// ============================================================================

import Foundation
import os.log

extension ConfigLoader {
    /// 从 SQLite 优先加载提供商配置，必要时回退旧版 JSON 并迁移到 SQLite。
    public static func loadProviders() -> [Provider] {
        let shouldMigrateToolCapability = !hasMigratedToolCapability()

        if var providers = loadProvidersFromSQLite() {
            if providers.isEmpty {
                let legacyResult = loadProvidersFromLegacyFiles(shouldMigrateToolCapability: shouldMigrateToolCapability)
                if !legacyResult.providers.isEmpty {
                    if saveProvidersToSQLite(legacyResult.providers) {
                        cleanupLegacyProviderFiles()
                    }
                    logger.info("从旧版 JSON 导入 \(legacyResult.providers.count) 个提供商到 SQLite。")
                    return legacyResult.providers
                }
            }

            var didRepair = false
            if shouldMigrateToolCapability {
                for index in providers.indices {
                    if migrateToolCallingCapabilityIfNeeded(for: &providers[index]) {
                        didRepair = true
                    }
                }
                markToolCapabilityMigrated()
            }

            if didRepair {
                _ = saveProvidersToSQLite(providers)
            }

            logger.info("正在从 SQLite 加载所有提供商，共 \(providers.count) 个。")
            return providers
        }

        logger.info("正在从 \(providersDirectory.path) 加载所有提供商...")
        let legacyResult = loadProvidersFromLegacyFiles(shouldMigrateToolCapability: shouldMigrateToolCapability)
        if shouldMigrateToolCapability, legacyResult.didScanProviderDirectory {
            markToolCapabilityMigrated()
        }

        if !legacyResult.providers.isEmpty, saveProvidersToSQLite(legacyResult.providers) {
            cleanupLegacyProviderFiles()
            logger.info("提供商配置已迁移到 SQLite。")
        }

        logger.info("总共加载了 \(legacyResult.providers.count) 个提供商。")
        return legacyResult.providers
    }

    static func loadProvidersFromLegacyFiles(shouldMigrateToolCapability: Bool) -> LegacyProviderLoadResult {
        setupInitialProviderConfigs()
        let fileManager = FileManager.default
        var providers: [Provider] = []
        var seenProviderIndexByID: [UUID: Int] = [:]
        var seenProviderSourceByID: [UUID: URL] = [:]
        var didScanProviderDirectory = false

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            didScanProviderDirectory = true
            for url in fileURLs.filter({ $0.pathExtension == "json" }) {
                do {
                    let data = try Data(contentsOf: url)
                    var provider = try JSONDecoder().decode(Provider.self, from: data)
                    var didRepair = false
                    let hintedProvider = provider.applyingInferredModelCapabilityHints()
                    if hintedProvider != provider {
                        provider = hintedProvider
                        didRepair = true
                    }
                    let fileAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)

                    if shouldMigrateToolCapability,
                       migrateToolCallingCapabilityIfNeeded(for: &provider) {
                        didRepair = true
                        logger.info("  - 已为旧模型补齐“工具”能力默认值: \(url.lastPathComponent)")
                    }

                    if deduplicateModelIDs(for: &provider) {
                        didRepair = true
                        logger.warning("  - 检测到重复模型 ID，已自动修复: \(url.lastPathComponent)")
                    }

                    if let existingIndex = seenProviderIndexByID[provider.id] {
                        let existingProvider = providers[existingIndex]
                        let existingSource = seenProviderSourceByID[provider.id]
                        let canonicalURL = canonicalProviderFileURL(for: provider.id)
                        let currentIsCanonical = isSameFileURL(url, canonicalURL)
                        let existingIsCanonical = existingSource.map { isSameFileURL($0, canonicalURL) } ?? false

                        if providersShareSamePersistentConfiguration(existingProvider, provider) {
                            let mergedAPIKeys = mergeAPIKeysPreservingOrder(
                                existingProvider.apiKeys,
                                fileAPIKeys
                            )
                            let didMergeAPIKeys = mergedAPIKeys != existingProvider.apiKeys
                            if didMergeAPIKeys {
                                providers[existingIndex].apiKeys = mergedAPIKeys
                            }

                            if !currentIsCanonical {
                                removeFileIfExists(at: url)
                                logger.warning("  - 发现重复配置并已清理冗余文件: \(url.lastPathComponent)")
                            } else if !existingIsCanonical, let existingSource {
                                removeFileIfExists(at: existingSource)
                                seenProviderSourceByID[provider.id] = url
                                logger.warning("  - 发现重复配置，已保留规范文件并清理旧文件。")
                            }

                            if didMergeAPIKeys {
                                var normalizedProvider = providers[existingIndex]
                                normalizedProvider.apiKeys = mergedAPIKeys
                                persistNormalizedProvider(normalizedProvider, sourceURL: canonicalURL)
                                seenProviderSourceByID[provider.id] = canonicalURL
                            }
                            continue
                        }

                        let oldID = provider.id
                        provider.id = UUID()
                        didRepair = true
                        logger.warning("  - 提供商 ID 冲突，已重建 ID: \(oldID.uuidString) -> \(provider.id.uuidString)")
                    }

                    let hydration = hydrateProviderCredentials(for: provider)
                    provider.apiKeys = hydration.apiKeys
                    providers.append(provider)
                    seenProviderIndexByID[provider.id] = providers.count - 1

                    let canonicalURL = canonicalProviderFileURL(for: provider.id)
                    if didRepair || hydration.shouldRewriteProviderFile || !isSameFileURL(url, canonicalURL) {
                        persistNormalizedProvider(provider, sourceURL: url)
                        seenProviderSourceByID[provider.id] = canonicalURL
                    } else {
                        seenProviderSourceByID[provider.id] = url
                    }

                    logger.info("  - 成功加载: \(url.lastPathComponent)")
                } catch {
                    logger.error("  - 解析文件失败 \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("无法读取 Providers 目录: \(error.localizedDescription)")
        }

        return LegacyProviderLoadResult(providers: providers, didScanProviderDirectory: didScanProviderDirectory)
    }

    static func persistNormalizedProvider(_ provider: Provider, sourceURL: URL) {
        persistProviderToFileOnly(provider)
        let canonicalURL = canonicalProviderFileURL(for: provider.id)
        if !isSameFileURL(sourceURL, canonicalURL) {
            removeFileIfExists(at: sourceURL)
        }
    }

    static func persistProviderToFileOnly(_ provider: Provider) {
        setupInitialProviderConfigs()
        let fileURL = canonicalProviderFileURL(for: provider.id)
        do {
            let normalizedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
            var persistedProvider = provider
            persistedProvider.apiKeys = normalizedAPIKeys

            try? FileManager.default.removeItem(at: fileURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(persistedProvider)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("写入旧版 Provider 文件失败: \(error.localizedDescription)")
        }
    }

    static func canonicalProviderFileURL(for providerID: UUID) -> URL {
        providersDirectory.appendingPathComponent("\(providerID.uuidString).json")
    }

    static func isSameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    static func removeFileIfExists(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func hasMigratedToolCapability() -> Bool {
        if AppConfigStore.boolValue(
            for: .configLoaderToolCapabilityMigrated,
            legacyUserDefaultsKey: toolCapabilityMigrationFlagKey
        ) {
            return true
        }
        return AppConfigStore.boolValue(
            for: .configLoaderToolCapabilityMigrated,
            legacyUserDefaultsKey: legacyToolCapabilityMigrationFlagKey
        )
    }

    static func markToolCapabilityMigrated() {
        _ = AppConfigStore.persistSynchronously(
            .bool(true),
            for: .configLoaderToolCapabilityMigrated,
            quickSync: false
        )
    }

    static func cleanupLegacyProviderFiles() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: providersDirectory.path) else { return }

        do {
            let files = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
                try? fileManager.removeItem(at: fileURL)
            }
            let remaining = try fileManager.contentsOfDirectory(atPath: providersDirectory.path)
            if remaining.isEmpty {
                try? fileManager.removeItem(at: providersDirectory)
            }
        } catch {
            logger.error("清理旧版 Provider JSON 文件失败: \(error.localizedDescription)")
        }
    }

    static func deduplicateModelIDs(for provider: inout Provider) -> Bool {
        var seenModelIDs = Set<UUID>()
        var didRepair = false
        for index in provider.models.indices {
            let modelID = provider.models[index].id
            if seenModelIDs.contains(modelID) {
                provider.models[index].id = UUID()
                didRepair = true
            }
            seenModelIDs.insert(provider.models[index].id)
        }
        return didRepair
    }

    static func migrateToolCallingCapabilityIfNeeded(for provider: inout Provider) -> Bool {
        var didRepair = false
        for index in provider.models.indices {
            var capabilitySet = Set(provider.models[index].capabilities)
            guard provider.models[index].kind == .chat else { continue }
            guard !capabilitySet.contains(.toolCalling) else { continue }
            capabilitySet.insert(.toolCalling)
            provider.models[index].capabilities = Model.orderedCapabilities(Array(capabilitySet))
            didRepair = true
        }
        return didRepair
    }

    static func encodeRawValues<T: RawRepresentable>(_ values: [T]) -> String where T.RawValue == String {
        let rawValues = values.map(\.rawValue)
        guard let data = try? jsonEncoder.encode(rawValues),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeJSON<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        guard let text,
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? jsonDecoder.decode(T.self, from: data)
    }

    static func decodeRawValues<T: RawRepresentable>(_ text: String?, as type: T.Type) -> [T]? where T.RawValue == String {
        guard let text,
              let data = text.data(using: .utf8),
              let rawValues = try? jsonDecoder.decode([String].self, from: data) else {
            return nil
        }
        return rawValues.compactMap(T.init(rawValue:))
    }

    public static func saveProvider(_ provider: Provider) {
        let normalizedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
        var persistedProvider = provider
        persistedProvider.apiKeys = normalizedAPIKeys

        var providers = loadProviders()
        let previousProvider = providers.first(where: { $0.id == persistedProvider.id })
        if let index = providers.firstIndex(where: { $0.id == persistedProvider.id }) {
            providers[index] = persistedProvider
        } else {
            providers.append(persistedProvider)
        }

        if saveProvidersToSQLite(providers) {
            cleanupLegacyProviderFiles()
            logger.info("已保存提供商 \(persistedProvider.name) 到 SQLite。")
        } else {
            let fileURL = providersDirectory.appendingPathComponent("\(persistedProvider.id.uuidString).json")
            logger.info("正在回退保存提供商 \(persistedProvider.name) 到 \(fileURL.path)")
            persistProviderToFileOnly(persistedProvider)
            logger.info("  - 回退保存成功。")
        }

        let changedFields = changedFieldsForProviderUpdate(old: previousProvider, new: persistedProvider)
        let action = previousProvider == nil ? "新增提供商配置" : "更新提供商配置"
        var payload: [String: String] = [
            "providerID": persistedProvider.id.uuidString,
            "providerName": persistedProvider.name,
            "apiFormat": persistedProvider.apiFormat,
            "baseURL": persistedProvider.baseURL,
            "modelCount": "\(persistedProvider.models.count)",
            "headerCount": "\(persistedProvider.headerOverrides.count)",
            "apiKeyCount": "\(normalizedAPIKeys.count)",
            "changedFields": changedFields.joined(separator: "、")
        ]
        if !persistedProvider.headerOverrides.isEmpty {
            let sortedHeaderKeys = persistedProvider.headerOverrides.keys.sorted().joined(separator: ", ")
            payload["headerKeys"] = sortedHeaderKeys
        }

        AppLog.userOperation(
            category: "配置",
            action: action,
            payload: payload
        )
        AppLog.developer(
            category: "config",
            action: action,
            message: "提供商配置已保存：\(persistedProvider.name)",
            payload: payload
        )
    }

    public static func deleteProvider(_ provider: Provider) {
        var providers = loadProviders()
        providers.removeAll { $0.id == provider.id }

        if saveProvidersToSQLite(providers) {
            cleanupLegacyProviderFiles()
            logger.info("已从 SQLite 删除提供商 \(provider.name)。")
        } else {
            let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
            logger.info("正在删除提供商 \(provider.name) 的配置文件: \(fileURL.path)")
            removeFileIfExists(at: fileURL)
        }
        _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
        logger.info("  - 删除成功。")
        let payload: [String: String] = [
            "providerID": provider.id.uuidString,
            "providerName": provider.name,
            "apiFormat": provider.apiFormat,
            "baseURL": provider.baseURL,
            "modelCount": "\(provider.models.count)"
        ]
        AppLog.userOperation(
            category: "配置",
            action: "删除提供商配置",
            payload: payload
        )
        AppLog.developer(
            category: "config",
            action: "删除提供商配置",
            message: "提供商配置已删除：\(provider.name)",
            payload: payload
        )
    }

    static func changedFieldsForProviderUpdate(old: Provider?, new: Provider) -> [String] {
        guard let old else { return ["首次保存"] }

        var fields: [String] = []
        if old.name != new.name {
            fields.append("名称")
        }
        if old.baseURL != new.baseURL {
            fields.append("Base URL")
        }
        if old.apiFormat != new.apiFormat {
            fields.append("API 格式")
        }
        if old.models != new.models {
            fields.append("模型列表")
        }
        if old.headerOverrides != new.headerOverrides {
            fields.append("请求头覆写")
        }
        if old.proxyConfiguration != new.proxyConfiguration {
            fields.append("代理配置")
        }
        if old.apiKeys != new.apiKeys {
            fields.append("API Key 列表")
        }

        return fields.isEmpty ? ["无字段变化（覆盖保存）"] : fields
    }

    static func providersShareSamePersistentConfiguration(_ lhs: Provider, _ rhs: Provider) -> Bool {
        lhs.name == rhs.name &&
        lhs.baseURL == rhs.baseURL &&
        lhs.apiFormat == rhs.apiFormat &&
        lhs.models == rhs.models &&
        lhs.headerOverrides == rhs.headerOverrides &&
        lhs.proxyConfiguration == rhs.proxyConfiguration
    }

    static func hydrateProviderCredentials(for provider: Provider) -> CredentialHydrationResult {
        let normalizedFileAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
        let storedAPIKeys = ProviderCredentialStore.shared.loadAPIKeys(for: provider.id)
        let didNormalizeFile = normalizedFileAPIKeys != provider.apiKeys

        if !normalizedFileAPIKeys.isEmpty {
            if !storedAPIKeys.isEmpty {
                _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
            }
            return CredentialHydrationResult(
                apiKeys: normalizedFileAPIKeys,
                shouldRewriteProviderFile: didNormalizeFile
            )
        }

        let migratedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(storedAPIKeys)
        let didMigrateFromCredentialStore = !migratedAPIKeys.isEmpty

        if didMigrateFromCredentialStore {
            logger.info("  - 已将提供商 \(provider.name) 的 API Key 从旧凭据存储迁移到主存储。")
        }
        if !storedAPIKeys.isEmpty {
            _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
        }

        return CredentialHydrationResult(
            apiKeys: migratedAPIKeys,
            shouldRewriteProviderFile: didNormalizeFile || didMigrateFromCredentialStore
        )
    }

    static func mergeAPIKeysPreservingOrder(_ primary: [String], _ additional: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(primary + additional)
    }
}
