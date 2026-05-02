import Foundation
import Combine

extension SyncEngine {
    static func mergeOptionalScalarField<Value: Equatable>(
        _ local: Value?,
        _ incoming: Value?
    ) -> (value: Value?, changed: Bool)? {
        switch (local, incoming) {
        case (nil, nil):
            return (nil, false)
        case let (lhs?, nil):
            return (lhs, false)
        case let (nil, rhs?):
            return (rhs, true)
        case let (lhs?, rhs?):
            return lhs == rhs ? (lhs, false) : nil
        }
    }

    static func mergeOptionalStringField(
        _ local: String?,
        _ incoming: String?,
        allowPrefixExtension: Bool
    ) -> (value: String?, changed: Bool)? {
        let normalizedLocal = normalizeOptionalString(local)
        let normalizedIncoming = normalizeOptionalString(incoming)

        switch (normalizedLocal, normalizedIncoming) {
        case (nil, nil):
            return (nil, false)
        case let (lhs?, nil):
            return (lhs, false)
        case let (nil, rhs?):
            return (rhs, true)
        case let (lhs?, rhs?):
            if lhs == rhs {
                return (lhs, false)
            }
            if allowPrefixExtension, stringsAreCompatible(lhs, rhs) {
                let preferred = preferLongerString(lhs, rhs)
                return (preferred, preferred != lhs)
            }
            return nil
        }
    }

    static func normalizeOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func stringsAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    static func preferLongerString(_ lhs: String, _ rhs: String) -> String {
        rhs.count > lhs.count ? rhs : lhs
    }

