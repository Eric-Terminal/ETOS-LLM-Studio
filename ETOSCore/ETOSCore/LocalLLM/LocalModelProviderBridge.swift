// ============================================================================
// LocalModelProviderBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 将本机权重记录投射为现有聊天系统可识别的 RunnableModel。
// ============================================================================

import Foundation

public enum LocalModelProviderBridge {
    public static let providerID = UUID(uuidString: "A129B884-B23B-4D9A-A536-3D141D64F6A8")!
    public static let apiFormat = "local-llama-cpp"
    public static let defaultBaseURL = "local://llama-cpp"

    public static var provider: Provider {
        Provider(
            id: providerID,
            name: NSLocalizedString("本地模型", comment: "Local model provider name"),
            baseURL: defaultBaseURL,
            apiKeys: [],
            apiFormat: apiFormat
        )
    }

    public static func isLocalProvider(_ provider: Provider) -> Bool {
        provider.id == providerID || provider.apiFormat == apiFormat
    }

    public static func isLocalRunnableModel(_ model: RunnableModel?) -> Bool {
        guard let model else { return false }
        return isLocalProvider(model.provider)
    }

    public static func runnableModel(for record: LocalModelRecord) -> RunnableModel {
        RunnableModel(provider: provider, model: model(for: record))
    }

    public static func runnableModels(from records: [LocalModelRecord]) -> [RunnableModel] {
        records.map(runnableModel(for:))
    }

    public static func localRecordID(from runnableModelID: String) -> UUID? {
        let prefix = "\(providerID.uuidString)-"
        guard runnableModelID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(runnableModelID.dropFirst(prefix.count)))
    }

    public static func model(for record: LocalModelRecord, preserving existingModel: Model? = nil, preferRecordBasics: Bool = true) -> Model {
        var overrideParameters = existingModel?.overrideParameters ?? [:]
        writeOverride("context_size", value: record.contextSize.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("max_output_tokens", value: record.maxOutputTokens.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("n_gpu_layers", value: record.gpuLayers.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("batch_size", value: record.batchSize.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("ubatch_size", value: record.ubatchSize.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("kv_offload", value: record.kvOffload.map(JSONValue.bool), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("flash_attn", value: record.flashAttention.map { .int(Int($0.rawValue)) }, to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("seed", value: record.seed.map { .string(String($0)) }, to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("temperature", value: record.temperature.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("top_k", value: record.topK.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("top_p", value: record.topP.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("min_p", value: record.minP.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("repeat_last_n", value: record.repeatLastN.map(JSONValue.int), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("repeat_penalty", value: record.repeatPenalty.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("frequency_penalty", value: record.frequencyPenalty.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("presence_penalty", value: record.presencePenalty.map(JSONValue.double), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("grammar", value: record.grammar.map(JSONValue.string), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("ignore_eos", value: record.ignoreEOS.map(JSONValue.bool), to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("sampler_seq", value: record.samplerKinds.map { .string(LocalLLMSamplerKind.chainString($0)) }, to: &overrideParameters, preferRecordBasics: preferRecordBasics)
        writeOverride("llama_cli_args", value: record.advancedArguments.nilIfEmpty.map(JSONValue.string), to: &overrideParameters, preferRecordBasics: preferRecordBasics)

        let capabilities = Model.orderedCapabilities((existingModel?.capabilities ?? []) + [.streaming])

        return Model(
            id: record.id,
            modelName: sanitized(existingModel?.modelName).nilIfEmpty ?? record.modelName,
            displayName: preferRecordBasics
                ? record.sanitizedDisplayName
                : (sanitized(existingModel?.displayName).nilIfEmpty ?? record.sanitizedDisplayName),
            isActivated: preferRecordBasics ? record.isActivated : (existingModel?.isActivated ?? record.isActivated),
            overrideParameters: overrideParameters,
            kind: existingModel?.kind ?? .chat,
            inputModalities: existingModel?.inputModalities ?? [.text],
            outputModalities: existingModel?.outputModalities ?? [.text],
            capabilities: capabilities,
            requestBodyOverrideMode: existingModel?.requestBodyOverrideMode ?? .keyValue,
            rawRequestBodyJSON: existingModel?.rawRequestBodyJSON,
            requestBodyControls: existingModel?.requestBodyControls ?? [],
            pricing: existingModel?.pricing
        )
    }

    public static func provider(records: [LocalModelRecord], preserving existingProvider: Provider? = nil, preferRecordBasics: Bool = true) -> Provider {
        let existingModelsByID = Dictionary(uniqueKeysWithValues: (existingProvider?.models ?? []).map { ($0.id, $0) })
        return Provider(
            id: providerID,
            name: sanitized(existingProvider?.name).nilIfEmpty
                ?? NSLocalizedString("本地模型", comment: "Local model provider name"),
            baseURL: sanitized(existingProvider?.baseURL).nilIfEmpty ?? defaultBaseURL,
            apiKeys: existingProvider?.apiKeys ?? [],
            apiFormat: apiFormat,
            models: records.map { record in
                model(
                    for: record,
                    preserving: existingModelsByID[record.id],
                    preferRecordBasics: preferRecordBasics
                )
            },
            headerOverrides: existingProvider?.headerOverrides ?? [:],
            proxyConfiguration: existingProvider?.proxyConfiguration
        )
    }

    public static func applyingLocalProvider(
        to providers: [Provider],
        records: [LocalModelRecord],
        isEnabled: Bool,
        preferRecordBasics: Bool
    ) -> [Provider] {
        let existingProvider = providers.first(where: isLocalProvider)
        var result = providers.filter { !isLocalProvider($0) }
        guard isEnabled else { return result }
        result.append(provider(records: records, preserving: existingProvider, preferRecordBasics: preferRecordBasics))
        return result
    }

    public static func localRecordID(from model: Model) -> UUID {
        model.id
    }

    private static func sanitized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func writeOverride(
        _ key: String,
        value: JSONValue?,
        to overrideParameters: inout [String: JSONValue],
        preferRecordBasics: Bool
    ) {
        if let value {
            if preferRecordBasics || overrideParameters[key] == nil {
                overrideParameters[key] = value
            }
        } else if preferRecordBasics {
            overrideParameters.removeValue(forKey: key)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
