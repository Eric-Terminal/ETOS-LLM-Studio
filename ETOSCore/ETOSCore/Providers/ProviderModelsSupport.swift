// ============================================================================
// ProviderModelsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 ProviderModels.swift 中的推断、排序、移动辅助与主流模型家族识别逻辑。
// ============================================================================

import Foundation

public extension Provider {
    func applyingInferredModelCapabilityHints() -> Provider {
        var repaired = self
        repaired.models = models.map { $0.applyingInferredCapabilityHints() }
        return repaired
    }

    /// 仅重排已添加模型（isActivated = true）的相对顺序，不影响未添加模型的相对顺序。
    /// - Parameters:
    ///   - offsets: 拖拽源索引（基于“已添加模型”子列表）
    ///   - destination: 拖拽目标索引（基于“已添加模型”子列表）
    mutating func moveActivatedModels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard destination >= 0 && destination <= activatedCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < activatedCount }) else { return }
        guard !offsets.isEmpty else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        moveActivatedModelElements(in: &activatedModels, fromOffsets: offsets, toOffset: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }

    /// 将已添加模型子列表中的某一项移动到目标位置。
    /// - Parameters:
    ///   - source: 源位置（基于“已添加模型”子列表）
    ///   - destination: 目标位置（基于“已添加模型”子列表）
    mutating func moveActivatedModel(fromPosition source: Int, toPosition destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard source >= 0 && source < activatedCount else { return }
        guard destination >= 0 && destination < activatedCount else { return }
        guard source != destination else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        let moved = activatedModels.remove(at: source)
        activatedModels.insert(moved, at: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }
}

public extension Model {
    var defaultRequestBodyControlState: ModelRequestBodyControlState {
        ModelRequestBodyControlCompiler.defaultState(for: requestBodyControls)
    }

    func effectiveOverrideParameters(using state: ModelRequestBodyControlState? = nil) -> [String: JSONValue] {
        ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: overrideParameters,
            controls: requestBodyControls,
            state: state ?? defaultRequestBodyControlState
        )
    }

    /// 将来源配置以独立副本追加到末尾，保留当前模型已有控制。
    mutating func appendCopiesOfRequestBodyControls(_ controls: [ModelRequestBodyControl]) {
        requestBodyControls.append(contentsOf: controls.map { $0.duplicatedWithNewIdentifiers() })
    }

    /// 为声明了推理能力的模型补充可直接调节的思考预算，保留用户已有控制。
    mutating func ensureThinkingRequestBodyControl(apiFormat: String) {
        guard !requestBodyControls.contains(where: ModelRequestBodyControlDefaults.isThinkingControl) else {
            return
        }
        requestBodyControls.append(
            ModelRequestBodyControlDefaults.thinkingOptionGroup(for: apiFormat)
        )
    }
}

public extension Model {
    mutating func resetCapabilityShape(for kind: ModelKind) {
        self.kind = kind
        inputModalities = Self.defaultInputModalities(for: kind)
        outputModalities = Self.defaultOutputModalities(for: kind)
        capabilities = Self.defaultCapabilities(for: kind)
    }

    static func defaultInputModalities(for kind: ModelKind) -> [ModelModality] {
        switch kind {
        case .chat:
            return [.text]
        case .image:
            return [.text, .image]
        case .embedding, .rerank:
            return [.text]
        case .speechToText:
            return [.audio]
        case .textToSpeech:
            return [.text]
        }
    }

    static func defaultOutputModalities(for kind: ModelKind) -> [ModelModality] {
        switch kind {
        case .chat:
            return [.text]
        case .image:
            return [.image]
        case .embedding:
            return []
        case .rerank:
            return [.text]
        case .speechToText:
            return [.text]
        case .textToSpeech:
            return [.audio]
        }
    }

    static func defaultCapabilities(for kind: ModelKind) -> [ModelCapability] {
        switch kind {
        case .chat:
            return defaultCapabilities
        case .image, .embedding, .rerank, .speechToText, .textToSpeech:
            return []
        }
    }

    static func orderedModalities(_ modalities: [ModelModality]) -> [ModelModality] {
        let modalitySet = Set(modalities)
        return ModelModality.allCases.filter { modalitySet.contains($0) }
    }

