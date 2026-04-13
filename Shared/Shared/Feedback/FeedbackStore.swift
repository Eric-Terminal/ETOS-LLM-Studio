// ============================================================================
// FeedbackStore.swift
// ============================================================================
// ETOS LLM Studio 反馈工单本地存储
//
// 定义内容:
// - 反馈工单读取、写入与合并
// - 与同步模块共享同一数据源
// ============================================================================

import Foundation
import GRDB
import os.log

private let feedbackStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "FeedbackStore")

public extension Notification.Name {
    static let feedbackTicketsUpdated = Notification.Name("com.ETOS.feedback.tickets.updated")
}

public enum FeedbackStore {
    private static let lock = NSLock()
    private static let fileName = "tickets.json"
    private static let grdbBlobKey = "feedback_tickets"
    private static let legacyGrdbBlobKey = "feedback_tickets_v1"
    private static let legacyBlobKeys = [grdbBlobKey, legacyGrdbBlobKey]

    private static var directoryURL: URL {
        StorageUtility.documentsDirectory.appendingPathComponent("FeedbackTickets")
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    public static func loadTickets() -> [FeedbackTicket] {
        lock.withLock {
            loadTicketsWithoutLock()
        }
    }

    public static func saveTickets(_ tickets: [FeedbackTicket]) {
        lock.withLock {
            writeTicketsWithoutLock(sortTickets(deduplicateByIssueNumber(tickets)))
        }

        NotificationCenter.default.post(name: .feedbackTicketsUpdated, object: nil)
    }

    public static func upsertTicket(_ ticket: FeedbackTicket) {
        lock.withLock {
            var current = loadTicketsWithoutLock()
            if let index = current.firstIndex(where: { $0.issueNumber == ticket.issueNumber }) {
                current[index] = ticket
            } else {
                current.insert(ticket, at: 0)
            }
            writeTicketsWithoutLock(sortTickets(deduplicateByIssueNumber(current)))
        }

        NotificationCenter.default.post(name: .feedbackTicketsUpdated, object: nil)
    }

    public static func deleteTicket(issueNumber: Int) {
        lock.withLock {
            var current = loadTicketsWithoutLock()
            current.removeAll { $0.issueNumber == issueNumber }
            writeTicketsWithoutLock(sortTickets(current))
        }

        NotificationCenter.default.post(name: .feedbackTicketsUpdated, object: nil)
    }

    @discardableResult
    public static func mergeTickets(_ incoming: [FeedbackTicket]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        let result: (Int, Int) = lock.withLock {
            var current = loadTicketsWithoutLock()
            var imported = 0
            var skipped = 0

            for incomingTicket in incoming {
                if let index = current.firstIndex(where: { $0.issueNumber == incomingTicket.issueNumber }) {
                    let existing = current[index]
                    if shouldReplace(existing: existing, with: incomingTicket) {
                        current[index] = incomingTicket
                        imported += 1
                    } else {
                        skipped += 1
                    }
                } else {
                    current.append(incomingTicket)
                    imported += 1
                }
            }

            writeTicketsWithoutLock(sortTickets(deduplicateByIssueNumber(current)))
            return (imported, skipped)
        }

        if result.0 > 0 {
            NotificationCenter.default.post(name: .feedbackTicketsUpdated, object: nil)
        }

        return result
    }

    // MARK: - 私有实现

    private static func loadTicketsWithoutLock() -> [FeedbackTicket] {
        if let tickets = loadTicketsFromSQLite() {
            return sortTickets(tickets)
        }

        do {
            try ensureDirectoryExists()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = FeedbackDateCodec.makeJSONDecoder()
            let tickets = try decoder.decode([FeedbackTicket].self, from: data)
            if saveTicketsToSQLite(tickets) {
                cleanupLegacyFileArtifactsWithoutLock()
            }
            return sortTickets(tickets)
        } catch {
            feedbackStoreLogger.error("读取反馈工单失败: \(error.localizedDescription)")
            return []
        }
    }

    private static func writeTicketsWithoutLock(_ tickets: [FeedbackTicket]) {
        if saveTicketsToSQLite(tickets) {
            cleanupLegacyFileArtifactsWithoutLock()
            return
        }

        do {
            try ensureDirectoryExists()
            let encoder = FeedbackDateCodec.makeJSONEncoder()
            let data = try encoder.encode(tickets)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            feedbackStoreLogger.error("保存反馈工单失败: \(error.localizedDescription)")
        }
    }

    private static func loadTicketsFromSQLite() -> [FeedbackTicket]? {
        guard let tickets = Persistence.withConfigDatabaseRead({ db in
            let rows = try RelationalFeedbackTicketRecord.fetchAll(db)
            return rows.map { row in
                FeedbackTicket(
                    issueNumber: row.issueNumber,
                    ticketToken: row.ticketToken,
                    category: FeedbackCategory(rawValue: row.category) ?? .bug,
                    title: row.title,
                    createdAt: Date(timeIntervalSince1970: row.createdAt),
                    lastKnownStatus: FeedbackTicketStatus(rawValue: row.lastKnownStatus) ?? .inProgress,
                    lastCheckedAt: row.lastCheckedAt.map(Date.init(timeIntervalSince1970:)),
                    lastKnownUpdatedAt: row.lastKnownUpdatedAt.map(Date.init(timeIntervalSince1970:)),
                    publicURL: row.publicURL.flatMap(URL.init(string:)),
                    moderationBlocked: row.moderationBlocked.map { $0 != 0 },
                    moderationMessage: row.moderationMessage,
                    archiveID: row.archiveID,
                    submittedTitle: row.submittedTitle,
                    submittedDetail: row.submittedDetail,
                    submittedReproductionSteps: row.submittedReproductionSteps,
                    submittedExpectedBehavior: row.submittedExpectedBehavior,
                    submittedActualBehavior: row.submittedActualBehavior,
                    submittedExtraContext: row.submittedExtraContext,
                    lastKnownCommentCount: row.lastKnownCommentCount,
                    lastKnownDeveloperCommentID: row.lastKnownDeveloperCommentID,
                    lastKnownDeveloperCommentAt: row.lastKnownDeveloperCommentAt.map(Date.init(timeIntervalSince1970:))
                )
            }.sorted { lhs, rhs in
                let lhsDate = lhs.lastCheckedAt ?? lhs.createdAt
                let rhsDate = rhs.lastCheckedAt ?? rhs.createdAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.issueNumber > rhs.issueNumber
            }
        }) else {
            return nil
        }

        if tickets.isEmpty,
           let legacy = loadLegacyTicketsFromBlob(),
           !legacy.isEmpty {
            if saveTicketsToSQLite(legacy) {
                removeLegacyTicketBlobs()
            }
            return legacy
        }
        return tickets
    }

    @discardableResult
    private static func saveTicketsToSQLite(_ tickets: [FeedbackTicket]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try RelationalFeedbackTicketRecord.deleteAll(db)
            for ticket in tickets {
                var record = RelationalFeedbackTicketRecord(
                    issueNumber: ticket.issueNumber,
                    ticketToken: ticket.ticketToken,
                    category: ticket.category.rawValue,
                    title: ticket.title,
                    createdAt: ticket.createdAt.timeIntervalSince1970,
                    lastKnownStatus: ticket.lastKnownStatus.rawValue,
                    lastCheckedAt: ticket.lastCheckedAt?.timeIntervalSince1970,
                    lastKnownUpdatedAt: ticket.lastKnownUpdatedAt?.timeIntervalSince1970,
                    publicURL: ticket.publicURL?.absoluteString,
                    moderationBlocked: ticket.moderationBlocked.map { $0 ? 1 : 0 },
                    moderationMessage: ticket.moderationMessage,
                    archiveID: ticket.archiveID,
                    submittedTitle: ticket.submittedTitle,
                    submittedDetail: ticket.submittedDetail,
                    submittedReproductionSteps: ticket.submittedReproductionSteps,
                    submittedExpectedBehavior: ticket.submittedExpectedBehavior,
                    submittedActualBehavior: ticket.submittedActualBehavior,
                    submittedExtraContext: ticket.submittedExtraContext,
                    lastKnownCommentCount: ticket.lastKnownCommentCount,
                    lastKnownDeveloperCommentID: ticket.lastKnownDeveloperCommentID,
                    lastKnownDeveloperCommentAt: ticket.lastKnownDeveloperCommentAt?.timeIntervalSince1970
                )
                try record.insert(db)
            }
            return true
        } ?? false

        if didSave {
            removeLegacyTicketBlobs()
        }
        return didSave
    }

