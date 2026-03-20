// ============================================================================
// AppLogCenter.swift
// ============================================================================
// ETOS LLM Studio 统一日志中心
//
// 功能特性:
// - 双通道日志（开发者 / 用户）
// - 用户通道自动脱敏，避免记录敏感聊天字段
// - 内存循环缓冲 + 按天持久化（最近 7 天）
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
    public nonisolated let objectWillChange = ObservableObjectPublisher()

    @Published public private(set) var developerLogs: [AppLogEvent] = []
    @Published public private(set) var userLogs: [AppLogEvent] = []

    private let systemLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogCenter")
    private var developerBuffer = AppLogRingBuffer(capacity: 500)
    private var userBuffer = AppLogRingBuffer(capacity: 500)
    private let fileStore: AppLogFileStore
    private var didLoadPersistedLogs = false

    private init(fileStore: AppLogFileStore = AppLogFileStore(), shouldAutoLoad: Bool = true) {
        self.fileStore = fileStore

        if shouldAutoLoad {
            Task { [weak self] in
                await self?.loadPersistedLogsIfNeeded()
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

        Task {
            await fileStore.clear(channel: channel)
        }
    }

    public func clearAll() {
        developerBuffer.removeAll()
        userBuffer.removeAll()
        developerLogs = []
        userLogs = []

        Task {
            await fileStore.clearAll()
        }
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
        switch event.channel {
        case .developer:
            developerBuffer.append(event)
            developerLogs = developerBuffer.values
        case .user:
            userBuffer.append(event)
            userLogs = userBuffer.values
        }

        if persist {
            Task {
                await fileStore.append(event)
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
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogFileStore")
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let retentionDays: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var dayFormatter: DateFormatter
    private var calendar: Calendar

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL = StorageUtility.documentsDirectory.appendingPathComponent("AppLogs", isDirectory: true),
        retentionDays: Int = 7,
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
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
            return events
        } catch {
            logger.error("读取持久化日志失败: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func append(_ event: AppLogEvent) {
        do {
            try ensureBaseDirectory()
            try purgeExpiredFiles(now: event.timestamp)
            let fileURL = logFileURL(for: event.timestamp)
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
        } catch {
            logger.error("清理日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearAll() {
        do {
            try ensureBaseDirectory()
            let files = try sortedLogFiles()
            for fileURL in files {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            logger.error("清空日志失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 文件读写

    private func ensureBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
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
        let files = try sortedLogFiles()

        for fileURL in files {
            guard let day = dateFromFileName(fileURL.lastPathComponent) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            if dayStart < cutoffStart {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func oldestRetainedDay(now: Date) -> Date {
        let startToday = calendar.startOfDay(for: now)
        let daysToSubtract = retentionDays - 1
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: startToday) ?? startToday
    }

    private func sortedLogFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.lastPathComponent.hasPrefix("app-log-") && $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    private func logFileURL(for date: Date) -> URL {
        let day = dayFormatter.string(from: date)
        return baseDirectory.appendingPathComponent("app-log-\(day).jsonl", isDirectory: false)
    }

    private func dateFromFileName(_ fileName: String) -> Date? {
        guard fileName.hasPrefix("app-log-") else { return nil }
        guard fileName.hasSuffix(".jsonl") else { return nil }

        let dayPart = fileName
            .replacingOccurrences(of: "app-log-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")

        return dayFormatter.date(from: dayPart)
    }
}