    static func mergeTokenUsage(
        _ local: MessageTokenUsage?,
        _ incoming: MessageTokenUsage?
    ) -> MessageTokenUsage? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            return MessageTokenUsage(
                promptTokens: maxOptional(lhs.promptTokens, rhs.promptTokens),
                completionTokens: maxOptional(lhs.completionTokens, rhs.completionTokens),
                totalTokens: maxOptional(lhs.totalTokens, rhs.totalTokens),
                thinkingTokens: maxOptional(lhs.thinkingTokens, rhs.thinkingTokens),
                cacheWriteTokens: maxOptional(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
                cacheReadTokens: maxOptional(lhs.cacheReadTokens, rhs.cacheReadTokens)
            )
        }
    }

    static func mergeResponseMetrics(
        _ local: MessageResponseMetrics?,
        _ incoming: MessageResponseMetrics?
    ) -> MessageResponseMetrics? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            let speedSamples = lhs.speedSamples ?? rhs.speedSamples
            let mergedReasoningSummary = mergeOptionalStringField(
                lhs.reasoningSummary,
                rhs.reasoningSummary,
                allowPrefixExtension: true
            )?.value
            return MessageResponseMetrics(
                schemaVersion: max(lhs.schemaVersion, rhs.schemaVersion),
                requestStartedAt: minOptional(lhs.requestStartedAt, rhs.requestStartedAt),
                responseCompletedAt: maxOptional(lhs.responseCompletedAt, rhs.responseCompletedAt),
                totalResponseDuration: maxOptional(lhs.totalResponseDuration, rhs.totalResponseDuration),
                timeToFirstToken: minOptional(lhs.timeToFirstToken, rhs.timeToFirstToken),
                reasoningStartedAt: minOptional(lhs.reasoningStartedAt, rhs.reasoningStartedAt),
                reasoningCompletedAt: maxOptional(lhs.reasoningCompletedAt, rhs.reasoningCompletedAt),
                completionTokensForSpeed: maxOptional(lhs.completionTokensForSpeed, rhs.completionTokensForSpeed),
                tokenPerSecond: maxOptional(lhs.tokenPerSecond, rhs.tokenPerSecond),
                isTokenPerSecondEstimated: lhs.isTokenPerSecondEstimated && rhs.isTokenPerSecondEstimated,
                reasoningSummary: mergedReasoningSummary,
                speedSamples: speedSamples
            )
        }
    }

    static func maxOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Value? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        }
    }

    static func minOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Value? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        }
    }

    // MARK: - Helpers

    /// 创建带有新 UUID 的会话副本（保留原名称，不添加后缀）
    static func makeNewSession(from session: ChatSession) -> ChatSession {
        return ChatSession(
            id: UUID(),
            name: session.name,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt,
            lorebookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled,
            folderID: session.folderID,
            isTemporary: false
        )
    }
    
    /// 计算会话内容的哈希值，用于快速比较
    /// 包含：会话基础名称（去除同步后缀）、系统提示、消息内容
    static func computeSessionContentHash(session: ChatSession, messages: [ChatMessage]) -> String {
        var hasher = Hasher()
        hasher.combine(session.baseNameWithoutSyncSuffix)
        hasher.combine(session.topicPrompt ?? "")
        hasher.combine(session.enhancedPrompt ?? "")
        hasher.combine(session.folderID?.uuidString ?? "")
        hasher.combine(session.worldbookContextIsolationEnabled)
        for worldbookID in session.lorebookIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(worldbookID.uuidString)
        }
        for message in messages {
            hasher.combine(messageSyncSignature(message))
        }
        return String(hasher.finalize())
    }
    
    /// 计算 Provider 内容的哈希值，用于快速比较
    /// 包含：基础名称（去除同步后缀）、URL、API 格式、模型配置
    static func computeProviderContentHash(_ provider: Provider) -> String {
        var hasher = Hasher()
        let canonicalAPIFormat = canonicalProviderAPIFormat(provider.apiFormat)
        hasher.combine(provider.baseNameWithoutSyncSuffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        hasher.combine(normalizeProviderBaseURL(provider.baseURL, apiFormat: canonicalAPIFormat))
        hasher.combine(canonicalAPIFormat)
        for (key, value) in provider.headerOverrides.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
        if let proxy = provider.proxyConfiguration {
            hasher.combine(proxy.isEnabled)
            hasher.combine(proxy.type.rawValue)
            hasher.combine(proxy.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            hasher.combine(proxy.port)
            hasher.combine(proxy.username.trimmingCharacters(in: .whitespacesAndNewlines))
            hasher.combine(proxy.password)
        } else {
            hasher.combine("proxy:nil")
        }
        for model in provider.models.sorted(by: { normalizedModelIdentity($0) < normalizedModelIdentity($1) }) {
            hasher.combine(model.modelName)
            hasher.combine(model.displayName)
            hasher.combine(model.isActivated)
            hasher.combine(model.kind.rawValue)
            for modality in model.inputModalities.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine("input:\(modality.rawValue)")
            }
            for modality in model.outputModalities.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine("output:\(modality.rawValue)")
            }
            hasher.combine(model.requestBodyOverrideMode.rawValue)
            hasher.combine(model.rawRequestBodyJSON ?? "")
            for capability in model.capabilities.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine(capability.rawValue)
            }
            for (key, value) in model.overrideParameters.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value.prettyPrintedCompact())
            }
        }
        return String(hasher.finalize())
    }

    static func messageSyncSignature(_ message: ChatMessage) -> String {
        var hasher = Hasher()
        hasher.combine(message.role.rawValue)
        for version in message.getAllVersions() {
            hasher.combine(version)
        }
        hasher.combine(message.getCurrentVersionIndex())
        hasher.combine(message.responseGroupID?.uuidString ?? "")
        hasher.combine(message.responseAttemptID?.uuidString ?? "")
        hasher.combine(message.responseAttemptIndex ?? -1)
        hasher.combine(message.selectedResponseAttemptID?.uuidString ?? "")
        hasher.combine(message.reasoningContent ?? "")
        for toolCall in message.toolCalls ?? [] {
            hasher.combine(toolCall.id)
            hasher.combine(toolCall.toolName)
            hasher.combine(toolCall.arguments)
            hasher.combine(toolCall.result ?? "")
            for (key, value) in (toolCall.providerSpecificFields ?? [:]).sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value.prettyPrintedCompact())
            }
        }
        hasher.combine(message.toolCallsPlacement?.rawValue ?? "")
        hasher.combine(message.audioFileName ?? "")
        for imageFileName in message.imageFileNames ?? [] {
            hasher.combine(imageFileName)
        }
        for fileName in message.fileFileNames ?? [] {
            hasher.combine(fileName)
        }
        hasher.combine(message.requestedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.fullErrorContent ?? "")
        hasher.combine(message.tokenUsage?.promptTokens ?? -1)
        hasher.combine(message.tokenUsage?.completionTokens ?? -1)
        hasher.combine(message.tokenUsage?.totalTokens ?? -1)
        hasher.combine(message.tokenUsage?.thinkingTokens ?? -1)
        hasher.combine(message.tokenUsage?.cacheWriteTokens ?? -1)
        hasher.combine(message.tokenUsage?.cacheReadTokens ?? -1)
        hasher.combine(message.responseMetrics?.schemaVersion ?? 0)
        hasher.combine(message.responseMetrics?.requestStartedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.responseCompletedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.totalResponseDuration ?? -1)
        hasher.combine(message.responseMetrics?.timeToFirstToken ?? -1)
        hasher.combine(message.responseMetrics?.reasoningStartedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.reasoningCompletedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.completionTokensForSpeed ?? -1)
        hasher.combine(message.responseMetrics?.tokenPerSecond ?? -1)
        hasher.combine(message.responseMetrics?.isTokenPerSecondEstimated ?? false)
        hasher.combine(message.responseMetrics?.reasoningSummary ?? "")
        return String(hasher.finalize())
    }
    
    /// 计算 MCP Server 内容的哈希值，用于快速比较
    static func computeMCPServerContentHash(_ server: MCPServerConfiguration) -> String {
        var hasher = Hasher()
        hasher.combine(server.baseNameWithoutSyncSuffix)
        hasher.combine(server.notes ?? "")
        hasher.combine(server.isSelectedForChat)
        for toolId in Set(server.disabledToolIds).sorted() {
            hasher.combine(toolId)
        }
        for (toolId, policy) in server.toolApprovalPolicies.sorted(by: { $0.key < $1.key }) {
            hasher.combine(toolId)
            hasher.combine(policy.rawValue)
        }
        // Transport 配置
        switch server.transport {
        case .http(let endpoint, let apiKey, let headers):
            hasher.combine("http")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            hasher.combine("httpSSE")
            hasher.combine(messageEndpoint.absoluteString)
            hasher.combine(sseEndpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .oauth(let endpoint, let tokenEndpoint, let clientID, _, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            hasher.combine("oauth")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(tokenEndpoint.absoluteString)
            hasher.combine(clientID)
            hasher.combine(scope ?? "")
            hasher.combine(grantType.rawValue)
            hasher.combine(authorizationCode ?? "")
            hasher.combine(redirectURI ?? "")
            hasher.combine(codeVerifier ?? "")
        }
        return String(hasher.finalize())
    }

    static func worldbookEntrySignature(_ entry: WorldbookEntry) -> String {
        let normalizedContent = WorldbookStore.normalizedContent(entry.content)
        let keys = entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|")
        return "\(normalizedContent)::\(keys)"
    }

    static func deduplicateWorldbookEntries(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var result: [WorldbookEntry] = []
        var seen = Set<String>()
        for var entry in entries {
            let signature = worldbookEntrySignature(entry)
            if seen.contains(signature) {
                continue
            }
            if result.contains(where: { $0.id == entry.id }) {
                entry.id = UUID()
            }
            seen.insert(signature)
            result.append(entry)
        }
        return result
    }

    static func remapWorldbookIDsInSessions(
        _ idMapping: [UUID: UUID],
        chatService: ChatService
    ) {
        guard !idMapping.isEmpty else { return }
        var sessions = chatService.chatSessionsSubject.value
        var changed = false

        for index in sessions.indices {
            let oldIDs = sessions[index].lorebookIDs
            guard !oldIDs.isEmpty else { continue }
            let mapped = oldIDs.map { idMapping[$0] ?? $0 }
            var deduped: [UUID] = []
            var seen = Set<UUID>()
            for id in mapped where !seen.contains(id) {
                seen.insert(id)
                deduped.append(id)
            }
            if deduped != oldIDs {
                sessions[index].lorebookIDs = deduped
                changed = true
            }
        }

        guard changed else { return }
        Persistence.saveChatSessions(sessions)
        chatService.chatSessionsSubject.send(sessions)
        if let current = chatService.currentSessionSubject.value,
           let mappedCurrent = sessions.first(where: { $0.id == current.id }) {
            chatService.currentSessionSubject.send(mappedCurrent)
        }
    }
}
