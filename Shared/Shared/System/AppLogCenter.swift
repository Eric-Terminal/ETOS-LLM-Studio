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

public struct AppLogTextPage: Identifiable, Hashable, Sendable {
    public let index: Int
    public let totalCount: Int
    public let startCharacterNumber: Int
    public let endCharacterNumber: Int
    public let content: String

    public init(
        index: Int,
        totalCount: Int,
        startCharacterNumber: Int,
        endCharacterNumber: Int,
        content: String
    ) {
        self.index = index
        self.totalCount = totalCount
        self.startCharacterNumber = startCharacterNumber
        self.endCharacterNumber = endCharacterNumber
        self.content = content
    }

    public var id: Int { index }
}

public enum AppLogTextPaginator {
    public static let defaultPageSize = 4_000

    public static func paginate(_ text: String, pageSize: Int = defaultPageSize) -> [AppLogTextPage] {
        let sanitizedPageSize = max(1, pageSize)
        guard !text.isEmpty else {
            return [
                AppLogTextPage(
                    index: 0,
                    totalCount: 1,
                    startCharacterNumber: 0,
                    endCharacterNumber: 0,
                    content: ""
                )
            ]
        }

        var chunks: [String] = []
        var cursor = text.startIndex
        let endIndex = text.endIndex

        while cursor < endIndex {
            let chunkEnd = text.index(cursor, offsetBy: sanitizedPageSize, limitedBy: endIndex) ?? endIndex
            chunks.append(String(text[cursor..<chunkEnd]))
            cursor = chunkEnd
        }

        let totalCount = chunks.count
        return chunks.enumerated().map { offset, content in
            let start = offset * sanitizedPageSize + 1
            let end = start + content.count - 1
            return AppLogTextPage(
                index: offset,
                totalCount: totalCount,
                startCharacterNumber: start,
                endCharacterNumber: end,
                content: content
            )
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

    public func deleteDayFolder(_ dayFolder: AppLogDayFolder) {
        Task { [weak self] in
            guard let self else { return }
            await self.fileStore.deleteDayFolder(day: dayFolder.day)
            await self.reloadPersistedLogsSnapshot()
            await self.refreshLogFolders()
        }
    }

    public func deleteRunFile(_ runFile: AppLogRunFile) {
        Task { [weak self] in
            guard let self else { return }
            await self.fileStore.deleteRunFile(relativePath: runFile.relativePath)
            await self.reloadPersistedLogsSnapshot()
            await self.refreshLogFolders()
        }
    }

    public func loadEvents(for runFile: AppLogRunFile) async -> [AppLogEvent] {
        await fileStore.loadEvents(for: runFile)
    }

    private func loadPersistedLogsIfNeeded() async {
        guard !didLoadPersistedLogs else { return }
        didLoadPersistedLogs = true

        await reloadPersistedLogsSnapshot()
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

    private func reloadPersistedLogsSnapshot() async {
        let loaded = await fileStore.loadRecentEvents()
        let sorted = loaded.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
        applySnapshot(sorted)
    }

    private func applySnapshot(_ sortedEvents: [AppLogEvent]) {
        mergedBuffer.replace(with: sortedEvents)
        mergedLogs = mergedBuffer.values

        developerBuffer.removeAll()
        userBuffer.removeAll()

        for event in mergedBuffer.values {
            switch event.channel {
            case .developer:
                developerBuffer.append(event)
            case .user:
                userBuffer.append(event)
            }
        }

        developerLogs = developerBuffer.values
        userLogs = userBuffer.values
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
    static var redactionToken: String {
        NSLocalizedString("[已隐藏]", comment: "App log redaction placeholder")
    }

    // 关键字段统一占位，避免持久化聊天敏感内容。
    private static let sensitiveFragments = [
        "message", "messages", "content", "prompt", "input", "output", "text"
    ]
    private static let requestBodySensitiveKeys: Set<String> = [
        "message",
        "messages",
        "content",
        "contents",
        "input",
        "prompt",
        "system",
        "system_instruction"
    ]
    private static let requestBodyPlainMessageKeys: Set<String> = [
        "message",
        "messages",
        "content",
        "contents",
        "input"
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

    static func sanitizeRequestBodyForLog(
        _ payload: [String: Any],
        exposesMessageFields: Bool? = nil
    ) -> String? {
        let shouldExposeMessages = exposesMessageFields ?? AppConfigStore.boolValue(for: .requestLogPlainMessageEnabled)
        let sanitized = sanitizeJSONValue(payload, exposesMessageFields: shouldExposeMessages)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func sanitizeURLForLog(_ url: URL?) -> String {
        guard let url else { return NSLocalizedString("无", comment: "App log empty value") }
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

    private static func sanitizeJSONValue(_ value: Any, exposesMessageFields: Bool) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, rawValue) in dictionary {
                if let text = rawValue as? String, shouldHideBinaryPayload(key: key, text: text) {
                    result[key] = binaryPayloadPlaceholder(for: text)
                } else if shouldHideRequestBodyField(key, exposesMessageFields: exposesMessageFields) {
                    result[key] = redactionPlaceholder(for: rawValue)
                } else {
                    result[key] = sanitizeJSONValue(rawValue, exposesMessageFields: exposesMessageFields)
                }
            }
            return result
        }

        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0, exposesMessageFields: exposesMessageFields) }
        }

        return value
    }

    private static func shouldHideRequestBodyField(_ key: String, exposesMessageFields: Bool) -> Bool {
        let normalized = key.lowercased()
        if exposesMessageFields, requestBodyPlainMessageKeys.contains(normalized) {
            return false
        }
        return requestBodySensitiveKeys.contains(normalized)
    }

    private static func shouldHideBinaryPayload(key: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalizedKey = key.lowercased()
        if (normalizedKey == "url" || normalizedKey == "image_url"), trimmed.hasPrefix("data:") {
            return true
        }
        return normalizedKey == "data" || normalizedKey == "file_data" || normalizedKey == "b64_json"
    }

    private static func binaryPayloadPlaceholder(for text: String) -> String {
        "[二进制内容已隐藏，长度: \(text.count)]"
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
