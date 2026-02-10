// ============================================================================
// WorldbookImportService.swift
// ============================================================================
// 世界书导入：支持 JSON / PNG(naidata) / 多种兼容格式转换。
// ============================================================================

import Foundation
import Compression

public enum WorldbookImportError: LocalizedError {
    case invalidPayload
    case unsupportedFormat
    case missingEntries
    case missingPNGPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "导入失败：文件内容不是有效的世界书数据。"
        case .unsupportedFormat:
            return "导入失败：暂不支持该文件格式。"
        case .missingEntries:
            return "导入失败：未找到可用条目。"
        case .missingPNGPayload:
            return "导入失败：PNG 内未找到 naidata 世界书数据。"
        }
    }
}

public struct WorldbookImportResult {
    public var worldbook: Worldbook
    public var diagnostics: WorldbookImportDiagnostics

    public init(worldbook: Worldbook, diagnostics: WorldbookImportDiagnostics) {
        self.worldbook = worldbook
        self.diagnostics = diagnostics
    }
}

public struct WorldbookImportService {
    public init() {}

    public func importWorldbook(from url: URL) throws -> Worldbook {
        let data = try Data(contentsOf: url)
        return try importWorldbook(from: data, fileName: url.lastPathComponent)
    }

    public func importWorldbook(from data: Data, fileName: String) throws -> Worldbook {
        try importWorldbookWithReport(from: data, fileName: fileName).worldbook
    }

    public func importWorldbookWithReport(from data: Data, fileName: String) throws -> WorldbookImportResult {
        let jsonData: Data
        if Self.isPNG(data) {
            guard let embedded = Self.extractNaiDataJSON(fromPNG: data) else {
                throw WorldbookImportError.missingPNGPayload
            }
            jsonData = embedded
        } else {
            jsonData = data
        }

        let payload = try JSONSerialization.jsonObject(with: jsonData)
        let parsed = try parseJSONPayload(payload, fileName: fileName)
        guard !parsed.entries.isEmpty else {
            throw WorldbookImportError.missingEntries
        }

        let worldbook = Worldbook(
            id: UUID(),
            name: parsed.name,
            isEnabled: true,
            createdAt: Date(),
            updatedAt: Date(),
            entries: parsed.entries,
            settings: parsed.settings,
            sourceFileName: fileName,
            metadata: parsed.metadata
        )
        let diagnostics = WorldbookImportDiagnostics(
            failedEntries: parsed.failedEntries,
            failureReasons: parsed.failureReasons
        )
        return WorldbookImportResult(worldbook: worldbook, diagnostics: diagnostics)
    }

    private func parseJSONPayload(_ payload: Any, fileName: String) throws -> ParsedBook {
        if let root = payload as? [String: Any] {
            return try parseRoot(root, fileName: fileName)
        }
        if let entries = payload as? [Any] {
            return try parseSillyTavernArray(entries: entries, root: [:], fileName: fileName)
        }
        if let text = payload as? String,
           let nestedData = decodeJSONStringPayload(text) {
            let nestedPayload = try JSONSerialization.jsonObject(with: nestedData)
            return try parseJSONPayload(nestedPayload, fileName: fileName)
        }
        throw WorldbookImportError.invalidPayload
    }

    private func parseRoot(_ root: [String: Any], fileName: String) throws -> ParsedBook {
        if let characterBook = root["character_book"] as? [String: Any] {
            return try parseCharacterBook(characterBook, root: root, fileName: fileName)
        }
        if let nestedData = root["data"] as? [String: Any],
           let characterBook = nestedData["character_book"] as? [String: Any] {
            return try parseCharacterBook(characterBook, root: nestedData, fileName: fileName)
        }

        if let entries = root["entries"] as? [String: Any] {
            return try parseSillyTavernLike(entriesContainer: entries, root: root, fileName: fileName)
        }
        if let entries = root["entries"] as? [Any] {
            if root["lorebookVersion"] != nil {
                return try parseNovel(entries: entries, root: root, fileName: fileName)
            }
            if let kind = root["kind"] as? String, kind.lowercased() == "memory" {
                return try parseAgnai(entries: entries, root: root, fileName: fileName)
            }
            if let type = root["type"] as? String, type.lowercased() == "risu" {
                return try parseRisu(entries: entries, root: root, fileName: fileName)
            }
            // 宽松回退：按 ST-like 解析数组 entries
            return try parseSillyTavernArray(entries: entries, root: root, fileName: fileName)
        }

        // 兼容部分导出会把实体放在 data/lorebook 字段
        if let nested = root["data"] as? [String: Any] {
            return try parseRoot(nested, fileName: fileName)
        }
        if let nested = root["lorebook"] as? [String: Any] {
            return try parseRoot(nested, fileName: fileName)
        }

        throw WorldbookImportError.invalidPayload
    }

