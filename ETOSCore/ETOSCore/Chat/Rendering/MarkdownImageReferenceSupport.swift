// ============================================================================
// MarkdownImageReferenceSupport.swift
// ============================================================================
// ETOSCore
//
// 从 Markdown AST 中提取可下载图片及其原始源码范围，供内联显示、下载与
// 用户主动转换附件共用同一套语义。
// ============================================================================

import Foundation
import Markdown

public struct MarkdownImageReference: Equatable, Sendable {
    public let source: String
    public let sourceUTF16Range: NSRange

    public init(source: String, sourceUTF16Range: NSRange) {
        self.source = source
        self.sourceUTF16Range = sourceUTF16Range
    }
}

public enum MarkdownImageReferenceSupport {
    public static func downloadableReferences(in source: String) -> [MarkdownImageReference] {
        guard !source.isEmpty else { return [] }

        var collector = ImageCollector(source: source)
        collector.visit(Document(parsing: source))
        return collector.references
    }

    public static func downloadableSources(in source: String) -> [String] {
        downloadableReferences(in: source).map(\.source)
    }

    public static func hasDownloadableImage(in source: String) -> Bool {
        !downloadableReferences(in: source).isEmpty
    }
}

private extension MarkdownImageReferenceSupport {
    struct ImageCollector: MarkupWalker {
        let source: String
        let converter: SourceIndexConverter
        var references: [MarkdownImageReference] = []

        init(source: String) {
            self.source = source
            self.converter = SourceIndexConverter(source: source)
        }

        mutating func visitImage(_ image: Markdown.Image) {
            guard let rawSource = image.source,
                  let normalizedSource = normalizedDownloadableSource(rawSource),
                  let sourceRange = image.range,
                  let lowerBound = converter.index(for: sourceRange.lowerBound),
                  let upperBound = converter.index(for: sourceRange.upperBound),
                  lowerBound <= upperBound else {
                return
            }

            references.append(
                MarkdownImageReference(
                    source: normalizedSource,
                    sourceUTF16Range: NSRange(lowerBound..<upperBound, in: source)
                )
            )
        }

        private func normalizedDownloadableSource(_ rawSource: String) -> String? {
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return nil }

            if source.lowercased().hasPrefix("data:image/") {
                return source
            }
            guard let url = URL(string: source),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return source
        }
    }

    // swift-markdown 的列号使用 UTF-8 字节，必须先换算后才能生成 NSString 范围。
    struct SourceIndexConverter {
        let source: String
        let lineStarts: [String.UTF8View.Index]

        init(source: String) {
            self.source = source
            var starts = [source.utf8.startIndex]
            var index = source.utf8.startIndex
            while index < source.utf8.endIndex {
                let nextIndex = source.utf8.index(after: index)
                if source.utf8[index] == 0x0A {
                    starts.append(nextIndex)
                }
                index = nextIndex
            }
            self.lineStarts = starts
        }

        func index(for location: SourceLocation) -> String.Index? {
            guard location.line > 0,
                  location.line <= lineStarts.count,
                  location.column > 0 else {
                return nil
            }
            let lineStart = lineStarts[location.line - 1]
            let lineEnd = location.line < lineStarts.count
                ? lineStarts[location.line]
                : source.utf8.endIndex
            guard let utf8Index = source.utf8.index(
                lineStart,
                offsetBy: location.column - 1,
                limitedBy: lineEnd
            ) else {
                return nil
            }
            return utf8Index.samePosition(in: source)
        }
    }
}
