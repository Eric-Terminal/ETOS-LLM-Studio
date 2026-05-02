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


public struct AppLogSourceContext: Codable, Hashable, Sendable {
    public let fileID: String
    public let function: String
    public let line: UInt
    public let capturedOnMainThread: Bool

    public init(
        fileID: String,
        function: String,
        line: UInt,
        capturedOnMainThread: Bool
    ) {
        self.fileID = fileID
        self.function = function
        self.line = line
        self.capturedOnMainThread = capturedOnMainThread
    }

    var payloadFields: [String: String] {
        [
            "来源文件": fileID,
            "来源函数": function,
            "来源行": "\(line)",
            "捕获线程": capturedOnMainThread ? "main" : "background"
        ]
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

    static func searchableParts(for event: AppLogEvent) -> [String] {
        var parts: [String] = [event.category, event.action, event.message]
        if let payload = event.payload, !payload.isEmpty {
            for (key, value) in payload {
                parts.append(key)
                parts.append(value)
            }
        }
        return parts
    }

    static func isConfigChangeEvent(_ event: AppLogEvent) -> Bool {
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
        payload: [String: String]? = nil,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let source = AppLogSourceContext(
            fileID: String(describing: fileID),
            function: String(describing: function),
            line: line,
            capturedOnMainThread: Thread.isMainThread
        )
        Task { @MainActor in
            AppLogCenter.shared.logDeveloper(
                level: level,
                category: category,
                action: action,
                message: message,
                payload: payload,
                source: source
            )
        }
    }

    public static func userOperation(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String? = nil,
        payload: [String: String]? = nil,
        fileID: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let source = AppLogSourceContext(
            fileID: String(describing: fileID),
            function: String(describing: function),
            line: line,
            capturedOnMainThread: Thread.isMainThread
        )
        Task { @MainActor in
            AppLogCenter.shared.logUserOperation(
                level: level,
                category: category,
                action: action,
                message: message,
                payload: payload,
                source: source
            )
        }
    }
}


@MainActor
public final class AppLogCenter: ObservableObject {
    public static let shared = AppLogCenter()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则日志列表追加后不会稳定触发 SwiftUI 刷新。

    @Published public var mergedLogs: [AppLogEvent] = []
    @Published public var developerLogs: [AppLogEvent] = []
    @Published public var userLogs: [AppLogEvent] = []
    @Published public var logDayFolders: [AppLogDayFolder] = []

    let systemLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogCenter")
    var mergedBuffer = AppLogRingBuffer(capacity: 2_000)
    var developerBuffer = AppLogRingBuffer(capacity: 500)
    var userBuffer = AppLogRingBuffer(capacity: 500)
    let fileStore: AppLogFileStore
    var didLoadPersistedLogs = false

    init(fileStore: AppLogFileStore = AppLogFileStore(), shouldAutoLoad: Bool = true) {
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
        payload: [String: String]? = nil,
        source: AppLogSourceContext? = nil
    ) {
        let event = AppLogEvent(
            channel: .developer,
            level: level,
            category: category,
            action: action,
            message: message,
            payload: Self.enrichedPayload(payload, source: source)
        )
        append(event, persist: true)
        mirrorToConsole(event)
    }

    public func logUserOperation(
        level: AppLogLevel = .info,
        category: String,
        action: String,
        message: String? = nil,
        payload: [String: String]? = nil,
        source: AppLogSourceContext? = nil
    ) {
        let redactedPayload = AppLogRedactor.redactPayload(Self.enrichedPayload(payload, source: source))
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

    static func enrichedPayload(
        _ payload: [String: String]?,
        source: AppLogSourceContext?
    ) -> [String: String]? {
        var result = payload ?? [:]
        if let source {
            for (key, value) in source.payloadFields where result[key] == nil {
                result[key] = value
            }
        }
        return result.isEmpty ? nil : result
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

    func loadPersistedLogsIfNeeded() async {
        guard !didLoadPersistedLogs else { return }
        didLoadPersistedLogs = true

        await reloadPersistedLogsSnapshot()
    }

    func append(_ event: AppLogEvent, persist: Bool) {
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

    func reloadPersistedLogsSnapshot() async {
        let loaded = await fileStore.loadRecentEvents()
        let sorted = loaded.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
        applySnapshot(sorted)
    }

    func applySnapshot(_ sortedEvents: [AppLogEvent]) {
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

    func mirrorToConsole(_ event: AppLogEvent) {
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
    var values: [AppLogEvent] = []
    let capacity: Int

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