    private func parseCharacterBook(_ characterBook: [String: Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        guard let entries = characterBook["entries"] as? [Any] else {
            throw WorldbookImportError.missingEntries
        }

        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []

        for (index, item) in entries.enumerated() {
            guard var dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("角色卡条目 #\(index) 结构无效，已跳过。", to: &failureReasons)
                continue
            }

            if dict["key"] == nil, let keys = dict["keys"] {
                dict["key"] = keys
            }
            if dict["keysecondary"] == nil, let secondary = dict["secondary_keys"] {
                dict["keysecondary"] = secondary
            }
            if dict["order"] == nil, let insertionOrder = dict["insertion_order"] {
                dict["order"] = insertionOrder
            }
            if let enabled = boolValue(dict["enabled"]) {
                dict["isEnabled"] = enabled
                dict["disable"] = !enabled
            }

            let uid = intValue(dict["uid"]) ?? intValue(dict["id"]) ?? index
            if let entry = parseEntry(dict, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("角色卡条目 \(uid) 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }

        var normalizedRoot = root
        if normalizedRoot["name"] == nil {
            normalizedRoot["name"] = stringValue(characterBook["name"]) ?? stringValue(root["name"])
        }
        if normalizedRoot["entries"] == nil {
            normalizedRoot["entries"] = entries
        }

        return buildParsedBook(
            entries: parsed,
            root: normalizedRoot,
            fileName: fileName,
            failedEntries: failedEntries,
            failureReasons: failureReasons
        )
    }

    private func parseSillyTavernLike(entriesContainer: [String: Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var entries: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (key, value) in entriesContainer {
            guard let dict = value as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("条目 \(key) 结构无效，已跳过。", to: &failureReasons)
                continue
            }
            let uidHint = Int(key)
            if let entry = parseEntry(dict, uidHint: uidHint) {
                entries.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("条目 \(uidHint.map(String.init) ?? key) 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }
        return buildParsedBook(entries: entries, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseSillyTavernArray(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("条目 #\(index) 结构无效，已跳过。", to: &failureReasons)
                continue
            }
            let uid = intValue(dict["uid"])
            if let entry = parseEntry(dict, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("条目 \(uid.map(String.init) ?? "#\(index)") 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseNovel(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("Novel 条目 #\(index) 结构无效，已跳过。", to: &failureReasons)
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["text"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["keys"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["displayName"] ?? dict["name"]
            }
            if converted["position"] == nil {
                converted["position"] = dict["position"] ?? "after"
            }
            let uid = intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("Novel 条目 \(uid.map(String.init) ?? "#\(index)") 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseAgnai(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("Agnai 条目 #\(index) 结构无效，已跳过。", to: &failureReasons)
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["value"] ?? dict["text"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["key"] ?? dict["keys"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["name"] ?? dict["memo"]
            }
            let uid = intValue(dict["uid"]) ?? intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("Agnai 条目 \(uid.map(String.init) ?? "#\(index)") 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func parseRisu(entries: [Any], root: [String: Any], fileName: String) throws -> ParsedBook {
        var parsed: [WorldbookEntry] = []
        var failedEntries = 0
        var failureReasons: [String] = []
        for (index, item) in entries.enumerated() {
            guard let dict = item as? [String: Any] else {
                failedEntries += 1
                appendFailureReason("Risu 条目 #\(index) 结构无效，已跳过。", to: &failureReasons)
                continue
            }
            var converted = dict
            if converted["content"] == nil {
                converted["content"] = dict["content"] ?? dict["text"] ?? dict["value"]
            }
            if converted["key"] == nil {
                converted["key"] = dict["keys"] ?? dict["key"]
            }
            if converted["comment"] == nil {
                converted["comment"] = dict["comment"] ?? dict["name"]
            }
            let uid = intValue(dict["uid"]) ?? intValue(dict["id"])
            if let entry = parseEntry(converted, uidHint: uid) {
                parsed.append(entry)
            } else {
                failedEntries += 1
                appendFailureReason("Risu 条目 \(uid.map(String.init) ?? "#\(index)") 缺少有效 content，已跳过。", to: &failureReasons)
            }
        }
        return buildParsedBook(entries: parsed, root: root, fileName: fileName, failedEntries: failedEntries, failureReasons: failureReasons)
    }

    private func buildParsedBook(
        entries: [WorldbookEntry],
        root: [String: Any],
        fileName: String,
        failedEntries: Int,
        failureReasons: [String]
    ) -> ParsedBook {
        let defaultName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let name = stringValue(root["name"]) ?? stringValue(root["title"]) ?? (defaultName.isEmpty ? "导入世界书" : defaultName)

        let settings = WorldbookSettings(
            scanDepth: intValue(root["scanDepth"]) ?? intValue(root["scan_depth"]) ?? 4,
            maxRecursionDepth: intValue(root["maxRecursionDepth"]) ?? intValue(root["max_recursion_depth"]) ?? 2,
            maxInjectedEntries: intValue(root["maxEntries"]) ?? intValue(root["max_entries"]) ?? 64,
            maxInjectedCharacters: intValue(root["maxChars"]) ?? intValue(root["max_chars"]) ?? 6000,
            fallbackPosition: WorldbookPosition(stRawValue: stringValue(root["position"]) ?? "after")
        )

        let metadata = jsonDictionary(from: root)
        return ParsedBook(
            name: name,
            entries: entries,
            settings: settings,
            metadata: metadata,
            failedEntries: failedEntries,
            failureReasons: failureReasons
        )
    }

    private func parseEntry(_ dict: [String: Any], uidHint: Int?) -> WorldbookEntry? {
        let extensionDict = dict["extensions"] as? [String: Any]
        let content = stringValue(dict["content"]) ?? stringValue(dict["text"]) ?? stringValue(dict["value"]) ?? ""
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }

        let primaryKeys = stringArrayValue(dict["keys"]) + stringArrayValue(dict["key"]) + stringArrayValue(dict["keywords"])
        let dedupPrimary = deduplicateStrings(primaryKeys)

        let secondaryKeys = stringArrayValue(dict["secondaryKeys"]) + stringArrayValue(dict["keysecondary"]) + stringArrayValue(dict["secondary_keys"])
        let dedupSecondary = deduplicateStrings(secondaryKeys)

        let rawPositionValue: Any? =
            dict["position"] ??
            extensionDict?["position"] ??
            dict["insertPosition"] ??
            "after"

        let order = intValue(dict["order"]) ?? 100
        let probabilityRaw = doubleValue(dict["probability"]) ?? 100
        let probability = probabilityRaw <= 1 ? probabilityRaw * 100 : probabilityRaw
        let outletName =
            stringValue(dict["outletName"]) ??
            stringValue(dict["outlet"]) ??
            stringValue(extensionDict?["outlet"]) ??
            stringValue(extensionDict?["outlet_name"])

        var logic = WorldbookSelectiveLogic(
            rawOrLegacyValue:
                stringValue(dict["selectiveLogic"]) ??
                stringValue(extensionDict?["selectiveLogic"]) ??
                stringValue(extensionDict?["selective_logic"])
        )
        if let legacyLogic = intValue(dict["selectiveLogic"]) ?? intValue(extensionDict?["selectiveLogic"]) ?? intValue(extensionDict?["selective_logic"]) {
            switch legacyLogic {
            case 1: logic = .notAll
            case 2: logic = .notAny
            case 3: logic = .andAll
            default: logic = .andAny
            }
        }

        let enabled: Bool
        if let disable = boolValue(dict["disable"]) {
            enabled = !disable
        } else if let directEnabled = boolValue(dict["isEnabled"]) {
            enabled = directEnabled
        } else if let legacyEnabled = boolValue(dict["enabled"]) {
            enabled = legacyEnabled
        } else {
            enabled = true
        }

        return WorldbookEntry(
            id: UUID(),
            uid: uidHint ?? intValue(dict["uid"]) ?? intValue(dict["id"]),
            comment: stringValue(dict["comment"]) ?? stringValue(dict["memo"]) ?? stringValue(dict["name"]) ?? "",
            content: trimmedContent,
            keys: dedupPrimary,
            secondaryKeys: dedupSecondary,
            selectiveLogic: logic,
            isEnabled: enabled,
            constant: boolValue(dict["constant"]) ?? false,
            position: positionFromRaw(rawPositionValue),
            outletName: outletName,
            order: order,
            depth: intValue(dict["depth"]) ?? intValue(extensionDict?["depth"]),
            scanDepth: intValue(dict["scanDepth"]) ?? intValue(dict["scan_depth"]) ?? intValue(extensionDict?["scan_depth"]) ?? intValue(extensionDict?["scanDepth"]),
            caseSensitive: boolValue(dict["caseSensitive"]) ?? boolValue(dict["case_sensitive"]) ?? boolValue(extensionDict?["case_sensitive"]) ?? false,
            matchWholeWords: boolValue(dict["matchWholeWords"]) ?? boolValue(dict["wholeWords"]) ?? boolValue(dict["match_whole_words"]) ?? boolValue(extensionDict?["match_whole_words"]) ?? false,
            useRegex: boolValue(dict["useRegex"]) ?? boolValue(dict["keyRegex"]) ?? boolValue(dict["regex"]) ?? false,
            useProbability: boolValue(dict["useProbability"]) ?? boolValue(extensionDict?["useProbability"]) ?? (probability < 100),
            probability: max(0, min(100, probability)),
            group: stringValue(dict["group"]) ?? stringValue(extensionDict?["group"]),
            groupOverride: boolValue(dict["groupOverride"]) ?? boolValue(extensionDict?["group_override"]) ?? false,
            groupWeight: doubleValue(dict["groupWeight"]) ?? doubleValue(extensionDict?["group_weight"]) ?? 1,
            useGroupScoring: boolValue(dict["useGroupScoring"]) ?? boolValue(extensionDict?["use_group_scoring"]) ?? false,
            sticky: intValue(dict["sticky"]) ?? intValue(extensionDict?["sticky"]),
            cooldown: intValue(dict["cooldown"]) ?? intValue(extensionDict?["cooldown"]),
            delay: intValue(dict["delay"]) ?? intValue(extensionDict?["delay"]),
            excludeRecursion: boolValue(dict["excludeRecursion"]) ?? boolValue(extensionDict?["exclude_recursion"]) ?? false,
            preventRecursion: boolValue(dict["preventRecursion"]) ?? boolValue(extensionDict?["prevent_recursion"]) ?? false,
            delayUntilRecursion: boolValue(dict["delayUntilRecursion"]) ?? boolValue(extensionDict?["delay_until_recursion"]) ?? false,
            metadata: jsonDictionary(from: dict)
        )
    }

    private func appendFailureReason(_ reason: String, to reasons: inout [String]) {
        guard reasons.count < 20 else { return }
        reasons.append(reason)
    }

    // MARK: - PNG naidata

    private static func isPNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Array(data.prefix(8)) == signature
    }

    private static func extractNaiDataJSON(fromPNG data: Data) -> Data? {
        guard isPNG(data) else { return nil }

        var offset = 8
        while offset + 12 <= data.count {
            let length = Int(readUInt32BigEndian(data, offset: offset))
            let typeStart = offset + 4
            let chunkStart = typeStart + 4
            let chunkEnd = chunkStart + length
            let crcEnd = chunkEnd + 4

            guard crcEnd <= data.count else { break }

            let type = String(data: data[typeStart..<(typeStart + 4)], encoding: .ascii) ?? ""
            let chunkData = Data(data[chunkStart..<chunkEnd])

            if let text = decodePNGTextChunk(type: type, data: chunkData),
               let payload = text["naidata"],
               let payloadData = decodeNaiDataPayload(payload) {
                return payloadData
            }

            if type == "IEND" { break }
            offset = crcEnd
        }
        return nil
    }

    private static func decodeNaiDataPayload(_ payload: String) -> Data? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: direct)) != nil {
            return direct
        }

        let normalizedBase64 = trimmed
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let decoded = Data(base64Encoded: normalizedBase64),
           (try? JSONSerialization.jsonObject(with: decoded)) != nil {
            return decoded
        }

        return nil
    }

    private static func decodePNGTextChunk(type: String, data: Data) -> [String: String]? {
        switch type {
        case "tEXt":
            guard let separator = data.firstIndex(of: 0) else { return nil }
            let key = String(data: data[..<separator], encoding: .isoLatin1) ?? ""
            let valueData = data[data.index(after: separator)...]
            let value = String(data: valueData, encoding: .isoLatin1) ?? ""
            return [key: value]
        case "zTXt":
            guard let separator = data.firstIndex(of: 0) else { return nil }
            let key = String(data: data[..<separator], encoding: .isoLatin1) ?? ""
            let methodIndex = data.index(after: separator)
            guard methodIndex < data.endIndex else { return nil }
            let compressedDataStart = data.index(after: methodIndex)
            guard compressedDataStart <= data.endIndex else { return nil }
            let compressed = Data(data[compressedDataStart...])
            guard let decompressed = decompressZlib(compressed) else { return nil }
            let value = String(data: decompressed, encoding: .utf8) ?? String(data: decompressed, encoding: .isoLatin1) ?? ""
            return [key: value]
        case "iTXt":
            guard let keyEnd = data.firstIndex(of: 0) else { return nil }
            let key = String(data: data[..<keyEnd], encoding: .utf8) ?? ""
            var cursor = data.index(after: keyEnd)
            guard cursor < data.endIndex else { return nil }
            let compressedFlag = data[cursor]
            cursor = data.index(after: cursor)
            guard cursor < data.endIndex else { return nil }
            _ = data[cursor] // compression method
            cursor = data.index(after: cursor)

            guard let languageEnd = data[cursor...].firstIndex(of: 0) else { return nil }
            cursor = data.index(after: languageEnd)
            guard let translatedEnd = data[cursor...].firstIndex(of: 0) else { return nil }
            cursor = data.index(after: translatedEnd)

            let textData = Data(data[cursor...])
            let decoded: Data
            if compressedFlag == 1 {
                guard let inflated = decompressZlib(textData) else { return nil }
                decoded = inflated
            } else {
                decoded = textData
            }
            let value = String(data: decoded, encoding: .utf8) ?? ""
            return [key: value]
        default:
            return nil
        }
    }

    private static func readUInt32BigEndian(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset]) << 24
        let b1 = UInt32(data[offset + 1]) << 16
        let b2 = UInt32(data[offset + 2]) << 8
        let b3 = UInt32(data[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func decompressZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var capacity = max(4096, data.count * 4)
        let maxCapacity = 32 * 1024 * 1024

        while capacity <= maxCapacity {
            var output = Data(count: capacity)
            let decodedCount: Int = output.withUnsafeMutableBytes { outputRaw in
                data.withUnsafeBytes { sourceRaw in
                    guard let dst = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                          let src = sourceRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
                }
            }

            if decodedCount > 0 {
                output.count = decodedCount
                return output
            }
            capacity *= 2
        }

        return nil
    }

    // MARK: - Value helpers

    private func positionFromRaw(_ raw: Any?) -> WorldbookPosition {
        if let number = intValue(raw) {
            switch number {
            case 0: return .before
            case 1: return .after
            case 2: return .anTop
            case 3: return .anBottom
            case 4: return .atDepth
            case 5: return .emTop
            case 6: return .emBottom
            case 7: return .outlet
            default: return .after
            }
        }
        if let text = stringValue(raw) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "before_char" {
                return .before
            }
            if normalized == "after_char" {
                return .after
            }
            return WorldbookPosition(stRawValue: text)
        }
        return .after
    }

    private func deduplicateStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSString:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    private func stringArrayValue(_ value: Any?) -> [String] {
        switch value {
        case let values as [String]:
            return values
        case let values as [Any]:
            return values.compactMap { stringValue($0) }
        case let text as String:
            return text
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        default:
            return []
        }
    }

    private func jsonDictionary(from source: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in source {
            if let jsonValue = jsonValue(from: value) {
                result[key] = jsonValue
            }
        }
        return result
    }

    private func jsonValue(from any: Any) -> JSONValue? {
        switch any {
        case let value as String:
            return .string(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as Float:
            return .double(Double(value))
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            // NSNumber 可能是 Bool，需要先判断 CFTypeID
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                return .int(value.intValue)
            }
            return .double(value.doubleValue)
        case let value as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (k, v) in value {
                if let nested = jsonValue(from: v) {
                    dict[k] = nested
                }
            }
            return .dictionary(dict)
        case let value as [Any]:
            return .array(value.compactMap { jsonValue(from: $0) })
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

private struct ParsedBook {
    var name: String
    var entries: [WorldbookEntry]
    var settings: WorldbookSettings
    var metadata: [String: JSONValue]
    var failedEntries: Int
    var failureReasons: [String]
}

private func decodeJSONStringPayload(_ raw: String) -> Data? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let direct = trimmed.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: direct)) != nil {
        return direct
    }

    let normalizedBase64 = trimmed
        .replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: " ", with: "")
    if let decoded = Data(base64Encoded: normalizedBase64),
       (try? JSONSerialization.jsonObject(with: decoded)) != nil {
        return decoded
    }

    return nil
}
