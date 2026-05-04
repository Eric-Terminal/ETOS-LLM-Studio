// ============================================================================
// ConfigLoaderProviderStoreSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 ConfigLoader 的提供商持久化、迁移、归并与旧文件兼容逻辑。
// ============================================================================

import Foundation
import GRDB
import os.log

extension ConfigLoader {
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

    static func loadProvidersFromSQLite() -> [Provider]? {
        guard let providers = Persistence.withConfigDatabaseRead({ db in
            try loadProvidersFromRelationalStore(db)
        }) else {
            return nil
        }

        if providers.isEmpty,
           let legacyProviders = loadLegacyProvidersFromBlob(),
           !legacyProviders.isEmpty {
            if saveProvidersToSQLite(legacyProviders) {
                removeLegacyProviderBlobs()
            }
            return legacyProviders
        }

        return providers
    }

    @discardableResult
    static func saveProvidersToSQLite(_ providers: [Provider]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try RelationalProviderRecord.deleteAll(db)

            let now = Date().timeIntervalSince1970
            for provider in providers {
                let normalizedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
                let proxy = provider.proxyConfiguration

                var providerRecord = RelationalProviderRecord(
                    id: provider.id.uuidString,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    apiFormat: provider.apiFormat,
                    proxyIsEnabled: proxy.map { $0.isEnabled ? 1 : 0 },
                    proxyType: proxy?.type.rawValue,
                    proxyHost: proxy?.host,
                    proxyPort: proxy?.port,
                    proxyUsername: proxy?.username,
                    proxyPassword: proxy?.password,
                    updatedAt: now
                )
                try providerRecord.insert(db)

                for (index, apiKey) in normalizedAPIKeys.enumerated() {
                    var apiKeyRecord = RelationalProviderAPIKeyRecord(
                        providerID: provider.id.uuidString,
                        keyIndex: index,
                        apiKey: apiKey
                    )
                    try apiKeyRecord.insert(db)
                }

                for headerKey in provider.headerOverrides.keys.sorted() {
                    let headerValue = provider.headerOverrides[headerKey] ?? ""
                    var headerRecord = RelationalProviderHeaderOverrideRecord(
                        providerID: provider.id.uuidString,
                        headerKey: headerKey,
                        headerValue: headerValue
                    )
                    try headerRecord.insert(db)
                }

                for (modelIndex, model) in provider.models.enumerated() {
                    var modelRecord = RelationalProviderModelRecord(
                        id: model.id.uuidString,
                        providerID: provider.id.uuidString,
                        modelName: model.modelName,
                        displayName: model.displayName,
                        isActivated: model.isActivated ? 1 : 0,
                        kind: model.kind.rawValue,
                        inputModalitiesJSON: encodeRawValues(model.inputModalities),
                        outputModalitiesJSON: encodeRawValues(model.outputModalities),
                        requestBodyOverrideMode: model.requestBodyOverrideMode.rawValue,
                        rawRequestBodyJSON: model.rawRequestBodyJSON,
                        requestBodyControlsJSON: encodeJSON(model.requestBodyControls),
                        sortIndex: modelIndex,
                        updatedAt: now
                    )
                    try modelRecord.insert(db)

                    for (capabilityIndex, capability) in model.capabilities.enumerated() {
                        var capabilityRecord = RelationalProviderModelCapabilityRecord(
                            modelID: model.id.uuidString,
                            capability: capability.rawValue,
                            sortIndex: capabilityIndex
                        )
                        try capabilityRecord.insert(db)
                    }

                    for parameterKey in model.overrideParameters.keys.sorted() {
                        let value = model.overrideParameters[parameterKey] ?? .null
                        let encodedValue = RelationalJSONValueCodec.encode(value)
                        var overrideRecord = RelationalProviderModelOverrideParameterRecord(
                            modelID: model.id.uuidString,
                            paramKey: parameterKey,
                            valueType: encodedValue.type,
                            stringValue: encodedValue.stringValue,
                            numberValue: encodedValue.numberValue,
                            boolValue: encodedValue.boolValue,
                            jsonValueText: encodedValue.jsonValueText
                        )
                        try overrideRecord.insert(db)
                    }
                }
            }
            return true
        } ?? false

