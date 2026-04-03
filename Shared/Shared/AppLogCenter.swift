// ============================================================================
// AppLogCenter.swift
// ============================================================================
// ETOS LLM Studio 统一日志中心
//
// 功能特性:
// - 双通道日志（开发者 / 用户）
// - 用户通道自动脱敏，避免记录敏感聊天字段
// - 统一日志视图 + 按日期文件夹/单次运行文件持久化
// ============================================================================

import Foundation
import Combine
import os.log

public enum AppLogChannel: String, Codable, CaseIterable, Sendable {
    case developer
    case user

    public var displayName: String {
        switch self {
        case .developer:
            return NSLocalizedString("开发者日志", comment: "Developer log channel")
        case .user:
            return NSLocalizedString("用户操作日志", comment: "User operation log channel")
        }
    }
}

public enum AppLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error

    public var displayName: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }
}

public struct AppLogEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let channel: AppLogChannel
    public let level: AppLogLevel
    public let category: String
    public let action: String
    public let message: String
    public let payload: [String: String]?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        channel: AppLogChannel,
        level: AppLogLevel,
        category: String,
        action: String,
        message: String,
        payload: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.level = level
        self.category = category
        self.action = action
        self.message = message
        self.payload = payload
    }
}

public struct AppLogRunFile: Identifiable, Hashable, Sendable {
    public let relativePath: String
    public let day: String
    public let fileName: String
    public let createdAt: Date
    public let updatedAt: Date
    public let firstEventAt: Date?
    public let lastEventAt: Date?
    public let totalEventCount: Int
    public let developerEventCount: Int
    public let userEventCount: Int
    public let fileSizeBytes: Int64

    public init(
        relativePath: String,
        day: String,
        fileName: String,
        createdAt: Date,
        updatedAt: Date,
        firstEventAt: Date?,
        lastEventAt: Date?,
        totalEventCount: Int,
        developerEventCount: Int,
        userEventCount: Int,
        fileSizeBytes: Int64
    ) {
        self.relativePath = relativePath
        self.day = day
        self.fileName = fileName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.totalEventCount = totalEventCount
        self.developerEventCount = developerEventCount
        self.userEventCount = userEventCount
        self.fileSizeBytes = fileSizeBytes
    }

    public var id: String { relativePath }
}

public struct AppLogDayFolder: Identifiable, Hashable, Sendable {
    public let day: String
    public let runs: [AppLogRunFile]

    public init(day: String, runs: [AppLogRunFile]) {
        self.day = day
        self.runs = runs
    }

    public var id: String { day }

    public var totalEventCount: Int {
        runs.reduce(0) { partialResult, run in
            partialResult + run.totalEventCount
        }
    }
}

/// 应用日志筛选条件。
public struct AppLogFilter: Sendable, Equatable {
    public var level: AppLogLevel?
    public var keyword: String
    public var categoryKeyword: String
    public var configChangesOnly: Bool

    public init(
        level: AppLogLevel? = nil,
        keyword: String = "",
        categoryKeyword: String = "",
        configChangesOnly: Bool = false
    ) {
        self.level = level
        self.keyword = keyword
        self.categoryKeyword = categoryKeyword
        self.configChangesOnly = configChangesOnly
    }
}

/// 日志筛选执行器。
public enum AppLogFilterEngine {
    public static func filter(_ events: [AppLogEvent], with filter: AppLogFilter) -> [AppLogEvent] {
        let normalizedKeyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCategoryKeyword = filter.categoryKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return events.filter { event in
            if let level = filter.level, event.level != level {
                return false
            }

            if !normalizedCategoryKeyword.isEmpty {
                let category = event.category.lowercased()
                if !category.contains(normalizedCategoryKeyword) {
                    return false
                }
            }

            if filter.configChangesOnly, !isConfigChangeEvent(event) {
                return false
            }

            if normalizedKeyword.isEmpty {
                return true
            }

            let searchableParts = searchableParts(for: event)
            return searchableParts.contains { part in
                part.lowercased().contains(normalizedKeyword)
            }
        }
    }

