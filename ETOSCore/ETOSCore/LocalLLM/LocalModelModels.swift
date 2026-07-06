// ============================================================================
// LocalModelModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义端侧本地模型的持久化记录与默认参数。
// ============================================================================

import Foundation

public enum LocalLLMFlashAttentionMode: Int32, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case auto = -1
    case disabled = 0
    case enabled = 1

    public var id: Int32 { rawValue }

    public var localizedTitle: String {
        switch self {
        case .auto:
            return NSLocalizedString("自动", comment: "Local flash attention auto")
        case .disabled:
            return NSLocalizedString("关闭", comment: "Local flash attention disabled")
        case .enabled:
            return NSLocalizedString("开启", comment: "Local flash attention enabled")
        }
    }

    public static func parse(_ rawValue: String) -> LocalLLMFlashAttentionMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "-1":
            return .auto
        case "off", "false", "0", "disabled", "disable", "no":
            return .disabled
        case "on", "true", "1", "enabled", "enable", "yes":
            return .enabled
        default:
            return nil
        }
    }
}

public struct LocalModelRecord: Codable, Identifiable, Hashable, Sendable {
    public static let defaultContextSize = 2048
    public static let defaultMaxOutputTokens = 512
    public static let defaultGPULayers = -1
    public static let defaultBatchSize = 0
    public static let defaultUbatchSize = 0
    public static let defaultKVOffload = true
    public static let defaultFlashAttention = LocalLLMFlashAttentionMode.auto
    public static let defaultAdvancedArguments = ""
    public static let defaultSeed = UInt32.max
    public static let defaultTemperature = 1.0
    public static let defaultTopK = 0
    public static let defaultTopP = 1.0
    public static let defaultMinP = 0.0
    public static let defaultRepeatLastN = 64
    public static let defaultRepeatPenalty = 1.0
    public static let defaultFrequencyPenalty = 0.0
    public static let defaultPresencePenalty = 0.0
    public static let defaultGrammar = ""
    public static let defaultIgnoreEOS = false
    public static let defaultImageMinTokens = -1
    public static let defaultImageMaxTokens = -1

    private static let legacyForcedDefaultTemperature = 0.8
    private static let legacyForcedDefaultTopK = 40
    private static let legacyForcedDefaultTopP = 0.95
    private static let legacyForcedDefaultMinP = 0.05
    private static let legacyForcedDefaultSamplerKinds = LocalLLMSamplerKind.parse("edskypmxt")

