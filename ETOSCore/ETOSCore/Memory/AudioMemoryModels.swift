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

/// 代表一条独立的记忆，包含内容和其向量表示。
public struct MemoryItem: Codable, Identifiable, Hashable {
    public var id: UUID
    public var content: String
    public var embedding: [Float]
    public var createdAt: Date
    public var updatedAt: Date?         // 最后编辑时间，nil 表示从未编辑
    public var isArchived: Bool  // 是否被归档（被遗忘），归档后不参与检索

    /// 显示时间：优先显示最后编辑时间，否则显示创建时间
    public var displayDate: Date {
        updatedAt ?? createdAt
    }

    public init(id: UUID = UUID(), content: String, embedding: [Float], createdAt: Date = Date(), updatedAt: Date? = nil, isArchived: Bool = false) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }

    // MARK: - 向后兼容的 Codable 实现

    enum CodingKeys: String, CodingKey {
        case id, content, embedding, createdAt, updatedAt, isArchived
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
    }
}