    private static func searchableParts(for event: AppLogEvent) -> [String] {
        var parts: [String] = [event.category, event.action, event.message]
        if let payload = event.payload, !payload.isEmpty {
            for (key, value) in payload {
                parts.append(key)
                parts.append(value)
            }
        }
        return parts
    }

    private static func isConfigChangeEvent(_ event: AppLogEvent) -> Bool {
        let category = event.category.lowercased()
        let action = event.action.lowercased()
        if category == "配置" || category == "config" {
            return true
        }
        if action.contains("配置") || action.contains("config") {
            return true
        }
        if let payload = event.payload, payload["providerID"] != nil {
            return true
        }
        return false
    }
}

/// 对外暴露的日志 API。
///
/// 约束：
/// - `userOperation` 的 `message` 字段始终写入占位值，避免敏感聊天内容落盘。
public enum AppLog {
    public static func developer(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String,
        payload: [String: String]? = nil
    ) {
        Task { @MainActor in
            AppLogCenter.shared.logDeveloper(
                level: level,
                category: category,
                action: action,
                message: message,
                payload: payload
            )
        }
    }

    public static func userOperation(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String? = nil,
        payload: [String: String]? = nil
    ) {
        Task { @MainActor in
            AppLogCenter.shared.logUserOperation(
                level: level,
                category: category,
                action: action,
                message: message,
                payload: payload
            )
        }
    }
}

@MainActor
public final class AppLogCenter: ObservableObject {
    public static let shared = AppLogCenter()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则日志列表追加后不会稳定触发 SwiftUI 刷新。

    @Published public private(set) var mergedLogs: [AppLogEvent] = []
    @Published public private(set) var developerLogs: [AppLogEvent] = []
    @Published public private(set) var userLogs: [AppLogEvent] = []
    @Published public private(set) var logDayFolders: [AppLogDayFolder] = []

    private let systemLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogCenter")
    private var mergedBuffer = AppLogRingBuffer(capacity: 2_000)
    private var developerBuffer = AppLogRingBuffer(capacity: 500)
    private var userBuffer = AppLogRingBuffer(capacity: 500)
    private let fileStore: AppLogFileStore
    private var didLoadPersistedLogs = false

    private init(fileStore: AppLogFileStore = AppLogFileStore(), shouldAutoLoad: Bool = true) {
        self.fileStore = fileStore

        if shouldAutoLoad {
            Task { [weak self] in
                guard let self else { return }
                await self.loadPersistedLogsIfNeeded()
                await self.refreshLogFolders()
            }
        }
    }

    public func logDeveloper(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String,
        payload: [String: String]? = nil
    ) {
        let event = AppLogEvent(
            channel: .developer,
            level: level,
            category: category,
            action: action,
            message: message,
            payload: payload
        )
        append(event, persist: true)
        mirrorToConsole(event)
    }

    public func logUserOperation(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String? = nil,
        payload: [String: String]? = nil
    ) {
        let redactedPayload = AppLogRedactor.redactPayload(payload)
        let event = AppLogEvent(
            channel: .user,
            level: level,
            category: category,
            action: action,
            message: AppLogRedactor.redactedMessage(message),
            payload: redactedPayload
        )
        append(event, persist: true)
    }

    public func clear(channel: AppLogChannel) {
        switch channel {
        case .developer:
            developerBuffer.removeAll()
            developerLogs = []
        case .user:
            userBuffer.removeAll()
            userLogs = []
        }
        let filteredMerged = mergedLogs.filter { $0.channel != channel }
        mergedBuffer.replace(with: filteredMerged)
        mergedLogs = mergedBuffer.values

        Task {
            await fileStore.clear(channel: channel)
            await refreshLogFolders()
        }
    }

    public func clearAll() {
        mergedBuffer.removeAll()
        developerBuffer.removeAll()
        userBuffer.removeAll()
        mergedLogs = []
        developerLogs = []
        userLogs = []
        logDayFolders = []

        Task {
            await fileStore.clearAll()
            await refreshLogFolders()
        }
    }

