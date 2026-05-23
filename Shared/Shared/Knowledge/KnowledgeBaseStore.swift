// ============================================================================
// KnowledgeBaseStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 知识库管理器：负责独立 SQLite 分库的 CRUD、资料分块和 URL 下载导入。
// UI 只订阅已整理好的轻量模型，不直接触碰磁盘或网络。
// ============================================================================

import Combine
import CoreFoundation
import Foundation
import GRDB

@MainActor
public final class KnowledgeBaseStore: ObservableObject {
    public static let shared = KnowledgeBaseStore()

    @Published public private(set) var knowledgeBases: [KnowledgeBase] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastErrorMessage: String?

    private let database: KnowledgeBaseDatabase
    private var refreshTask: Task<Void, Never>?

    public convenience init() {
        self.init(database: KnowledgeBaseDatabase.shared)
    }

    public init(database: KnowledgeBaseDatabase) {
        self.database = database
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() {
        refreshTask?.cancel()
        isLoading = true
        lastErrorMessage = nil

        let database = self.database
        refreshTask = Task { [weak self] in
            let result = await Self.loadSnapshot(database: database)
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            switch result {
            case .success(let bases):
                self.knowledgeBases = bases
            case .failure(let error):
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func createKnowledgeBase(
        name: String,
        description: String = "",
        embeddingModelIdentifier: String? = nil,
        embeddingModelDisplayName: String? = nil
    ) async throws -> KnowledgeBase {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw KnowledgeBaseStoreError.emptyName
        }

        let settings = KnowledgeBaseSettings(
            embeddingModelIdentifier: emptyToNil(embeddingModelIdentifier),
            embeddingModelDisplayName: emptyToNil(embeddingModelDisplayName)
        )
        let base = KnowledgeBase(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            settings: settings
        )
        let database = self.database
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            try database.write { db in
                try Self.insert(base, into: db)
            }
        }.value
        await reloadAfterMutation()
        return base
    }

    public func deleteKnowledgeBase(id: UUID) async throws {
        let database = self.database
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            try database.write { db in
                try db.execute(sql: "DELETE FROM knowledge_bases WHERE id = ?", arguments: [id.uuidString])
            }
        }.value
        await reloadAfterMutation()
    }

    @discardableResult
    public func addNote(
        to baseID: UUID,
        title: String,
        content: String
    ) async throws -> KnowledgeBaseSourceItem {
        try await addTextItem(
            to: baseID,
            kind: .note,
            title: title,
            content: content,
            sourceURL: nil,
            fileName: nil,
            mimeType: "text/plain",
            byteCount: content.data(using: .utf8)?.count
        )
    }

    @discardableResult
    public func addFileText(
        to baseID: UUID,
        fileName: String,
        mimeType: String,
        byteCount: Int,
        content: String
    ) async throws -> KnowledgeBaseSourceItem {
        try await addTextItem(
            to: baseID,
            kind: .file,
            title: fileName,
            content: content,
            sourceURL: nil,
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount
        )
    }

    @discardableResult
    public func importURL(
        to baseID: UUID,
        urlText: String,
        title: String? = nil
    ) async throws -> KnowledgeBaseSourceItem {
        guard let url = normalizedHTTPURL(from: urlText) else {
            throw KnowledgeBaseStoreError.invalidURL
        }

        let importResult = try await KnowledgeBaseURLImporter.download(from: url)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try await addTextItem(
            to: baseID,
            kind: .url,
            title: trimmedTitle.isEmpty ? importResult.title : trimmedTitle,
            content: importResult.text,
            sourceURL: url,
            fileName: nil,
            mimeType: importResult.mimeType,
            byteCount: importResult.byteCount
        )
    }

    public func deleteItem(baseID: UUID, itemID: UUID) async throws {
        let database = self.database
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            try database.write { db in
                try db.execute(
                    sql: "DELETE FROM knowledge_base_items WHERE base_id = ? AND id = ?",
                    arguments: [baseID.uuidString, itemID.uuidString]
                )
                try Self.touchBase(baseID, in: db)
            }
        }.value
        await reloadAfterMutation()
    }