    static func orderedOutputModalities(_ modalities: [ModelModality]) -> [ModelModality] {
        let modalitySet = Set(modalities)
        return ModelModality.outputCases.filter { modalitySet.contains($0) }
    }

    static func orderedCapabilities(_ capabilities: [ModelCapability]) -> [ModelCapability] {
        let capabilitySet = Set(capabilities)
        return ModelCapability.allCases.filter { capabilitySet.contains($0) }
    }

    static func inferred(
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        supportedGenerationMethods: [String]? = nil
    ) -> Model {
        let profile = inferredCapabilityShape(
            modelName: modelName,
            displayName: displayName,
            supportedGenerationMethods: supportedGenerationMethods
        )
        return Model(
            modelName: modelName,
            displayName: displayName,
            isActivated: isActivated,
            kind: profile.kind,
            inputModalities: profile.inputModalities,
            outputModalities: profile.outputModalities,
            capabilities: profile.capabilities
        )
    }

    func applyingInferredCapabilityHints() -> Model {
        let inferred = Self.inferredCapabilityShape(
            modelName: modelName,
            displayName: displayName,
            supportedGenerationMethods: nil
        )

        let originalKind = kind
        let originalInputModalities = inputModalities
        let originalOutputModalities = outputModalities
        let originalCapabilities = capabilities
        var repaired = self

        if repaired.kind == .chat, inferred.kind != .chat {
            repaired.kind = inferred.kind
        }

        let shouldApplyInferredShape = originalKind == .chat || inferred.kind == originalKind
        guard shouldApplyInferredShape else {
            return repaired
        }

        if originalInputModalities == Self.defaultInputModalities(for: originalKind) {
            repaired.inputModalities = inferred.inputModalities
        }
        if originalOutputModalities == Self.defaultOutputModalities(for: originalKind) {
            repaired.outputModalities = inferred.outputModalities
        }
        if originalCapabilities == Self.defaultCapabilities(for: originalKind) {
            repaired.capabilities = inferred.capabilities
        }
        return repaired
    }
}

extension Model {
    enum LegacyCapability: String {
        case chat
        case toolCalling
        case speechToText
        case textToSpeech
        case embedding
        case imageGeneration
    }

    struct CapabilityShape {
        var kind: ModelKind
        var inputModalities: [ModelModality]
        var outputModalities: [ModelModality]
        var capabilities: [ModelCapability]
    }

    static func normalizedCapabilityShape(
        kind explicitKind: ModelKind? = nil,
        inputModalities explicitInputModalities: [ModelModality]? = nil,
        outputModalities explicitOutputModalities: [ModelModality]? = nil,
        capabilities explicitCapabilities: [ModelCapability]? = nil,
        legacyCapabilityRawValues: [String]? = nil
    ) -> CapabilityShape {
        let legacyCapabilities = legacyCapabilityRawValues?.compactMap(LegacyCapability.init(rawValue:)) ?? []
        let legacySet = Set(legacyCapabilities)

        let resolvedKind: ModelKind
        if let explicitKind {
            resolvedKind = explicitKind
        } else if legacySet.contains(.embedding) {
            resolvedKind = .embedding
        } else if legacySet.contains(.speechToText) {
            resolvedKind = .speechToText
        } else if legacySet.contains(.textToSpeech) {
            resolvedKind = .textToSpeech
        } else if legacySet.contains(.imageGeneration), !legacySet.contains(.chat) {
            resolvedKind = .image
        } else {
            resolvedKind = .chat
        }

        var resolvedInputModalities = explicitInputModalities ?? defaultInputModalities(for: resolvedKind)
        var resolvedOutputModalities = explicitOutputModalities ?? defaultOutputModalities(for: resolvedKind)
        var resolvedCapabilities = explicitCapabilities ?? (legacyCapabilityRawValues == nil ? defaultCapabilities(for: resolvedKind) : [])

        if legacySet.contains(.toolCalling), !resolvedCapabilities.contains(.toolCalling) {
            resolvedCapabilities.append(.toolCalling)
        }
        if legacySet.contains(.speechToText), !resolvedInputModalities.contains(.audio) {
            resolvedInputModalities.append(.audio)
        }
        if legacySet.contains(.speechToText), !resolvedCapabilities.contains(.speechToText) {
            resolvedCapabilities.append(.speechToText)
        }
        if legacySet.contains(.textToSpeech), !resolvedOutputModalities.contains(.audio) {
            resolvedOutputModalities.append(.audio)
        }
        if legacySet.contains(.textToSpeech), !resolvedCapabilities.contains(.textToSpeech) {
            resolvedCapabilities.append(.textToSpeech)
        }
        if legacySet.contains(.imageGeneration), !resolvedOutputModalities.contains(.image) {
            resolvedOutputModalities.append(.image)
        }

        return CapabilityShape(
            kind: resolvedKind,
            inputModalities: orderedModalities(resolvedInputModalities),
            outputModalities: orderedOutputModalities(resolvedOutputModalities),
            capabilities: orderedCapabilities(resolvedCapabilities)
        )
    }

