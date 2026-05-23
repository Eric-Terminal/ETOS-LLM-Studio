// ============================================================================
// KnowledgeBaseModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 知识库的基础领域模型。当前先覆盖 Cherry Studio 式的知识库、资料项与
// 分块生命周期，向量索引和聊天注入会在后续纵切面继续接入。
// ============================================================================

import Foundation

public enum KnowledgeBaseSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case note
    case url
    case file

    public var localizedTitle: String {
        switch self {
        case .note:
            return NSLocalizedString("笔记", comment: "知识库资料类型：笔记")
        case .url:
            return NSLocalizedString("URL", comment: "知识库资料类型：URL")
        case .file:
            return NSLocalizedString("文件", comment: "知识库资料类型：文件")
        }
    }
}

public enum KnowledgeBaseProcessingStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case processing
    case chunked
    case indexed
    case failed

    public var localizedTitle: String {
        switch self {
        case .pending:
            return NSLocalizedString("待处理", comment: "知识库资料处理状态：待处理")
        case .processing:
            return NSLocalizedString("处理中", comment: "知识库资料处理状态：处理中")
        case .chunked:
            return NSLocalizedString("已分块", comment: "知识库资料处理状态：已分块")
        case .indexed:
            return NSLocalizedString("已索引", comment: "知识库资料处理状态：已索引")
        case .failed:
            return NSLocalizedString("失败", comment: "知识库资料处理状态：失败")
        }
    }
}

public struct KnowledgeBaseSettings: Codable, Hashable, Sendable {
    public var embeddingModelIdentifier: String?
    public var embeddingModelDisplayName: String?
    public var chunkSize: Int
    public var chunkOverlap: Int
    public var retrievalDocumentCount: Int
    public var scoreThreshold: Double

    public init(
        embeddingModelIdentifier: String? = nil,
        embeddingModelDisplayName: String? = nil,
        chunkSize: Int = 1_000,
        chunkOverlap: Int = 200,
        retrievalDocumentCount: Int = 6,
        scoreThreshold: Double = 0.35
    ) {
        self.embeddingModelIdentifier = embeddingModelIdentifier
        self.embeddingModelDisplayName = embeddingModelDisplayName
        self.chunkSize = max(100, chunkSize)
        self.chunkOverlap = max(0, min(chunkOverlap, self.chunkSize - 1))
        self.retrievalDocumentCount = max(1, retrievalDocumentCount)
        self.scoreThreshold = min(1, max(0, scoreThreshold))
    }

    public static let `default` = KnowledgeBaseSettings()
}

public struct KnowledgeBaseSourceItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var baseID: UUID
    public var kind: KnowledgeBaseSourceKind
    public var title: String
    public var sourceURL: URL?
    public var fileName: String?
    public var mimeType: String?
    public var byteCount: Int?
    public var contentPreview: String
    public var contentCharacterCount: Int
    public var status: KnowledgeBaseProcessingStatus
    public var errorMessage: String?
    public var chunkCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        baseID: UUID,
        kind: KnowledgeBaseSourceKind,
        title: String,
        sourceURL: URL? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        contentPreview: String,
        contentCharacterCount: Int,
        status: KnowledgeBaseProcessingStatus,
        errorMessage: String? = nil,
        chunkCount: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.baseID = baseID
        self.kind = kind
        self.title = title
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.contentPreview = contentPreview
        self.contentCharacterCount = max(0, contentCharacterCount)
        self.status = status
        self.errorMessage = errorMessage
        self.chunkCount = max(0, chunkCount)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeBase: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var settings: KnowledgeBaseSettings
    public var items: [KnowledgeBaseSourceItem]
    public var totalChunkCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        settings: KnowledgeBaseSettings = .default,
        items: [KnowledgeBaseSourceItem] = [],
        totalChunkCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.settings = settings
        self.items = items
        self.totalChunkCount = totalChunkCount ?? items.reduce(0) { $0 + $1.chunkCount }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeBaseChunk: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var baseID: UUID
    public var itemID: UUID
    public var index: Int
    public var text: String
    public var characterCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        baseID: UUID,
        itemID: UUID,
        index: Int,
        text: String,
        characterCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.baseID = baseID
        self.itemID = itemID
        self.index = max(0, index)
        self.text = text
        self.characterCount = max(0, characterCount)
        self.createdAt = createdAt
    }
}

public struct KnowledgeBaseURLImportResult: Hashable, Sendable {
    public var title: String
    public var text: String
    public var mimeType: String?
    public var byteCount: Int

    public init(title: String, text: String, mimeType: String?, byteCount: Int) {
        self.title = title
        self.text = text
        self.mimeType = mimeType
        self.byteCount = max(0, byteCount)
    }
}

public enum KnowledgeBaseStoreError: LocalizedError, Sendable {
    case databaseUnavailable
    case knowledgeBaseNotFound
    case emptyName
    case emptyContent
    case invalidURL
    case unsupportedURLResponse
    case downloadFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return NSLocalizedString("知识库数据库暂时不可用。", comment: "知识库数据库不可用错误")
        case .knowledgeBaseNotFound:
            return NSLocalizedString("找不到这个知识库。", comment: "知识库不存在错误")
        case .emptyName:
            return NSLocalizedString("知识库名称不能为空。", comment: "知识库名称为空错误")
        case .emptyContent:
            return NSLocalizedString("资料内容不能为空。", comment: "知识库资料内容为空错误")
        case .invalidURL:
            return NSLocalizedString("请输入有效的 HTTP 或 HTTPS 地址。", comment: "知识库 URL 无效错误")
        case .unsupportedURLResponse:
            return NSLocalizedString("无法识别服务器返回的内容。", comment: "知识库 URL 响应无效错误")
        case .downloadFailed(let statusCode):
            return String(
                format: NSLocalizedString("URL 下载失败（HTTP %d）。", comment: "知识库 URL 下载失败错误"),
                statusCode
            )
        }
    }
}
