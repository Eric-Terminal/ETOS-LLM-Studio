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
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT issue_number, ticket_token, category, title,
                       created_at, last_known_status, last_checked_at, last_known_updated_at,
                       public_url, moderation_blocked, moderation_message, archive_id,
                       submitted_title, submitted_detail, submitted_reproduction_steps,
                       submitted_expected_behavior, submitted_actual_behavior, submitted_extra_context,
                       last_known_comment_count, last_known_developer_comment_id, last_known_developer_comment_at
                FROM feedback_tickets
                ORDER BY COALESCE(last_checked_at, created_at) DESC, issue_number DESC
                """
            )

            return rows.map { row in
                let categoryRaw: String = row["category"]
                let statusRaw: String = row["last_known_status"]
                let publicURLString: String? = row["public_url"]
                let publicURL = publicURLString.flatMap(URL.init(string:))
                let moderationBlockedValue: Int? = row["moderation_blocked"]
                return FeedbackTicket(
                    issueNumber: row["issue_number"],
                    ticketToken: row["ticket_token"],
                    category: FeedbackCategory(rawValue: categoryRaw) ?? .bug,
                    title: row["title"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    lastKnownStatus: FeedbackTicketStatus(rawValue: statusRaw) ?? .inProgress,
                    lastCheckedAt: (row["last_checked_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    lastKnownUpdatedAt: (row["last_known_updated_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    publicURL: publicURL,
                    moderationBlocked: moderationBlockedValue.map { $0 != 0 },
                    moderationMessage: row["moderation_message"],
                    archiveID: row["archive_id"],
                    submittedTitle: row["submitted_title"],
                    submittedDetail: row["submitted_detail"],
                    submittedReproductionSteps: row["submitted_reproduction_steps"],
                    submittedExpectedBehavior: row["submitted_expected_behavior"],
                    submittedActualBehavior: row["submitted_actual_behavior"],
                    submittedExtraContext: row["submitted_extra_context"],
                    lastKnownCommentCount: row["last_known_comment_count"],
                    lastKnownDeveloperCommentID: row["last_known_developer_comment_id"],
                    lastKnownDeveloperCommentAt: (row["last_known_developer_comment_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
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
            try db.execute(sql: "DELETE FROM feedback_tickets")
            for ticket in tickets {
                try db.execute(
                    sql: """
                    INSERT INTO feedback_tickets (
                        issue_number, ticket_token, category, title,
                        created_at, last_known_status, last_checked_at, last_known_updated_at,
                        public_url, moderation_blocked, moderation_message, archive_id,
                        submitted_title, submitted_detail, submitted_reproduction_steps,
                        submitted_expected_behavior, submitted_actual_behavior, submitted_extra_context,
                        last_known_comment_count, last_known_developer_comment_id, last_known_developer_comment_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        ticket.issueNumber,
                        ticket.ticketToken,
                        ticket.category.rawValue,
                        ticket.title,
                        ticket.createdAt.timeIntervalSince1970,
                        ticket.lastKnownStatus.rawValue,
                        ticket.lastCheckedAt?.timeIntervalSince1970,
                        ticket.lastKnownUpdatedAt?.timeIntervalSince1970,
                        ticket.publicURL?.absoluteString,
                        ticket.moderationBlocked.map { $0 ? 1 : 0 },
                        ticket.moderationMessage,
                        ticket.archiveID,
                        ticket.submittedTitle,
                        ticket.submittedDetail,
                        ticket.submittedReproductionSteps,
                        ticket.submittedExpectedBehavior,
                        ticket.submittedActualBehavior,
                        ticket.submittedExtraContext,
                        ticket.lastKnownCommentCount,
                        ticket.lastKnownDeveloperCommentID,
                        ticket.lastKnownDeveloperCommentAt?.timeIntervalSince1970
                    ]
                )
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
}

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
