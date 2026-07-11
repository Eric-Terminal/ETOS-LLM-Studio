// ============================================================================
// AudioMemoryModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义音频录制格式与长期记忆条目模型。
// ============================================================================

import Foundation

// MARK: - 音频录制格式

/// 音频录制格式枚举
public enum AudioRecordingFormat: String, CaseIterable, Codable {
    case aac = "aac"
    case wav = "wav"

    /// 显示名称
    public var displayName: String {
        switch self {
        case .aac: return "AAC (M4A)"
        case .wav: return "WAV"
        }
    }

    /// 文件扩展名
    public var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }

    /// MIME 类型
    public var mimeType: String {
        switch self {
        case .aac: return "audio/m4a"
        case .wav: return "audio/wav"
        }
    }

    /// 格式说明
    public var formatDescription: String {
        switch self {
        case .aac: return "AAC 压缩格式，文件小，兼容性好"
        case .wav: return "WAV 无压缩格式，音质最佳，文件较大"
        }
    }
}

// MARK: - 记忆与智能体模型

/// 记忆的认知用途。不同类型会在检索和提示词注入时采用不同权重与说明。
public enum MemoryKind: String, CaseIterable, Codable, Hashable, Sendable {
    case semantic
    case preference
    case episodic
    case procedural

    public var promptLabel: String {
        switch self {
        case .semantic: return "fact"
        case .preference: return "preference"
        case .episodic: return "episode"
        case .procedural: return "instruction"
        }
    }

    public var localizedTitle: String {
        switch self {
        case .semantic: return NSLocalizedString("事实", comment: "Semantic memory kind")
        case .preference: return NSLocalizedString("偏好", comment: "Preference memory kind")
        case .episodic: return NSLocalizedString("经历", comment: "Episodic memory kind")
        case .procedural: return NSLocalizedString("长期规则", comment: "Procedural memory kind")
        }
    }
}

/// 记录一条记忆来自哪里，避免把模型推测与用户明确陈述混为一谈。
public enum MemorySource: String, Codable, Hashable, Sendable {
    case manual
    case userStatement
    case assistantAction
    case conversationSummary
    case imported
}

/// 代表一条独立的记忆，包含内容和其向量表示。
public struct MemoryItem: Codable, Identifiable, Hashable {
    public var id: UUID
    public var content: String
    public var embedding: [Float]
    public var createdAt: Date
    public var updatedAt: Date?         // 最后编辑时间，nil 表示从未编辑
    public var isArchived: Bool  // 是否被归档（被遗忘），归档后不参与检索
    public var kind: MemoryKind
    public var source: MemorySource
    public var importance: Double
    public var confidence: Double
    public var entities: [String]
    public var validFrom: Date?
    public var validUntil: Date?
    public var sourceSessionID: UUID?
    public var accessCount: Int
    public var lastAccessedAt: Date?

    /// 显示时间：优先显示最后编辑时间，否则显示创建时间
    public var displayDate: Date {
        updatedAt ?? createdAt
    }

    public var isCurrentlyValid: Bool {
        isValid(at: Date())
    }

    public init(
        id: UUID = UUID(),
        content: String,
        embedding: [Float],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        isArchived: Bool = false,
        kind: MemoryKind = .semantic,
        source: MemorySource = .manual,
        importance: Double = 0.5,
        confidence: Double = 1,
        entities: [String] = [],
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        sourceSessionID: UUID? = nil,
        accessCount: Int = 0,
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.kind = kind
        self.source = source
        self.importance = min(max(importance, 0), 1)
        self.confidence = min(max(confidence, 0), 1)
        self.entities = Self.normalizedEntities(entities)
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.sourceSessionID = sourceSessionID
        self.accessCount = max(0, accessCount)
        self.lastAccessedAt = lastAccessedAt
    }

    // MARK: - 向后兼容的 Codable 实现

    enum CodingKeys: String, CodingKey {
        case id, content, embedding, createdAt, updatedAt, isArchived
        case kind, source, importance, confidence, entities, validFrom, validUntil
        case sourceSessionID, accessCount, lastAccessedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        embedding = try container.decode([Float].self, forKey: .embedding)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // 向后兼容：如果旧数据没有 updatedAt 字段，默认为 nil
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        // 向后兼容：如果旧数据没有 isArchived 字段，默认为 false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        kind = try container.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? .semantic
        source = try container.decodeIfPresent(MemorySource.self, forKey: .source) ?? .manual
        importance = min(max(try container.decodeIfPresent(Double.self, forKey: .importance) ?? 0.5, 0), 1)
        confidence = min(max(try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1, 0), 1)
        entities = Self.normalizedEntities(try container.decodeIfPresent([String].self, forKey: .entities) ?? [])
        validFrom = try container.decodeIfPresent(Date.self, forKey: .validFrom)
        validUntil = try container.decodeIfPresent(Date.self, forKey: .validUntil)
        sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
        accessCount = max(0, try container.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0)
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
    }

    public func isValid(at date: Date) -> Bool {
        guard !isArchived else { return false }
        if let validFrom, date < validFrom { return false }
        if let validUntil, date >= validUntil { return false }
        return true
    }

    private static func normalizedEntities(_ entities: [String]) -> [String] {
        var seen = Set<String>()
        return entities.compactMap { entity in
            let trimmed = entity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }
}