    static func inferredCapabilityShape(
        modelName: String,
        displayName: String?,
        supportedGenerationMethods: [String]?
    ) -> CapabilityShape {
        let searchableName = [modelName, displayName].compactMap { $0?.lowercased() }.joined(separator: " ")
        let normalizedName = searchableName
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        let supportsGenerateContent = supportedGenerationMethods?.contains(where: { method in
            method == "generateContent" || method == "streamGenerateContent"
        }) ?? true
        let supportsEmbedding = supportedGenerationMethods?.contains(where: { method in
            method == "embedContent" || method == "batchEmbedContents" || method == "asyncBatchEmbedContent"
        }) ?? false

        let imageModelSignals = [
            "dall-e",
            "gpt-image",
            "imagen",
            "flux",
            "stable-diffusion",
            "qwen-image"
        ]
        let embeddingSignals = ["embedding", "embed"]

        let kind: ModelKind
        if containsAny(normalizedName, signals: embeddingSignals) || (supportsEmbedding && !supportsGenerateContent) {
            kind = .embedding
        } else if containsAny(normalizedName, signals: imageModelSignals) {
            kind = .image
        } else {
            kind = .chat
        }

        var inputModalities = defaultInputModalities(for: kind)
        let outputModalities = defaultOutputModalities(for: kind)
        let capabilities = defaultCapabilities(for: kind)

        if kind == .chat {
            let visionSignals = [
                "gpt-4o",
                "gpt-4.1",
                "gpt-5",
                "claude-3",
                "claude-4",
                "gemini",
                "qwen-vl",
                "qwen2-vl",
                "qwen2.5-vl",
                "qwen-omni",
                "llava",
                "pixtral"
            ]
            if containsAny(normalizedName, signals: visionSignals), !inputModalities.contains(.image) {
                inputModalities.append(.image)
            }
        }

        return CapabilityShape(
            kind: kind,
            inputModalities: orderedModalities(inputModalities),
            outputModalities: orderedOutputModalities(outputModalities),
            capabilities: orderedCapabilities(capabilities)
        )
    }

    static func containsAny(_ text: String, signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }
}

