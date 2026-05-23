// ============================================================================
// SyncEngineProviderMerge.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 Provider 与模型配置的同步深合并逻辑。
// ============================================================================

import Foundation

extension SyncEngine {
    static func compactProvidersByIdentity(_ providers: [Provider]) -> ProviderCompactionResult {
        guard !providers.isEmpty else {
            return ProviderCompactionResult(
                providers: [],
                updatedProviders: [],
                removedProviders: []
            )
        }

        var compacted: [Provider] = []
        var indexByIdentity: [String: Int] = [:]
        var updatedProvidersByID: [UUID: Provider] = [:]
        var removedProviders: [Provider] = []

        for provider in providers {
            let identity = providerMergeIdentity(provider)
            if let existingIndex = indexByIdentity[identity] {
                let existing = compacted[existingIndex]
                let result = mergeProviderConservatively(existing, with: provider)
                compacted[existingIndex] = result.provider
                if result.changed {
                    updatedProvidersByID[result.provider.id] = result.provider
                }
                removedProviders.append(provider)
                continue
            }

            indexByIdentity[identity] = compacted.count
            compacted.append(provider)
        }

        return ProviderCompactionResult(
            providers: compacted,
            updatedProviders: Array(updatedProvidersByID.values),
            removedProviders: removedProviders
        )
    }

    static func mergeProviderConservatively(
        _ local: Provider,
        with incoming: Provider,
        preferIncomingModelCapabilityShape: Bool = false
    ) -> (provider: Provider, changed: Bool) {
        var merged = local
        var changed = false

        let canonicalFormat = canonicalProviderAPIFormat(local.apiFormat)
        if normalizeAPIFormatToken(local.apiFormat) != canonicalFormat {
            merged.apiFormat = canonicalFormat
            changed = true
        }

        let mergedAPIKeys = mergeProviderAPIKeys(merged.apiKeys, incoming.apiKeys)
        if mergedAPIKeys != merged.apiKeys {
            merged.apiKeys = mergedAPIKeys
            changed = true
        }

        let mergedHeaders = mergeStringDictionaryConservatively(merged.headerOverrides, incoming.headerOverrides)
        if mergedHeaders != merged.headerOverrides {
            merged.headerOverrides = mergedHeaders
            changed = true
        }

        let mergedProxyConfiguration = mergeProviderProxyConfigurationConservatively(
            merged.proxyConfiguration,
            incoming.proxyConfiguration
        )
        if mergedProxyConfiguration != merged.proxyConfiguration {
            merged.proxyConfiguration = mergedProxyConfiguration
            changed = true
        }

        let mergedModelsResult = mergeProviderModelsConservatively(
            merged.models,
            incoming.models,
            preferIncomingCapabilityShape: preferIncomingModelCapabilityShape
        )
        if mergedModelsResult.changed {
            merged.models = mergedModelsResult.models
            changed = true
        }

        return (merged, changed)
    }

    static func mergeProviderModelsConservatively(
        _ localModels: [Model],
        _ incomingModels: [Model],
        preferIncomingCapabilityShape: Bool = false
    ) -> (models: [Model], changed: Bool) {
        var merged = localModels
        var changed = false
        var modelIDs = Set(merged.map(\.id))

        for incomingModel in incomingModels {
            if let existingIndex = merged.firstIndex(where: {
                normalizedModelIdentity($0) == normalizedModelIdentity(incomingModel)
            }) {
                switch mergeModelDeep(merged[existingIndex], with: incomingModel) {
                case .unchanged(let model):
                    merged[existingIndex] = model
                case .merged(let model):
                    merged[existingIndex] = model
                    changed = true
                case .conflict:
                    let conservative = mergeModelConservatively(
                        merged[existingIndex],
                        with: incomingModel,
                        preferIncomingCapabilityShape: preferIncomingCapabilityShape
                    )
                    if conservative.changed {
                        merged[existingIndex] = conservative.model
                        changed = true
                    }
                }
                continue
            }

            var appended = incomingModel
            if modelIDs.contains(appended.id) {
                appended.id = UUID()
            }
            merged.append(appended)
            modelIDs.insert(appended.id)
            changed = true
        }

        return (merged, changed)
    }