    public func recentMergedLogs(limit: Int = 300) -> [AppLogEvent] {
        let sanitizedLimit = max(1, limit)
        return Array(mergedLogs.suffix(sanitizedLimit))
    }

    public func recentLogs(for channel: AppLogChannel, limit: Int = 200) -> [AppLogEvent] {
        let sanitizedLimit = max(1, limit)
        switch channel {
        case .developer:
            return Array(developerLogs.suffix(sanitizedLimit))
        case .user:
            return Array(userLogs.suffix(sanitizedLimit))
        }
    }

    public func refreshLogFolders() async {
        let folders = await fileStore.loadDayFolders()
        logDayFolders = folders
    }

    public func loadEvents(for runFile: AppLogRunFile) async -> [AppLogEvent] {
        await fileStore.loadEvents(for: runFile)
    }

    private func loadPersistedLogsIfNeeded() async {
        guard !didLoadPersistedLogs else { return }
        didLoadPersistedLogs = true

        let loaded = await fileStore.loadRecentEvents()
        let sorted = loaded.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }

        for event in sorted {
            append(event, persist: false)
        }
    }

    private func append(_ event: AppLogEvent, persist: Bool) {
        mergedBuffer.append(event)
        mergedLogs = mergedBuffer.values

        switch event.channel {
        case .developer:
            developerBuffer.append(event)
            developerLogs = developerBuffer.values
        case .user:
            userBuffer.append(event)
            userLogs = userBuffer.values
        }

        if persist {
            Task { [weak self] in
                guard let self else { return }
                await self.fileStore.append(event)
                await self.refreshLogFolders()
            }
        }
    }

    private func mirrorToConsole(_ event: AppLogEvent) {
        guard event.channel == .developer else { return }

        let payloadText: String
        if let payload = event.payload, !payload.isEmpty {
            payloadText = " payload=\(payload.description)"
        } else {
            payloadText = ""
        }

        let merged = "[\(event.category)][\(event.action)] \(event.message)\(payloadText)"

        switch event.level {
        case .debug:
            systemLogger.debug("\(merged, privacy: .public)")
        case .info:
            systemLogger.info("\(merged, privacy: .public)")
        case .warning:
            systemLogger.warning("\(merged, privacy: .public)")
        case .error:
            systemLogger.error("\(merged, privacy: .public)")
        }
    }
}

struct AppLogRingBuffer {
    private(set) var values: [AppLogEvent] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ event: AppLogEvent) {
        values.append(event)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
    }

    mutating func replace(with newValues: [AppLogEvent]) {
        values = Array(newValues.suffix(capacity))
    }
}

enum AppLogRedactor {
    static let redactionToken = "[已隐藏]"