public enum ModelOrderIndex {
    public static func merge(storedIDs: [String], currentIDs: [String]) -> [String] {
        let currentSet = Set(currentIDs)
        var result: [String] = []
        result.reserveCapacity(currentIDs.count)
        var seen = Set<String>()

        for id in storedIDs where currentSet.contains(id) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in currentIDs {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public static func move(ids: [String], fromPosition source: Int, toPosition destination: Int) -> [String] {
        var orderedIDs = ids
        guard source >= 0 && source < orderedIDs.count else { return ids }
        guard destination >= 0 && destination < orderedIDs.count else { return ids }
        guard source != destination else { return ids }

        let moved = orderedIDs.remove(at: source)
        orderedIDs.insert(moved, at: destination)
        return orderedIDs
    }
}

public extension Model {
    var supportsToolCalling: Bool {
        capabilities.contains(.toolCalling)
    }

    var supportsReasoning: Bool {
        capabilities.contains(.reasoning)
    }

    var supportsStreaming: Bool {
        capabilities.contains(.streaming)
    }

    var supportsJSONMode: Bool {
        capabilities.contains(.jsonMode)
    }

    var supportsSpeechToText: Bool {
        kind == .speechToText || capabilities.contains(.speechToText)
    }

    var supportsTextToSpeech: Bool {
        kind == .textToSpeech || capabilities.contains(.textToSpeech)
    }

    var supportsEmbedding: Bool {
        kind == .embedding || capabilities.contains(.embedding)
    }

    var supportsRerank: Bool {
        kind == .rerank
    }

    var supportsVisionInput: Bool {
        inputModalities.contains(.image)
    }

    var supportsImageGeneration: Bool {
        kind == .image || outputModalities.contains(.image)
    }

    /// 仅图像类型模型使用独立生图接口；聊天模型的图片输出仍属于对话响应。
    var usesDedicatedImageGenerationEndpoint: Bool {
        kind == .image
    }

    var isChatModel: Bool {
        kind == .chat
    }

    var isConversationModel: Bool {
        kind == .chat || kind == .image
    }

    /// 识别是否属于主流模型家族（用于模型列表分组与筛选）
    var mainstreamFamily: MainstreamModelFamily? {
        MainstreamModelFamily.detect(
            modelName: modelName,
            displayName: displayName
        )
    }

    var isMainstreamModel: Bool {
        mainstreamFamily != nil
    }
}

/// 常见主流模型家族（用于“主流/其他”分组）
public enum MainstreamModelFamily: String, Codable, Hashable, CaseIterable, Sendable {
    case chatgpt
    case gemini
    case claude
    case deepseek
    case qwen
    case kimi
    case doubao
    case grok
    case llama
    case mistral
    case glm

    public var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return "Qwen"
        case .kimi:
            return "Kimi"
        case .doubao:
            return "Doubao"
        case .grok:
            return "Grok"
        case .llama:
            return "Llama"
        case .mistral:
            return "Mistral"
        case .glm:
            return "GLM"
        }
    }

    public static func detect(modelName: String, displayName: String? = nil) -> MainstreamModelFamily? {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchableText = "\(normalizedModelName) \(normalizedDisplayName)"

        if let matched = detectByKeyword(in: searchableText, modelName: normalizedModelName) {
            return matched
        }
        if isChatGPTFamily(modelName: normalizedModelName, displayName: normalizedDisplayName) {
            return .chatgpt
        }
        return nil
    }

    private static let keywordRules: [(family: MainstreamModelFamily, keywords: [String])] = [
        (.gemini, ["gemini"]),
        (.claude, ["claude"]),
        (.deepseek, ["deepseek"]),
        (.qwen, ["qwen"]),
        (.kimi, ["kimi", "moonshot"]),
        (.doubao, ["doubao", "豆包"]),
        (.grok, ["grok"]),
        (.llama, ["llama", "meta-llama"]),
        (.mistral, ["mistral", "mixtral"]),
        (.glm, ["chatglm", "glm-"])
    ]

    private static func detectByKeyword(in searchableText: String, modelName: String) -> MainstreamModelFamily? {
        for rule in keywordRules {
            if rule.keywords.contains(where: { searchableText.contains($0) }) {
                return rule.family
            }
        }
        if modelName.hasPrefix("glm") {
            return .glm
        }
        return nil
    }

    private static func isChatGPTFamily(modelName: String, displayName: String) -> Bool {
        if displayName.contains("chatgpt") || displayName.contains("openai") {
            return true
        }
        if modelName.contains("chatgpt") || modelName.contains("openai") {
            return true
        }
        if modelName.hasPrefix("gpt-") || modelName.contains("/gpt-") {
            return true
        }
        if modelName.hasPrefix("o1") || modelName.hasPrefix("o3") || modelName.hasPrefix("o4") {
            return true
        }
        if modelName.contains("gpt-4")
            || modelName.contains("gpt-5")
            || modelName.contains("gpt-3.5")
            || modelName.contains("gpt4o") {
            return true
        }
        return false
    }
}

private func moveActivatedModelElements<T>(in array: inout [T], fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let sortedOffsets = offsets.sorted()
    guard !sortedOffsets.isEmpty else { return }
    guard sortedOffsets.allSatisfy({ $0 >= 0 && $0 < array.count }) else { return }
    guard destination >= 0 && destination <= array.count else { return }

    let movedItems = sortedOffsets.map { array[$0] }
    for index in sortedOffsets.reversed() {
        array.remove(at: index)
    }

    let removedBeforeDestination = sortedOffsets.filter { $0 < destination }.count
    let insertionIndex = max(0, min(destination - removedBeforeDestination, array.count))
    array.insert(contentsOf: movedItems, at: insertionIndex)
}
