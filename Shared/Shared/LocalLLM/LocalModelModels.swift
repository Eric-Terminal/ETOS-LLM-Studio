// ============================================================================
// LocalModelModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义端侧本地模型的持久化记录与默认参数。
// ============================================================================

import Foundation

public struct LocalModelRecord: Codable, Identifiable, Hashable, Sendable {
    public static let defaultContextSize = 2048
    public static let defaultMaxOutputTokens = 512
    public static let defaultGPULayers = -1
    public static let defaultAdvancedArguments = ""
    public static let defaultSeed = UInt32.max
    public static let defaultTemperature = 0.8
    public static let defaultTopK = 40
    public static let defaultTopP = 0.95
    public static let defaultMinP = 0.05
    public static let defaultRepeatLastN = 64
    public static let defaultRepeatPenalty = 1.0
    public static let defaultFrequencyPenalty = 0.0
    public static let defaultPresencePenalty = 0.0
    public static let defaultGrammar = ""
    public static let defaultIgnoreEOS = false

    public var id: UUID
    public var displayName: String
    public var fileName: String
    public var relativePath: String
    public var fileSize: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var isActivated: Bool
    public var contextSize: Int
    public var maxOutputTokens: Int
    public var gpuLayers: Int
    public var seed: UInt32
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    public var minP: Double
    public var repeatLastN: Int
    public var repeatPenalty: Double
    public var frequencyPenalty: Double
    public var presencePenalty: Double
    public var grammar: String
    public var ignoreEOS: Bool
    public var samplerKinds: [LocalLLMSamplerKind]
    public var advancedArguments: String
    public var note: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        fileName: String,
        relativePath: String,
        fileSize: Int64,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActivated: Bool = true,
        contextSize: Int = LocalModelRecord.defaultContextSize,
        maxOutputTokens: Int = LocalModelRecord.defaultMaxOutputTokens,
        gpuLayers: Int = LocalModelRecord.defaultGPULayers,
        seed: UInt32 = LocalModelRecord.defaultSeed,
        temperature: Double = LocalModelRecord.defaultTemperature,
        topK: Int = LocalModelRecord.defaultTopK,
        topP: Double = LocalModelRecord.defaultTopP,
        minP: Double = LocalModelRecord.defaultMinP,
        repeatLastN: Int = LocalModelRecord.defaultRepeatLastN,
        repeatPenalty: Double = LocalModelRecord.defaultRepeatPenalty,
        frequencyPenalty: Double = LocalModelRecord.defaultFrequencyPenalty,
        presencePenalty: Double = LocalModelRecord.defaultPresencePenalty,
        grammar: String = LocalModelRecord.defaultGrammar,
        ignoreEOS: Bool = LocalModelRecord.defaultIgnoreEOS,
        samplerKinds: [LocalLLMSamplerKind] = LocalLLMSamplerKind.defaultChain,
        advancedArguments: String = LocalModelRecord.defaultAdvancedArguments,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActivated = isActivated
        self.contextSize = max(1, contextSize)
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.gpuLayers = gpuLayers
        self.seed = seed
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatLastN = repeatLastN
        self.repeatPenalty = repeatPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.grammar = grammar.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ignoreEOS = ignoreEOS
        self.samplerKinds = LocalLLMSamplerKind.unique(samplerKinds)
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

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileName
        case relativePath
        case fileSize
        case createdAt
        case updatedAt
        case isActivated
        case contextSize
        case maxOutputTokens
        case gpuLayers
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
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            isActivated: try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? true,
            contextSize: try container.decodeIfPresent(Int.self, forKey: .contextSize) ?? Self.defaultContextSize,
            maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? Self.defaultMaxOutputTokens,
            gpuLayers: try container.decodeIfPresent(Int.self, forKey: .gpuLayers) ?? Self.defaultGPULayers,
            seed: try container.decodeIfPresent(UInt32.self, forKey: .seed) ?? Self.defaultSeed,
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature) ?? Self.defaultTemperature,
            topK: try container.decodeIfPresent(Int.self, forKey: .topK) ?? Self.defaultTopK,
            topP: try container.decodeIfPresent(Double.self, forKey: .topP) ?? Self.defaultTopP,
            minP: try container.decodeIfPresent(Double.self, forKey: .minP) ?? Self.defaultMinP,
            repeatLastN: try container.decodeIfPresent(Int.self, forKey: .repeatLastN) ?? Self.defaultRepeatLastN,
            repeatPenalty: try container.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? Self.defaultRepeatPenalty,
            frequencyPenalty: try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty) ?? Self.defaultFrequencyPenalty,
            presencePenalty: try container.decodeIfPresent(Double.self, forKey: .presencePenalty) ?? Self.defaultPresencePenalty,
            grammar: try container.decodeIfPresent(String.self, forKey: .grammar) ?? Self.defaultGrammar,
            ignoreEOS: try container.decodeIfPresent(Bool.self, forKey: .ignoreEOS) ?? Self.defaultIgnoreEOS,
            samplerKinds: try container.decodeIfPresent([LocalLLMSamplerKind].self, forKey: .samplerKinds) ?? LocalLLMSamplerKind.defaultChain,
            advancedArguments: try container.decodeIfPresent(String.self, forKey: .advancedArguments) ?? Self.defaultAdvancedArguments,
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }

    public mutating func normalizeGenerationParameters() {
        contextSize = contextSize.clamped(to: 1...1_048_576)
        maxOutputTokens = maxOutputTokens.clamped(to: 1...131_072)
        gpuLayers = gpuLayers.clamped(to: -1...999)
        temperature = temperature.clamped(to: 0...5)
        topK = topK.clamped(to: 0...1_000)
        topP = topP.clamped(to: 0...1)
        minP = minP.clamped(to: 0...1)
        repeatLastN = repeatLastN.clamped(to: -1...1_048_576)
        repeatPenalty = repeatPenalty.clamped(to: 0...4)
        frequencyPenalty = frequencyPenalty.clamped(to: -2...2)
        presencePenalty = presencePenalty.clamped(to: -2...2)
        grammar = grammar.trimmingCharacters(in: .whitespacesAndNewlines)
        samplerKinds = LocalLLMSamplerKind.unique(samplerKinds)
        if samplerKinds.isEmpty {
            samplerKinds = LocalLLMSamplerKind.defaultChain
        }
        advancedArguments = advancedArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct LocalModelStoreSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
