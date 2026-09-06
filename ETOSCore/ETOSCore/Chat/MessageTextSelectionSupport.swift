// ============================================================================
// MessageTextSelectionSupport.swift
// ============================================================================
// 为消息文字选择页准备连续纯文本，并记录其到原始 Markdown 的位置映射。
// ============================================================================

import Foundation

public struct MessageRewriteSelectionTarget: Hashable, Sendable {
    public let displayText: String
    public let sourceText: String
    public let sourceUTF16Range: Range<Int>

    public init(
        displayText: String,
        sourceText: String,
        sourceUTF16Range: Range<Int>
    ) {
        self.displayText = displayText
        self.sourceText = sourceText
        self.sourceUTF16Range = sourceUTF16Range
    }

    public func replacingSelection(in markdown: String, with replacement: String) -> String? {
        let source = markdown as NSString
        guard sourceUTF16Range.lowerBound >= 0,
              sourceUTF16Range.upperBound <= source.length else {
            return nil
        }

        let range = NSRange(
            location: sourceUTF16Range.lowerBound,
            length: sourceUTF16Range.count
        )
        guard source.substring(with: range) == sourceText else {
            return nil
        }
        return source.replacingCharacters(in: range, with: replacement)
    }
}

public struct MessageSelectableTextDocument: Sendable {
    public let plainText: String

    private let sourceMarkdown: String
    private let sourceRangesByDisplayUTF16Offset: [Range<Int>?]

    fileprivate init(
        plainText: String,
        sourceMarkdown: String,
        sourceRangesByDisplayUTF16Offset: [Range<Int>?]
    ) {
        self.plainText = plainText
        self.sourceMarkdown = sourceMarkdown
        self.sourceRangesByDisplayUTF16Offset = sourceRangesByDisplayUTF16Offset
    }

    public func rewriteTarget(
        displayUTF16Range: Range<Int>
    ) -> MessageRewriteSelectionTarget? {
        guard !displayUTF16Range.isEmpty,
              displayUTF16Range.lowerBound >= 0,
              displayUTF16Range.upperBound <= sourceRangesByDisplayUTF16Offset.count else {
            return nil
        }

        let mappings = sourceRangesByDisplayUTF16Offset[displayUTF16Range]
        guard let first = mappings.first ?? nil,
              let last = mappings.last ?? nil,
              mappings.allSatisfy({ $0 != nil }) else {
            return nil
        }

        let sourceRange = first.lowerBound..<last.upperBound
        guard !sourceRange.isEmpty else { return nil }

        let displayRange = NSRange(
            location: displayUTF16Range.lowerBound,
            length: displayUTF16Range.count
        )
        let displayText = (plainText as NSString).substring(with: displayRange)
        guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let sourceText = (sourceMarkdown as NSString).substring(
            with: NSRange(location: sourceRange.lowerBound, length: sourceRange.count)
        )
        return MessageRewriteSelectionTarget(
            displayText: displayText,
            sourceText: sourceText,
            sourceUTF16Range: sourceRange
        )
    }
}

public enum MessageTextSelectionSupport {
    public static func selectableDocument(fromMarkdown markdown: String) -> MessageSelectableTextDocument {
        let normalized = NormalizedMarkdown(markdown)
        let lines = normalized.lines()
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        var renderedLines: [RenderedLine] = []
        renderedLines.reserveCapacity(lines.count)
        var codeFenceMarker: Character?

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(in: trimmed) {
                if codeFenceMarker == nil {
                    codeFenceMarker = marker
                } else if codeFenceMarker == marker {
                    codeFenceMarker = nil
                }
                continue
            }

            if codeFenceMarker != nil {
                renderedLines.append(
                    RenderedLine(
                        text: line.text,
                        sourceRanges: line.sourceRanges,
                        newlineSourceRange: line.newlineSourceRange
                    )
                )
                continue
            }

            if isHorizontalRule(trimmed) {
                continue
            }

            let blockStripped = strippingBlockPrefix(from: line.text)
            let blockMappings = align(
                output: blockStripped,
                source: line.text,
                sourceRanges: line.sourceRanges,
                mapsSyntheticListBullet: true,
                mapsDecodedEntities: false
            )
            let attributed = try? AttributedString(markdown: blockStripped, options: options)
            let rendered = attributed.map { String($0.characters) } ?? blockStripped
            let renderedMappings = align(
                output: rendered,
                source: blockStripped,
                sourceRanges: blockMappings,
                mapsSyntheticListBullet: false,
                mapsDecodedEntities: true
            )
            renderedLines.append(
                RenderedLine(
                    text: rendered,
                    sourceRanges: renderedMappings,
                    newlineSourceRange: line.newlineSourceRange
                )
            )
        }

