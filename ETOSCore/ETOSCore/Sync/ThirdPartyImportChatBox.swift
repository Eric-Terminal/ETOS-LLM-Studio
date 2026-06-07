// ============================================================================
// ThirdPartyImportChatBox.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 ChatBox 导出的提供商配置与会话数据。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    struct ChatBoxProviderReference {
        var provider: Provider
        var modelByChatBoxModelID: [String: Model]
    }

    struct ChatBoxProviderBundle {
        var providers: [Provider]
        var referenceByChatBoxProviderID: [String: ChatBoxProviderReference]
    }

    struct ChatBoxProviderDefinition {
        var name: String
        var apiFormat: String
        var defaultBaseURL: String
        var isSupported: Bool
    }

    static func parseChatBox(fileURL: URL) throws -> ParsedPayload {
        let root = try loadChatBoxRoot(fileURL: fileURL)

        var warnings: [String] = []
        let settings = chatBoxSettings(from: root)
        if settings == nil {
            warnings.append(NSLocalizedString("ChatBox 导出未找到 settings，提供商配置未导入。", comment: "ChatBox import missing settings warning"))
        }

        let sessionEntries = chatBoxSessionEntries(from: root)
        let referencedModels = collectChatBoxReferencedModels(
            settings: settings,
            sessionEntries: sessionEntries
        )
        let providerBundle = parseChatBoxProviders(
            settings,
            referencedModelsByProvider: referencedModels,
            warnings: &warnings
        )
        let sessions = parseChatBoxSessions(
            sessionEntries,
            providerReferences: providerBundle.referenceByChatBoxProviderID
        )

        if providerBundle.providers.isEmpty {
            warnings.append(NSLocalizedString("ChatBox 导出未识别到可导入的提供商配置。", comment: "ChatBox import missing providers warning"))
        }
        if sessions.isEmpty {
            warnings.append(NSLocalizedString("ChatBox 导出未识别到会话记录。", comment: "ChatBox import missing sessions warning"))
        }

        if providerBundle.providers.isEmpty && sessions.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未识别到 ChatBox 导出中的可导入数据。", comment: "ChatBox import no importable data")
            )
        }

        return ParsedPayload(
            providers: providerBundle.providers,
            sessions: sessions,
            warnings: dedupeStrings(warnings)
        )
    }

    static func loadChatBoxRoot(fileURL: URL) throws -> [String: Any] {
        if isDirectory(fileURL),
           let root = try findFirstDictionaryJSON(inDirectory: fileURL, where: looksLikeChatBoxRoot) {
            return root
        }

        if isDirectory(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("ChatBox 导出不是可识别的 JSON 备份。", comment: "ChatBox import unrecognized backup")
            )
        }

        if let root = tryParseDictionaryJSON(from: fileURL), looksLikeChatBoxRoot(root) {
            return root
        }

        if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后导入 ChatBox 导出的 JSON。", comment: "ChatBox import compressed backup unsupported")
            )
        }

        if tryParseDictionaryJSON(from: fileURL) == nil {
            throw ThirdPartyImportError.invalidJSON
        }

        throw ThirdPartyImportError.unsupportedBackupFormat(
            reason: NSLocalizedString("ChatBox 导出不是可识别的 JSON 备份。", comment: "ChatBox import unrecognized backup")
        )
    }

    static func looksLikeChatBoxRoot(_ root: [String: Any]) -> Bool {
        if root["settings"] != nil
            || root["chat-sessions-list"] != nil
            || root["chat-sessions"] != nil
            || root["__exported_items"] != nil {
            return true
        }

        if root.keys.contains(where: { $0.hasPrefix("session:") }) {
            return true
        }

        return looksLikeChatBoxSettings(root) || looksLikeChatBoxSession(root)
    }

    static func looksLikeChatBoxSettings(_ root: [String: Any]) -> Bool {
        root["providers"] != nil
            || root["customProviders"] != nil
            || root["defaultChatModel"] != nil
            || root["defaultPrompt"] != nil
    }

    static func looksLikeChatBoxSession(_ root: [String: Any]) -> Bool {
        root["messages"] != nil
            && root["id"] != nil
            && root["name"] != nil
    }

    static func chatBoxSettings(from root: [String: Any]) -> [String: Any]? {
        if let settings = chatBoxDictionary(root["settings"]) {
            return unwrapChatBoxPersistedState(settings)
        }

        if looksLikeChatBoxSettings(root) {
            return unwrapChatBoxPersistedState(root)
        }

        return nil
    }

    static func unwrapChatBoxPersistedState(_ value: [String: Any]) -> [String: Any] {
        if let state = chatBoxDictionary(value["state"]) {
            return state
        }
        return value
    }

    static func chatBoxSessionEntries(from root: [String: Any]) -> [(sourceID: String, session: [String: Any])] {
        if looksLikeChatBoxSession(root) {
            return [(nonEmpty(string(root["id"])) ?? "single-session", root)]
        }

        var sessionByID: [String: [String: Any]] = [:]
        for (key, value) in root where key.hasPrefix("session:") {
            guard let session = chatBoxDictionary(value) else { continue }
            let fallbackID = String(key.dropFirst("session:".count))
            let sessionID = nonEmpty(string(session["id"])) ?? fallbackID
            sessionByID[sessionID] = session
        }

        var orderedIDs: [String] = []
        for metaAny in normalizeJSONArray(root["chat-sessions-list"]) {
            guard let meta = chatBoxDictionary(metaAny),
                  let id = nonEmpty(string(meta["id"])) else {
                continue
            }
            orderedIDs.append(id)
        }

        var result: [(sourceID: String, session: [String: Any])] = []
        var emitted = Set<String>()
        for id in orderedIDs {
            guard let session = sessionByID[id], emitted.insert(id).inserted else { continue }
            result.append((id, session))
        }

        for id in sessionByID.keys.sorted() where !emitted.contains(id) {
            guard let session = sessionByID[id] else { continue }
            emitted.insert(id)
            result.append((id, session))
        }

        for (index, sessionAny) in normalizeJSONArray(root["chat-sessions"]).enumerated() {
            guard let session = chatBoxDictionary(sessionAny) else { continue }
            let sessionID = nonEmpty(string(session["id"])) ?? "legacy-\(index)"
            guard emitted.insert(sessionID).inserted else { continue }
            result.append((sessionID, session))
        }

        return result
    }

    static func collectChatBoxReferencedModels(
        settings: [String: Any]?,
        sessionEntries: [(sourceID: String, session: [String: Any])]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]

        func record(provider: String?, model: String?) {
            guard let provider = nonEmpty(provider),
                  let model = nonEmpty(model) else {
                return
            }
            result[provider, default: []].insert(model)
        }

        if let settings {
            for key in ["defaultChatModel", "threadNamingModel", "searchTermConstructionModel", "ocrModel"] {
                guard let modelRef = chatBoxDictionary(settings[key]) else { continue }
                record(provider: string(modelRef["provider"]), model: string(modelRef["model"]))
            }

            for favoriteAny in normalizeJSONArray(settings["favoritedModels"]) {
                guard let favorite = chatBoxDictionary(favoriteAny) else { continue }
                record(provider: string(favorite["provider"]), model: string(favorite["model"]))
            }
        }

        for entry in sessionEntries {
            let session = entry.session
            let sessionSettings = chatBoxDictionary(session["settings"])
            let fallbackProvider = string(sessionSettings?["provider"])
            let fallbackModel = string(sessionSettings?["modelId"])
            record(provider: fallbackProvider, model: fallbackModel)

            for message in chatBoxAllMessageMaps(in: session) {
                record(
                    provider: string(message["aiProvider"]) ?? fallbackProvider,
                    model: string(message["model"]) ?? fallbackModel
                )
            }
        }

        return result
    }

    static func parseChatBoxProviders(
        _ settings: [String: Any]?,
        referencedModelsByProvider: [String: Set<String>],
        warnings: inout [String]
    ) -> ChatBoxProviderBundle {
        guard let settings else {
            return ChatBoxProviderBundle(providers: [], referenceByChatBoxProviderID: [:])
        }

        let providerSettingsByID = chatBoxDictionary(settings["providers"]) ?? [:]
        let customProviderByID = normalizeJSONArray(settings["customProviders"]).reduce(into: [String: [String: Any]]()) { result, customAny in
            guard let custom = chatBoxDictionary(customAny),
                  let id = nonEmpty(string(custom["id"])) else {
                return
            }
            result[id] = custom
        }
        let candidateIDs = Set(providerSettingsByID.keys).union(customProviderByID.keys)
        var providers: [Provider] = []
        var references: [String: ChatBoxProviderReference] = [:]
        var warnedUnsupported = Set<String>()
        var warnedChatBoxAI = false

        for providerID in candidateIDs.sorted() {
            if providerID == "chatbox-ai" {
                if !warnedChatBoxAI {
                    warnings.append(NSLocalizedString("ChatBox 导出包含 Chatbox AI 专用授权或内置服务配置，ELS 无法直接迁移这类账号授权。", comment: "ChatBox import skips Chatbox AI warning"))
                    warnedChatBoxAI = true
                }
                continue
            }

            let settingsMap = chatBoxDictionary(providerSettingsByID[providerID]) ?? [:]
            let customInfo = customProviderByID[providerID]
            let typeHint = nonEmpty(string(customInfo?["type"]))
            let definition = chatBoxProviderDefinition(providerID: providerID, typeHint: typeHint)
            guard definition.isSupported else {
                if warnedUnsupported.insert(providerID).inserted {
                    warnings.append(
                        String(
                            format: NSLocalizedString("ChatBox 提供商 %@ 使用了暂不支持的专用配置，已跳过。", comment: "ChatBox import skips unsupported provider warning"),
                            nonEmpty(string(customInfo?["name"])) ?? definition.name
                        )
                    )
                }
                continue
            }

            let models = chatBoxImportedModels(
                providerID: providerID,
                settingsMap: settingsMap,
                customInfo: customInfo,
                referencedModelIDs: referencedModelsByProvider[providerID] ?? []
            )
            let name = nonEmpty(string(customInfo?["name"])) ?? definition.name
            let baseURL = normalizeBaseURL(
                nonEmpty(string(settingsMap["apiHost"]))
                    ?? nonEmpty(string(settingsMap["endpoint"]))
                    ?? chatBoxDefaultSettingsBaseURL(customInfo)
                    ?? definition.defaultBaseURL,
                for: definition.apiFormat
            )
            let provider = Provider(
                id: stableUUID(from: "chatbox-provider:\(providerID)") ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: splitAPIKeys(string(settingsMap["apiKey"]) ?? ""),
                apiFormat: definition.apiFormat,
                models: normalizeModelsForProviderFormat(models, apiFormat: definition.apiFormat)
            )
            providers.append(provider)
            references[providerID] = ChatBoxProviderReference(
                provider: provider,
                modelByChatBoxModelID: Dictionary(uniqueKeysWithValues: provider.models.map { ($0.modelName, $0) })
            )
        }

        return ChatBoxProviderBundle(
            providers: dedupeProviders(providers),
            referenceByChatBoxProviderID: references
        )
    }

    static func chatBoxDefaultSettingsBaseURL(_ customInfo: [String: Any]?) -> String? {
        guard let defaultSettings = chatBoxDictionary(customInfo?["defaultSettings"]) else {
            return nil
        }
        return nonEmpty(string(defaultSettings["apiHost"]))
    }

    static func chatBoxImportedModels(
        providerID: String,
        settingsMap: [String: Any],
        customInfo: [String: Any]?,
        referencedModelIDs: Set<String>
    ) -> [Model] {
        let excludedModels = Set(normalizeStringArray(settingsMap["excludedModels"]))
        var modelMaps = normalizeJSONArray(settingsMap["models"]).compactMap(chatBoxDictionary)
        if modelMaps.isEmpty,
           let defaultSettings = chatBoxDictionary(customInfo?["defaultSettings"]) {
            modelMaps = normalizeJSONArray(defaultSettings["models"]).compactMap(chatBoxDictionary)
        }

        var result: [Model] = []
        var seenModelIDs = Set<String>()

        for modelMap in modelMaps {
            let modelID = nonEmpty(string(modelMap["modelId"]) ?? string(modelMap["id"])) ?? ""
            guard let model = chatBoxImportedModel(
                providerID: providerID,
                modelMap: modelMap,
                isActivated: !excludedModels.contains(modelID)
            ) else {
                continue
            }
            if seenModelIDs.insert(model.modelName).inserted {
                result.append(model)
            }
        }

        for modelID in referencedModelIDs.sorted() where !seenModelIDs.contains(modelID) {
            var model = importedModel(
                modelName: modelID,
                displayName: modelID,
                isActivated: !excludedModels.contains(modelID),
                kind: nil,
                capabilities: nil
            ).applyingInferredCapabilityHints()
            if let id = stableUUID(from: "chatbox-model:\(providerID):\(modelID)") {
                model.id = id
            }
            result.append(model)
            seenModelIDs.insert(modelID)
        }

        return result
    }

    static func chatBoxImportedModel(
        providerID: String,
        modelMap: [String: Any],
        isActivated: Bool
    ) -> Model? {
        guard let modelID = nonEmpty(string(modelMap["modelId"]) ?? string(modelMap["id"])) else {
            return nil
        }

        let displayName = nonEmpty(string(modelMap["nickname"]))
            ?? nonEmpty(string(modelMap["name"]))
            ?? nonEmpty(string(modelMap["displayName"]))
            ?? modelID
        let rawType = string(modelMap["type"])
        let kind = modelKind(from: rawType)
        let capabilityValues = Set(normalizeStringArray(modelMap["capabilities"]).map(normalizedTypeString))
        let hasCapabilityField = modelMap.keys.contains("capabilities")
        let inputModalities: [ModelModality]? = capabilityValues.contains("vision")
            ? [.text, .image]
            : nil
        let capabilities = chatBoxModelCapabilities(
            from: capabilityValues,
            fieldPresent: hasCapabilityField,
            kind: kind
        )

        var model = importedModel(
            modelName: modelID,
            displayName: displayName,
            isActivated: isActivated,
            kind: kind,
            inputModalities: inputModalities,
            capabilities: capabilities
        )
        if !hasCapabilityField && kind == nil {
            model = model.applyingInferredCapabilityHints()
        }
        if let id = stableUUID(from: "chatbox-model:\(providerID):\(modelID)") {
            model.id = id
        }
        return model
    }

    static func chatBoxModelCapabilities(
        from values: Set<String>,
        fieldPresent: Bool,
        kind: ModelKind?
    ) -> [ModelCapability]? {
        if kind == .embedding {
            return []
        }

        var result: [ModelCapability] = []
        if values.contains("tool-use")
            || values.contains("tool")
            || values.contains("tools")
            || values.contains("function-calling")
            || values.contains("tool-calling") {
            result.append(.toolCalling)
        }
        if values.contains("reasoning") {
            result.append(.reasoning)
        }

        if result.isEmpty {
            return fieldPresent ? [] : nil
        }
        return Model.orderedCapabilities(result)
    }

    static func chatBoxProviderDefinition(providerID: String, typeHint: String?) -> ChatBoxProviderDefinition {
        switch providerID {
        case "openai":
            return ChatBoxProviderDefinition(name: "OpenAI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.openai.com", isSupported: true)
        case "openai-responses":
            return ChatBoxProviderDefinition(name: "OpenAI Responses", apiFormat: "openai-responses", defaultBaseURL: "https://api.openai.com", isSupported: true)
        case "claude":
            return ChatBoxProviderDefinition(name: "Claude", apiFormat: "anthropic", defaultBaseURL: "https://api.anthropic.com", isSupported: true)
        case "gemini":
            return ChatBoxProviderDefinition(name: "Gemini", apiFormat: "gemini", defaultBaseURL: "https://generativelanguage.googleapis.com", isSupported: true)
        case "ollama":
            return ChatBoxProviderDefinition(name: "Ollama", apiFormat: "openai-compatible", defaultBaseURL: "http://127.0.0.1:11434", isSupported: true)
        case "groq":
            return ChatBoxProviderDefinition(name: "Groq", apiFormat: "openai-compatible", defaultBaseURL: "https://api.groq.com/openai", isSupported: true)
        case "deepseek":
            return ChatBoxProviderDefinition(name: "DeepSeek", apiFormat: "openai-compatible", defaultBaseURL: "https://api.deepseek.com", isSupported: true)
        case "siliconflow":
            return ChatBoxProviderDefinition(name: "SiliconFlow", apiFormat: "openai-compatible", defaultBaseURL: "https://api.siliconflow.cn", isSupported: true)
        case "volcengine":
            return ChatBoxProviderDefinition(name: "VolcEngine", apiFormat: "openai-compatible", defaultBaseURL: "https://ark.cn-beijing.volces.com", isSupported: true)
        case "mistral-ai":
            return ChatBoxProviderDefinition(name: "Mistral AI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.mistral.ai/v1", isSupported: true)
        case "lm-studio":
            return ChatBoxProviderDefinition(name: "LM Studio", apiFormat: "openai-compatible", defaultBaseURL: "http://127.0.0.1:1234", isSupported: true)
        case "perplexity":
            return ChatBoxProviderDefinition(name: "Perplexity", apiFormat: "openai-compatible", defaultBaseURL: "https://api.perplexity.ai", isSupported: true)
        case "xAI", "xai":
            return ChatBoxProviderDefinition(name: "xAI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.x.ai", isSupported: true)
        case "openrouter":
            return ChatBoxProviderDefinition(name: "OpenRouter", apiFormat: "openai-compatible", defaultBaseURL: "https://openrouter.ai/api/v1", isSupported: true)
        case "chatglm-6b":
            return ChatBoxProviderDefinition(name: "ChatGLM6B", apiFormat: "openai-compatible", defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4", isSupported: true)
        case "qwen":
            return ChatBoxProviderDefinition(name: "Qwen", apiFormat: "openai-compatible", defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", isSupported: true)
        case "qwen-portal":
            return ChatBoxProviderDefinition(name: "Qwen Portal", apiFormat: "openai-compatible", defaultBaseURL: "https://portal.qwen.ai/v1", isSupported: true)
        case "minimax":
            return ChatBoxProviderDefinition(name: "MiniMax Global", apiFormat: "openai-compatible", defaultBaseURL: "https://api.minimax.io/v1", isSupported: true)
        case "minimax-cn":
            return ChatBoxProviderDefinition(name: "MiniMax CN", apiFormat: "openai-compatible", defaultBaseURL: "https://api.minimaxi.com/v1", isSupported: true)
        case "moonshot":
            return ChatBoxProviderDefinition(name: "Moonshot AI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.moonshot.ai/v1", isSupported: true)
        case "moonshot-cn":
            return ChatBoxProviderDefinition(name: "Moonshot CN", apiFormat: "openai-compatible", defaultBaseURL: "https://api.moonshot.cn/v1", isSupported: true)
        case "azure", "bedrock":
            return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-compatible", defaultBaseURL: "", isSupported: false)
        default:
            let normalized = normalizedTypeString(typeHint)
            if normalized == "claude" || normalized == "anthropic" {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "anthropic", defaultBaseURL: "https://api.anthropic.com", isSupported: true)
            }
            if normalized == "gemini" || normalized == "google" {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "gemini", defaultBaseURL: "https://generativelanguage.googleapis.com", isSupported: true)
            }
            if isOpenAIResponsesType(normalized) {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-responses", defaultBaseURL: "https://api.openai.com", isSupported: true)
            }
            return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-compatible", defaultBaseURL: "https://api.openai.com", isSupported: true)
        }
    }

    static func parseChatBoxSessions(
        _ entries: [(sourceID: String, session: [String: Any])],
        providerReferences: [String: ChatBoxProviderReference]
    ) -> [SyncedSession] {
        var sessions: [SyncedSession] = []

        for (index, entry) in entries.enumerated() {
            let sourceID = entry.sourceID
            let session = entry.session
            if normalizedTypeString(string(session["type"])) == "picture" {
                continue
            }

            let baseName = nonEmpty(string(session["name"]))
                ?? String(format: NSLocalizedString("ChatBox 对话 %d", comment: "ChatBox imported conversation fallback title"), index + 1)
            let sessionSettings = chatBoxDictionary(session["settings"])
            let fallbackProvider = string(sessionSettings?["provider"])
            let fallbackModel = string(sessionSettings?["modelId"])
            let mainMessages = parseChatBoxMessages(
                normalizeJSONArray(session["messages"]),
                fallbackProvider: fallbackProvider,
                fallbackModel: fallbackModel,
                providerReferences: providerReferences
            )
            appendChatBoxSession(
                name: baseName,
                sourceID: "chatbox-session:\(sourceID):main",
                messages: mainMessages,
                into: &sessions
            )

            for (threadIndex, threadAny) in normalizeJSONArray(session["threads"]).enumerated() {
                guard let thread = chatBoxDictionary(threadAny) else { continue }
                let rawMessages = normalizeJSONArray(thread["messages"])
                let messages = parseChatBoxMessages(
                    rawMessages,
                    fallbackProvider: fallbackProvider,
                    fallbackModel: fallbackModel,
                    providerReferences: providerReferences
                )
                let threadName = nonEmpty(string(thread["name"]))
                    ?? String(format: NSLocalizedString("ChatBox 线程 %d", comment: "ChatBox imported thread fallback title"), threadIndex + 1)
                appendChatBoxSession(
                    name: "\(baseName) - \(threadName)",
                    sourceID: "chatbox-session:\(sourceID):thread:\(nonEmpty(string(thread["id"])) ?? "\(threadIndex)")",
                    messages: messages,
                    into: &sessions
                )
            }

            let forks = dictionary(session["messageForksHash"]) ?? [:]
            for (messageID, forkAny) in forks.sorted(by: { $0.key < $1.key }) {
                guard let fork = chatBoxDictionary(forkAny) else { continue }
                for (listIndex, listAny) in normalizeJSONArray(fork["lists"]).enumerated() {
                    guard let list = chatBoxDictionary(listAny) else { continue }
                    let messages = parseChatBoxMessages(
                        normalizeJSONArray(list["messages"]),
                        fallbackProvider: fallbackProvider,
                        fallbackModel: fallbackModel,
                        providerReferences: providerReferences
                    )
                    let forkName = String(format: NSLocalizedString("ChatBox 分支 %d", comment: "ChatBox imported fork fallback title"), listIndex + 1)
                    appendChatBoxSession(
                        name: "\(baseName) - \(forkName)",
                        sourceID: "chatbox-session:\(sourceID):fork:\(messageID):\(nonEmpty(string(list["id"])) ?? "\(listIndex)")",
                        messages: messages,
                        into: &sessions
                    )
                }
            }
        }

        return sessions
    }

    static func appendChatBoxSession(
        name: String,
        sourceID: String,
        messages: [ChatMessage],
        into sessions: inout [SyncedSession]
    ) {
        guard !messages.isEmpty else { return }
        let chatSession = ChatSession(
            id: stableUUID(from: sourceID) ?? UUID(),
            name: name,
            isTemporary: false
        )
        sessions.append(SyncedSession(session: chatSession, messages: messages))
    }

    static func parseChatBoxMessages(
        _ rawMessages: [Any],
        fallbackProvider: String?,
        fallbackModel: String?,
        providerReferences: [String: ChatBoxProviderReference]
    ) -> [ChatMessage] {
        rawMessages.compactMap { messageAny in
            guard let message = chatBoxDictionary(messageAny) else { return nil }
            return parseChatBoxMessage(
                message,
                fallbackProvider: fallbackProvider,
                fallbackModel: fallbackModel,
                providerReferences: providerReferences
            )
        }
    }

    static func parseChatBoxMessage(
        _ message: [String: Any],
        fallbackProvider: String?,
        fallbackModel: String?,
        providerReferences: [String: ChatBoxProviderReference]
    ) -> ChatMessage? {
        let role = mapMessageRole(string(message["role"]))
        let extracted = chatBoxMessageText(message)
        var content = extracted.content
        if content.isEmpty, let reasoning = extracted.reasoning {
            content = reasoning
        }
        guard !content.isEmpty else {
            return nil
        }

        let timestamp = parseDate(message["timestamp"] ?? message["createdAt"] ?? message["updatedAt"])
        let completedAt = parseDate(message["updatedAt"]) ?? timestamp
        let providerID = nonEmpty(string(message["aiProvider"])) ?? fallbackProvider
        let modelID = nonEmpty(string(message["model"])) ?? fallbackModel
        let modelReference = chatBoxModelReference(
            providerID: providerID,
            modelID: modelID,
            providerReferences: providerReferences
        )
        let tokenUsage = chatBoxTokenUsage(from: message)
        let responseMetrics = chatBoxResponseMetrics(
            timestamp: timestamp,
            completedAt: completedAt,
            firstTokenLatency: double(message["firstTokenLatency"])
        )

        return ChatMessage(
            id: stableUUID(from: nonEmpty(string(message["id"])).map { "chatbox-message:\($0)" }) ?? UUID(),
            role: role,
            content: content,
            requestedAt: timestamp,
            reasoningContent: extracted.reasoning,
            tokenUsage: tokenUsage,
            modelReference: modelReference,
            responseMetrics: responseMetrics
        )
    }

    static func chatBoxMessageText(_ message: [String: Any]) -> (content: String, reasoning: String?) {
        var contentPieces: [String] = []
        var reasoningPieces: [String] = []

        if let legacyContent = nonEmpty(string(message["content"])) {
            contentPieces.append(legacyContent)
        }

        for partAny in normalizeJSONArray(message["contentParts"]) {
            guard let part = chatBoxDictionary(partAny) else { continue }
            switch normalizedTypeString(string(part["type"])) {
            case "text", "":
                if let text = flattenText(part["text"] ?? part["content"]) {
                    contentPieces.append(text)
                }
            case "reasoning":
                if let text = flattenText(part["text"] ?? part["content"]) {
                    reasoningPieces.append(text)
                }
            case "info":
                if let text = flattenText(part["text"] ?? part["content"]) {
                    contentPieces.append(text)
                }
            case "image":
                if let ocr = nonEmpty(string(part["ocrResult"])) {
                    contentPieces.append(
                        String(
                            format: NSLocalizedString("图片 OCR：%@", comment: "Imported ChatBox image OCR placeholder"),
                            ocr
                        )
                    )
                } else {
                    contentPieces.append(NSLocalizedString("图片附件（原始文件需在 ChatBox 中查看）", comment: "Imported ChatBox image placeholder"))
                }
            case "tool-call":
                if let text = chatBoxToolCallText(part) {
                    contentPieces.append(text)
                }
            default:
                if let text = flattenText(part["text"] ?? part["content"] ?? part["value"]) {
                    contentPieces.append(text)
                }
            }
        }

        if let reasoning = nonEmpty(string(message["reasoningContent"])) {
            reasoningPieces.append(reasoning)
        }

        for fileAny in normalizeJSONArray(message["files"]) {
            guard let file = chatBoxDictionary(fileAny) else { continue }
            let name = nonEmpty(string(file["name"]))
                ?? nonEmpty(string(file["fileType"]))
                ?? NSLocalizedString("未命名文件", comment: "Imported ChatBox unnamed file placeholder")
            contentPieces.append(
                String(
                    format: NSLocalizedString("文件附件：%@", comment: "Imported ChatBox file placeholder"),
                    name
                )
            )
        }

        for linkAny in normalizeJSONArray(message["links"]) {
            guard let link = chatBoxDictionary(linkAny) else { continue }
            let title = nonEmpty(string(link["title"]))
            let url = nonEmpty(string(link["url"]))
            let detail = [title, url].compactMap { $0 }.joined(separator: " ")
            guard !detail.isEmpty else { continue }
            contentPieces.append(
                String(
                    format: NSLocalizedString("链接：%@", comment: "Imported ChatBox link placeholder"),
                    detail
                )
            )
        }

        let content = dedupeStrings(contentPieces)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = dedupeStrings(reasoningPieces)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, reasoning.isEmpty ? nil : reasoning)
    }

    static func chatBoxToolCallText(_ part: [String: Any]) -> String? {
        let toolName = nonEmpty(string(part["toolName"])) ?? NSLocalizedString("未知工具", comment: "Imported ChatBox unknown tool placeholder")
        let state = normalizedTypeString(string(part["state"]))
        switch state {
        case "call":
            return String(
                format: NSLocalizedString("工具调用 %@\n参数：%@", comment: "Imported ChatBox tool call placeholder"),
                toolName,
                compactJSONString(part["args"])
            )
        case "result":
            return String(
                format: NSLocalizedString("工具结果 %@\n结果：%@", comment: "Imported ChatBox tool result placeholder"),
                toolName,
                compactJSONString(part["result"])
            )
        case "error":
            let detail = nonEmpty(string(part["result"]))
                ?? nonEmpty(string(part["error"]))
                ?? compactJSONString(part["result"])
            return String(
                format: NSLocalizedString("工具错误 %@\n%@", comment: "Imported ChatBox tool error placeholder"),
                toolName,
                detail
            )
        default:
            return nil
        }
    }

    static func chatBoxModelReference(
        providerID: String?,
        modelID: String?,
        providerReferences: [String: ChatBoxProviderReference]
    ) -> MessageModelReference? {
        guard let providerID = nonEmpty(providerID),
              let modelID = nonEmpty(modelID),
              let providerReference = providerReferences[providerID] else {
            return nil
        }

        let model = providerReference.modelByChatBoxModelID[modelID]
        return MessageModelReference(
            providerID: providerReference.provider.id,
            providerName: providerReference.provider.name,
            modelUUID: model?.id,
            modelName: modelID,
            modelDisplayName: model?.displayName ?? modelID
        )
    }

    static func chatBoxTokenUsage(from message: [String: Any]) -> MessageTokenUsage? {
        let usage = chatBoxDictionary(message["usage"]) ?? [:]
        let promptTokens = int(usage["inputTokens"] ?? usage["promptTokens"])
        let completionTokens = int(usage["outputTokens"] ?? usage["completionTokens"] ?? message["tokenCount"])
        let thinkingTokens = int(usage["reasoningTokens"])
        let cachedTokens = int(usage["cachedInputTokens"])
        let totalTokens = int(usage["totalTokens"] ?? message["tokensUsed"])
        let tokenUsage = MessageTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            thinkingTokens: thinkingTokens,
            cacheReadTokens: cachedTokens
        )
        return tokenUsage.hasAnyData ? tokenUsage : nil
    }

    static func chatBoxResponseMetrics(
        timestamp: Date?,
        completedAt: Date?,
        firstTokenLatency: Double?
    ) -> MessageResponseMetrics? {
        guard timestamp != nil || completedAt != nil || firstTokenLatency != nil else {
            return nil
        }

        let timeToFirstToken = firstTokenLatency.map { value in
            value > 100 ? value / 1_000 : value
        }
        return MessageResponseMetrics(
            requestStartedAt: timestamp,
            responseCompletedAt: completedAt ?? timestamp,
            timeToFirstToken: timeToFirstToken
        )
    }

    static func chatBoxAllMessageMaps(in session: [String: Any]) -> [[String: Any]] {
        var result = normalizeJSONArray(session["messages"]).compactMap(chatBoxDictionary)

        for threadAny in normalizeJSONArray(session["threads"]) {
            guard let thread = chatBoxDictionary(threadAny) else { continue }
            result.append(contentsOf: normalizeJSONArray(thread["messages"]).compactMap(chatBoxDictionary))
        }

        let forks = dictionary(session["messageForksHash"]) ?? [:]
        for forkAny in forks.values {
            guard let fork = chatBoxDictionary(forkAny) else { continue }
            for listAny in normalizeJSONArray(fork["lists"]) {
                guard let list = chatBoxDictionary(listAny) else { continue }
                result.append(contentsOf: normalizeJSONArray(list["messages"]).compactMap(chatBoxDictionary))
            }
        }

        return result
    }

    static func chatBoxDictionary(_ any: Any?) -> [String: Any]? {
        if let dict = any as? [String: Any] {
            return dict
        }
        if let text = any as? String,
           let parsed = parseJSONStringToDictionary(text) {
            return parsed
        }
        return nil
    }

    static func compactJSONString(_ any: Any?) -> String {
        guard let any else { return "" }
        if let string = string(any) {
            return string
        }
        if let array = any as? [Any],
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let dict = any as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(any)"
    }

    static func double(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Float { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value) }
        return nil
    }
}