    private static func loadLegacyTicketsFromBlob() -> [FeedbackTicket]? {
        for key in legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([FeedbackTicket].self, forKey: key) ?? []
        }
        return nil
    }

    private static func removeLegacyTicketBlobs() {
        for key in legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    private static func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func cleanupLegacyFileArtifactsWithoutLock() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
        if fm.fileExists(atPath: directoryURL.path),
           let items = try? fm.contentsOfDirectory(atPath: directoryURL.path),
           items.isEmpty {
            try? fm.removeItem(at: directoryURL)
        }
    }

    private static func deduplicateByIssueNumber(_ tickets: [FeedbackTicket]) -> [FeedbackTicket] {
        var merged: [Int: FeedbackTicket] = [:]
        for ticket in tickets {
            if let existing = merged[ticket.issueNumber] {
                merged[ticket.issueNumber] = shouldReplace(existing: existing, with: ticket) ? ticket : existing
            } else {
                merged[ticket.issueNumber] = ticket
            }
        }
        return Array(merged.values)
    }

    private static func shouldReplace(existing: FeedbackTicket, with incoming: FeedbackTicket) -> Bool {
        let incomingCheck = incoming.lastCheckedAt ?? incoming.createdAt
        let existingCheck = existing.lastCheckedAt ?? existing.createdAt
        return incomingCheck >= existingCheck
    }

    private static func sortTickets(_ tickets: [FeedbackTicket]) -> [FeedbackTicket] {
        tickets.sorted { lhs, rhs in
            let lhsDate = lhs.lastCheckedAt ?? lhs.createdAt
            let rhsDate = rhs.lastCheckedAt ?? rhs.createdAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.issueNumber > rhs.issueNumber
        }
    }

    // MARK: - GRDB 关系模型

    private struct RelationalFeedbackTicketRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "feedback_tickets"

        enum CodingKeys: String, CodingKey {
            case issueNumber = "issue_number"
            case ticketToken = "ticket_token"
            case category
            case title
            case createdAt = "created_at"
            case lastKnownStatus = "last_known_status"
            case lastCheckedAt = "last_checked_at"
            case lastKnownUpdatedAt = "last_known_updated_at"
            case publicURL = "public_url"
            case moderationBlocked = "moderation_blocked"
            case moderationMessage = "moderation_message"
            case archiveID = "archive_id"
            case submittedTitle = "submitted_title"
            case submittedDetail = "submitted_detail"
            case submittedReproductionSteps = "submitted_reproduction_steps"
            case submittedExpectedBehavior = "submitted_expected_behavior"
            case submittedActualBehavior = "submitted_actual_behavior"
            case submittedExtraContext = "submitted_extra_context"
            case lastKnownCommentCount = "last_known_comment_count"
            case lastKnownDeveloperCommentID = "last_known_developer_comment_id"
            case lastKnownDeveloperCommentAt = "last_known_developer_comment_at"
        }

        var issueNumber: Int
        var ticketToken: String
        var category: String
        var title: String
        var createdAt: Double
        var lastKnownStatus: String
        var lastCheckedAt: Double?
        var lastKnownUpdatedAt: Double?
        var publicURL: String?
        var moderationBlocked: Int?
        var moderationMessage: String?
        var archiveID: String?
        var submittedTitle: String?
        var submittedDetail: String?
        var submittedReproductionSteps: String?
        var submittedExpectedBehavior: String?
        var submittedActualBehavior: String?
        var submittedExtraContext: String?
        var lastKnownCommentCount: Int?
        var lastKnownDeveloperCommentID: String?
        var lastKnownDeveloperCommentAt: Double?
    }
}

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
