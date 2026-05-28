// ============================================================================
// ConfigLoaderProviderSQLiteSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// Provider 配置的 SQLite 关系表读写、旧辅助 blob 迁移和关系记录解码。
// ============================================================================

import Foundation
import GRDB

extension ConfigLoader {
    static func loadProvidersFromSQLite() -> [Provider]? {
        let storedProviderOrderIDs = AppConfigStore.stringArrayValue(for: .providerOrderIDs, defaultValue: []) ?? []
        guard let providers = Persistence.withConfigDatabaseRead({ db in
            try loadProvidersFromRelationalStore(db, storedProviderOrderIDs: storedProviderOrderIDs)
        }) else {
            return nil
        }

        if providers.isEmpty,
           let legacyProviders = loadLegacyProvidersFromBlob(),
           !legacyProviders.isEmpty {
            if saveProvidersToSQLite(legacyProviders) {
                removeLegacyProviderBlobs()
            }
            reconcileStoredProviderOrder(currentIDs: legacyProviders.map { $0.id.uuidString })
            return legacyProviders
        }

        reconcileStoredProviderOrder(currentIDs: providers.map { $0.id.uuidString })
        return providers
    }

    @discardableResult
    static func saveProvidersToSQLite(_ providers: [Provider]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try clearProviderRelationalTables(db)

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
                        pricingJSON: model.pricing.flatMap { encodeJSON($0.normalized) },
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

    static func clearProviderRelationalTables(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM provider_model_override_parameters")
        try db.execute(sql: "DELETE FROM provider_model_capabilities")
        try db.execute(sql: "DELETE FROM provider_models")
        try db.execute(sql: "DELETE FROM provider_header_overrides")
        try db.execute(sql: "DELETE FROM provider_api_keys")
        try db.execute(sql: "DELETE FROM providers")
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

    static func loadProvidersFromRelationalStore(
        _ db: Database,
        storedProviderOrderIDs: [String] = []
    ) throws -> [Provider] {
        let providerRows = applyStoredProviderOrder(
            to: try RelationalProviderRecord.fetchAll(db),
            storedIDs: storedProviderOrderIDs
        )

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
                    requestBodyControls: decodeJSON(modelRow.requestBodyControlsJSON, as: [ModelRequestBodyControl].self) ?? [],
                    pricing: decodeJSON(modelRow.pricingJSON, as: ModelPricing.self)
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

    static func applyStoredProviderOrder(
        to rows: [RelationalProviderRecord],
        storedIDs: [String]
    ) -> [RelationalProviderRecord] {
        guard !rows.isEmpty else { return [] }
        let fallbackRows = rows.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            if lhsName == rhsName {
                return lhs.id < rhs.id
            }
            return lhsName < rhsName
        }
        let currentIDs = fallbackRows.map(\.id)
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        let rankByID = Dictionary(uniqueKeysWithValues: mergedIDs.enumerated().map { ($1, $0) })

        return fallbackRows.sorted { lhs, rhs in
            let lhsRank = rankByID[lhs.id] ?? Int.max
            let rhsRank = rankByID[rhs.id] ?? Int.max
            if lhsRank == rhsRank {
                return lhs.id < rhs.id
            }
            return lhsRank < rhsRank
        }
    }

    static func reconcileStoredProviderOrder(currentIDs: [String]) {
        let storedIDs = AppConfigStore.stringArrayValue(for: .providerOrderIDs, defaultValue: []) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        AppConfigStore.persistStringArray(mergedIDs, for: .providerOrderIDs)
    }
}