    // 关键字段统一占位，避免持久化聊天敏感内容。
    private static let sensitiveFragments = [
        "message", "messages", "content", "prompt", "input", "output", "text"
    ]
    private static let requestBodySensitiveKeys: Set<String> = [
        "message",
        "messages",
        "content",
        "contents",
        "prompt",
        "system",
        "system_instruction"
    ]
    private static let sensitiveQueryFragments = [
        "key", "api_key", "token", "secret", "signature", "sig", "auth"
    ]
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "cookie",
        "set-cookie"
    ]

    static func redactedMessage(_ message: String?) -> String {
        guard let message else { return redactionToken }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return redactionToken
        }
        return redactionToken
    }

    static func redactPayload(_ payload: [String: String]?) -> [String: String]? {
        guard let payload else { return nil }
        guard !payload.isEmpty else { return payload }

        var result: [String: String] = [:]
        for (key, value) in payload {
            if isSensitiveKey(key) {
                result[key] = redactionToken
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func sanitizeRequestBodyForLog(_ payload: [String: Any], maxLength: Int = 4_000) -> String? {
        let sanitized = sanitizeJSONValue(payload)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let safeMaxLength = max(200, maxLength)
        if text.count > safeMaxLength {
            text = String(text.prefix(safeMaxLength)) + "\n...(已截断，原始长度 \(text.count) 字符)"
        }
        return text
    }

    static func sanitizeURLForLog(_ url: URL?) -> String {
        guard let url else { return "无" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                let normalizedName = item.name.lowercased()
                let isSensitive = sensitiveQueryFragments.contains { fragment in
                    normalizedName.contains(fragment)
                }
                guard isSensitive else { return item }
                return URLQueryItem(name: item.name, value: redactionToken)
            }
        }

        return components.string ?? url.absoluteString
    }

    static func sanitizeHeadersForLog(_ headers: [String: String]?) -> String? {
        guard let headers, !headers.isEmpty else { return nil }
        let lines = headers
            .map { key, value -> (String, String) in
                let normalizedName = key.lowercased()
                let isSensitive = sensitiveHeaderNames.contains(normalizedName) ||
                    normalizedName.contains("token") ||
                    normalizedName.contains("secret")
                return (key, isSensitive ? redactionToken : value)
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0): \($0.1)" }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func sanitizeJSONValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, rawValue) in dictionary {
                if shouldHideRequestBodyField(key) {
                    result[key] = redactionPlaceholder(for: rawValue)
                } else {
                    result[key] = sanitizeJSONValue(rawValue)
                }
            }
            return result
        }

        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0) }
        }

        return value
    }

    private static func shouldHideRequestBodyField(_ key: String) -> Bool {
        requestBodySensitiveKeys.contains(key.lowercased())
    }

    private static func redactionPlaceholder(for value: Any) -> String {
        if let array = value as? [Any] {
            return "[已隐藏数组，元素数: \(array.count)]"
        }
        if let dictionary = value as? [String: Any] {
            return "[已隐藏对象，字段数: \(dictionary.count)]"
        }
        if let text = value as? String {
            return "[已隐藏文本，长度: \(text.count)]"
        }
        return redactionToken
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveFragments.contains { fragment in
            normalized.contains(fragment)
        }
    }
}

