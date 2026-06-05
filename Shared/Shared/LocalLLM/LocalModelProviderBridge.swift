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
        if preferRecordBasics || overrideParameters["context_size"] == nil {
            overrideParameters["context_size"] = .int(record.contextSize)
        }
        if preferRecordBasics || overrideParameters["max_output_tokens"] == nil {
            overrideParameters["max_output_tokens"] = .int(record.maxOutputTokens)
        }
        if preferRecordBasics || overrideParameters["n_gpu_layers"] == nil {
            overrideParameters["n_gpu_layers"] = .int(record.gpuLayers)
        }
        if preferRecordBasics || overrideParameters["seed"] == nil {
            overrideParameters["seed"] = .string(String(record.seed))
        }
        if preferRecordBasics || overrideParameters["temperature"] == nil {
            overrideParameters["temperature"] = .double(record.temperature)
        }
        if preferRecordBasics || overrideParameters["top_k"] == nil {
            overrideParameters["top_k"] = .int(record.topK)
        }
        if preferRecordBasics || overrideParameters["top_p"] == nil {
            overrideParameters["top_p"] = .double(record.topP)
        }
        if preferRecordBasics || overrideParameters["min_p"] == nil {
            overrideParameters["min_p"] = .double(record.minP)
        }
        if preferRecordBasics || overrideParameters["repeat_last_n"] == nil {
            overrideParameters["repeat_last_n"] = .int(record.repeatLastN)
        }
        if preferRecordBasics || overrideParameters["repeat_penalty"] == nil {
            overrideParameters["repeat_penalty"] = .double(record.repeatPenalty)
        }
        if preferRecordBasics || overrideParameters["frequency_penalty"] == nil {
            overrideParameters["frequency_penalty"] = .double(record.frequencyPenalty)
        }
        if preferRecordBasics || overrideParameters["presence_penalty"] == nil {
            overrideParameters["presence_penalty"] = .double(record.presencePenalty)
        }
        if preferRecordBasics || overrideParameters["grammar"] == nil {
            overrideParameters["grammar"] = .string(record.grammar)
        }
        if preferRecordBasics || overrideParameters["ignore_eos"] == nil {
            overrideParameters["ignore_eos"] = .bool(record.ignoreEOS)
        }
        if preferRecordBasics || overrideParameters["sampler_seq"] == nil {
            overrideParameters["sampler_seq"] = .string(LocalLLMSamplerKind.chainString(record.samplerKinds))
        }
        if preferRecordBasics || overrideParameters["llama_cli_args"] == nil {
            overrideParameters["llama_cli_args"] = .string(record.advancedArguments)
        }

        let capabilities = Model.orderedCapabilities(
            (existingModel?.capabilities ?? []) + [.toolCalling, .streaming, .embedding]
        )

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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
