// ============================================================================
// ThirdPartyImportParsingUtilities.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责第三方导入共享的文件访问、JSON、日期与基础类型解析。
// ============================================================================

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

extension ThirdPartyImportService {
    static func withSecurityScopedAccess<T>(to fileURL: URL, action: () throws -> T) throws -> T {
        let didStart = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        return try action()
    }

    static func tryParseDictionaryJSON(from fileURL: URL) -> [String: Any]? {
        guard !isDirectory(fileURL),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return tryParseDictionaryJSON(data)
    }

    static func tryParseDictionaryJSON(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func parseJSONStringToDictionary(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return tryParseDictionaryJSON(data)
    }

    static func findFirstDictionaryJSON(
        inDirectory directoryURL: URL,
        where predicate: ([String: Any]) -> Bool
    ) throws -> [String: Any]? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            guard fileURL.pathExtension.lowercased() == "json",
                  let parsed = tryParseDictionaryJSON(from: fileURL) else {
                continue
            }
            if predicate(parsed) {
                return parsed
            }
        }

        return nil
    }

    static func findJSONInDirectory(
        _ directoryURL: URL,
        preferredNames: [String]
    ) -> [String: Any]? {
        guard let fileURL = findFileInDirectory(directoryURL, preferredNames: preferredNames) else {
            return nil
        }
        return tryParseDictionaryJSON(from: fileURL)
    }

    static func findFileInDirectory(
        _ directoryURL: URL,
        preferredNames: [String]
    ) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let nameSet = Set(preferredNames.map { $0.lowercased() })
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            if nameSet.contains(fileURL.lastPathComponent.lowercased()) {
                return fileURL
            }
        }

        return nil
    }

    static func findETOSJSONFile(inDirectory directoryURL: URL) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var fallback: URL?
        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            if fileURL.lastPathComponent.hasPrefix("ETOS-数据导出-") {
                return fileURL
            }
            fallback = fallback ?? fileURL
        }

        return fallback
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    static func isLikelyCompressedBackup(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext == "zip" || ext == "bak"
    }

    static func splitAPIKeys(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n;")
        return dedupeStrings(
            raw
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func dedupeStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    static func mapMessageRole(_ raw: String?) -> MessageRole {
        switch (raw ?? "").lowercased() {
        case "system": return .system
        case "assistant", "model": return .assistant
        case "tool", "function": return .tool
        case "error": return .error
        default: return .user
        }
    }

    static func flattenText(_ any: Any?) -> String? {
        guard let any else { return nil }

        if let string = any as? String {
            return nonEmpty(string)
        }

        if let number = any as? NSNumber {
            return number.stringValue
        }

        if let list = any as? [Any] {
            let parts = list.compactMap { flattenText($0) }
            let merged = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return merged.isEmpty ? nil : merged
        }

        if let map = any as? [String: Any] {
            if let direct = nonEmpty(string(map["text"])) {
                return direct
            }
            if let direct = nonEmpty(string(map["content"])) {
                return direct
            }
            if let parts = flattenText(map["parts"]) {
                return parts
            }
            if let value = flattenText(map["value"]) {
                return value
            }
        }

        return nil
    }

    static func parseDate(_ any: Any?) -> Date? {
        guard let any else { return nil }

        if let date = any as? Date {
            return date
        }

        if let number = any as? NSNumber {
            return dateFromTimestamp(number.doubleValue)
        }

        if let string = any as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let numeric = Double(trimmed) {
                return dateFromTimestamp(numeric)
            }

            if let iso = ISO8601DateFormatter.full.date(from: trimmed) {
                return iso
            }
            if let basic = ISO8601DateFormatter.basic.date(from: trimmed) {
                return basic
            }
            if let parsed = ThirdPartyDateParser.shared.date(from: trimmed) {
                return parsed
            }
        }

        return nil
    }

    static func dateFromTimestamp(_ value: Double) -> Date {
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return Date(timeIntervalSince1970: value)
    }

    static func stableUUID(from raw: String?) -> UUID? {
        guard let raw = nonEmpty(raw) else { return nil }
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(raw.utf8))
        let bytes = Array(digest)
        guard bytes.count >= 16 else { return nil }
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
#else
        return nil
#endif
    }

    static func dictionary(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }

    static func normalizeJSONArray(_ any: Any?) -> [Any] {
        if let list = any as? [Any] {
            return list
        }
        if let dict = any as? [String: Any] {
            return Array(dict.values)
        }
        return []
    }

    static func normalizeStringArray(_ any: Any?) -> [String] {
        normalizeJSONArray(any)
            .compactMap { nonEmpty(string($0)) }
    }

    static func string(_ any: Any?) -> String? {
        if let string = any as? String { return string }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ any: Any?, defaultValue: Bool) -> Bool {
        if let value = any as? Bool {
            return value
        }
        if let value = any as? NSNumber {
            return value.boolValue
        }
        if let value = any as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return defaultValue
    }

    static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private enum ThirdPartyDateParser {
    static let shared = DateFormatterPool()

    final class DateFormatterPool {
        private let formatters: [DateFormatter]

        init() {
            let patterns = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd"
            ]
            self.formatters = patterns.map { pattern in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = pattern
                return formatter
            }
        }

        func date(from value: String) -> Date? {
            for formatter in formatters {
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            return nil
        }
    }
}

private extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
