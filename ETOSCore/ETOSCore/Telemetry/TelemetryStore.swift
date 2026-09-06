// ============================================================================
// TelemetryStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 独立的性能遥测队列。所有文件操作都由 actor 串行执行，且只作用于专用目录。
// ============================================================================

import Foundation
import os.log

struct TelemetryStoredFile: Sendable {
    let url: URL
    let relativePath: String
    let envelope: TelemetryEnvelope
    let data: Data
    let rawJSON: String
    let fileSizeBytes: Int64

    func makeLogRecord(
        state: TelemetryLogDeliveryState,
        maxUploadFileBytes: Int64
    ) -> TelemetryLogRecord {
        let resolvedState: TelemetryLogDeliveryState =
            fileSizeBytes > maxUploadFileBytes ? .tooLarge : state
        return TelemetryLogRecord(
            envelope: envelope,
            rawJSON: rawJSON,
            fileSizeBytes: fileSizeBytes,
            deliveryState: resolvedState,
            relativePath: relativePath
        )
    }
}

struct TelemetryStoreSnapshot: Sendable {
    let files: [TelemetryStoredFile]
    let totalBytes: Int64
}

private struct TelemetryUploadState: Codable, Sendable {
    var lastAttemptAt: Date? = nil
    var lastSuccessAt: Date? = nil
    var lastError: String? = nil
}

