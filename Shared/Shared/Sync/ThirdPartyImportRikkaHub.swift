// ============================================================================
// ThirdPartyImportRikkaHub.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 RikkaHub 导出的提供商配置。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseRikkaHub(fileURL: URL) throws -> ParsedPayload {
        var warnings: [String] = [
            NSLocalizedString("RikkaHub 备份当前仅支持读取 settings.json 中的提供商配置，会话内容暂未解析。", comment: "RikkaHub import limitation warning")
        ]

        let settings: [String: Any]
        if isDirectory(fileURL),
           let parsed = findJSONInDirectory(fileURL, preferredNames: ["settings.json"]) {
            settings = parsed
        } else if let parsed = tryParseDictionaryJSON(from: fileURL) {
            settings = parsed
        } else {
            if isLikelyCompressedBackup(fileURL) {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后再导入 settings.json。", comment: "RikkaHub import compressed backup unsupported")
                )
            }
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未找到 RikkaHub 可识别的 settings.json。", comment: "RikkaHub import missing settings")
            )
        }

        let providerList = normalizeJSONArray(settings["providers"])
        let providers = parseRikkaProviders(providerList)

        if providers.isEmpty {
            warnings.append(NSLocalizedString("未在 RikkaHub 备份中识别到可导入的提供商。", comment: "RikkaHub import no providers warning"))
            throw ThirdPartyImportError.noImportableContent
        }

        return ParsedPayload(
            providers: dedupeProviders(providers),
            sessions: [],
            warnings: warnings
        )
    }

    static func parseRikkaProviders(_ providerList: [Any]) -> [Provider] {
        var result: [Provider] = []

        for providerAny in providerList {
            guard let provider = dictionary(providerAny) else { continue }

            let type = string(provider["type"])?.lowercased()
            let format = normalizeProviderFormat(typeHint: type, modelIDs: [])
            let name = nonEmpty(string(provider["name"]))
                ?? (type?.capitalized ?? "RikkaHub")
            let apiKey = nonEmpty(string(provider["apiKey"])) ?? ""
            let baseURL = normalizeBaseURL(string(provider["baseUrl"]), for: format)
            let enabled = bool(provider["enabled"], defaultValue: true)
            let providerUsesResponsesAPI = format == "openai-compatible"
                && bool(provider["useResponseApi"], defaultValue: false)

            let modelsRaw = normalizeJSONArray(provider["models"])
            let models: [Model] = modelsRaw.compactMap { modelAny in
                if let modelName = nonEmpty(string(modelAny)) {
                    return importedModel(
                        modelName: modelName,
                        displayName: modelName,
                        isActivated: enabled,
                        useResponsesAPI: providerUsesResponsesAPI
                    )
                }

                guard let model = dictionary(modelAny) else { return nil }
                let modelID = nonEmpty(string(model["modelId"]))
                    ?? nonEmpty(string(model["id"]))
                guard let modelID else { return nil }
                let displayName = nonEmpty(string(model["displayName"]))
                    ?? nonEmpty(string(model["name"]))
                    ?? modelID
                let modelUsesResponsesAPI = providerUsesResponsesAPI
                    || bool(model["useResponseApi"], defaultValue: false)
                let capabilityShape = rikkaModelCapabilityShape(model)
                let customBody = customBodyOverrideParameters(from: model["customBodies"])
                return importedModel(
                    modelName: modelID,
                    displayName: displayName,
                    isActivated: enabled,
                    useResponsesAPI: modelUsesResponsesAPI,
                    overrideParameters: customBody,
                    kind: capabilityShape.kind,
                    inputModalities: capabilityShape.inputModalities,
                    outputModalities: capabilityShape.outputModalities,
                    capabilities: capabilityShape.capabilities
                )
            }

            let imported = Provider(
                id: stableUUID(from: string(provider["id"])) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: apiKey.isEmpty ? [] : [apiKey],
                apiFormat: format,
                models: normalizeModelsForProviderFormat(models, apiFormat: format)
            )
            result.append(imported)
        }

        return result
    }
}
