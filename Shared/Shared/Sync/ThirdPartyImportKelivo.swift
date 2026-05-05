// ============================================================================
// ThirdPartyImportKelivo.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 Kelivo 导出的提供商与会话数据。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseKelivo(fileURL: URL) throws -> ParsedPayload {
        var warnings: [String] = []
        var settings = [String: Any]()
        var chats = [String: Any]()

        if isDirectory(fileURL) {
            if let parsedSettings = findJSONInDirectory(fileURL, preferredNames: ["settings.json"]) {
                settings = parsedSettings
            }
            if let parsedChats = findJSONInDirectory(fileURL, preferredNames: ["chats.json"]) {
                chats = parsedChats
            }
        } else if let parsed = tryParseDictionaryJSON(from: fileURL) {
            if parsed["conversations"] != nil || parsed["messages"] != nil {
                chats = parsed
            } else {
                settings = parsed
            }
        } else if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "当前版本暂不支持直接读取压缩包，请先解压后再导入 settings.json/chats.json。"
            )
        }

        let providers = parseKelivoProviders(settings)
        let sessions = parseKelivoSessions(chats)

        if providers.isEmpty {
            warnings.append("Kelivo 备份中未识别到 provider_configs。")
        }
        if sessions.isEmpty {
            warnings.append("Kelivo 备份中未识别到 chats.json 会话。")
        }

        if providers.isEmpty && sessions.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "未识别到 Kelivo 备份中的可导入数据。"
            )
        }

        return ParsedPayload(
            providers: dedupeProviders(providers),
            sessions: sessions,
            warnings: warnings
        )
    }

    static func parseKelivoProviders(_ settings: [String: Any]) -> [Provider] {
        var result: [Provider] = []

        let rawConfigs = settings["provider_configs"] ?? settings["provider_configs_v1"]
        var configs: [String: Any] = [:]

        if let rawString = string(rawConfigs), let parsed = parseJSONStringToDictionary(rawString) {
            configs = parsed
        } else if let rawDict = dictionary(rawConfigs) {
            configs = rawDict
        }

        for (providerID, configAny) in configs {
            guard let config = dictionary(configAny) else { continue }

            let typeHint = nonEmpty(string(config["providerType"]))?.lowercased()
            let modelKeys = normalizeStringArray(config["models"])
            let modelOverrides = dictionary(config["modelOverrides"]) ?? [:]
            var apiModelIDCounts: [String: Int] = [:]
            for modelKey in modelKeys {
                guard let override = dictionary(modelOverrides[modelKey]),
                      let apiModelID = kelivoAPIModelID(from: override) else {
                    continue
                }
                apiModelIDCounts[apiModelID, default: 0] += 1
            }

            let format = normalizeProviderFormat(typeHint: typeHint, modelIDs: modelKeys)
            let name = nonEmpty(string(config["name"])) ?? providerID

            var keys: [String] = []
            if let key = nonEmpty(string(config["apiKey"])) {
                keys.append(key)
            }
            if let apiKeysRaw = array(config["apiKeys"]) {
                for apiKeyAny in apiKeysRaw {
                    guard let map = dictionary(apiKeyAny),
                          bool(map["isEnabled"], defaultValue: true),
                          string(map["status"])?.lowercased() != "disabled",
                          let key = nonEmpty(string(map["key"])) else {
                        continue
                    }
                    keys.append(key)
                }
            }
            keys = dedupeStrings(keys)

            let baseURL = normalizeBaseURL(string(config["baseUrl"]), for: format)
            let enabled = bool(config["enabled"], defaultValue: true)
            let providerUsesResponsesAPI = format == "openai-compatible"
                && bool(config["useResponseApi"], defaultValue: false)

            let modelList: [Model] = modelKeys.map { modelKey in
                let override = dictionary(modelOverrides[modelKey]) ?? [:]
                let apiModelID = kelivoAPIModelID(from: override)
                let shouldKeepLogicalModelName = apiModelID.map { (apiModelIDCounts[$0] ?? 0) > 1 } ?? false
                let modelName = shouldKeepLogicalModelName ? modelKey : (apiModelID ?? modelKey)
                let displayName = nonEmpty(string(override["name"])) ?? modelKey
                let capabilityShape = kelivoModelCapabilityShape(override)
                var customBody = customBodyOverrideParameters(
                    from: override["body"],
                    parseStringValues: true
                )
                if shouldKeepLogicalModelName, let apiModelID {
                    customBody["model"] = .string(apiModelID)
                }

                return importedModel(
                    modelName: modelName,
                    displayName: displayName,
                    isActivated: enabled,
                    useResponsesAPI: providerUsesResponsesAPI,
                    overrideParameters: customBody,
                    kind: capabilityShape.kind,
                    inputModalities: capabilityShape.inputModalities,
                    outputModalities: capabilityShape.outputModalities,
                    capabilities: capabilityShape.capabilities
                )
            }

            let provider = Provider(
                id: stableUUID(from: providerID) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: keys,
                apiFormat: format,
                models: normalizeModelsForProviderFormat(modelList, apiFormat: format),
                proxyConfiguration: networkProxyConfiguration(from: config)
            )
            result.append(provider)
        }

        return result
    }

    static func parseKelivoSessions(_ chats: [String: Any]) -> [SyncedSession] {
        let conversations = normalizeJSONArray(chats["conversations"])
        let messages = normalizeJSONArray(chats["messages"])

        var messagesByConversationID: [String: [[String: Any]]] = [:]
        for messageAny in messages {
            guard let message = dictionary(messageAny),
                  let conversationID = nonEmpty(string(message["conversationId"])) else {
                continue
            }
            messagesByConversationID[conversationID, default: []].append(message)
        }

        var sessions: [SyncedSession] = []
        sessions.reserveCapacity(conversations.count)

        for (index, conversationAny) in conversations.enumerated() {
            guard let conversation = dictionary(conversationAny) else { continue }
            let conversationID = nonEmpty(string(conversation["id"])) ?? "kelivo-conversation-\(index)"
            let title = nonEmpty(string(conversation["title"])) ?? "Kelivo 对话 \(index + 1)"
            let rawMessages = messagesByConversationID[conversationID] ?? []
            guard !rawMessages.isEmpty else { continue }

            let sortedMessages = rawMessages.sorted {
                let lhs = parseDate($0["timestamp"]) ?? .distantPast
                let rhs = parseDate($1["timestamp"]) ?? .distantPast
                return lhs < rhs
            }

            let converted: [ChatMessage] = sortedMessages.compactMap { message in
                let role = mapMessageRole(string(message["role"]))
                var content = nonEmpty(string(message["content"])) ?? ""
                let reasoning = nonEmpty(string(message["reasoningText"]))
                if content.isEmpty, let reasoning {
                    content = reasoning
                }
                guard !content.isEmpty else { return nil }

                var chatMessage = ChatMessage(
                    id: stableUUID(from: string(message["id"])) ?? UUID(),
                    role: role,
                    content: content,
                    reasoningContent: reasoning
                )
                if let totalTokens = int(message["totalTokens"]) {
                    chatMessage.tokenUsage = MessageTokenUsage(
                        promptTokens: nil,
                        completionTokens: nil,
                        totalTokens: totalTokens
                    )
                }
                return chatMessage
            }

            guard !converted.isEmpty else { continue }
            let session = ChatSession(
                id: stableUUID(from: conversationID) ?? UUID(),
                name: title,
                isTemporary: false
            )
            sessions.append(SyncedSession(session: session, messages: converted))
        }

        if sessions.isEmpty, !messagesByConversationID.isEmpty {
            for (index, pair) in messagesByConversationID.enumerated() {
                let conversationID = pair.key
                let rawMessages = pair.value

                let converted: [ChatMessage] = rawMessages.compactMap { message in
                    let role = mapMessageRole(string(message["role"]))
                    let content = nonEmpty(string(message["content"])) ?? nonEmpty(string(message["reasoningText"])) ?? ""
                    guard !content.isEmpty else { return nil }
                    return ChatMessage(
                        id: stableUUID(from: string(message["id"])) ?? UUID(),
                        role: role,
                        content: content
                    )
                }
                guard !converted.isEmpty else { continue }

                let session = ChatSession(
                    id: stableUUID(from: conversationID) ?? UUID(),
                    name: "Kelivo 对话 \(index + 1)",
                    isTemporary: false
                )
                sessions.append(SyncedSession(session: session, messages: converted))
            }
        }

        return sessions
    }
}
