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
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var sanitizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    public var modelName: String {
        "local-gguf-\(id.uuidString.lowercased())"
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
