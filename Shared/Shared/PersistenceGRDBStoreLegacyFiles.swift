// ============================================================================
// PersistenceGRDBStoreLegacyFiles.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 迁移旧 JSON 数据时的文件扫描、读取与清理。
// ============================================================================

import Foundation
import os.log

extension PersistenceGRDBStore {
    func loadLegacySessionSnapshot(from plan: LegacySessionImportPlan) throws -> LegacySessionSnapshot {
        if let recordURL = plan.sessionRecordURL,
           let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: recordURL) {
            let session = ChatSession(
                id: record.session.id,
                name: record.session.name.isEmpty ? plan.fallbackSession.name : record.session.name,
                topicPrompt: record.prompts.topicPrompt,
                enhancedPrompt: record.prompts.enhancedPrompt,
                lorebookIDs: record.session.lorebookIDs,
                worldbookContextIsolationEnabled: record.session.worldbookContextIsolationEnabled ?? false,
                folderID: record.session.folderID,
                isTemporary: false
            )
            let summary = record.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSummary = (summary?.isEmpty == false) ? summary : nil
            let summaryUpdatedAt = parseISO8601Date(record.session.conversationSummaryUpdatedAt)
            return LegacySessionSnapshot(
                session: session,
                messages: normalizeToolCallsPlacement(in: record.messages),
                sortIndex: plan.sortIndex,
                updatedAt: plan.fallbackUpdatedAt,
                conversationSummary: normalizedSummary,
                conversationSummaryUpdatedAt: summaryUpdatedAt
            )
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL == nil {
            logger.error("旧版会话文件解析失败，且没有可回退的消息文件: \(recordURL.path, privacy: .public)")
            throw LegacyIncrementalImportError.malformedSessionRecord(sessionID: plan.id, path: recordURL.path)
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL != nil {
            logger.warning("旧版会话文件解析失败，将回退到旧版消息文件: \(recordURL.path, privacy: .public)")
        }

        let messages = try readLegacyMessagesFromURL(plan.legacyMessagesURL, sessionID: plan.id)
        return LegacySessionSnapshot(
            session: plan.fallbackSession,
            messages: messages,
            sortIndex: plan.sortIndex,
            updatedAt: plan.fallbackUpdatedAt,
            conversationSummary: nil,
            conversationSummaryUpdatedAt: nil
        )
    }

    func buildLegacyImportPlan() -> LegacyImportPlan {
        let sessionPlans = buildLegacySessionImportPlans()
        let sessionIDsForCleanup = sessionPlans.map(\.id)
        let candidateSet = Set(
            legacyJSONArtifactURLs(sessionIDs: sessionIDsForCleanup)
            + legacyRootMessageJSONFiles()
            + sessionPlans.compactMap(\.sessionRecordURL)
            + sessionPlans.compactMap(\.legacyMessagesURL)
        )
        let existingCandidates = candidateSet.filter { FileManager.default.fileExists(atPath: $0.path) }
        let estimatedBytes = existingCandidates.reduce(into: Int64(0)) { partialResult, url in
            partialResult += fileSize(at: url)
        }
        return LegacyImportPlan(
            sessionPlans: sessionPlans,
            sessionIDsForCleanup: sessionIDsForCleanup,
            estimatedBytes: estimatedBytes,
            candidateURLs: Array(existingCandidates)
        )
    }

    func buildLegacySessionImportPlans() -> [LegacySessionImportPlan] {
        if let index: LegacySessionIndexFile = decodeFile(
            LegacySessionIndexFile.self,
            at: chatsDirectory.appendingPathComponent("index.json")
        ) {
            let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
            return index.sessions.enumerated().map { position, item in
                let recordURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()
                let estimatedBytes = fileSize(at: recordURL) + fileSize(at: legacyMessagesURL)
                return LegacySessionImportPlan(
                    id: item.id,
                    fallbackSession: fallbackSession,
                    sortIndex: position,
                    fallbackUpdatedAt: fallbackUpdatedAt,
                    sessionRecordURL: FileManager.default.fileExists(atPath: recordURL.path) ? recordURL : nil,
                    legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                    estimatedBytes: estimatedBytes
                )
            }
        }

        if let sessions: [ChatSession] = decodeFile(
            [ChatSession].self,
            at: chatsDirectory.appendingPathComponent("sessions.json")
        ) {
            return sessions
                .filter { !$0.isTemporary }
                .enumerated()
                .map { position, session in
                    let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(session.id.uuidString).json")
                    return LegacySessionImportPlan(
                        id: session.id,
                        fallbackSession: session,
                        sortIndex: position,
                        fallbackUpdatedAt: Date(),
                        sessionRecordURL: nil,
                        legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                        estimatedBytes: fileSize(at: legacyMessagesURL)
                    )
                }
        }

        let orphanMessageFiles = legacyRootMessageJSONFiles()
        return orphanMessageFiles.enumerated().compactMap { position, url in
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let sessionID = UUID(uuidString: baseName) else { return nil }
            let fallbackSession = ChatSession(id: sessionID, name: "历史会话", isTemporary: false)
            return LegacySessionImportPlan(
                id: sessionID,
                fallbackSession: fallbackSession,
                sortIndex: position,
                fallbackUpdatedAt: Date(),
                sessionRecordURL: nil,
                legacyMessagesURL: url,
                estimatedBytes: fileSize(at: url)
            )
        }
    }

    func readLegacyMessagesFromURL(_ url: URL?, sessionID: UUID) throws -> [ChatMessage] {
        guard let url else { return [] }
        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: url) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: url) {
            return normalizeToolCallsPlacement(in: messages)
        }
        logger.error("旧版消息文件解析失败: \(url.path, privacy: .public)")
        throw LegacyIncrementalImportError.malformedMessagesFile(sessionID: sessionID, path: url.path)
    }

    func fileSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let rawSize = attributes[.size] as? NSNumber else {
            return 0
        }
        return rawSize.int64Value
    }

    func hasLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    func removeLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        var failedPaths: [String] = []

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failedPaths.append(url.path)
                logger.warning("清理旧 JSON 文件失败: \(url.path) - \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("RequestLogs"))
        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("DailyPulse"))

        if !failedPaths.isEmpty {
            return false
        }
        return !hasLegacyJSONArtifacts(sessionIDs: sessionIDs)
    }

    func legacyJSONArtifactURLs(sessionIDs: [UUID]) -> [URL] {
        var urls: [URL] = [
            chatsDirectory.appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("sessions"),
            chatsDirectory.appendingPathComponent("sessions.json"),
            chatsDirectory.appendingPathComponent("folders.json"),
            chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json"),
            chatsDirectory.appendingPathComponent("v3"),
            chatsDirectory.appendingPathComponent("legacy")
        ]

        urls.append(contentsOf: sessionIDs.map { chatsDirectory.appendingPathComponent("\($0.uuidString).json") })
        return urls
    }

    func legacyRootMessageJSONFiles() -> [URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            return UUID(uuidString: name) != nil
        }
    }

    func hasUnindexedLegacySessionArtifacts() -> Bool {
        if !legacyRootMessageJSONFiles().isEmpty {
            return true
        }

        let fileManager = FileManager.default
        let candidateDirectories = [
            chatsDirectory.appendingPathComponent("sessions", isDirectory: true),
            chatsDirectory.appendingPathComponent("v3", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        ]

        for directoryURL in candidateDirectories {
            guard fileManager.fileExists(atPath: directoryURL.path),
                  let fileURLs = try? fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            if fileURLs.contains(where: { $0.pathExtension.lowercased() == "json" }) {
                return true
            }
        }

        return false
    }

    func removeDirectoryIfEmpty(_ directoryURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        guard let children = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        guard children.isEmpty else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    func readCurrentLayoutSessions() -> [LegacySessionSnapshot]? {
        let indexURL = chatsDirectory.appendingPathComponent("index.json")
        guard let index: LegacySessionIndexFile = decodeFile(LegacySessionIndexFile.self, at: indexURL) else {
            return nil
        }

        let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
        var snapshots: [LegacySessionSnapshot] = []
        snapshots.reserveCapacity(index.sessions.count)

        for (indexPosition, item) in index.sessions.enumerated() {
            let sessionFileURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
            let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()

            if let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: sessionFileURL) {
                let session = ChatSession(
                    id: record.session.id,
                    name: record.session.name.isEmpty ? item.name : record.session.name,
                    topicPrompt: record.prompts.topicPrompt,
                    enhancedPrompt: record.prompts.enhancedPrompt,
                    lorebookIDs: record.session.lorebookIDs,
                    worldbookContextIsolationEnabled: record.session.worldbookContextIsolationEnabled ?? false,
                    folderID: record.session.folderID,
                    isTemporary: false
                )

                let summary = record.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedSummary = (summary?.isEmpty == false) ? summary : nil
                let summaryUpdatedAt = parseISO8601Date(record.session.conversationSummaryUpdatedAt)

                snapshots.append(
                    LegacySessionSnapshot(
                        session: session,
                        messages: normalizeToolCallsPlacement(in: record.messages),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: normalizedSummary,
                        conversationSummaryUpdatedAt: summaryUpdatedAt
                    )
                )
            } else {
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                snapshots.append(
                    LegacySessionSnapshot(
                        session: fallbackSession,
                        messages: readLegacyMessages(for: item.id),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: nil,
                        conversationSummaryUpdatedAt: nil
                    )
                )
            }
        }

        return snapshots
    }

    func readLegacyLayoutSessions() -> [LegacySessionSnapshot] {
        let legacySessionsURL = chatsDirectory.appendingPathComponent("sessions.json")
        guard let sessions: [ChatSession] = decodeFile([ChatSession].self, at: legacySessionsURL) else {
            return []
        }

        let normalizedSessions = sessions.filter { !$0.isTemporary }
        return normalizedSessions.enumerated().map { index, session in
            LegacySessionSnapshot(
                session: session,
                messages: readLegacyMessages(for: session.id),
                sortIndex: index,
                updatedAt: Date(),
                conversationSummary: nil,
                conversationSummaryUpdatedAt: nil
            )
        }
    }

    func readLegacyMessages(for sessionID: UUID) -> [ChatMessage] {
        let legacyURL = chatsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return []
        }

        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: messages)
        }
        return []
    }

    func readSessionFolders() -> [SessionFolder] {
        let url = chatsDirectory.appendingPathComponent("folders.json")
        if let envelope: SessionFoldersFileEnvelope = decodeFile(SessionFoldersFileEnvelope.self, at: url) {
            return normalizeSessionFoldersForPersistence(envelope.folders)
        }
        return []
    }

    func readRequestLogs() -> [RequestLogEntry] {
        let url = chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json")
        if let envelope: RequestLogFileEnvelope = decodeFile(RequestLogFileEnvelope.self, at: url) {
            return envelope.logs
        }
        return []
    }

    func readDailyPulseRuns() -> [DailyPulseRun] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json")
        return decodeFile([DailyPulseRun].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json")
        return decodeFile([DailyPulseFeedbackEvent].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json")
        return decodeFile(DailyPulseCurationNote.self, at: url, decoder: makeISO8601Decoder())
    }

    func readDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json")
        return decodeFile([DailyPulseExternalSignal].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulseTasks() -> [DailyPulseTask] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json")
        return decodeFile([DailyPulseTask].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }
}