        while renderedLines.last?.text.isEmpty == true {
            renderedLines.removeLast()
        }

        var plainText = ""
        var mappings: [Range<Int>?] = []
        for (index, line) in renderedLines.enumerated() {
            if index > 0 {
                plainText.append("\n")
                mappings.append(renderedLines[index - 1].newlineSourceRange)
            }
            plainText.append(line.text)
            mappings.append(contentsOf: line.sourceRanges)
        }

        return MessageSelectableTextDocument(
            plainText: plainText,
            sourceMarkdown: markdown,
            sourceRangesByDisplayUTF16Offset: mappings
        )
    }

    public static func plainText(fromMarkdown markdown: String) -> String {
        selectableDocument(fromMarkdown: markdown).plainText
    }

    public static func substring(
        in text: String,
        characterRange: Range<Int>
    ) -> String {
        let lowerBound = min(max(characterRange.lowerBound, 0), text.count)
        let upperBound = min(max(characterRange.upperBound, lowerBound), text.count)
        let start = text.index(text.startIndex, offsetBy: lowerBound)
        let end = text.index(text.startIndex, offsetBy: upperBound)
        return String(text[start..<end])
    }

    private static func align(
        output: String,
        source: String,
        sourceRanges: [Range<Int>?],
        mapsSyntheticListBullet: Bool,
        mapsDecodedEntities: Bool
    ) -> [Range<Int>?] {
        let outputUnits = Array(output.utf16)
        let sourceUnits = Array(source.utf16)
        guard sourceUnits.count == sourceRanges.count else {
            return Array(repeating: nil, count: outputUnits.count)
        }

        var mappings: [Range<Int>?] = []
        mappings.reserveCapacity(outputUnits.count)
        var sourceCursor = 0
        var mapsNextListBullet = mapsSyntheticListBullet

        var outputIndex = 0
        while outputIndex < outputUnits.count {
            let outputUnit = outputUnits[outputIndex]
            if mapsNextListBullet, outputUnit == 0x2022,
               let markerIndex = nextListMarker(in: sourceUnits, from: sourceCursor) {
                mappings.append(sourceRanges[markerIndex])
                sourceCursor = markerIndex + 1
                mapsNextListBullet = false
                outputIndex += 1
                continue
            }

            let matchedIndex = sourceUnits[sourceCursor...].firstIndex(of: outputUnit)
            let nextAmpersand = sourceUnits[sourceCursor...].firstIndex(of: 0x0026)
            let shouldCheckEntity: Bool
            if !mapsDecodedEntities {
                shouldCheckEntity = false
            } else if let matchedIndex {
                shouldCheckEntity = nextAmpersand.map { $0 <= matchedIndex } == true
            } else {
                shouldCheckEntity = true
            }
            if shouldCheckEntity,
               let entity = nextDecodedEntity(
                    in: sourceUnits,
                    from: sourceCursor,
                    matching: outputUnits[outputIndex...]
               ), matchedIndex.map({ entity.sourceRange.lowerBound <= $0 }) ?? true {
                let mapping = mergedRange(in: sourceRanges, range: entity.sourceRange)
                mappings.append(contentsOf: repeatElement(mapping, count: entity.outputLength))
                sourceCursor = entity.sourceRange.upperBound
                outputIndex += entity.outputLength
                continue
            }

            guard let matchedIndex else {
                mappings.append(nil)
                outputIndex += 1
                continue
            }

            if matchedIndex > sourceCursor,
               matchedIndex > 0,
               sourceUnits[matchedIndex - 1] == 0x005C,
               isMarkdownEscapable(outputUnit) {
                mappings.append(mergedRange(in: sourceRanges, range: (matchedIndex - 1)..<(matchedIndex + 1)))
            } else {
                mappings.append(sourceRanges[matchedIndex])
            }
            sourceCursor = matchedIndex + 1
            outputIndex += 1
        }

        return mappings
    }

    private static func mergedRange(
        in mappings: [Range<Int>?],
        range: Range<Int>
    ) -> Range<Int>? {
        let available = mappings[range].compactMap { $0 }
        guard let first = available.first, let last = available.last else { return nil }
        return first.lowerBound..<last.upperBound
    }

    private static func nextListMarker(in units: [UInt16], from start: Int) -> Int? {
        guard start < units.count else { return nil }
        return units.indices[start...].first { index in
            guard units[index] == 0x002D || units[index] == 0x002A || units[index] == 0x002B,
                  index + 1 < units.count else {
                return false
            }
            return units[index + 1] == 0x0020 || units[index + 1] == 0x0009
        }
    }

    private static func isMarkdownEscapable(_ unit: UInt16) -> Bool {
        guard unit < 128, let scalar = UnicodeScalar(Int(unit)) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static func nextDecodedEntity(
        in units: [UInt16],
        from start: Int,
        matching output: ArraySlice<UInt16>
    ) -> DecodedEntity? {
        var cursor = start
        while cursor < units.count {
            guard let ampersand = units[cursor...].firstIndex(of: 0x0026) else { return nil }
            if let entity = decodedEntity(in: units, from: ampersand),
               output.starts(with: entity.outputUnits) {
                return entity
            }
            cursor = ampersand + 1
        }
        return nil
    }

    private static func decodedEntity(in units: [UInt16], from start: Int) -> DecodedEntity? {
        guard units[start] == 0x0026 else { return nil }
        let upperBound = min(start + 32, units.count)
        guard let semicolonIndex = units[(start + 1)..<upperBound].firstIndex(of: 0x003B) else {
            return nil
        }
        let sourceRange = start..<(semicolonIndex + 1)
        let entityText = String(decoding: units[sourceRange], as: UTF16.self)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: entityText, options: options) else {
            return nil
        }
        let decoded = String(attributed.characters)
        guard decoded != entityText, !decoded.isEmpty else { return nil }
        return DecodedEntity(
            sourceRange: sourceRange,
            outputUnits: Array(decoded.utf16)
        )
    }

    private static func fenceMarker(in trimmedLine: String) -> Character? {
        guard let marker = trimmedLine.first, marker == "`" || marker == "~" else {
            return nil
        }
        return trimmedLine.prefix { $0 == marker }.count >= 3 ? marker : nil
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        let compact = trimmedLine.filter { !$0.isWhitespace }
        guard compact.count >= 3,
              let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func strippingBlockPrefix(from line: String) -> String {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        var body = line.dropFirst(leadingWhitespace.count)

        while body.first == ">" {
            body = body.dropFirst()
            if body.first == " " {
                body = body.dropFirst()
            }
        }

        let headingMarkerCount = body.prefix { $0 == "#" }.count
        if (1...6).contains(headingMarkerCount) {
            let afterHeading = body.dropFirst(headingMarkerCount)
            if afterHeading.isEmpty || afterHeading.first?.isWhitespace == true {
                body = afterHeading.drop(while: { $0.isWhitespace })
            }
        }

        if let marker = body.first,
           marker == "-" || marker == "*" || marker == "+",
           body.dropFirst().first?.isWhitespace == true {
            body = body.dropFirst(2)
            return String(leadingWhitespace) + "• " + String(body)
        }

        return String(leadingWhitespace) + String(body)
    }
}

