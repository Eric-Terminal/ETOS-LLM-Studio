// ============================================================================
// ThirdPartyImportCherryStudio.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 Cherry Studio 导出的提供商与会话数据。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    struct CherryBlockBundle {
        var textByBlockID: [String: String]
        var textByMessageID: [String: String]
    }

    static func parseCherryStudio(fileURL: URL) throws -> ParsedPayload {
        let root = try loadCherryRoot(fileURL: fileURL)

        var warnings: [String] = []
        var providers: [Provider] = []
        var sessions: [SyncedSession] = []

        let localStorage = dictionary(root["localStorage"])
        let indexedDB = dictionary(root["indexedDB"])

        if localStorage == nil {
            warnings.append(NSLocalizedString("Cherry 备份未找到 localStorage。", comment: "Cherry import missing localStorage warning"))
        }
        if indexedDB == nil {
            warnings.append(NSLocalizedString("Cherry 备份未找到 indexedDB。", comment: "Cherry import missing indexedDB warning"))
        }

        let persistRaw = string(localStorage?["persist:cherry-studio"])
        var persist = [String: Any]()
        if let persistRaw, let parsed = parseJSONStringToDictionary(persistRaw) {
            persist = parsed
        }

        if let llmRaw = string(persist["llm"]),
           let llm = parseJSONStringToDictionary(llmRaw),
           let providerList = array(llm["providers"]) {
            providers = parseCherryProviders(providerList)
        }

        var topicNameByID: [String: String] = [:]
        if let assistantsRaw = string(persist["assistants"]),
           let assistantsSlice = parseJSONStringToDictionary(assistantsRaw),
           let assistants = array(assistantsSlice["assistants"]) {
            for assistantAny in assistants {
                guard let assistant = dictionary(assistantAny),
                      let topics = array(assistant["topics"]) else {
                    continue
                }
                for topicAny in topics {
                    guard let topic = dictionary(topicAny),
                          let topicID = nonEmpty(string(topic["id"])) else {
                        continue
                    }
                    let topicName = nonEmpty(string(topic["name"]))
                    if let topicName {
                        topicNameByID[topicID] = topicName
                    }
                }
            }
        }

        let topicsAny = indexedDB?["topics"]
        let messageBlocksAny = indexedDB?["message_blocks"]
        let topics = normalizeJSONArray(topicsAny)
        let messageBlocks = normalizeJSONArray(messageBlocksAny)
        let blockBundle = parseCherryMessageBlocks(messageBlocks)

        for (index, topicAny) in topics.enumerated() {
            guard let topic = dictionary(topicAny) else { continue }
            let topicID = nonEmpty(string(topic["id"])) ?? "cherry-topic-\(index)"
            let topicName = nonEmpty(string(topic["name"]))
                ?? topicNameByID[topicID]
                ?? "Cherry 对话 \(index + 1)"

            let rawMessages = normalizeJSONArray(topic["messages"])
            guard !rawMessages.isEmpty else { continue }

            var messages: [ChatMessage] = []
            messages.reserveCapacity(rawMessages.count)

            for messageAny in rawMessages {
                guard let message = dictionary(messageAny) else { continue }

                let messageID = string(message["id"])
                let role = mapMessageRole(string(message["role"]))
                var content = nonEmpty(string(message["content"])) ?? ""

                if content.isEmpty {
                    if let blocks = array(message["blocks"]) {
                        let pieces = blocks.compactMap { blockAny -> String? in
                            guard let blockID = nonEmpty(string(blockAny)) else { return nil }
                            return blockBundle.textByBlockID[blockID]
                        }
                        if !pieces.isEmpty {
                            content = pieces.joined(separator: "\n")
                        }
                    }

                    if content.isEmpty,
                       let messageID,
                       let fallback = blockBundle.textByMessageID[messageID] {
                        content = fallback
                    }
                }

                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                var chatMessage = ChatMessage(
                    id: stableUUID(from: messageID) ?? UUID(),
                    role: role,
                    content: content
                )
                let timestamp = parseDate(
                    message["createdAt"]
                        ?? message["created_at"]
                        ?? message["timestamp"]
                )
                if let timestamp {
                    chatMessage.responseMetrics = MessageResponseMetrics(
                        requestStartedAt: timestamp,
                        responseCompletedAt: timestamp
                    )
                }
                messages.append(chatMessage)
            }

            guard !messages.isEmpty else { continue }

            let session = ChatSession(
                id: stableUUID(from: topicID) ?? UUID(),
                name: topicName,
                isTemporary: false
            )
            sessions.append(SyncedSession(session: session, messages: messages))
        }

        if providers.isEmpty && sessions.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("Cherry 备份格式无法识别，或文件中没有可导入数据。", comment: "Cherry import unrecognized or empty backup")
            )
        }

        return ParsedPayload(
            providers: dedupeProviders(providers),
            sessions: sessions,
            warnings: warnings
        )
    }

    static func loadCherryRoot(fileURL: URL) throws -> [String: Any] {
        if let root = tryParseDictionaryJSON(from: fileURL), looksLikeCherryRoot(root) {
            return root
        }

        if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后选择包含 JSON 的文件或目录。", comment: "Cherry import compressed backup unsupported")
            )
        }

        if isDirectory(fileURL),
           let root = try findFirstDictionaryJSON(inDirectory: fileURL, where: looksLikeCherryRoot) {
            return root
        }

        throw ThirdPartyImportError.unsupportedBackupFormat(
            reason: NSLocalizedString("无法识别 Cherry 备份结构（需包含 localStorage 与 indexedDB）。", comment: "Cherry import unrecognized backup structure")
        )
    }

    static func looksLikeCherryRoot(_ root: [String: Any]) -> Bool {
        root["localStorage"] != nil && root["indexedDB"] != nil
    }

    static func parseCherryProviders(_ providerList: [Any]) -> [Provider] {
        var result: [Provider] = []
        result.reserveCapacity(providerList.count)

        for providerAny in providerList {
            guard let provider = dictionary(providerAny) else { continue }

            let type = string(provider["type"])?.lowercased()
            let name = nonEmpty(string(provider["name"])) ?? "Cherry Studio"
            let rawHost = nonEmpty(string(provider["apiHost"]))
            let rawApiKey = string(provider["apiKey"]) ?? ""
            let apiKeys = splitAPIKeys(rawApiKey)
            let modelEntries = normalizeJSONArray(provider["models"])
            let providerUsesResponsesAPI = isOpenAIResponsesType(type)
            let enabled = bool(provider["enabled"], defaultValue: true)
            let headerOverrides = stringDictionary(provider["extra_headers"])

            let modelList: [Model] = modelEntries.compactMap { modelAny in
                guard let modelMap = dictionary(modelAny) else { return nil }
                let modelID = nonEmpty(string(modelMap["id"]))
                    ?? nonEmpty(string(modelMap["modelId"]))
                guard let modelID else { return nil }
                let displayName = nonEmpty(string(modelMap["name"]))
                    ?? nonEmpty(string(modelMap["displayName"]))
                    ?? modelID
                let modelUsesResponsesAPI = providerUsesResponsesAPI
                    || isOpenAIResponsesType(string(modelMap["endpoint_type"]))
                let capabilityShape = cherryModelCapabilityShape(modelMap)
                return importedModel(
                    modelName: modelID,
                    displayName: displayName,
                    isActivated: enabled,
                    useResponsesAPI: modelUsesResponsesAPI,
                    kind: capabilityShape.kind,
                    inputModalities: capabilityShape.inputModalities,
                    outputModalities: capabilityShape.outputModalities,
                    capabilities: capabilityShape.capabilities
                )
            }

            let format = normalizeProviderFormat(typeHint: type, modelIDs: modelList.map(\.modelName))
            let baseURL = normalizeBaseURL(rawHost, for: format)
            let normalizedModels = normalizeModelsForProviderFormat(modelList, apiFormat: format)

            let imported = Provider(
                id: stableUUID(from: string(provider["id"])) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: apiKeys,
                apiFormat: format,
                models: normalizedModels,
                headerOverrides: headerOverrides
            )
            result.append(imported)
        }

        return result
    }

    static func parseCherryMessageBlocks(_ blocks: [Any]) -> CherryBlockBundle {
        var textByBlockID: [String: String] = [:]
        var textByMessageIDPieces: [String: [String]] = [:]

        for blockAny in blocks {
            guard let block = dictionary(blockAny) else { continue }
            let blockID = nonEmpty(string(block["id"]))
            let messageID = nonEmpty(string(block["messageId"]))
            let type = string(block["type"])?.lowercased() ?? ""

            var text: String = ""
            switch type {
            case "main_text", "text":
                text = nonEmpty(string(block["content"])) ?? ""
            case "code":
                let code = nonEmpty(string(block["content"])) ?? ""
                if !code.isEmpty {
                    let language = nonEmpty(string(block["language"])) ?? ""
                    text = "```\(language)\n\(code)\n```"
                }
            case "thinking":
                text = nonEmpty(string(block["content"])) ?? ""
            case "error":
                if let content = nonEmpty(string(block["content"])) {
                    text = "[错误] \(content)"
                }
            case "tool":
                if let content = nonEmpty(string(block["content"])) {
                    text = content
                }
            default:
                text = nonEmpty(string(block["content"])) ?? ""
            }

            guard !text.isEmpty else { continue }
            if let blockID {
                textByBlockID[blockID] = text
            }
            if let messageID {
                textByMessageIDPieces[messageID, default: []].append(text)
            }
        }

        let textByMessageID = textByMessageIDPieces.mapValues { $0.joined(separator: "\n") }
        return CherryBlockBundle(textByBlockID: textByBlockID, textByMessageID: textByMessageID)
    }
}