actor TelemetryStore {
    static let defaultRetentionDays = 14
    static let defaultMaxTotalBytes: Int64 = 20 * 1_024 * 1_024
    // 为批次信封保留余量，确保单文件不会越过服务端 4 MiB 请求上限。
    static let defaultMaxUploadFileBytes: Int64 = 3 * 1_024 * 1_024

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "TelemetryStore")
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let pendingDirectory: URL
    private let stateDirectory: URL
    private let uploadStateURL: URL
    private let retentionDays: Int
    let maxTotalBytes: Int64
    let maxUploadFileBytes: Int64
    private var calendar: Calendar
    private let dayFormatter: DateFormatter

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        retentionDays: Int = defaultRetentionDays,
        maxTotalBytes: Int64 = defaultMaxTotalBytes,
        maxUploadFileBytes: Int64 = defaultMaxUploadFileBytes,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        let resolvedBase = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.baseDirectory = resolvedBase
        self.pendingDirectory = resolvedBase.appendingPathComponent("Pending", isDirectory: true)
        self.stateDirectory = resolvedBase.appendingPathComponent("State", isDirectory: true)
        self.uploadStateURL = stateDirectory.appendingPathComponent("upload-state.json", isDirectory: false)
        self.retentionDays = max(1, retentionDays)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxUploadFileBytes = max(1, maxUploadFileBytes)

        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        self.calendar = utcCalendar

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utcCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
    }

    func prepareLaunchSnapshot(now: Date = Date()) -> TelemetryStoreSnapshot {
        do {
            try ensureDirectories()
            try purgeExpiredAndOversizedFiles(now: now)
            return try loadSnapshot()
        } catch {
            logger.error("准备遥测启动快照失败: \(error.localizedDescription, privacy: .public)")
            return TelemetryStoreSnapshot(files: [], totalBytes: 0)
        }
    }

    @discardableResult
    func save(
        kind: TelemetryPayloadKind,
        rawPayloadData: Data,
        capturedAt: Date,
        periodStart: Date?,
        periodEnd: Date?,
        app: TelemetryAppMetadata,
        platform: TelemetryPlatformMetadata
    ) -> TelemetryStoredFile? {
        do {
            try ensureDirectories()
            let envelope = try TelemetryEnvelopeCodec.makeEnvelope(
                kind: kind,
                rawPayloadData: rawPayloadData,
                capturedAt: capturedAt,
                periodStart: periodStart,
                periodEnd: periodEnd,
                app: app,
                platform: platform
            )
            if let existing = try findFile(payloadID: envelope.payloadID) {
                return existing
            }

            let data = try TelemetryEnvelopeCodec.encode(envelope)
            let day = dayFormatter.string(from: capturedAt)
            let dayDirectory = pendingDirectory.appendingPathComponent(day, isDirectory: true)
            try ensureDirectory(dayDirectory)
            let fileURL = dayDirectory.appendingPathComponent(
                "\(kind.rawValue)_\(envelope.payloadID).json",
                isDirectory: false
            )
            guard isInsidePendingDirectory(fileURL) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }

            try data.write(to: fileURL, options: .atomic)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            #endif

            try purgeExpiredAndOversizedFiles(now: capturedAt)
            guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
            return makeStoredFile(url: fileURL, envelope: envelope, data: data)
        } catch {
            logger.error("保存 MetricKit 遥测失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func loadCurrentSnapshot(now: Date = Date()) -> TelemetryStoreSnapshot {
        do {
            try ensureDirectories()
            try purgeExpiredAndOversizedFiles(now: now)
            return try loadSnapshot()
        } catch {
            logger.error("读取待发送遥测失败: \(error.localizedDescription, privacy: .public)")
            return TelemetryStoreSnapshot(files: [], totalBytes: 0)
        }
    }

    func deleteConfirmed(payloadIDs: Set<String>) {
        guard !payloadIDs.isEmpty else { return }
        do {
            let files = try loadSnapshot().files
            for file in files where payloadIDs.contains(file.envelope.payloadID) {
                try removeValidatedFile(file.url)
            }
            try purgeEmptyDayDirectories()
        } catch {
            logger.error("删除已确认遥测失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearPending() {
        do {
            try ensureDirectories()
            for fileURL in try pendingFileURLs() {
                try removeValidatedFile(fileURL)
            }
            try purgeEmptyDayDirectories()
        } catch {
            logger.error("清除待发送遥测失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordUploadAttempt(error: String?, succeeded: Bool, at date: Date = Date()) {
        do {
            try ensureDirectories()
            var state = loadUploadState()
            state.lastAttemptAt = date
            state.lastError = error
            if succeeded {
                state.lastSuccessAt = date
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: uploadStateURL, options: .atomic)
        } catch {
            logger.error("写入遥测上传状态失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ETOS LLM Studio", isDirectory: true)
            .appendingPathComponent("Telemetry", isDirectory: true)
    }

    private func ensureDirectories() throws {
        guard isSafeBaseDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try ensureDirectory(pendingDirectory)
        try ensureDirectory(stateDirectory)
    }

    private var isSafeBaseDirectory: Bool {
        let path = baseDirectory.standardizedFileURL.path
        guard path != "/", !path.isEmpty else { return false }
        return pendingDirectory.standardizedFileURL.path.hasPrefix(path + "/") &&
            stateDirectory.standardizedFileURL.path.hasPrefix(path + "/")
    }

    private func ensureDirectory(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func loadSnapshot() throws -> TelemetryStoreSnapshot {
        var files: [TelemetryStoredFile] = []
        var totalBytes: Int64 = 0
        for fileURL in try pendingFileURLs() {
            do {
                guard let file = try loadStoredFile(at: fileURL) else {
                    removeInvalidFile(fileURL)
                    continue
                }
                files.append(file)
                totalBytes += file.fileSizeBytes
            } catch {
                removeInvalidFile(fileURL)
            }
        }

        files.sort {
            if $0.envelope.capturedAt == $1.envelope.capturedAt {
                return $0.relativePath < $1.relativePath
            }
            return $0.envelope.capturedAt < $1.envelope.capturedAt
        }
        return TelemetryStoreSnapshot(files: files, totalBytes: totalBytes)
    }

    private func findFile(payloadID: String) throws -> TelemetryStoredFile? {
        for fileURL in try pendingFileURLs() where fileURL.lastPathComponent.contains(payloadID) {
            do {
                guard let file = try loadStoredFile(at: fileURL) else {
                    removeInvalidFile(fileURL)
                    continue
                }
                guard file.envelope.payloadID == payloadID else { continue }
                return file
            } catch {
                removeInvalidFile(fileURL)
            }
        }
        return nil
    }

    private func loadStoredFile(at fileURL: URL) throws -> TelemetryStoredFile? {
        let data = try Data(contentsOf: fileURL)
        let envelope = try TelemetryEnvelopeCodec.decode(data)
        guard TelemetryEnvelope.supportedSchemaVersions.contains(envelope.schemaVersion),
              envelope.privacy.isSafeForUpload,
              fileURL.lastPathComponent.contains(envelope.payloadID) else {
            return nil
        }
        return makeStoredFile(url: fileURL, envelope: envelope, data: data)
    }

    private func removeInvalidFile(_ fileURL: URL) {
        logger.warning("删除无效遥测文件: \(fileURL.lastPathComponent, privacy: .public)")
        do {
            try removeValidatedFile(fileURL)
        } catch {
            logger.error(
                "删除无效遥测文件失败: \(fileURL.lastPathComponent, privacy: .public)"
            )
        }
    }

    private func makeStoredFile(
        url: URL,
        envelope: TelemetryEnvelope,
        data: Data
    ) -> TelemetryStoredFile {
        let relativePath = relativePath(for: url) ?? url.lastPathComponent
        return TelemetryStoredFile(
            url: url,
            relativePath: relativePath,
            envelope: envelope,
            data: data,
            rawJSON: String(decoding: data, as: UTF8.self),
            fileSizeBytes: Int64(data.count)
        )
    }

    private func pendingFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: pendingDirectory.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  isInsidePendingDirectory(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private func purgeExpiredAndOversizedFiles(now: Date) throws {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -retentionDays,
            to: now
        ) ?? now.addingTimeInterval(-Double(retentionDays) * 86_400)

        var snapshot = try loadSnapshot()
        for file in snapshot.files where file.envelope.capturedAt < cutoff {
            try removeValidatedFile(file.url)
        }

        snapshot = try loadSnapshot()
        guard snapshot.totalBytes > maxTotalBytes else {
            try purgeEmptyDayDirectories()
            return
        }

        var remainingBytes = snapshot.totalBytes
        let metrics = snapshot.files
            .filter { $0.envelope.kind == .metric }
            .sorted { $0.envelope.capturedAt < $1.envelope.capturedAt }
        let diagnostics = snapshot.files
            .filter { $0.envelope.kind == .diagnostic }
            .sorted { $0.envelope.capturedAt < $1.envelope.capturedAt }

        for file in metrics + diagnostics where remainingBytes > maxTotalBytes {
            try removeValidatedFile(file.url)
            remainingBytes -= file.fileSizeBytes
        }
        try purgeEmptyDayDirectories()
    }

    private func removeValidatedFile(_ url: URL) throws {
        guard url.pathExtension == "json",
              isInsidePendingDirectory(url),
              fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func purgeEmptyDayDirectories() throws {
        guard fileManager.fileExists(atPath: pendingDirectory.path) else { return }
        let directories = try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            guard isInsidePendingDirectory(directory),
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if contents.isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private func relativePath(for url: URL) -> String? {
        guard isInsidePendingDirectory(url) else { return nil }
        let basePath = pendingDirectory.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(basePath.count))
    }

    private func isInsidePendingDirectory(_ url: URL) -> Bool {
        let basePath = pendingDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath.hasPrefix(basePath + "/")
    }

    private func loadUploadState() -> TelemetryUploadState {
        guard let data = try? Data(contentsOf: uploadStateURL) else {
            return TelemetryUploadState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TelemetryUploadState.self, from: data)) ?? TelemetryUploadState()
    }
}