private struct RenderedLine {
    let text: String
    let sourceRanges: [Range<Int>?]
    let newlineSourceRange: Range<Int>?
}

private struct DecodedEntity {
    let sourceRange: Range<Int>
    let outputUnits: [UInt16]

    var outputLength: Int { outputUnits.count }
}

private struct NormalizedMarkdown {
    let text: String
    let sourceRanges: [Range<Int>]

    init(_ source: String) {
        let sourceUnits = Array(source.utf16)
        var normalizedUnits: [UInt16] = []
        var mappings: [Range<Int>] = []
        normalizedUnits.reserveCapacity(sourceUnits.count)
        mappings.reserveCapacity(sourceUnits.count)

        var index = 0
        while index < sourceUnits.count {
            if sourceUnits[index] == 0x000D {
                let upperBound = index + 1 < sourceUnits.count && sourceUnits[index + 1] == 0x000A
                    ? index + 2
                    : index + 1
                normalizedUnits.append(0x000A)
                mappings.append(index..<upperBound)
                index = upperBound
            } else {
                normalizedUnits.append(sourceUnits[index])
                mappings.append(index..<(index + 1))
                index += 1
            }
        }

        text = String(decoding: normalizedUnits, as: UTF16.self)
        sourceRanges = mappings
    }

    func lines() -> [NormalizedLine] {
        let units = Array(text.utf16)
        var lines: [NormalizedLine] = []
        var lineStart = 0

        for index in units.indices where units[index] == 0x000A {
            lines.append(makeLine(range: lineStart..<index, newlineIndex: index))
            lineStart = index + 1
        }
        lines.append(makeLine(range: lineStart..<units.count, newlineIndex: nil))
        return lines
    }

    private func makeLine(range: Range<Int>, newlineIndex: Int?) -> NormalizedLine {
        let text = (self.text as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count)
        )
        return NormalizedLine(
            text: text,
            sourceRanges: Array(sourceRanges[range]),
            newlineSourceRange: newlineIndex.map { sourceRanges[$0] }
        )
    }
}

private struct NormalizedLine {
    let text: String
    let sourceRanges: [Range<Int>?]
    let newlineSourceRange: Range<Int>?
}
