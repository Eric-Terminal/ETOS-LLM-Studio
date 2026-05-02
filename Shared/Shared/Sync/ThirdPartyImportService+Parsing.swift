import Foundation
import CryptoKit

extension ThirdPartyImportService {
    struct ParsedPayload {
        var providers: [Provider]
        var sessions: [SyncedSession]
        var warnings: [String]
    }

    struct CherryBlockBundle {
        var textByBlockID: [String: String]
        var textByMessageID: [String: String]
    }

    static func makePackage(from parsed: ParsedPayload) throws -> SyncPackage {
        var options: SyncOptions = []
        if !parsed.providers.isEmpty {
            options.insert(.providers)
        }
        if !parsed.sessions.isEmpty {
            options.insert(.sessions)
        }
        guard !options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return SyncPackage(
            options: options,
            providers: parsed.providers,
            sessions: parsed.sessions
        )
    }

    // MARK: ETOS

    static func parseETOSBackup(fileURL: URL) throws -> SyncPackage {
        let rootURL: URL
        if isDirectory(fileURL) {
            guard let foundURL = findETOSJSONFile(inDirectory: fileURL) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: "未在目录中找到 ETOS 可识别的 JSON 导出包。"
                )
            }
            rootURL = foundURL
        } else {
            rootURL = fileURL
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "ETOS 数据包请直接选择 .json 文件，不支持压缩包。"
            )
        }

        guard let data = try? Data(contentsOf: rootURL) else {
            throw ThirdPartyImportError.fileNotReadable
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ThirdPartyImportError.invalidJSON
        }

        guard let package = try? SyncPackageTransferService.decodePackage(from: data) else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "文件不是可识别的 ETOS 导出数据包。"
            )
        }
        guard !package.options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return package
    }

    // MARK: Cherry Studio

    static func parseCherryStudio(fileURL: URL) throws -> ParsedPayload {
        let root = try loadCherryRoot(fileURL: fileURL)

        var warnings: [String] = []
        var providers: [Provider] = []
        var sessions: [SyncedSession] = []

        let localStorage = dictionary(root["localStorage"])
        let indexedDB = dictionary(root["indexedDB"])

        if localStorage == nil {
            warnings.append("Cherry 备份未找到 localStorage。")
        }
        if indexedDB == nil {
            warnings.append("Cherry 备份未找到 indexedDB。")
        }

        let persistRaw = string(localStorage?["persist:cherry-studio"])
        var persist = [String: Any]()
        if let persistRaw, let parsed = parseJSONStringToDictionary(persistRaw) {
            persist = parsed
        }

        // providers
        if let llmRaw = string(persist["llm"]),
           let llm = parseJSONStringToDictionary(llmRaw),
           let providerList = array(llm["providers"]) {
            providers = parseCherryProviders(providerList)
        }

        // topic metadata
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

        // sessions
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
                    // 1) 优先按 message.blocks 回填
                    if let blocks = array(message["blocks"]) {
                        let pieces = blocks.compactMap { blockAny -> String? in
                            guard let blockID = nonEmpty(string(blockAny)) else { return nil }
                            return blockBundle.textByBlockID[blockID]
                        }
                        if !pieces.isEmpty {
                            content = pieces.joined(separator: "\n")
                        }
                    }

                    // 2) 再按 messageId 回填
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
                reason: "Cherry 备份格式无法识别，或文件中没有可导入数据。"
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
                reason: "当前版本暂不支持直接读取压缩包，请先解压后选择包含 JSON 的文件或目录。"
            )
        }

        if isDirectory(fileURL),
           let root = try findFirstDictionaryJSON(inDirectory: fileURL, where: looksLikeCherryRoot) {
            return root
        }

        throw ThirdPartyImportError.unsupportedBackupFormat(
            reason: "无法识别 Cherry 备份结构（需包含 localStorage 与 indexedDB）。"
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

            let imported = Provider(
                id: stableUUID(from: string(provider["id"])) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: apiKeys,
                apiFormat: format,
                models: modelList,
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

    // MARK: RikkaHub

    static func parseRikkaHub(fileURL: URL) throws -> ParsedPayload {
        var warnings: [String] = [
            "RikkaHub 备份当前仅支持读取 settings.json 中的提供商配置，会话内容暂未解析。"
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
                    reason: "当前版本暂不支持直接读取压缩包，请先解压后再导入 settings.json。"
                )
            }
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "未找到 RikkaHub 可识别的 settings.json。"
            )
        }

        let providerList = normalizeJSONArray(settings["providers"])
        let providers = parseRikkaProviders(providerList)

        if providers.isEmpty {
            warnings.append("未在 RikkaHub 备份中识别到可导入的提供商。")
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
                models: models
            )
            result.append(imported)
        }

        return result
    }

    // MARK: Kelivo

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
                models: modelList,
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

        // 兼容 conversations 缺失但 messages 有数据的场景
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

    // MARK: ChatGPT

    static func parseChatGPT(fileURL: URL) throws -> ParsedPayload {
        let rootURL: URL
        if isDirectory(fileURL) {
            guard let conversationsURL = findFileInDirectory(
                fileURL,
                preferredNames: ["conversations.json"]
            ) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: "未在目录中找到 conversations.json。"
                )
            }
            rootURL = conversationsURL
        } else {
            rootURL = fileURL
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "当前版本暂不支持直接读取压缩包，请先解压后导入 conversations.json。"
            )
        }

        guard let data = try? Data(contentsOf: rootURL) else {
            throw ThirdPartyImportError.fileNotReadable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ThirdPartyImportError.invalidJSON
        }

        let sessions = try parseChatGPTJSONRoot(json)
        guard !sessions.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }

        return ParsedPayload(providers: [], sessions: sessions, warnings: [])
    }

    static func parseChatGPTJSONRoot(_ json: Any) throws -> [SyncedSession] {
        let conversations: [[String: Any]]
        if let list = json as? [[String: Any]] {
            conversations = list
        } else if let root = json as? [String: Any] {
            let list: [[String: Any]] = normalizeJSONArray(root["conversations"]).compactMap(dictionary)
            if !list.isEmpty {
                conversations = list
            } else if root["mapping"] != nil || root["messages"] != nil {
                conversations = [root]
            } else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: "未识别到 ChatGPT conversations.json 结构。"
                )
            }
        } else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: "未识别到 ChatGPT conversations.json 结构。"
            )
        }

        var sessions: [SyncedSession] = []
        sessions.reserveCapacity(conversations.count)

        for (index, conversation) in conversations.enumerated() {
            let title = nonEmpty(string(conversation["title"])) ?? "ChatGPT 对话 \(index + 1)"

            let messages: [ChatMessage]
            if let mapping = dictionary(conversation["mapping"]) {
                messages = extractChatGPTTreeMessages(mapping: mapping, currentNode: string(conversation["current_node"]))
            } else {
                messages = extractChatGPTFlatMessages(normalizeJSONArray(conversation["messages"]))
            }

            guard !messages.isEmpty else { continue }
            let session = ChatSession(
                id: stableUUID(from: string(conversation["id"])) ?? UUID(),
                name: title,
                isTemporary: false
            )
            sessions.append(SyncedSession(session: session, messages: messages))
        }

        return sessions
    }

    static func extractChatGPTTreeMessages(
        mapping: [String: Any],
        currentNode: String?
    ) -> [ChatMessage] {
        var chain: [String] = []
        var nodeID = nonEmpty(currentNode)

        if nodeID == nil {
            // 找叶子节点
            for (candidateID, nodeAny) in mapping {
                guard let node = dictionary(nodeAny) else { continue }
                let children = normalizeJSONArray(node["children"])
                if children.isEmpty {
                    nodeID = candidateID
                    break
                }
            }
        }

        while let id = nodeID, let node = dictionary(mapping[id]) {
            chain.insert(id, at: 0)
            nodeID = nonEmpty(string(node["parent"]))
        }

        var result: [ChatMessage] = []
        for id in chain {
            guard let node = dictionary(mapping[id]),
                  let message = dictionary(node["message"]) else {
                continue
            }

            let role = mapMessageRole(string(dictionary(message["author"])?["role"]))
            if role == .tool { continue }

            let content = extractChatGPTMessageContent(message)
            guard !content.isEmpty else { continue }

            var chatMessage = ChatMessage(
                id: stableUUID(from: string(message["id"])) ?? UUID(),
                role: role,
                content: content
            )
            if let createdAt = parseDate(message["create_time"]) {
                chatMessage.responseMetrics = MessageResponseMetrics(
                    requestStartedAt: createdAt,
                    responseCompletedAt: createdAt
                )
            }
            result.append(chatMessage)
        }

        return result
    }

    static func extractChatGPTFlatMessages(_ rawMessages: [Any]) -> [ChatMessage] {
        rawMessages.compactMap { messageAny in
            guard let message = dictionary(messageAny) else { return nil }
            let role = mapMessageRole(string(message["role"]) ?? string(dictionary(message["author"])?["role"]))
            var content = nonEmpty(string(message["content"])) ?? ""
            if content.isEmpty {
                content = flattenText(message["parts"]) ?? flattenText(dictionary(message["content"])?["parts"]) ?? ""
            }
            guard !content.isEmpty else { return nil }
            return ChatMessage(
                id: stableUUID(from: string(message["id"])) ?? UUID(),
                role: role,
                content: content
            )
        }
    }

    static func extractChatGPTMessageContent(_ message: [String: Any]) -> String {
        if let content = nonEmpty(string(message["content"])) {
            return content
        }

        if let contentObject = dictionary(message["content"]) {
            if let partsText = flattenText(contentObject["parts"]), !partsText.isEmpty {
                return partsText
            }
            if let text = nonEmpty(string(contentObject["text"])) {
                return text
            }
        }

        if let partsText = flattenText(message["parts"]), !partsText.isEmpty {
            return partsText
        }

        return ""
    }
}
