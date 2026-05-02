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

enum AppLogRedactor {
    static let redactionToken = "[已隐藏]"

    // 关键字段统一占位，避免持久化聊天敏感内容。
    static let sensitiveFragments = [
        "message", "messages", "content", "prompt", "input", "output", "text"
    ]
    static let requestBodySensitiveKeys: Set<String> = [
        "message",
        "messages",
        "content",
        "contents",
        "prompt",
        "system",
        "system_instruction"
    ]
    static let sensitiveQueryFragments = [
        "key", "api_key", "token", "secret", "signature", "sig", "auth"
    ]
    static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
        "cookie",
        "set-cookie"
    ]
    static let freeTextRedactionRules: [(pattern: String, template: String)] = [
        ("(?i)(\"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret)\"\\s*:\\s*\")[^\"]+\"", "$1***\""),
        (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1***"),
        (#"(?i)(proxy-authorization\s*:\s*)[^\s]+"#, "$1***"),
        (#"(?i)(x-api-key\s*:\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)(api[_-]?key\s*[=:]\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)(access[_-]?token\s*[=:]\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)(refresh[_-]?token\s*[=:]\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)(secret\s*[=:]\s*)[^\s\",]+"#, "$1***"),
        (#"(?i)sk-[A-Za-z0-9]{12,}"#, "***")
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
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return sanitizeFreeTextForLog(text, maxLength: maxLength)
    }

    static func sanitizeFreeTextForLog(_ text: String, maxLength: Int = 4_000) -> String {
        guard !text.isEmpty else { return text }
        var output = text
        for rule in freeTextRedactionRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }

        let safeMaxLength = max(200, maxLength)
        if output.count > safeMaxLength {
            let originalLength = output.count
            output = String(output.prefix(safeMaxLength)) + "\n...(已截断，脱敏后长度 \(originalLength) 字符)"
        }
        return output
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

    static func sanitizeJSONValue(_ value: Any) -> Any {
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

    static func shouldHideRequestBodyField(_ key: String) -> Bool {
        requestBodySensitiveKeys.contains(key.lowercased())
    }

    static func redactionPlaceholder(for value: Any) -> String {
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

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveFragments.contains { fragment in
            normalized.contains(fragment)
        }
    }
}


actor AppLogFileStore {
    enum SortOrder {
        case ascending
        case descending
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLogFileStore")
    let fileManager: FileManager
    let baseDirectory: URL
    let retentionDays: Int
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    var dayFormatter: DateFormatter
    var calendar: Calendar
    let sessionDayKey: String
    let sessionFileName: String
    var didMigrateLegacyFiles = false

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

    func deleteDayFolder(day: String) {
        do {
            try ensureBaseDirectory()
            guard dateFromDayFolderName(day) != nil else { return }
            let dayDirectory = baseDirectory.appendingPathComponent(day, isDirectory: true)
            guard fileManager.fileExists(atPath: dayDirectory.path) else { return }
            try fileManager.removeItem(at: dayDirectory)
        } catch {
            logger.error("删除日志日期目录失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRunFile(relativePath: String) {
        do {
            try ensureBaseDirectory()
            guard let fileURL = resolveFileURL(relativePath: relativePath) else {
                logger.error("日志路径非法，拒绝删除: \(relativePath, privacy: .public)")
                return
            }
            guard fileURL.pathExtension == "jsonl" else { return }
            guard fileManager.fileExists(atPath: fileURL.path) else { return }

            try fileManager.removeItem(at: fileURL)
            try purgeEmptyDayDirectories()
        } catch {
            logger.error("删除日志文件失败: \(error.localizedDescription, privacy: .public)")
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

    func ensureBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        if !didMigrateLegacyFiles {
            try migrateLegacyFlatFilesIfNeeded()
            didMigrateLegacyFiles = true
        }
    }

    func migrateLegacyFlatFilesIfNeeded() throws {
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

    func makeLegacyDestinationURL(dayDirectory: URL, day: String) -> URL {
        var candidate = dayDirectory.appendingPathComponent("legacy-\(day).jsonl", isDirectory: false)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dayDirectory.appendingPathComponent("legacy-\(day)-\(index).jsonl", isDirectory: false)
            index += 1
        }
        return candidate
    }

    func ensureDirectory(_ directoryURL: URL) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    func append(_ event: AppLogEvent, to fileURL: URL) throws {
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

    func readEvents(from fileURL: URL) throws -> [AppLogEvent] {
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

    func rewrite(events: [AppLogEvent], to fileURL: URL) throws {
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

    func purgeExpiredFiles(now: Date) throws {
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

    func purgeEmptyDayDirectories() throws {
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

    func oldestRetainedDay(now: Date) -> Date {
        let startToday = calendar.startOfDay(for: now)
        let daysToSubtract = retentionDays - 1
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: startToday) ?? startToday
    }

    // MARK: - 列表与路径

    func sortedLogFiles() throws -> [URL] {
        let dayDirectories = try sortedDayDirectories(order: .ascending)
        var files: [URL] = []
        for dayDirectory in dayDirectories {
            files.append(contentsOf: try sortedRunFiles(in: dayDirectory, order: .ascending))
        }
        return files
    }

    func sortedDayDirectories(order: SortOrder = .ascending) throws -> [URL] {
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

    func sortedRunFiles(in dayDirectory: URL, order: SortOrder = .ascending) throws -> [URL] {
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

    func sessionLogFileURL() -> URL {
        baseDirectory
            .appendingPathComponent(sessionDayKey, isDirectory: true)
            .appendingPathComponent(sessionFileName, isDirectory: false)
    }

    func resolveFileURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        guard !relativePath.hasPrefix("/") else { return nil }
        let resolved = baseDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard isInsideBaseDirectory(resolved) else { return nil }
        return resolved
    }

    func isInsideBaseDirectory(_ url: URL) -> Bool {
        let basePath = baseDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        return targetPath == basePath || targetPath.hasPrefix(basePath + "/")
    }

    func dateFromDayFolderName(_ folderName: String) -> Date? {
        dayFormatter.date(from: folderName)
    }

    func legacyDateFromFileName(_ fileName: String) -> Date? {
        guard fileName.hasPrefix("app-log-") else { return nil }
        guard fileName.hasSuffix(".jsonl") else { return nil }

        let dayPart = fileName
            .replacingOccurrences(of: "app-log-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")

        return dayFormatter.date(from: dayPart)
    }
}