    static func mergeModelConservatively(
        _ local: Model,
        with incoming: Model,
        preferIncomingCapabilityShape: Bool = false
    ) -> (model: Model, changed: Bool) {
        var merged = local
        var changed = false

        if merged.displayName == merged.modelName,
           incoming.displayName != incoming.modelName,
           incoming.displayName != merged.displayName {
            merged.displayName = incoming.displayName
            changed = true
        }

        let mergedIsActivated = merged.isActivated || incoming.isActivated
        if mergedIsActivated != merged.isActivated {
            merged.isActivated = mergedIsActivated
            changed = true
        }

        let mergedKind = preferIncomingCapabilityShape ? incoming.kind : mergeModelKind(merged.kind, incoming.kind)
        if mergedKind != merged.kind {
            merged.kind = mergedKind
            changed = true
        }

        let mergedInputModalities = preferIncomingCapabilityShape
            ? incoming.inputModalities
            : mergeModelModalities(merged.inputModalities, incoming.inputModalities)
        if mergedInputModalities != merged.inputModalities {
            merged.inputModalities = mergedInputModalities
            changed = true
        }

        let mergedOutputModalities = preferIncomingCapabilityShape
            ? incoming.outputModalities
            : mergeModelModalities(merged.outputModalities, incoming.outputModalities)
        if mergedOutputModalities != merged.outputModalities {
            merged.outputModalities = mergedOutputModalities
            changed = true
        }

        let mergedCapabilities = preferIncomingCapabilityShape
            ? incoming.capabilities
            : mergeCapabilities(merged.capabilities, incoming.capabilities)
        if mergedCapabilities != merged.capabilities {
            merged.capabilities = mergedCapabilities
            changed = true
        }

        let mergedOverrideParameters = mergeJSONDictionaryConservatively(
            merged.overrideParameters,
            incoming.overrideParameters
        )
        if mergedOverrideParameters != merged.overrideParameters {
            merged.overrideParameters = mergedOverrideParameters
            changed = true
        }

        if let mergedRequestBodyMode = mergeRequestBodyOverrideMode(local: merged, incoming: incoming),
           mergedRequestBodyMode != merged.requestBodyOverrideMode {
            merged.requestBodyOverrideMode = mergedRequestBodyMode
            changed = true
        }

        let normalizedLocalRaw = normalizeOptionalJSONString(merged.rawRequestBodyJSON)
        let normalizedIncomingRaw = normalizeOptionalJSONString(incoming.rawRequestBodyJSON)
        if normalizedLocalRaw == nil, let normalizedIncomingRaw {
            merged.rawRequestBodyJSON = normalizedIncomingRaw
            changed = true
        }

        let mergedControls = mergeRequestBodyControlsConservatively(
            merged.requestBodyControls,
            incoming.requestBodyControls
        )
        if mergedControls != merged.requestBodyControls {
            merged.requestBodyControls = mergedControls
            changed = true
        }

        if merged.pricing == nil, let incomingPricing = incoming.pricing?.normalized, !incomingPricing.isEffectivelyEmpty {
            merged.pricing = incomingPricing
            changed = true
        }

        return (merged, changed)
    }

    static func mergeStringDictionaryConservatively(
        _ local: [String: String],
        _ incoming: [String: String]
    ) -> [String: String] {
        var merged = local
        for (key, incomingValue) in incoming {
            guard merged[key] == nil else { continue }
            merged[key] = incomingValue
        }
        return merged
    }

