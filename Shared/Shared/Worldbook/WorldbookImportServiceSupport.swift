// ============================================================================
// WorldbookImportServiceSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接世界书导入服务的 PNG naidata 解析、值转换辅助与中间解析模型。
// ============================================================================

import Foundation
import Compression

extension WorldbookImportService {
    func appendFailureReason(_ reason: String, to reasons: inout [String]) {
        guard reasons.count < 20 else { return }
        reasons.append(reason)
    }

    func positionFromRaw(_ raw: Any?) -> WorldbookPosition {
        if let number = intValue(raw) {
            switch number {
            case 0: return .before
            case 1: return .after
            case 2: return .emTop
            case 3: return .emTop
            case 4: return .atDepth
            case 5: return .emTop
            case 6: return .emBottom
            case 7: return .outlet
            default: return .after
            }
        }
        if let text = stringValue(raw) {
            let normalized = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            if normalized == "before_char" || normalized == "before_system_prompt" {
                return .before
            }
            if normalized == "after_char" || normalized == "after_system_prompt" {
                return .after
            }
            if normalized == "top_of_chat" { return .emTop }
            if normalized == "bottom_of_chat" { return .emBottom }
            if normalized == "at_depth" { return .atDepth }
            return WorldbookPosition(stRawValue: text)
        }
        return .after
    }

    func deduplicateStrings(_ values: [String]) -> [String] {
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

    func stringValue(_ value: Any?) -> String? {
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

    func intValue(_ value: Any?) -> Int? {
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

    func doubleValue(_ value: Any?) -> Double? {
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

    func boolValue(_ value: Any?) -> Bool? {
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

    func stringArrayValue(_ value: Any?) -> [String] {
        switch value {
        case let values as [String]:
            return values
        case let values as [Any]:
            return values.compactMap { stringValue($0) }
        case let text as String:
            return text
                .replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
                .replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "，", with: ",")
                .split { character in
                    character == "," || character == "\n" || character == "\r"
                }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        default:
            return []
        }
    }

    func jsonDictionary(from source: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in source {
            if let jsonValue = jsonValue(from: value) {
                result[key] = jsonValue
            }
        }
        return result
    }

    func jsonValue(from any: Any) -> JSONValue? {
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

struct ParsedBook {
    var name: String
    var description: String
    var entries: [WorldbookEntry]
    var settings: WorldbookSettings
    var metadata: [String: JSONValue]
    var failedEntries: Int
    var failureReasons: [String]
}

func decodeJSONStringPayload(_ raw: String) -> Data? {
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

extension WorldbookImportService {
    // MARK: - PNG naidata

    static func isPNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Array(data.prefix(8)) == signature
    }

    static func extractNaiDataJSON(fromPNG data: Data) -> Data? {
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

    static func decodeNaiDataPayload(_ payload: String) -> Data? {
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

    static func decodePNGTextChunk(type: String, data: Data) -> [String: String]? {
        switch type {
        case "tEXt":
            guard let separator = data.firstIndex(of: 0) else { return nil }
            let key = String(data: data[..<separator], encoding: .isoLatin1) ?? ""
            let valueData = data[data.index(after: separator)...]
            let value = String(data: valueData, encoding: .utf8) ?? String(data: valueData, encoding: .isoLatin1) ?? ""
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
            _ = data[cursor]
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

    static func readUInt32BigEndian(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset]) << 24
        let b1 = UInt32(data[offset + 1]) << 16
        let b2 = UInt32(data[offset + 2]) << 8
        let b3 = UInt32(data[offset + 3])
        return b0 | b1 | b2 | b3
    }

    static func decompressZlib(_ data: Data) -> Data? {
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
}
