import Foundation

/// 仅供 MetricKit 超限报告恢复使用。先扫描值边界，再解码有限深度和大小的片段；
/// 跳过的子树不交给 Foundation，避免深层 JSON 在解析和释放时耗尽栈。
enum TelemetryBoundedJSONReader {
    static func read(_ data: Data) throws -> [String: Any] {
        try data.withUnsafeBytes { rawBuffer in
            var reader = Reader(bytes: rawBuffer.bindMemory(to: UInt8.self))
            var position = 0
            let range = try reader.valueRange(at: &position)
            reader.skipWhitespace(&position)
            guard position == reader.bytes.count, reader.bytes[range.lowerBound] == 0x7B,
                  let object = try reader.decode(range, depth: 0, key: nil) as? [String: Any] else {
                throw TelemetryEnvelopeError.payloadIsNotJSONObject
            }
            return object
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var remainingValues = 30_000
        var remainingScalarBytes = 2 * 1_024 * 1_024
        let maximumDepth = 96
        let maximumChildren = 4_096

        func skipWhitespace(_ position: inout Int) {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        func stringEnd(at start: Int) throws -> Int {
            var position = start + 1
            var escaped = false
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { return position }
            }
            throw corruptJSON()
        }

        func valueRange(at position: inout Int) throws -> Range<Int> {
            skipWhitespace(&position)
            guard position < bytes.count else { throw corruptJSON() }
            let start = position
            if bytes[position] == 0x22 {
                position = try stringEnd(at: position)
            } else if bytes[position] == 0x7B || bytes[position] == 0x5B {
                var depth = 0
                repeat {
                    guard position < bytes.count else { throw corruptJSON() }
                    switch bytes[position] {
                    case 0x22:
                        position = try stringEnd(at: position)
                        continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1
                    default: break
                    }
                    position += 1
                } while depth > 0
            } else {
                while position < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D, 0x5D].contains(bytes[position]) {
                    position += 1
                }
            }
            guard position > start else { throw corruptJSON() }
            return start..<position
        }

        func fragment(_ range: Range<Int>) throws -> Any {
            let data = Data(bytes: bytes.baseAddress!.advanced(by: range.lowerBound), count: range.count)
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        func objectMembers(_ range: Range<Int>) throws -> [(String, Range<Int>)] {
            var members: [(String, Range<Int>)] = []
            var position = range.lowerBound + 1
            skipWhitespace(&position)
            if position < range.upperBound, bytes[position] == 0x7D { return members }
            while position < range.upperBound {
                guard bytes[position] == 0x22 else { throw corruptJSON() }
                let keyStart = position
                position = try stringEnd(at: position)
                let keyRange = keyStart..<position
                skipWhitespace(&position)
                guard position < range.upperBound, bytes[position] == 0x3A else { throw corruptJSON() }
                position += 1
                let value = try valueRange(at: &position)
                if members.count < 128, keyRange.count <= 1_024,
                   let key = try fragment(keyRange) as? String {
                    members.append((key, value))
                }
                skipWhitespace(&position)
                guard position < range.upperBound else { throw corruptJSON() }
                if bytes[position] == 0x7D { return members }
                guard bytes[position] == 0x2C else { throw corruptJSON() }
                position += 1
                skipWhitespace(&position)
            }
            throw corruptJSON()
        }

        func arrayElements(_ range: Range<Int>) throws -> [Range<Int>] {
            var elements: [Range<Int>] = []
            var position = range.lowerBound + 1
            skipWhitespace(&position)
            if position < range.upperBound, bytes[position] == 0x5D { return elements }
            while position < range.upperBound {
                let value = try valueRange(at: &position)
                if elements.count < maximumChildren { elements.append(value) }
                skipWhitespace(&position)
                guard position < range.upperBound else { throw corruptJSON() }
                if bytes[position] == 0x5D { return elements }
                guard bytes[position] == 0x2C else { throw corruptJSON() }
                position += 1
                skipWhitespace(&position)
            }
            throw corruptJSON()
        }

        mutating func decode(_ range: Range<Int>, depth: Int, key: String?) throws -> Any {
            guard remainingValues > 0, depth < maximumDepth else {
                switch bytes[range.lowerBound] {
                case 0x7B: return [String: Any]()
                case 0x5B: return [Any]()
                default: return NSNull()
                }
            }
            remainingValues -= 1
            switch bytes[range.lowerBound] {
            case 0x7B:
                // 元数据和异常类型先于调用栈，避免大栈消耗完预算后无法归因版本。
                let members = try objectMembers(range).sorted {
                    let left = priority($0.0)
                    let right = priority($1.0)
                    return left == right ? $0.0 < $1.0 : left < right
                }
                var object: [String: Any] = [:]
                for (key, value) in members where remainingValues > 0 {
                    object[key] = try decode(value, depth: depth + 1, key: key)
                }
                return object
            case 0x5B:
                var elements = try arrayElements(range)
                if key == "callStacks" {
                    // 线程顺序不是归因依据；只提升明确标记的线程，并保留其余线程的相对顺序。
                    var attributed: [Range<Int>] = []
                    var other: [Range<Int>] = []
                    for element in elements {
                        if bytes[element.lowerBound] == 0x7B,
                           let marker = try objectMembers(element).first(where: { $0.0 == "threadAttributed" }),
                           marker.1.count == 4, bytes[marker.1.lowerBound] == 0x74 {
                            attributed.append(element)
                        } else { other.append(element) }
                    }
                    elements = attributed + other
                }
                var array: [Any] = []
                for element in elements where remainingValues > 0 {
                    array.append(try decode(element, depth: depth + 1, key: nil))
                }
                return array
            default:
                guard range.count <= min(16_384, remainingScalarBytes) else { return NSNull() }
                remainingScalarBytes -= range.count
                return try fragment(range)
            }
        }

        private func priority(_ key: String) -> Int {
            switch key.lowercased() {
            case "metadata", "diagnosticmetadata", "threadattributed": return 0
            case "callstacktree", "callstacks", "callstackrootframes", "subframes": return 2
            default: return 1
            }
        }

        private func corruptJSON() -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue)
        }
    }
}
