// ============================================================================
// PersistenceStoreFileIO.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 会话索引、会话记录与请求日志文件的底层读写辅助。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    static func loadRequestLogEnvelope() throws -> RequestLogFileEnvelope? {
        let fileURL = requestLogsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RequestLogFileEnvelope.self, from: data)
    }

    static func writeRequestLogEnvelope(_ envelope: RequestLogFileEnvelope) throws {
        let fileURL = requestLogsFileURL()
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

    static func loadSessionIndexFile() -> SessionIndexFilePayload? {
        let fileURL = sessionIndexFileURLCurrent()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SessionIndexFilePayload.self, from: data)
        } catch {
            logger.warning("读取会话索引文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func writeSessionIndexFile(_ index: SessionIndexFilePayload) throws {
        let url = sessionIndexFileURLCurrent()
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    static func loadSessionSummaryFile(for sessionID: UUID) throws -> SessionRecordSummaryPayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordSummaryPayload.self, from: data)
    }

    static func loadSessionRecordFile(for sessionID: UUID) throws -> SessionRecordFilePayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordFilePayload.self, from: data)
    }

    static func writeSessionRecordFile(_ record: SessionRecordFilePayload, for sessionID: UUID) throws {
        let url = sessionRecordFileURL(for: sessionID)
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    static func removeLegacySourceFiles(sessions: [ChatSession]) throws {
        let legacyIndexURL = legacySessionIndexFileURL()
        let legacyMessageURLs = sessions.map { legacyMessagesFileURL(for: $0.id) }

        try removeItemIfExists(at: legacyIndexURL)
        for sourceURL in legacyMessageURLs {
            try removeItemIfExists(at: sourceURL)
        }

        logger.info("\(migrationLogPrefix) 旧版会话索引与消息文件已清理。")
    }
}