actor AppLogFileStore {
    private enum SortOrder {
        case ascending
        case descending
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogFileStore")
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let retentionDays: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var dayFormatter: DateFormatter
    private var calendar: Calendar
    private let sessionDayKey: String
    private let sessionFileName: String
    private var didMigrateLegacyFiles = false

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL = StorageUtility.documentsDirectory.appendingPathComponent("AppLogs", isDirectory: true),
        retentionDays: Int = 180,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.retentionDays = max(1, retentionDays)
        self.calendar = calendar

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter

        let runFormatter = DateFormatter()
        runFormatter.locale = Locale(identifier: "en_US_POSIX")
        runFormatter.timeZone = calendar.timeZone
        runFormatter.dateFormat = "HH-mm-ss-SSS"
        let launchDate = Date()
        self.sessionDayKey = dayFormatter.string(from: launchDate)
        self.sessionFileName = "run-\(runFormatter.string(from: launchDate))-\(UUID().uuidString.lowercased()).jsonl"
    }

    func loadRecentEvents(now: Date = Date()) -> [AppLogEvent] {
        do {
            try ensureBaseDirectory()
            try purgeExpiredFiles(now: now)
            let files = try sortedLogFiles()

            var events: [AppLogEvent] = []
            for fileURL in files {
                events.append(contentsOf: try readEvents(from: fileURL))
            }
            return events.sorted { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
        } catch {
            logger.error("读取持久化日志失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func loadDayFolders(now: Date = Date()) -> [AppLogDayFolder] {
        do {
            try ensureBaseDirectory()
            try purgeExpiredFiles(now: now)

            let dayDirectories = try sortedDayDirectories(order: .descending)
            var folders: [AppLogDayFolder] = []

            for dayDirectory in dayDirectories {
                let day = dayDirectory.lastPathComponent
                let runFiles = try sortedRunFiles(in: dayDirectory, order: .descending)

                var runs: [AppLogRunFile] = []
                for runFileURL in runFiles {
                    let events = try readEvents(from: runFileURL)
                    let firstEventAt = events.first?.timestamp
                    let lastEventAt = events.last?.timestamp
                    let developerCount = events.reduce(0) { partialResult, event in
                        partialResult + (event.channel == .developer ? 1 : 0)
                    }
                    let userCount = events.count - developerCount

                    let values = try? runFileURL.resourceValues(
                        forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
                    )
                    let dayDate = dateFromDayFolderName(day) ?? Date.distantPast
                    let createdAt = values?.creationDate ?? firstEventAt ?? dayDate
                    let updatedAt = values?.contentModificationDate ?? lastEventAt ?? createdAt
                    let fileSizeBytes = Int64(values?.fileSize ?? 0)

                    let relativePath = "\(day)/\(runFileURL.lastPathComponent)"
                    runs.append(
                        AppLogRunFile(
                            relativePath: relativePath,
                            day: day,
                            fileName: runFileURL.lastPathComponent,
                            createdAt: createdAt,
                            updatedAt: updatedAt,
                            firstEventAt: firstEventAt,
                            lastEventAt: lastEventAt,
                            totalEventCount: events.count,
                            developerEventCount: developerCount,
                            userEventCount: userCount,
                            fileSizeBytes: fileSizeBytes
                        )
                    )
                }

                let sortedRuns = runs.sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.fileName > rhs.fileName
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                if !sortedRuns.isEmpty {
                    folders.append(AppLogDayFolder(day: day, runs: sortedRuns))
                }
            }

            return folders
        } catch {
            logger.error("加载日志目录索引失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func loadEvents(for runFile: AppLogRunFile) -> [AppLogEvent] {
        do {
            try ensureBaseDirectory()
            try purgeExpiredFiles(now: Date())
            guard let fileURL = resolveFileURL(relativePath: runFile.relativePath) else {
                logger.error("日志路径非法，拒绝读取: \(runFile.relativePath, privacy: .public)")
                return []
            }
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            return try readEvents(from: fileURL)
        } catch {
            logger.error("读取日志文件失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func append(_ event: AppLogEvent) {
        do {
            try ensureBaseDirectory()
            try purgeExpiredFiles(now: event.timestamp)
            let fileURL = sessionLogFileURL()
            try ensureDirectory(fileURL.deletingLastPathComponent())
            try append(event, to: fileURL)
        } catch {
            logger.error("追加日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear(channel: AppLogChannel) {
        do {
            try ensureBaseDirectory()
            let files = try sortedLogFiles()
            for fileURL in files {
                let events = try readEvents(from: fileURL)
                let filtered = events.filter { $0.channel != channel }
                try rewrite(events: filtered, to: fileURL)
            }
            try purgeEmptyDayDirectories()
        } catch {
            logger.error("清理日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearAll() {
        do {
            if fileManager.fileExists(atPath: baseDirectory.path) {
                try fileManager.removeItem(at: baseDirectory)
            }
            didMigrateLegacyFiles = false
            try ensureBaseDirectory()
        } catch {
            logger.error("清空日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 文件读写

    private func ensureBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        if !didMigrateLegacyFiles {
            try migrateLegacyFlatFilesIfNeeded()
            didMigrateLegacyFiles = true
        }
    }

    private func migrateLegacyFlatFilesIfNeeded() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            guard let dayDate = legacyDateFromFileName(url.lastPathComponent) else { continue }

            let day = dayFormatter.string(from: dayDate)
            let dayDirectory = baseDirectory.appendingPathComponent(day, isDirectory: true)
            try ensureDirectory(dayDirectory)

            let destination = makeLegacyDestinationURL(dayDirectory: dayDirectory, day: day)
            try fileManager.moveItem(at: url, to: destination)
        }
    }

    private func makeLegacyDestinationURL(dayDirectory: URL, day: String) -> URL {
        var candidate = dayDirectory.appendingPathComponent("legacy-\(day).jsonl", isDirectory: false)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dayDirectory.appendingPathComponent("legacy-\(day)-\(index).jsonl", isDirectory: false)
            index += 1
        }
        return candidate
    }

    private func ensureDirectory(_ directoryURL: URL) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func append(_ event: AppLogEvent, to fileURL: URL) throws {
        let encoded = try encoder.encode(event)
        var line = Data()
        line.append(encoded)
        line.append(0x0A)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    private func readEvents(from fileURL: URL) throws -> [AppLogEvent] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var events: [AppLogEvent] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            do {
                let event = try decoder.decode(AppLogEvent.self, from: lineData)
                events.append(event)
            } catch {
                logger.warning("忽略无法解析的日志行: \(error.localizedDescription, privacy: .public)")
            }
        }

        return events
    }

    private func rewrite(events: [AppLogEvent], to fileURL: URL) throws {
        if events.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        let encodedLines: [String] = try events.map { event in
            let data = try encoder.encode(event)
            return String(decoding: data, as: UTF8.self)
        }

        let content = encodedLines.joined(separator: "\n") + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 过期管理

    private func purgeExpiredFiles(now: Date) throws {
        let cutoffStart = oldestRetainedDay(now: now)
        let dayDirectories = try sortedDayDirectories(order: .ascending)

        for dayDirectory in dayDirectories {
            guard let dayDate = dateFromDayFolderName(dayDirectory.lastPathComponent) else { continue }
            let dayStart = calendar.startOfDay(for: dayDate)
            if dayStart < cutoffStart {
                try fileManager.removeItem(at: dayDirectory)
            }
        }

        try purgeEmptyDayDirectories()
    }

    private func purgeEmptyDayDirectories() throws {
        let dayDirectories = try sortedDayDirectories(order: .ascending)
        for dayDirectory in dayDirectories {
            let entries = try fileManager.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if entries.isEmpty {
                try fileManager.removeItem(at: dayDirectory)
            }
        }
    }

    private func oldestRetainedDay(now: Date) -> Date {
        let startToday = calendar.startOfDay(for: now)
        let daysToSubtract = retentionDays - 1
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: startToday) ?? startToday
    }

    // MARK: - 列表与路径

    private func sortedLogFiles() throws -> [URL] {
        let dayDirectories = try sortedDayDirectories(order: .ascending)
        var files: [URL] = []
        for dayDirectory in dayDirectories {
            files.append(contentsOf: try sortedRunFiles(in: dayDirectory, order: .ascending))
        }
        return files
    }

    private func sortedDayDirectories(order: SortOrder = .ascending) throws -> [URL] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var directories = urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
                return false
            }
            return dateFromDayFolderName(url.lastPathComponent) != nil
        }
        directories.sort { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }

        if order == .descending {
            directories.reverse()
        }
        return directories
    }

    private func sortedRunFiles(in dayDirectory: URL, order: SortOrder = .ascending) throws -> [URL] {
        guard fileManager.fileExists(atPath: dayDirectory.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: dayDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var files = urls.filter { url in
            guard url.pathExtension == "jsonl" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        files.sort { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }

        if order == .descending {
            files.reverse()
        }
        return files
    }

    private func sessionLogFileURL() -> URL {
        baseDirectory
            .appendingPathComponent(sessionDayKey, isDirectory: true)
            .appendingPathComponent(sessionFileName, isDirectory: false)
    }

    private func resolveFileURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        guard !relativePath.hasPrefix("/") else { return nil }
        let resolved = baseDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard isInsideBaseDirectory(resolved) else { return nil }
        return resolved
    }

    private func isInsideBaseDirectory(_ url: URL) -> Bool {
        let basePath = baseDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath == basePath || targetPath.hasPrefix(basePath + "/")
    }

    private func dateFromDayFolderName(_ folderName: String) -> Date? {
        dayFormatter.date(from: folderName)
    }

    private func legacyDateFromFileName(_ fileName: String) -> Date? {
        guard fileName.hasPrefix("app-log-") else { return nil }
        guard fileName.hasSuffix(".jsonl") else { return nil }

        let dayPart = fileName
            .replacingOccurrences(of: "app-log-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")

        return dayFormatter.date(from: dayPart)
    }
}
