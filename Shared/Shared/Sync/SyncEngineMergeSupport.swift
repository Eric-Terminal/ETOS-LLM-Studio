// ============================================================================
// SyncEngineMergeSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步深合并所需的通用类型、哈希与合并辅助逻辑。
// ============================================================================

import Foundation

extension SyncEngine {
    enum DeepMergeResult<Value> {
        case unchanged(Value)
        case merged(Value)
        case conflict
        /// 真分叉：本地与远端均在 LCA 之后有新消息，远端克隆为独立分支
        case forked(Value)
    }

    struct ProviderCompactionResult {
        var providers: [Provider]
        var updatedProviders: [Provider]
        var removedProviders: [Provider]

        var changed: Bool {
            !updatedProviders.isEmpty || !removedProviders.isEmpty
        }
    }

    static func makeNewSession(from session: ChatSession) -> ChatSession {
        ChatSession(
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

    /// 克隆远端分叉会话：分配新 UUID，名称追加「[同步分支]」标签
    static func makeBranchSession(from session: ChatSession) -> ChatSession {
        let branchSuffix = NSLocalizedString("[同步分支]", comment: "会话平行分支后缀标签")
        let baseName = session.baseNameWithoutSyncSuffix
        let branchedName = "\(baseName) \(branchSuffix)"
        return ChatSession(
            id: UUID(),
            name: branchedName,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt,
            lorebookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled,
            folderID: session.folderID,
            isTemporary: false
        )
    }

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
            for control in model.requestBodyControls.sorted(by: { $0.id < $1.id }) {
                hasher.combine(control.id)
                hasher.combine(control.title)
                hasher.combine(control.kind.rawValue)
                hasher.combine(control.isEnabled)
                hasher.combine(control.defaultIsActive)
                hasher.combine(control.defaultOptionID ?? "")
                for (key, value) in control.payload.sorted(by: { $0.key < $1.key }) {
                    hasher.combine("control-payload:\(key)")
                    hasher.combine(value.prettyPrintedCompact())
                }
                for option in control.options.sorted(by: { $0.id < $1.id }) {
                    hasher.combine(option.id)
                    hasher.combine(option.title)
                    for (key, value) in option.payload.sorted(by: { $0.key < $1.key }) {
                        hasher.combine("option-payload:\(key)")
                        hasher.combine(value.prettyPrintedCompact())
                    }
                }
            }
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

    static func providerMergeIdentity(_ provider: Provider) -> String {
        let canonicalAPIFormat = canonicalProviderAPIFormat(provider.apiFormat)
        return [
            provider.baseNameWithoutSyncSuffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizeProviderBaseURL(provider.baseURL, apiFormat: canonicalAPIFormat),
            canonicalAPIFormat
        ].joined(separator: "\u{1F}")
    }

    static func normalizeAPIFormatToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func canonicalProviderAPIFormat(_ value: String) -> String {
        let normalized = normalizeAPIFormatToken(value)
        if normalized == "openai-responses"
            || normalized == "openai-response"
            || normalized.contains("responses") {
            return "openai-responses"
        }
        if normalized.contains("anthropic") || normalized.contains("claude") {
            return "anthropic"
        }
        if normalized.contains("gemini") || normalized.contains("google") || normalized.contains("vertex") {
            return "gemini"
        }
        return "openai-compatible"
    }

    static func normalizeProviderBaseURL(_ value: String, apiFormat: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return normalized }

        let lower = normalized.lowercased()
        let hasVersion = lower.contains("/v1") || lower.contains("/v1beta") || lower.contains("/v2")
        if !hasVersion {
            switch canonicalProviderAPIFormat(apiFormat) {
            case "anthropic":
                normalized += "/v1"
            case "gemini":
                normalized += "/v1beta"
            default:
                normalized += "/v1"
            }
        }

        return normalized.lowercased()
    }

    static func normalizedModelIdentity(_ model: Model) -> String {
        model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeOptionalJSONString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func mergeProviderAPIKeys(_ local: [String], _ incoming: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(local + incoming)
    }

    static func mergeOrderedUUIDs(_ local: [UUID], _ incoming: [UUID]) -> [UUID] {
        var merged = local
        for value in incoming where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    static func mergeOrderedStrings(_ local: [String]?, _ incoming: [String]?) -> [String]? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            var merged = lhs
            for value in rhs where !merged.contains(value) {
                merged.append(value)
            }
            return merged
        }
    }

    static func mergeOptionalArrayField<Element: Equatable>(
        _ local: [Element]?,
        _ incoming: [Element]?
    ) -> (value: [Element]?, changed: Bool)? {
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
}