    public func chunks(for itemID: UUID) async throws -> [KnowledgeBaseChunk] {
        let database = self.database
        return try await Task.detached(priority: .userInitiated) { () throws -> [KnowledgeBaseChunk] in
            try database.read { db in
                let records = try KnowledgeBaseChunkRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM knowledge_base_chunks
                    WHERE item_id = ?
                    ORDER BY chunk_index ASC
                    """,
                    arguments: [itemID.uuidString]
                )
                return records.map(Self.chunk(from:))
            }
        }.value
    }

    public func search(
        query: String,
        baseID: UUID? = nil,
        limit: Int = 12
    ) async throws -> [KnowledgeBaseSearchResult] {
        let tokens = KnowledgeBaseTextProcessor.keywordTokens(from: query)
        guard !tokens.isEmpty else { return [] }

        let database = self.database
        let resolvedLimit = max(1, min(limit, 30))
        return try await Task.detached(priority: .userInitiated) { () throws -> [KnowledgeBaseSearchResult] in
            let candidates = try database.read { db in
                try Self.searchCandidates(baseID: baseID, in: db)
            }
            return candidates
                .compactMap { candidate -> KnowledgeBaseSearchResult? in
                    let score = Self.keywordScore(for: candidate.text, tokens: tokens)
                    guard score > 0 else { return nil }
                    return KnowledgeBaseSearchResult(
                        baseID: candidate.baseID,
                        baseName: candidate.baseName,
                        itemID: candidate.itemID,
                        itemTitle: candidate.itemTitle,
                        itemKind: candidate.itemKind,
                        chunkID: candidate.chunkID,
                        chunkIndex: candidate.chunkIndex,
                        text: candidate.text,
                        score: score
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    if lhs.itemTitle != rhs.itemTitle {
                        return lhs.itemTitle.localizedCaseInsensitiveCompare(rhs.itemTitle) == .orderedAscending
                    }
                    return lhs.chunkIndex < rhs.chunkIndex
                }
                .prefix(resolvedLimit)
                .map { $0 }
        }.value
    }

    @discardableResult
    private func addTextItem(
        to baseID: UUID,
        kind: KnowledgeBaseSourceKind,
        title: String,
        content: String,
        sourceURL: URL?,
        fileName: String?,
        mimeType: String?,
        byteCount: Int?
    ) async throws -> KnowledgeBaseSourceItem {
        let database = self.database
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = try await Task.detached(priority: .userInitiated) { () throws -> KnowledgeBaseSourceItem in
            let normalizedContent = KnowledgeBaseTextProcessor.normalize(content)
            guard !normalizedContent.isEmpty else {
                throw KnowledgeBaseStoreError.emptyContent
            }

            try database.write { db in
                guard let base = try Self.baseRecord(id: baseID, in: db) else {
                    throw KnowledgeBaseStoreError.knowledgeBaseNotFound
                }
                let fallbackTitle = sourceURL?.absoluteString ?? fileName ?? NSLocalizedString("未命名资料", comment: "知识库未命名资料")
                let itemID = UUID()
                let chunks = KnowledgeBaseTextProcessor.chunks(
                    from: normalizedContent,
                    baseID: baseID,
                    itemID: itemID,
                    chunkSize: base.chunkSize,
                    overlap: base.chunkOverlap
                )
                let status: KnowledgeBaseProcessingStatus = chunks.isEmpty ? .pending : .chunked
                let now = Date()
                let item = KnowledgeBaseSourceItem(
                    id: itemID,
                    baseID: baseID,
                    kind: kind,
                    title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle,
                    sourceURL: sourceURL,
                    fileName: fileName,
                    mimeType: mimeType,
                    byteCount: byteCount,
                    contentPreview: KnowledgeBaseTextProcessor.preview(for: normalizedContent),
                    contentCharacterCount: normalizedContent.count,
                    status: status,
                    chunkCount: chunks.count,
                    createdAt: now,
                    updatedAt: now
                )
                try Self.insert(item, contentText: normalizedContent, into: db)
                for chunk in chunks {
                    try Self.insert(chunk, into: db)
                }
                try Self.touchBase(baseID, in: db, at: now)
                return item
            }
        }.value
        await reloadAfterMutation()
        return item
    }

    private func reloadAfterMutation() async {
        let result = await Self.loadSnapshot(database: database)
        isLoading = false
        switch result {
        case .success(let bases):
            knowledgeBases = bases
            lastErrorMessage = nil
        case .failure(let error):
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func loadSnapshot(database: KnowledgeBaseDatabase) async -> Result<[KnowledgeBase], Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<[KnowledgeBase], Error> in
            Result {
                try database.read { db in
                    try loadKnowledgeBases(in: db)
                }
            }
        }.value
    }

    private static func loadKnowledgeBases(in db: Database) throws -> [KnowledgeBase] {
        let baseRecords = try KnowledgeBaseRecord.fetchAll(
            db,
            sql: "SELECT * FROM knowledge_bases ORDER BY updated_at DESC, name COLLATE NOCASE ASC"
        )
        let itemRecords = try KnowledgeBaseItemRecord.fetchAll(
            db,
            sql: """
            SELECT
                id, base_id, kind, title, source_url, file_name, mime_type, byte_count,
                '' AS content_text,
                content_preview, content_character_count, status, error_message,
                chunk_count, created_at, updated_at
            FROM knowledge_base_items
            ORDER BY updated_at DESC, title COLLATE NOCASE ASC
            """
        )
        let items = itemRecords.map(Self.item(from:))
        let itemsByBaseID = Dictionary(grouping: items, by: \.baseID)

        return baseRecords.map { record in
            let baseID = UUID(uuidString: record.id) ?? UUID()
            let baseItems = itemsByBaseID[baseID] ?? []
            return KnowledgeBase(
                id: baseID,
                name: record.name,
                description: record.description,
                settings: KnowledgeBaseSettings(
                    embeddingModelIdentifier: record.embeddingModelIdentifier,
                    embeddingModelDisplayName: record.embeddingModelDisplayName,
                    chunkSize: record.chunkSize,
                    chunkOverlap: record.chunkOverlap,
                    retrievalDocumentCount: record.retrievalDocumentCount,
                    scoreThreshold: record.scoreThreshold
                ),
                items: baseItems,
                totalChunkCount: baseItems.reduce(0) { $0 + $1.chunkCount },
                createdAt: Date(timeIntervalSince1970: record.createdAt),
                updatedAt: Date(timeIntervalSince1970: record.updatedAt)
            )
        }
    }

    private struct KnowledgeBaseSearchCandidate {
        var baseID: UUID
        var baseName: String
        var itemID: UUID
        var itemTitle: String
        var itemKind: KnowledgeBaseSourceKind
        var chunkID: UUID
        var chunkIndex: Int
        var text: String
    }

    private static func searchCandidates(baseID: UUID?, in db: Database) throws -> [KnowledgeBaseSearchCandidate] {
        var sql = """
        SELECT
            c.id AS chunk_id,
            c.base_id AS base_id,
            c.item_id AS item_id,
            c.chunk_index AS chunk_index,
            c.text AS text,
            b.name AS base_name,
            i.title AS item_title,
            i.kind AS item_kind
        FROM knowledge_base_chunks c
        JOIN knowledge_base_items i ON i.id = c.item_id
        JOIN knowledge_bases b ON b.id = c.base_id
        WHERE i.status IN ('chunked', 'indexed')
        """
        let rows: [Row]
        if let baseID {
            sql += "\nAND c.base_id = ?"
            sql += "\nORDER BY b.updated_at DESC, i.updated_at DESC, c.chunk_index ASC"
            rows = try Row.fetchAll(db, sql: sql, arguments: [baseID.uuidString])
        } else {
            sql += "\nORDER BY b.updated_at DESC, i.updated_at DESC, c.chunk_index ASC"
            rows = try Row.fetchAll(db, sql: sql)
        }

        return rows.map { row in
            KnowledgeBaseSearchCandidate(
                baseID: UUID(uuidString: row["base_id"]) ?? UUID(),
                baseName: row["base_name"],
                itemID: UUID(uuidString: row["item_id"]) ?? UUID(),
                itemTitle: row["item_title"],
                itemKind: KnowledgeBaseSourceKind(rawValue: row["item_kind"]) ?? .note,
                chunkID: UUID(uuidString: row["chunk_id"]) ?? UUID(),
                chunkIndex: row["chunk_index"],
                text: row["text"]
            )
        }
    }

    private static func keywordScore(for text: String, tokens: [String]) -> Double {
        let normalizedText = KnowledgeBaseTextProcessor.normalizedSearchText(text)
        guard !normalizedText.isEmpty else { return 0 }

        var score = 0.0
        for token in tokens {
            let count = occurrenceCount(of: token, in: normalizedText)
            guard count > 0 else { return 0 }
            let tokenWeight = token.count >= 4 ? 1.5 : 1.0
            score += Double(count) * tokenWeight
        }

        let lengthPenalty = max(1.0, log(Double(normalizedText.count + 10)))
        return score / lengthPenalty
    }

    private static func occurrenceCount(of token: String, in text: String) -> Int {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func baseRecord(id: UUID, in db: Database) throws -> KnowledgeBaseRecord? {
        try KnowledgeBaseRecord.fetchOne(
            db,
            sql: "SELECT * FROM knowledge_bases WHERE id = ?",
            arguments: [id.uuidString]
        )
    }

    private static func insert(_ base: KnowledgeBase, into db: Database) throws {
        var record = KnowledgeBaseRecord(
            id: base.id.uuidString,
            name: base.name,
            description: base.description,
            embeddingModelIdentifier: base.settings.embeddingModelIdentifier,
            embeddingModelDisplayName: base.settings.embeddingModelDisplayName,
            chunkSize: base.settings.chunkSize,
            chunkOverlap: base.settings.chunkOverlap,
            retrievalDocumentCount: base.settings.retrievalDocumentCount,
            scoreThreshold: base.settings.scoreThreshold,
            createdAt: base.createdAt.timeIntervalSince1970,
            updatedAt: base.updatedAt.timeIntervalSince1970
        )
        try record.insert(db)
    }

    private static func insert(_ item: KnowledgeBaseSourceItem, contentText: String, into db: Database) throws {
        var record = KnowledgeBaseItemRecord(
            id: item.id.uuidString,
            baseID: item.baseID.uuidString,
            kind: item.kind.rawValue,
            title: item.title,
            sourceURL: item.sourceURL?.absoluteString,
            fileName: item.fileName,
            mimeType: item.mimeType,
            byteCount: item.byteCount,
            contentText: contentText,
            contentPreview: item.contentPreview,
            contentCharacterCount: item.contentCharacterCount,
            status: item.status.rawValue,
            errorMessage: item.errorMessage,
            chunkCount: item.chunkCount,
            createdAt: item.createdAt.timeIntervalSince1970,
            updatedAt: item.updatedAt.timeIntervalSince1970
        )
        try record.insert(db)
    }

    private static func insert(_ chunk: KnowledgeBaseChunk, into db: Database) throws {
        var record = KnowledgeBaseChunkRecord(
            id: chunk.id.uuidString,
            baseID: chunk.baseID.uuidString,
            itemID: chunk.itemID.uuidString,
            index: chunk.index,
            text: chunk.text,
            characterCount: chunk.characterCount,
            createdAt: chunk.createdAt.timeIntervalSince1970
        )
        try record.insert(db)
    }

    private static func touchBase(_ baseID: UUID, in db: Database, at date: Date = Date()) throws {
        try db.execute(
            sql: "UPDATE knowledge_bases SET updated_at = ? WHERE id = ?",
            arguments: [date.timeIntervalSince1970, baseID.uuidString]
        )
    }

    private static func item(from record: KnowledgeBaseItemRecord) -> KnowledgeBaseSourceItem {
        KnowledgeBaseSourceItem(
            id: UUID(uuidString: record.id) ?? UUID(),
            baseID: UUID(uuidString: record.baseID) ?? UUID(),
            kind: KnowledgeBaseSourceKind(rawValue: record.kind) ?? .note,
            title: record.title,
            sourceURL: record.sourceURL.flatMap(URL.init(string:)),
            fileName: record.fileName,
            mimeType: record.mimeType,
            byteCount: record.byteCount,
            contentPreview: record.contentPreview,
            contentCharacterCount: record.contentCharacterCount,
            status: KnowledgeBaseProcessingStatus(rawValue: record.status) ?? .pending,
            errorMessage: record.errorMessage,
            chunkCount: record.chunkCount,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt)
        )
    }

    private static func chunk(from record: KnowledgeBaseChunkRecord) -> KnowledgeBaseChunk {
        KnowledgeBaseChunk(
            id: UUID(uuidString: record.id) ?? UUID(),
            baseID: UUID(uuidString: record.baseID) ?? UUID(),
            itemID: UUID(uuidString: record.itemID) ?? UUID(),
            index: record.index,
            text: record.text,
            characterCount: record.characterCount,
            createdAt: Date(timeIntervalSince1970: record.createdAt)
        )
    }

    private func normalizedHTTPURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func emptyToNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum KnowledgeBaseURLImporter {
    public static func download(from url: URL) async throws -> KnowledgeBaseURLImportResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
        request.setValue("text/html, text/plain, application/json, application/xml, text/*;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KnowledgeBaseStoreError.unsupportedURLResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw KnowledgeBaseStoreError.downloadFailed(http.statusCode)
        }

        let mimeType = http.mimeType
        let decoded = decodeText(from: data, response: http)
        let text: String
        if mimeType?.localizedCaseInsensitiveContains("html") == true {
            text = KnowledgeBaseTextProcessor.plainTextFromHTML(decoded)
        } else {
            text = decoded
        }
        let normalized = KnowledgeBaseTextProcessor.normalize(text)
        guard !normalized.isEmpty else {
            throw KnowledgeBaseStoreError.emptyContent
        }
        return KnowledgeBaseURLImportResult(
            title: title(from: normalized, fallback: url.absoluteString),
            text: normalized,
            mimeType: mimeType,
            byteCount: data.count
        )
    }

    private static func decodeText(from data: Data, response: HTTPURLResponse) -> String {
        if let encodingName = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                    return text
                }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func title(from text: String, fallback: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let firstLine, !firstLine.isEmpty else {
            return fallback
        }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) : firstLine
    }
}