        if didSave {
            removeLegacyProviderBlobs()
        }
        return didSave
    }

    static func hasMigratedToolCapability() -> Bool {
        UserDefaults.standard.bool(forKey: toolCapabilityMigrationFlagKey)
        || UserDefaults.standard.bool(forKey: legacyToolCapabilityMigrationFlagKey)
    }

    static func markToolCapabilityMigrated() {
        UserDefaults.standard.set(true, forKey: toolCapabilityMigrationFlagKey)
        UserDefaults.standard.set(true, forKey: legacyToolCapabilityMigrationFlagKey)
    }

    static func loadLegacyProvidersFromBlob() -> [Provider]? {
        for key in legacyProvidersBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([Provider].self, forKey: key) ?? []
        }
        return nil
    }

    static func removeLegacyProviderBlobs() {
        for key in legacyProvidersBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    static func loadProvidersFromRelationalStore(_ db: Database) throws -> [Provider] {
        let providerRows = try RelationalProviderRecord.fetchAll(db)
            .sorted { lhs, rhs in
                let lhsName = lhs.name.lowercased()
                let rhsName = rhs.name.lowercased()
                if lhsName == rhsName {
                    return lhs.id < rhs.id
                }
                return lhsName < rhsName
            }

        var providers: [Provider] = []
        providers.reserveCapacity(providerRows.count)

        for row in providerRows {
            let providerIDRaw = row.id
            let providerID = UUID(uuidString: providerIDRaw) ?? UUID()

            let apiKeys = try RelationalProviderAPIKeyRecord
                .filter(RelationalProviderAPIKeyRecord.Columns.providerID == providerIDRaw)
                .fetchAll(db)
                .sorted { $0.keyIndex < $1.keyIndex }
                .map(\.apiKey)

            let headerRows = try RelationalProviderHeaderOverrideRecord
                .filter(RelationalProviderHeaderOverrideRecord.Columns.providerID == providerIDRaw)
                .fetchAll(db)
                .sorted { $0.headerKey < $1.headerKey }
            var headerOverrides: [String: String] = [:]
            for headerRow in headerRows {
                headerOverrides[headerRow.headerKey] = headerRow.headerValue
            }

            let modelRows = try RelationalProviderModelRecord
                .filter(RelationalProviderModelRecord.Columns.providerID == providerIDRaw)
                .fetchAll(db)
                .sorted {
                    if $0.sortIndex == $1.sortIndex {
                        return $0.id < $1.id
                    }
                    return $0.sortIndex < $1.sortIndex
                }

            var models: [Model] = []
            models.reserveCapacity(modelRows.count)
            for modelRow in modelRows {
                let modelIDRaw = modelRow.id
                let modelID = UUID(uuidString: modelIDRaw) ?? UUID()

                let rawCapabilities = try RelationalProviderModelCapabilityRecord
                    .filter(RelationalProviderModelCapabilityRecord.Columns.modelID == modelIDRaw)
                    .fetchAll(db)
                    .sorted { $0.sortIndex < $1.sortIndex }
                    .map(\.capability)

                let hasStoredCapabilityShape = modelRow.kind != nil
                    || modelRow.inputModalitiesJSON != nil
                    || modelRow.outputModalitiesJSON != nil
                let decodedCapabilities = Model.orderedCapabilities(rawCapabilities.compactMap(ModelCapability.init(rawValue:)))
                let capabilities = rawCapabilities.isEmpty && !hasStoredCapabilityShape ? nil : decodedCapabilities
                let legacyCapabilityRawValues = rawCapabilities.isEmpty && !hasStoredCapabilityShape ? nil : rawCapabilities

                let overrideRows = try RelationalProviderModelOverrideParameterRecord
                    .filter(RelationalProviderModelOverrideParameterRecord.Columns.modelID == modelIDRaw)
                    .fetchAll(db)
                    .sorted { $0.paramKey < $1.paramKey }
                var overrideParameters: [String: JSONValue] = [:]
                for overrideRow in overrideRows {
                    overrideParameters[overrideRow.paramKey] = RelationalJSONValueCodec.decode(
                        type: overrideRow.valueType,
                        stringValue: overrideRow.stringValue,
                        numberValue: overrideRow.numberValue,
                        boolValue: overrideRow.boolValue,
                        jsonValueText: overrideRow.jsonValueText
                    )
                }

                let requestBodyOverrideMode = modelRow.requestBodyOverrideMode
                    .flatMap(Model.RequestBodyOverrideMode.init(rawValue:))
                    ?? .keyValue

                var model = Model(
                    id: modelID,
                    modelName: modelRow.modelName,
                    displayName: modelRow.displayName,
                    isActivated: modelRow.isActivated != 0,
                    overrideParameters: overrideParameters,
                    kind: modelRow.kind.flatMap(ModelKind.init(rawValue:)),
                    inputModalities: decodeRawValues(modelRow.inputModalitiesJSON, as: ModelModality.self),
                    outputModalities: decodeRawValues(modelRow.outputModalitiesJSON, as: ModelModality.self),
                    capabilities: capabilities,
                    legacyCapabilityRawValues: legacyCapabilityRawValues,
                    requestBodyOverrideMode: requestBodyOverrideMode,
                    rawRequestBodyJSON: modelRow.rawRequestBodyJSON,
                    requestBodyControls: decodeJSON(modelRow.requestBodyControlsJSON, as: [ModelRequestBodyControl].self) ?? []
                )
                if !hasStoredCapabilityShape {
                    model = model.applyingInferredCapabilityHints()
                }
                models.append(model)
            }

            let proxyConfiguration: NetworkProxyConfiguration?
            if row.proxyIsEnabled != nil || row.proxyType != nil || row.proxyHost != nil || row.proxyPort != nil {
                proxyConfiguration = NetworkProxyConfiguration(
                    isEnabled: (row.proxyIsEnabled ?? 0) != 0,
                    type: row.proxyType.flatMap(NetworkProxyType.init(rawValue:)) ?? .http,
                    host: row.proxyHost ?? "",
                    port: row.proxyPort ?? 8080,
                    username: row.proxyUsername ?? "",
                    password: row.proxyPassword ?? ""
                )
            } else {
                proxyConfiguration = nil
            }

            providers.append(
                Provider(
                    id: providerID,
                    name: row.name,
                    baseURL: row.baseURL,
                    apiKeys: apiKeys,
                    apiFormat: row.apiFormat,
                    models: models,
                    headerOverrides: headerOverrides,
                    proxyConfiguration: proxyConfiguration
                )
            )
        }

        return providers
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
