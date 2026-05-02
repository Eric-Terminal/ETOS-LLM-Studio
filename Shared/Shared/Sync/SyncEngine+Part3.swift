import Foundation
import Combine

extension SyncEngine {
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

    static func containsSessionHash(
        _ hash: String,
        sessions: [ChatSession],
        messagesBySessionID: inout [UUID: [ChatMessage]]
    ) -> Bool {
        for session in sessions {
            let messages = messagesForSession(session.id, cache: &messagesBySessionID)
            if computeSessionContentHash(session: session, messages: messages) == hash {
                return true
            }
        }
        return false
    }

    static func messagesForSession(
        _ sessionID: UUID,
        cache: inout [UUID: [ChatMessage]]
    ) -> [ChatMessage] {
        if let cached = cache[sessionID] {
            return cached
        }
        let loaded = Persistence.loadMessages(for: sessionID)
        cache[sessionID] = loaded
        return loaded
    }

    static func sessionMergeCandidateIndex(
        for incomingSession: ChatSession,
        localSessions: [ChatSession]
    ) -> Int? {
        if let exactIDMatch = localSessions.firstIndex(where: { $0.id == incomingSession.id }) {
            return exactIDMatch
        }
        return localSessions.firstIndex(where: { $0.isEquivalentIgnoringSyncSuffix(to: incomingSession) })
    }

    static func mergeSessionDeep(
        localSession: ChatSession,
        localMessages: [ChatMessage],
        incomingSession: ChatSession,
        incomingMessages: [ChatMessage]
    ) -> DeepMergeResult<(ChatSession, [ChatMessage])> {
        guard let mergedSession = mergeChatSessionMetadata(local: localSession, incoming: incomingSession) else {
            return .conflict
        }
        guard let mergedMessagesResult = mergeLinearMessages(local: localMessages, incoming: incomingMessages) else {
            return .conflict
        }

        let payload = (mergedSession, mergedMessagesResult.messages)
        if mergedSession == localSession && !mergedMessagesResult.changed {
            return .unchanged(payload)
        }
        return .merged(payload)
    }

