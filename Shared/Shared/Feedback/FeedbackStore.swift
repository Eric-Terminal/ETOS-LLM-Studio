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
import os.log

private let feedbackStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "FeedbackStore")

public extension Notification.Name {
    static let feedbackTicketsUpdated = Notification.Name("com.ETOS.feedback.tickets.updated")
}

public enum FeedbackStore {
    private static let lock = NSLock()
    private static let fileName = "tickets.json"

    private static var directoryURL: URL {
        StorageUtility.documentsDirectory.appendingPathComponent("FeedbackTickets")
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    public static func loadTickets() -> [FeedbackTicket] {
        lock.withLock {
            do {
                try ensureDirectoryExists()
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return []
                }

                let data = try Data(contentsOf: fileURL)
                let decoder = FeedbackDateCodec.makeJSONDecoder()
                let tickets = try decoder.decode([FeedbackTicket].self, from: data)
                return sortTickets(tickets)
            } catch {
                feedbackStoreLogger.error("读取反馈工单失败: \(error.localizedDescription)")
                return []
            }
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
        do {
            try ensureDirectoryExists()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = FeedbackDateCodec.makeJSONDecoder()
            let tickets = try decoder.decode([FeedbackTicket].self, from: data)
            return sortTickets(tickets)
        } catch {
            feedbackStoreLogger.error("读取反馈工单失败: \(error.localizedDescription)")
            return []
        }
    }

    private static func writeTicketsWithoutLock(_ tickets: [FeedbackTicket]) {
        do {
            try ensureDirectoryExists()
            let encoder = FeedbackDateCodec.makeJSONEncoder()
            let data = try encoder.encode(tickets)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            feedbackStoreLogger.error("保存反馈工单失败: \(error.localizedDescription)")
        }
    }

    private static func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
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