    static func mergeProviderProxyConfigurationConservatively(
        _ local: NetworkProxyConfiguration?,
        _ incoming: NetworkProxyConfiguration?
    ) -> NetworkProxyConfiguration? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case (let local?, nil):
            return local
        case (nil, let incoming?):
            return incoming
        case (let local?, let incoming?):
            if local == incoming {
                return local
            }
            if !local.isEnabled && incoming.isEnabled {
                return incoming
            }
            return local
        }
    }

    static func mergeJSONDictionaryConservatively(
        _ local: [String: JSONValue],
        _ incoming: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                merged[key] = mergeJSONValueConservatively(localValue, incomingValue)
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    static func mergeJSONValueConservatively(_ local: JSONValue, _ incoming: JSONValue) -> JSONValue {
        if local == incoming {
            return local
        }

        switch (local, incoming) {
        case (.dictionary(let localDictionary), .dictionary(let incomingDictionary)):
            return .dictionary(mergeJSONDictionaryConservatively(localDictionary, incomingDictionary))
        case (.array(let localArray), .array(let incomingArray)):
            return .array(mergeJSONArray(localArray, incomingArray))
        case (.null, _):
            return incoming
        case (_, .null):
            return local
        default:
            return local
        }
    }

    static func providerMergeCandidateIndex(
        for incomingProvider: Provider,
        localProviders: [Provider]
    ) -> Int? {
        if let exactIDMatch = localProviders.firstIndex(where: { $0.id == incomingProvider.id }) {
            return exactIDMatch
        }
        let identity = providerMergeIdentity(incomingProvider)
        return localProviders.firstIndex(where: { providerMergeIdentity($0) == identity })
    }

    static func mergeProviderDeep(
        _ local: Provider,
        with incoming: Provider
    ) -> DeepMergeResult<Provider> {
        guard providerMergeIdentity(local) == providerMergeIdentity(incoming) else {
            return .conflict
        }

        var merged = local
        var changed = false

        let canonicalFormat = canonicalProviderAPIFormat(local.apiFormat)
        if normalizeAPIFormatToken(local.apiFormat) != canonicalFormat {
            merged.apiFormat = canonicalFormat
            changed = true
        }

        let mergedAPIKeys = mergeProviderAPIKeys(local.apiKeys, incoming.apiKeys)
        if mergedAPIKeys != local.apiKeys {
            merged.apiKeys = mergedAPIKeys
            changed = true
        }

        guard let mergedHeaders = mergeStringDictionary(local.headerOverrides, incoming.headerOverrides) else {
            return .conflict
        }
        if mergedHeaders != local.headerOverrides {
            merged.headerOverrides = mergedHeaders
            changed = true
        }

        guard let mergedProxyConfiguration = mergeProviderProxyConfiguration(
            local.proxyConfiguration,
            incoming.proxyConfiguration
        ) else {
            return .conflict
        }
        if mergedProxyConfiguration != local.proxyConfiguration {
            merged.proxyConfiguration = mergedProxyConfiguration
            changed = true
        }

        guard let mergedModelsResult = mergeProviderModels(local.models, incoming.models) else {
            return .conflict
        }
        if mergedModelsResult.changed {
            merged.models = mergedModelsResult.models
            changed = true
        }

        if changed {
            return .merged(merged)
        }
        return .unchanged(merged)
    }

    static func mergeProviderModels(
        _ localModels: [Model],
        _ incomingModels: [Model]
    ) -> (models: [Model], changed: Bool)? {
        var merged = localModels
        var changed = false
        var modelIDs = Set(merged.map(\.id))

        for incomingModel in incomingModels {
            if let existingIndex = merged.firstIndex(where: {
                normalizedModelIdentity($0) == normalizedModelIdentity(incomingModel)
            }) {
                switch mergeModelDeep(merged[existingIndex], with: incomingModel) {
                case .unchanged(let model):
                    merged[existingIndex] = model
                case .merged(let model):
                    merged[existingIndex] = model
                    changed = true
                case .conflict:
                    return nil
                }
                continue
            }

            var appended = incomingModel
            if modelIDs.contains(appended.id) {
                appended.id = UUID()
            }
            merged.append(appended)
            modelIDs.insert(appended.id)
            changed = true
        }

        return (merged, changed)
    }

    static func mergeModelDeep(_ local: Model, with incoming: Model) -> DeepMergeResult<Model> {
        guard normalizedModelIdentity(local) == normalizedModelIdentity(incoming) else {
            return .conflict
        }

        var merged = local
        var changed = false

        guard let displayName = mergeDisplayName(local: local.displayName, incoming: incoming.displayName, fallback: local.modelName) else {
            return .conflict
        }
        if displayName != local.displayName {
            merged.displayName = displayName
            changed = true
        }

        let mergedIsActivated = local.isActivated || incoming.isActivated
        if mergedIsActivated != local.isActivated {
            merged.isActivated = mergedIsActivated
            changed = true
        }

        let mergedKind = incoming.kind
        if mergedKind != local.kind {
            merged.kind = mergedKind
            changed = true
        }

        let mergedInputModalities = incoming.inputModalities
        if mergedInputModalities != local.inputModalities {
            merged.inputModalities = mergedInputModalities
            changed = true
        }

        let mergedOutputModalities = incoming.outputModalities
        if mergedOutputModalities != local.outputModalities {
            merged.outputModalities = mergedOutputModalities
            changed = true
        }

        let mergedCapabilities = incoming.capabilities
        if mergedCapabilities != local.capabilities {
            merged.capabilities = mergedCapabilities
            changed = true
        }

        guard let mergedOverrideParameters = mergeJSONDictionary(local.overrideParameters, incoming.overrideParameters) else {
            return .conflict
        }
        if mergedOverrideParameters != local.overrideParameters {
            merged.overrideParameters = mergedOverrideParameters
            changed = true
        }

        guard let requestBodyMode = mergeRequestBodyOverrideMode(local: local, incoming: incoming) else {
            return .conflict
        }
        if requestBodyMode != local.requestBodyOverrideMode {
            merged.requestBodyOverrideMode = requestBodyMode
            changed = true
        }

        guard let rawRequestBody = mergeOptionalStringField(
            normalizeOptionalJSONString(local.rawRequestBodyJSON),
            normalizeOptionalJSONString(incoming.rawRequestBodyJSON),
            allowPrefixExtension: false
        ) else {
            return .conflict
        }
        if rawRequestBody.value != normalizeOptionalJSONString(local.rawRequestBodyJSON) {
            merged.rawRequestBodyJSON = rawRequestBody.value
            changed = true
        }

        guard let requestBodyControls = mergeRequestBodyControls(local.requestBodyControls, incoming.requestBodyControls) else {
            return .conflict
        }
        if requestBodyControls != local.requestBodyControls {
            merged.requestBodyControls = requestBodyControls
            changed = true
        }

        guard let pricing = mergeOptionalScalarField(
            local.pricing?.normalized,
            incoming.pricing?.normalized
        ) else {
            return .conflict
        }
        if pricing.value != local.pricing?.normalized {
            merged.pricing = pricing.value
            changed = true
        }

        if changed {
            return .merged(merged)
        }
        return .unchanged(merged)
    }

    static func mergeStringDictionary(_ local: [String: String], _ incoming: [String: String]) -> [String: String]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard localValue == incomingValue else { return nil }
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    static func mergeJSONDictionary(_ local: [String: JSONValue], _ incoming: [String: JSONValue]) -> [String: JSONValue]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard let mergedValue = mergeJSONValue(localValue, incomingValue) else { return nil }
                merged[key] = mergedValue
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    static func mergeJSONValue(_ local: JSONValue, _ incoming: JSONValue) -> JSONValue? {
        if local == incoming {
            return local
        }

        switch (local, incoming) {
        case (.dictionary(let localDictionary), .dictionary(let incomingDictionary)):
            guard let merged = mergeJSONDictionary(localDictionary, incomingDictionary) else { return nil }
            return .dictionary(merged)
        case (.array(let localArray), .array(let incomingArray)):
            return .array(mergeJSONArray(localArray, incomingArray))
        case (.null, _):
            return incoming
        case (_, .null):
            return local
        default:
            return nil
        }
    }

    static func mergeJSONArray(_ local: [JSONValue], _ incoming: [JSONValue]) -> [JSONValue] {
        if local == incoming {
            return local
        }
        var merged = local
        for value in incoming where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    static func mergeRequestBodyControlsConservatively(
        _ local: [ModelRequestBodyControl],
        _ incoming: [ModelRequestBodyControl]
    ) -> [ModelRequestBodyControl] {
        var merged = local
        var ids = Set(local.map(\.id))
        for control in incoming where !ids.contains(control.id) {
            merged.append(control)
            ids.insert(control.id)
        }
        return merged
    }

    static func mergeRequestBodyControls(
        _ local: [ModelRequestBodyControl],
        _ incoming: [ModelRequestBodyControl]
    ) -> [ModelRequestBodyControl]? {
        var merged = local
        var indexByID = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($1.id, $0) })
        for control in incoming {
            if let index = indexByID[control.id] {
                guard merged[index] == control else { return nil }
            } else {
                indexByID[control.id] = merged.count
                merged.append(control)
            }
        }
        return merged
    }

    static func mergeCapabilities(_ local: [ModelCapability], _ incoming: [ModelCapability]) -> [ModelCapability] {
        var merged = local
        for capability in incoming where !merged.contains(capability) {
            merged.append(capability)
        }
        return Model.orderedCapabilities(merged)
    }

    static func mergeModelKind(_ local: ModelKind, _ incoming: ModelKind) -> ModelKind {
        local == .chat && incoming != .chat ? incoming : local
    }

    static func mergeModelModalities(_ local: [ModelModality], _ incoming: [ModelModality]) -> [ModelModality] {
        var merged = local
        for modality in incoming where !merged.contains(modality) {
            merged.append(modality)
        }
        return Model.orderedModalities(merged)
    }

    static func mergeRequestBodyOverrideMode(local: Model, incoming: Model) -> Model.RequestBodyOverrideMode? {
        if local.requestBodyOverrideMode == incoming.requestBodyOverrideMode {
            return local.requestBodyOverrideMode
        }

        let localHasRawJSON = normalizeOptionalJSONString(local.rawRequestBodyJSON) != nil
        let incomingHasRawJSON = normalizeOptionalJSONString(incoming.rawRequestBodyJSON) != nil

        if local.requestBodyOverrideMode == .keyValue && !localHasRawJSON {
            return incoming.requestBodyOverrideMode
        }
        if incoming.requestBodyOverrideMode == .keyValue && !incomingHasRawJSON {
            return local.requestBodyOverrideMode
        }
        return nil
    }

    static func mergeDisplayName(local: String, incoming: String, fallback: String) -> String? {
        if local == incoming {
            return local
        }
        if local == fallback {
            return incoming
        }
        if incoming == fallback {
            return local
        }
        return nil
    }

    static func mergeProviderProxyConfiguration(
        _ local: NetworkProxyConfiguration?,
        _ incoming: NetworkProxyConfiguration?
    ) -> NetworkProxyConfiguration?? {
        switch (local, incoming) {
        case (nil, nil):
            return .some(nil)
        case (let local?, nil):
            return .some(local)
        case (nil, let incoming?):
            return .some(incoming)
        case (let local?, let incoming?):
            guard local == incoming else { return nil }
            return .some(local)
        }
    }

    static func reassignProviderIdentifiersIfNeeded(_ provider: Provider, existingProviders: [Provider]) -> Provider {
        var copied = provider
        if existingProviders.contains(where: { $0.id == copied.id }) {
            copied.id = UUID()
            copied.models = copied.models.map { model in
                var clone = model
                clone.id = UUID()
                return clone
            }
            return copied
        }

        var seenModelIDs = Set(existingProviders.flatMap { $0.models.map(\.id) })
        copied.models = copied.models.map { model in
            var clone = model
            if seenModelIDs.contains(clone.id) {
                clone.id = UUID()
            }
            seenModelIDs.insert(clone.id)
            return clone
        }
        return copied
    }
}
