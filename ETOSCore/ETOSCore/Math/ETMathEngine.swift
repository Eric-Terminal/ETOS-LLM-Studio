// ============================================================================
// ETMathEngine.swift
// ============================================================================
// ETMathEngine 共享模块
// - 提供跨平台复用的数学内容分段与探测能力
// - 实际公式渲染交给各平台的 Web/原生渲染器处理
// ============================================================================

import Foundation

public enum ETMathContentSegment: Equatable, Sendable {
    case text(String)
    case inlineMath(String)
    case blockMath(String)
}

public enum ETMathContentParser {
    public static func containsMath(in source: String) -> Bool {
        cachedSegments(for: source).contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
    }

    public static func parseSegments(in source: String) -> [ETMathContentSegment] {
        cachedSegments(for: source)
    }

    private static func cachedSegments(for source: String) -> [ETMathContentSegment] {
        ETMathContentParseCache.segments(for: source) {
            parseSegmentsUncached(in: source)
        }
    }

    private static func parseSegmentsUncached(in source: String) -> [ETMathContentSegment] {
        var segments: [ETMathContentSegment] = []
        var buffer = ""
        var index = source.startIndex

        func flushText() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < source.endIndex {
            if hasPrefix(source, at: index, prefix: "$$"),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "$$") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.blockMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\["),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "\\]") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.blockMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\("),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "\\)") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.inlineMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if source[index] == "$",
               !isEscaped(source, at: index),
               !hasPrefix(source, at: index, prefix: "$$"),
               let close = findInlineDollarEnd(source, from: source.index(after: index)) {
                flushText()
                let start = source.index(after: index)
                segments.append(.inlineMath(String(source[start..<close])))
                index = source.index(after: close)
                continue
            }

            buffer.append(source[index])
            index = source.index(after: index)
        }

        flushText()
        return segments
    }

    private static func hasPrefix(_ source: String, at index: String.Index, prefix: String) -> Bool {
        guard let end = source.index(index, offsetBy: prefix.count, limitedBy: source.endIndex) else {
            return false
        }
        return source[index..<end] == prefix
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        guard index > source.startIndex else { return false }
        return source[source.index(before: index)] == "\\"
    }

    private static func findInlineDollarEnd(_ source: String, from index: String.Index) -> String.Index? {
        var cursor = index
        while cursor < source.endIndex {
            if source[cursor] == "$",
               !isEscaped(source, at: cursor),
               !hasPrefix(source, at: cursor, prefix: "$$") {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func findDelimitedEnd(
        _ source: String,
        from index: String.Index,
        delimiter: String
    ) -> String.Index? {
        var cursor = index
        while cursor < source.endIndex {
            if hasPrefix(source, at: cursor, prefix: delimiter), !isEscaped(source, at: cursor) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}

private final class ETMathContentSegmentsBox: NSObject {
    let segments: [ETMathContentSegment]

    init(segments: [ETMathContentSegment]) {
        self.segments = segments
    }
}

private enum ETMathContentParseCache {
    private static let cache: NSCache<NSString, ETMathContentSegmentsBox> = {
        let cache = NSCache<NSString, ETMathContentSegmentsBox>()
        cache.countLimit = 256
        return cache
    }()

    static func segments(
        for source: String,
        loader: () -> [ETMathContentSegment]
    ) -> [ETMathContentSegment] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.segments
        }

        let segments = loader()
        cache.setObject(ETMathContentSegmentsBox(segments: segments), forKey: key)
        return segments
    }
}