    static func mergeChatSessionMetadata(
        local: ChatSession,
        incoming: ChatSession
    ) -> ChatSession? {
        guard local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix else {
            return nil
        }

        var merged = local
        guard let topicMerge = mergeOptionalStringField(
            local.topicPrompt,
            incoming.topicPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.topicPrompt = topicMerge.value

        guard let enhancedMerge = mergeOptionalStringField(
            local.enhancedPrompt,
            incoming.enhancedPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.enhancedPrompt = enhancedMerge.value

        if local.folderID == nil {
            merged.folderID = incoming.folderID
        }

        merged.lorebookIDs = mergeOrderedUUIDs(local.lorebookIDs, incoming.lorebookIDs)

        if local.worldbookContextIsolationEnabled != incoming.worldbookContextIsolationEnabled {
            let localHasBindings = !local.lorebookIDs.isEmpty
            let incomingHasBindings = !incoming.lorebookIDs.isEmpty
            if local.worldbookContextIsolationEnabled && !localHasBindings {
                merged.worldbookContextIsolationEnabled = incoming.worldbookContextIsolationEnabled
            } else if incoming.worldbookContextIsolationEnabled && !incomingHasBindings {
                merged.worldbookContextIsolationEnabled = local.worldbookContextIsolationEnabled
            } else if local.worldbookContextIsolationEnabled || incoming.worldbookContextIsolationEnabled {
                merged.worldbookContextIsolationEnabled = true
            }
        }

        if local.name != incoming.name {
            if local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix {
                merged.name = local.name
            } else {
                return nil
            }
        }

        merged.isTemporary = false
        return merged
    }

    static func mergeLinearMessages(
        local: [ChatMessage],
        incoming: [ChatMessage]
    ) -> (messages: [ChatMessage], changed: Bool)? {
        if local == incoming {
            return (local, false)
        }

        var merged = local
        var changed = false
        let overlapCount = min(local.count, incoming.count)

        for index in 0..<overlapCount {
            guard let mergedMessage = mergeChatMessage(local[index], incoming[index]) else {
                return nil
            }
            if mergedMessage != merged[index] {
                merged[index] = mergedMessage
                changed = true
            }
        }

        if incoming.count > local.count {
            merged.append(contentsOf: incoming.dropFirst(overlapCount))
            changed = true
        }

        return (merged, changed)
    }

    static func mergeChatMessage(_ local: ChatMessage, _ incoming: ChatMessage) -> ChatMessage? {
        if local == incoming {
            return local
        }

        let canTreatAsSameMessage = local.id == incoming.id
            || messagesShareMergeIdentity(local, incoming)
        guard canTreatAsSameMessage else {
            return nil
        }

        guard let contentMerge = mergeMessageVersions(local: local, incoming: incoming) else {
            return nil
        }
        guard let reasoningMerge = mergeOptionalStringField(
            local.reasoningContent,
            incoming.reasoningContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }
        guard let toolCallsMerge = mergeOptionalArrayField(local.toolCalls, incoming.toolCalls) else {
            return nil
        }
        guard let toolCallsPlacement = mergeOptionalScalarField(
            local.toolCallsPlacement,
            incoming.toolCallsPlacement
        ) else {
            return nil
        }
        guard let audioFileName = mergeOptionalStringField(
            local.audioFileName,
            incoming.audioFileName,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        guard let responseGroupID = mergeOptionalScalarField(
            local.responseGroupID,
            incoming.responseGroupID
        ) else {
            return nil
        }
        guard let responseAttemptID = mergeOptionalScalarField(
            local.responseAttemptID,
            incoming.responseAttemptID
        ) else {
            return nil
        }
        guard let responseAttemptIndex = mergeOptionalScalarField(
            local.responseAttemptIndex,
            incoming.responseAttemptIndex
        ) else {
            return nil
        }
        guard let fullErrorContent = mergeOptionalStringField(
            local.fullErrorContent,
            incoming.fullErrorContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }

        let mergedImageFiles = mergeOrderedStrings(local.imageFileNames, incoming.imageFileNames)
        let mergedFileFiles = mergeOrderedStrings(local.fileFileNames, incoming.fileFileNames)
        let mergedTokenUsage = mergeTokenUsage(local.tokenUsage, incoming.tokenUsage)
        let mergedResponseMetrics = mergeResponseMetrics(local.responseMetrics, incoming.responseMetrics)
        let mergedRequestedAt = minOptional(local.requestedAt, incoming.requestedAt)

        var merged = buildMessage(
            from: local,
            versions: contentMerge.versions,
            currentVersionIndex: contentMerge.currentVersionIndex,
            requestedAt: mergedRequestedAt,
            reasoningContent: reasoningMerge.value,
            toolCalls: toolCallsMerge.value,
            toolCallsPlacement: toolCallsPlacement.value,
            tokenUsage: mergedTokenUsage,
            audioFileName: audioFileName.value,
            imageFileNames: mergedImageFiles,
            fileFileNames: mergedFileFiles,
            fullErrorContent: fullErrorContent.value,
            responseMetrics: mergedResponseMetrics
        )
        merged.responseGroupID = responseGroupID.value
        merged.responseAttemptID = responseAttemptID.value
        merged.responseAttemptIndex = responseAttemptIndex.value
        merged.selectedResponseAttemptID = incoming.selectedResponseAttemptID ?? local.selectedResponseAttemptID

        if local.id != incoming.id, local.content == incoming.content {
            merged.id = local.id
        }
        return merged
    }

    static func messagesShareMergeIdentity(_ local: ChatMessage, _ incoming: ChatMessage) -> Bool {
        guard local.role == incoming.role else {
            return false
        }

        if stringsAreCompatible(local.content, incoming.content) {
            return true
        }

        let localVersions = local.getAllVersions()
        let incomingVersions = incoming.getAllVersions()
        for localVersion in localVersions {
            if incomingVersions.contains(where: { stringsAreCompatible(localVersion, $0) }) {
                return true
            }
        }
        return false
    }

    static func buildMessage(
        from template: ChatMessage,
        versions: [String],
        currentVersionIndex: Int,
        requestedAt: Date?,
        reasoningContent: String?,
        toolCalls: [InternalToolCall]?,
        toolCallsPlacement: ToolCallsPlacement?,
        tokenUsage: MessageTokenUsage?,
        audioFileName: String?,
        imageFileNames: [String]?,
        fileFileNames: [String]?,
        fullErrorContent: String?,
        responseMetrics: MessageResponseMetrics?
    ) -> ChatMessage {
        let safeVersions = versions.isEmpty ? [""] : versions
        var message = ChatMessage(
            id: template.id,
            role: template.role,
            content: safeVersions[0],
            requestedAt: requestedAt,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls,
            toolCallsPlacement: toolCallsPlacement,
            tokenUsage: tokenUsage,
            audioFileName: audioFileName,
            imageFileNames: imageFileNames,
            fileFileNames: fileFileNames,
            fullErrorContent: fullErrorContent,
            responseMetrics: responseMetrics
        )
        if safeVersions.count > 1 {
            for version in safeVersions.dropFirst() {
                message.addVersion(version)
            }
            let safeCurrentIndex = min(max(0, currentVersionIndex), safeVersions.count - 1)
            message.switchToVersion(safeCurrentIndex)
        }
        return message
    }

    static func mergeMessageVersions(
        local: ChatMessage,
        incoming: ChatMessage
    ) -> (versions: [String], currentVersionIndex: Int)? {
        let localCurrent = local.content
        let incomingCurrent = incoming.content
        guard stringsAreCompatible(localCurrent, incomingCurrent) else {
            return nil
        }

        var versions = local.getAllVersions()
        for version in incoming.getAllVersions() where !versions.contains(version) {
            versions.append(version)
        }

        let preferredCurrent = preferLongerString(localCurrent, incomingCurrent)
        if !versions.contains(preferredCurrent) {
            versions.append(preferredCurrent)
        }
        let currentIndex = versions.firstIndex(of: preferredCurrent) ?? max(0, versions.count - 1)
        return (versions, currentIndex)
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

    static func mergeModelDeep(
        _ local: Model,
        with incoming: Model
    ) -> DeepMergeResult<Model> {
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

        if changed {
            return .merged(merged)
        }
        return .unchanged(merged)
    }

    static func mergeStringDictionary(
        _ local: [String: String],
        _ incoming: [String: String]
    ) -> [String: String]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard localValue == incomingValue else {
                    return nil
                }
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    static func mergeJSONDictionary(
        _ local: [String: JSONValue],
        _ incoming: [String: JSONValue]
    ) -> [String: JSONValue]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard let mergedValue = mergeJSONValue(localValue, incomingValue) else {
                    return nil
                }
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
            guard let merged = mergeJSONDictionary(localDictionary, incomingDictionary) else {
                return nil
            }
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

    static func mergeCapabilities(
        _ local: [ModelCapability],
        _ incoming: [ModelCapability]
    ) -> [ModelCapability] {
        var merged = local
        for capability in incoming where !merged.contains(capability) {
            merged.append(capability)
        }
        return Model.orderedCapabilities(merged)
    }

    static func mergeModelKind(_ local: ModelKind, _ incoming: ModelKind) -> ModelKind {
        local == .chat && incoming != .chat ? incoming : local
    }

    static func mergeModelModalities(
        _ local: [ModelModality],
        _ incoming: [ModelModality]
    ) -> [ModelModality] {
        var merged = local
        for modality in incoming where !merged.contains(modality) {
            merged.append(modality)
        }
        return Model.orderedModalities(merged)
    }

    static func mergeRequestBodyOverrideMode(
        local: Model,
        incoming: Model
    ) -> Model.RequestBodyOverrideMode? {
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

    static func mergeDisplayName(
        local: String,
        incoming: String,
        fallback: String
    ) -> String? {
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

    static func mergeProviderAPIKeys(_ local: [String], _ incoming: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(local + incoming)
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

    static func reassignProviderIdentifiersIfNeeded(
        _ provider: Provider,
        existingProviders: [Provider]
    ) -> Provider {
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

}