    public var id: UUID
    public var displayName: String
    public var fileName: String
    public var relativePath: String
    public var fileSize: Int64
    public var mmprojFileName: String?
    public var mmprojRelativePath: String?
    public var mmprojFileSize: Int64?
    public var createdAt: Date
    public var updatedAt: Date
    public var isActivated: Bool
    public var contextSize: Int?
    public var maxOutputTokens: Int?
    public var gpuLayers: Int?
    public var batchSize: Int?
    public var ubatchSize: Int?
    public var kvOffload: Bool?
    public var flashAttention: LocalLLMFlashAttentionMode?
    public var seed: UInt32?
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var repeatLastN: Int?
    public var repeatPenalty: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var grammar: String?
    public var ignoreEOS: Bool?
    public var imageMinTokens: Int?
    public var imageMaxTokens: Int?
    public var samplerKinds: [LocalLLMSamplerKind]?
    public var advancedArguments: String
    public var note: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        fileName: String,
        relativePath: String,
        fileSize: Int64,
        mmprojFileName: String? = nil,
        mmprojRelativePath: String? = nil,
        mmprojFileSize: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActivated: Bool = true,
        contextSize: Int? = nil,
        maxOutputTokens: Int? = nil,
        gpuLayers: Int? = nil,
        batchSize: Int? = nil,
        ubatchSize: Int? = nil,
        kvOffload: Bool? = nil,
        flashAttention: LocalLLMFlashAttentionMode? = nil,
        seed: UInt32? = nil,
        temperature: Double? = nil,
        topK: Int? = nil,
        topP: Double? = nil,
        minP: Double? = nil,
        repeatLastN: Int? = nil,
        repeatPenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        grammar: String? = nil,
        ignoreEOS: Bool? = nil,
        imageMinTokens: Int? = nil,
        imageMaxTokens: Int? = nil,
        samplerKinds: [LocalLLMSamplerKind]? = nil,
        advancedArguments: String = LocalModelRecord.defaultAdvancedArguments,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.mmprojFileName = mmprojFileName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.mmprojRelativePath = mmprojRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.mmprojFileSize = mmprojFileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActivated = isActivated
        self.contextSize = contextSize
        self.maxOutputTokens = maxOutputTokens
        self.gpuLayers = gpuLayers
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
        self.kvOffload = kvOffload
        self.flashAttention = flashAttention
        self.seed = seed
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatLastN = repeatLastN
        self.repeatPenalty = repeatPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.grammar = grammar.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        self.ignoreEOS = ignoreEOS
        self.imageMinTokens = imageMinTokens
        self.imageMaxTokens = imageMaxTokens
        self.samplerKinds = samplerKinds.flatMap { LocalLLMSamplerKind.unique($0).nilIfEmpty }
        self.advancedArguments = advancedArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalizeGenerationParameters()
    }

    public var sanitizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    public var modelName: String {
        "local-gguf-\(id.uuidString.lowercased())"
    }

    public var effectiveContextSize: Int {
        contextSize ?? Self.defaultContextSize
    }

    public var effectiveMaxOutputTokens: Int {
        maxOutputTokens ?? Self.defaultMaxOutputTokens
    }

    public var effectiveGPULayers: Int {
        gpuLayers ?? Self.defaultGPULayers
    }

    public var effectiveBatchSize: Int {
        batchSize ?? Self.defaultBatchSize
    }

    public var effectiveUbatchSize: Int {
        ubatchSize ?? Self.defaultUbatchSize
    }

    public var effectiveKVOffload: Bool {
        kvOffload ?? Self.defaultKVOffload
    }

    public var effectiveFlashAttention: LocalLLMFlashAttentionMode {
        flashAttention ?? Self.defaultFlashAttention
    }

    public var effectiveSeed: UInt32 {
        seed ?? Self.defaultSeed
    }

    public var effectiveTemperature: Double {
        temperature ?? Self.defaultTemperature
    }

    public var effectiveTopK: Int {
        topK ?? Self.defaultTopK
    }

    public var effectiveTopP: Double {
        topP ?? Self.defaultTopP
    }

    public var effectiveMinP: Double {
        minP ?? Self.defaultMinP
    }

    public var effectiveRepeatLastN: Int {
        repeatLastN ?? Self.defaultRepeatLastN
    }

    public var effectiveRepeatPenalty: Double {
        repeatPenalty ?? Self.defaultRepeatPenalty
    }

    public var effectiveFrequencyPenalty: Double {
        frequencyPenalty ?? Self.defaultFrequencyPenalty
    }

    public var effectivePresencePenalty: Double {
        presencePenalty ?? Self.defaultPresencePenalty
    }

    public var effectiveGrammar: String {
        grammar ?? Self.defaultGrammar
    }

    public var effectiveIgnoreEOS: Bool {
        ignoreEOS ?? Self.defaultIgnoreEOS
    }

    public var effectiveImageMinTokens: Int {
        imageMinTokens ?? Self.defaultImageMinTokens
    }

    public var effectiveImageMaxTokens: Int {
        imageMaxTokens ?? Self.defaultImageMaxTokens
    }

    public var effectiveSamplerKinds: [LocalLLMSamplerKind] {
        samplerKinds ?? LocalLLMSamplerKind.defaultChain
    }

    public var hasMultimodalProjector: Bool {
        mmprojRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileName
        case relativePath
        case fileSize
        case mmprojFileName
        case mmprojRelativePath
        case mmprojFileSize
        case createdAt
        case updatedAt
        case isActivated
        case contextSize
        case maxOutputTokens
        case gpuLayers
        case batchSize
        case ubatchSize
        case kvOffload
        case flashAttention
        case seed
        case temperature
        case topK
        case topP
        case minP
        case repeatLastN
        case repeatPenalty
        case frequencyPenalty
        case presencePenalty
        case grammar
        case ignoreEOS
        case imageMinTokens
        case imageMaxTokens
        case samplerKinds
        case advancedArguments
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            fileName: try container.decode(String.self, forKey: .fileName),
            relativePath: try container.decode(String.self, forKey: .relativePath),
            fileSize: try container.decode(Int64.self, forKey: .fileSize),
            mmprojFileName: try container.decodeIfPresent(String.self, forKey: .mmprojFileName),
            mmprojRelativePath: try container.decodeIfPresent(String.self, forKey: .mmprojRelativePath),
            mmprojFileSize: try container.decodeIfPresent(Int64.self, forKey: .mmprojFileSize),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            isActivated: try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? true,
            contextSize: try container.decodeIfPresent(Int.self, forKey: .contextSize),
            maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
            gpuLayers: try container.decodeIfPresent(Int.self, forKey: .gpuLayers),
            batchSize: try container.decodeIfPresent(Int.self, forKey: .batchSize),
            ubatchSize: try container.decodeIfPresent(Int.self, forKey: .ubatchSize),
            kvOffload: try container.decodeIfPresent(Bool.self, forKey: .kvOffload),
            flashAttention: try container.decodeIfPresent(LocalLLMFlashAttentionMode.self, forKey: .flashAttention),
            seed: try container.decodeIfPresent(UInt32.self, forKey: .seed),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            topK: try container.decodeIfPresent(Int.self, forKey: .topK),
            topP: try container.decodeIfPresent(Double.self, forKey: .topP),
            minP: try container.decodeIfPresent(Double.self, forKey: .minP),
            repeatLastN: try container.decodeIfPresent(Int.self, forKey: .repeatLastN),
            repeatPenalty: try container.decodeIfPresent(Double.self, forKey: .repeatPenalty),
            frequencyPenalty: try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty),
            presencePenalty: try container.decodeIfPresent(Double.self, forKey: .presencePenalty),
            grammar: try container.decodeIfPresent(String.self, forKey: .grammar),
            ignoreEOS: try container.decodeIfPresent(Bool.self, forKey: .ignoreEOS),
            imageMinTokens: try container.decodeIfPresent(Int.self, forKey: .imageMinTokens),
            imageMaxTokens: try container.decodeIfPresent(Int.self, forKey: .imageMaxTokens),
            samplerKinds: try container.decodeIfPresent([LocalLLMSamplerKind].self, forKey: .samplerKinds),
            advancedArguments: try container.decodeIfPresent(String.self, forKey: .advancedArguments) ?? Self.defaultAdvancedArguments,
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }

    public mutating func normalizeGenerationParameters() {
        mmprojFileName = mmprojFileName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        mmprojRelativePath = mmprojRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if mmprojRelativePath == nil {
            mmprojFileName = nil
            mmprojFileSize = nil
        }
        contextSize = contextSize?.clamped(to: 1...1_048_576)
        maxOutputTokens = maxOutputTokens?.clamped(to: 1...131_072)
        gpuLayers = gpuLayers?.clamped(to: -1...999)
        batchSize = batchSize?.clamped(to: 0...1_048_576)
        ubatchSize = ubatchSize?.clamped(to: 0...1_048_576)
        temperature = temperature?.clamped(to: 0...5)
        topK = topK?.clamped(to: 0...1_000)
        topP = topP?.clamped(to: 0...1)
        minP = minP?.clamped(to: 0...1)
        repeatLastN = repeatLastN?.clamped(to: -1...1_048_576)
        repeatPenalty = repeatPenalty?.clamped(to: 0...4)
        frequencyPenalty = frequencyPenalty?.clamped(to: -2...2)
        presencePenalty = presencePenalty?.clamped(to: -2...2)
        grammar = grammar.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        imageMinTokens = imageMinTokens?.clamped(to: -1...1_048_576)
        imageMaxTokens = imageMaxTokens?.clamped(to: -1...1_048_576)
        samplerKinds = samplerKinds.flatMap { LocalLLMSamplerKind.unique($0).nilIfEmpty }
        advancedArguments = advancedArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func removingLegacyForcedDefaultOverrides() -> LocalModelRecord {
        var record = self
        if record.contextSize == Self.defaultContextSize { record.contextSize = nil }
        if record.maxOutputTokens == Self.defaultMaxOutputTokens { record.maxOutputTokens = nil }
        if record.gpuLayers == Self.defaultGPULayers { record.gpuLayers = nil }
        if record.batchSize == Self.defaultBatchSize { record.batchSize = nil }
        if record.ubatchSize == Self.defaultUbatchSize { record.ubatchSize = nil }
        if record.kvOffload == Self.defaultKVOffload { record.kvOffload = nil }
        if record.flashAttention == Self.defaultFlashAttention { record.flashAttention = nil }
        if record.seed == Self.defaultSeed { record.seed = nil }
        if record.temperature == Self.legacyForcedDefaultTemperature { record.temperature = nil }
        if record.topK == Self.legacyForcedDefaultTopK { record.topK = nil }
        if record.topP == Self.legacyForcedDefaultTopP { record.topP = nil }
        if record.minP == Self.legacyForcedDefaultMinP { record.minP = nil }
        if record.repeatLastN == Self.defaultRepeatLastN { record.repeatLastN = nil }
        if record.repeatPenalty == Self.defaultRepeatPenalty { record.repeatPenalty = nil }
        if record.frequencyPenalty == Self.defaultFrequencyPenalty { record.frequencyPenalty = nil }
        if record.presencePenalty == Self.defaultPresencePenalty { record.presencePenalty = nil }
        if record.grammar?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == nil {
            record.grammar = nil
        }
        if record.ignoreEOS == Self.defaultIgnoreEOS { record.ignoreEOS = nil }
        if record.imageMinTokens == Self.defaultImageMinTokens { record.imageMinTokens = nil }
        if record.imageMaxTokens == Self.defaultImageMaxTokens { record.imageMaxTokens = nil }
        if LocalLLMSamplerKind.unique(record.samplerKinds ?? []) == Self.legacyForcedDefaultSamplerKinds {
            record.samplerKinds = nil
        }
        record.normalizeGenerationParameters()
        return record
    }
}

public struct LocalModelStoreSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var models: [LocalModelRecord]

    public init(
        schemaVersion: Int = LocalModelStoreSnapshot.currentSchemaVersion,
        models: [LocalModelRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.models = models
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
