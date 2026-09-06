// ============================================================================
// MemoryGovernanceModels.swift
// ETOS LLM Studio
// ============================================================================

import CryptoKit
import Foundation

public enum MemoryMutationOperation: String, Codable, CaseIterable, Sendable {
    case created
    case edited
    case archived
    case restored
    case deleted
    case automaticConsolidation = "automatic_consolidation"
    case imported

    public var localizedTitle: String {
        switch self {
        case .created: return NSLocalizedString("创建", comment: "Memory mutation created")
        case .edited: return NSLocalizedString("编辑", comment: "Memory mutation edited")
        case .archived: return NSLocalizedString("归档", comment: "Memory mutation archived")
        case .restored: return NSLocalizedString("恢复", comment: "Memory mutation restored")
        case .deleted: return NSLocalizedString("删除", comment: "Memory mutation deleted")
        case .automaticConsolidation: return NSLocalizedString("自动整理", comment: "Memory mutation automatic consolidation")
        case .imported: return NSLocalizedString("导入", comment: "Memory mutation imported")
        }
    }
}

public enum MemoryMutationOrigin: String, Codable, Sendable {
    case manual
    case tool
    case shortcut
    case automaticConsolidation = "automatic_consolidation"
    case imported
    case sync

    public var localizedTitle: String {
        switch self {
        case .manual: return NSLocalizedString("手动操作", comment: "Manual memory mutation origin")
        case .tool: return NSLocalizedString("模型工具", comment: "Tool memory mutation origin")
        case .shortcut: return NSLocalizedString("快捷指令", comment: "Shortcut memory mutation origin")
        case .automaticConsolidation: return NSLocalizedString("自动整理", comment: "Automatic memory mutation origin")
        case .imported: return NSLocalizedString("导入归档", comment: "Imported memory mutation origin")
        case .sync: return NSLocalizedString("设备同步", comment: "Sync memory mutation origin")
        }
    }
}

public struct MemoryMutationContext: Codable, Equatable, Sendable {
    public let origin: MemoryMutationOrigin
    public let sourceSessionID: UUID?
    public let sourceMessageID: UUID?
    public let sourceToolName: String?
    public let sourceShortcutName: String?
    public let transferReceiptID: UUID?

    public init(
        origin: MemoryMutationOrigin = .manual,
        sourceSessionID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        sourceToolName: String? = nil,
        sourceShortcutName: String? = nil,
        transferReceiptID: UUID? = nil
    ) {
        self.origin = origin
        self.sourceSessionID = sourceSessionID
        self.sourceMessageID = sourceMessageID
        self.sourceToolName = sourceToolName
        self.sourceShortcutName = sourceShortcutName
        self.transferReceiptID = transferReceiptID
    }
}

public struct MemoryVersionSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let content: String
    public let createdAt: Date
    public let updatedAt: Date?
    public let isArchived: Bool
    public let kind: MemoryKind
    public let source: MemorySource
    public let importance: Double
    public let confidence: Double
    public let entities: [String]
    public let validFrom: Date?
    public let validUntil: Date?
    public let sourceSessionID: UUID?
    public let accessCount: Int
    public let lastAccessedAt: Date?

    public init(memory: MemoryItem) {
        id = memory.id
        content = memory.content
        createdAt = memory.createdAt
        updatedAt = memory.updatedAt
        isArchived = memory.isArchived
        kind = memory.kind
        source = memory.source
        importance = memory.importance
        confidence = memory.confidence
        entities = memory.entities
        validFrom = memory.validFrom
        validUntil = memory.validUntil
        sourceSessionID = memory.sourceSessionID
        accessCount = memory.accessCount
        lastAccessedAt = memory.lastAccessedAt
    }

    public var memoryItem: MemoryItem {
        MemoryItem(
            id: id,
            content: content,
            embedding: [],
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: isArchived,
            kind: kind,
            source: source,
            importance: importance,
            confidence: confidence,
            entities: entities,
            validFrom: validFrom,
            validUntil: validUntil,
            sourceSessionID: sourceSessionID,
            accessCount: accessCount,
            lastAccessedAt: lastAccessedAt
        )
    }

    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var summary: String {
        let compact = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(compact.prefix(160))
    }
}

public struct MemoryMutationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let memoryID: UUID
    public let operation: MemoryMutationOperation
    public let context: MemoryMutationContext
    public let before: MemoryVersionSnapshot?
    public let after: MemoryVersionSnapshot?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        memoryID: UUID,
        operation: MemoryMutationOperation,
        context: MemoryMutationContext,
        before: MemoryVersionSnapshot?,
        after: MemoryVersionSnapshot?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.memoryID = memoryID
        self.operation = operation
        self.context = context
        self.before = before
        self.after = after
        self.createdAt = createdAt
    }
}

struct MemoryPendingMutation: Sendable {
    let before: MemoryItem?
    let after: MemoryItem?
    let record: MemoryMutationRecord
}

public struct MemoryRetrievalExplanation: Codable, Equatable, Sendable {
    public let totalScore: Double
    public let semantic: Double
    public let lexical: Double
    public let entity: Double
    public let importance: Double
    public let confidence: Double
    public let recency: Double
    public let strength: Double
    public let temporal: Double
    public let typeBoost: Double

    public init(
        totalScore: Double,
        semantic: Double,
        lexical: Double,
        entity: Double,
        importance: Double,
        confidence: Double,
        recency: Double,
        strength: Double,
        temporal: Double,
        typeBoost: Double
    ) {
        self.totalScore = totalScore
        self.semantic = semantic
        self.lexical = lexical
        self.entity = entity
        self.importance = importance
        self.confidence = confidence
        self.recency = recency
        self.strength = strength
        self.temporal = temporal
        self.typeBoost = typeBoost
    }
}

public struct ExplainedMemoryResult: Codable, Equatable, Sendable {
    public let memory: MemoryItem
    public let explanation: MemoryRetrievalExplanation

    public init(memory: MemoryItem, explanation: MemoryRetrievalExplanation) {
        self.memory = memory
        self.explanation = explanation
    }
}

public enum MemoryTransferKind: String, Codable, Sendable {
    case markdownExport = "markdown_export"
    case archiveExport = "archive_export"
    case archiveImport = "archive_import"
}

public struct MemoryTransferReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: MemoryTransferKind
    public let fileName: String
    public let payloadSHA256: String
    public let addedCount: Int
    public let updatedCount: Int
    public let conflictCount: Int
    public let archivedCount: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: MemoryTransferKind,
        fileName: String,
        payloadSHA256: String,
        addedCount: Int = 0,
        updatedCount: Int = 0,
        conflictCount: Int = 0,
        archivedCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.payloadSHA256 = payloadSHA256
        self.addedCount = addedCount
        self.updatedCount = updatedCount
        self.conflictCount = conflictCount
        self.archivedCount = archivedCount
        self.createdAt = createdAt
    }
}
