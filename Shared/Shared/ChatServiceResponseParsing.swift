// ============================================================================
// ChatServiceResponseParsing.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的响应正文规范化、思考标签解析、inline 图片提取与工具展示位置推断。
// ============================================================================

import Foundation

extension ChatService {
    struct InlineImageExtractionResult {
        let cleanedContent: String
        let imageFileNames: [String]
    }

    private struct InlineImagePayload {
        let data: Data
        let mimeType: String
    }

    func extractInlineImagesFromMarkdown(_ content: String) async -> InlineImageExtractionResult {
        guard !content.isEmpty else {
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)", options: [])
        } catch {
            logger.error("解析 markdown 图片正则失败: \(error.localizedDescription)")
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return InlineImageExtractionResult(cleanedContent: content, imageFileNames: [])
        }

        var workingContent = content
        var savedFileNamesInReverse: [String] = []
        var extractedCount = 0

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: content),
                  let sourceRange = Range(match.range(at: 1), in: content) else { continue }

            let rawSource = String(content[sourceRange])
            guard let normalizedSource = normalizeMarkdownImageSource(rawSource) else { continue }
            guard let payload = await resolveInlineImagePayload(from: normalizedSource) else { continue }
            guard let savedFileName = saveInlineImage(payload) else { continue }

            if let replaceRange = Range(match.range(at: 0), in: workingContent) {
                workingContent.replaceSubrange(replaceRange, with: "")
            } else {
                // 退化处理：范围映射失败时保持原文，避免误删
                logger.warning("图片标记替换失败，已跳过该标记: \(String(content[fullRange]))")
            }

            savedFileNamesInReverse.append(savedFileName)
            extractedCount += 1
        }

        if extractedCount > 0 {
            logger.info("已从 markdown 正文提取并保存 \(extractedCount) 张图片附件。")
        }

        return InlineImageExtractionResult(
            cleanedContent: normalizeContentAfterImageExtraction(workingContent),
            imageFileNames: savedFileNamesInReverse.reversed()
        )
    }

    private func normalizeMarkdownImageSource(_ rawSource: String) -> String? {
        var source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("<"), source.hasSuffix(">"), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        if let firstWhitespace = source.firstIndex(where: { $0.isWhitespace }) {
            source = String(source[..<firstWhitespace])
        }
        if source.hasPrefix("\""), source.hasSuffix("\""), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        if source.hasPrefix("'"), source.hasSuffix("'"), source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        return source.isEmpty ? nil : source
    }

    private func resolveInlineImagePayload(from source: String) async -> InlineImagePayload? {
        if let payload = decodeInlineDataURL(source) {
            return payload
        }

        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let contentType, !contentType.lowercased().hasPrefix("image/") {
                return nil
            }
            let mimeType = contentType ?? detectImageMimeType(from: data)
            return InlineImagePayload(data: data, mimeType: mimeType)
        } catch {
            logger.warning("下载 markdown 图片失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func decodeInlineDataURL(_ source: String) -> InlineImagePayload? {
        let lowercased = source.lowercased()
        guard lowercased.hasPrefix("data:image/"),
              let commaIndex = source.firstIndex(of: ",") else {
            return nil
        }

        let header = String(source[source.index(source.startIndex, offsetBy: 5)..<commaIndex])
        guard header.lowercased().contains(";base64") else {
            return nil
        }

        let mimeType = header.split(separator: ";").first.map(String.init) ?? "image/png"
        let encoded = String(source[source.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return InlineImagePayload(data: data, mimeType: mimeType)
    }

    private func saveInlineImage(_ payload: InlineImagePayload) -> String? {
        let ext = imageFileExtension(for: payload.mimeType)
        let fileName = "\(UUID().uuidString).\(ext)"
        guard Persistence.saveImage(payload.data, fileName: fileName) != nil else {
            logger.error("保存 markdown 提取图片失败: \(fileName)")
            return nil
        }
        return fileName
    }

    private func normalizeContentAfterImageExtraction(_ content: String) -> String {
        let normalizedLineBreaks = content.replacingOccurrences(of: "\r\n", with: "\n")
        let collapsed = normalizedLineBreaks.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectImageMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "image/png" }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        return "image/png"
    }

    func imageFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "png"
        }
    }

    /// 仅当思考标签位于回复开头时，才解析并移除其中内容。
    func parseThoughtTags(from text: String) -> (content: String, reasoning: String) {
        var scanIndex = text.startIndex
        var reasoningSegments: [String] = []

        while let block = leadingThoughtBlock(in: text, from: scanIndex) {
            reasoningSegments.append(block.reasoning)
            scanIndex = block.upperBound
        }

        guard !reasoningSegments.isEmpty else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let remainingContent = String(text[scanIndex...])
        return (remainingContent.trimmingCharacters(in: .whitespacesAndNewlines), reasoningSegments.joined(separator: "\n\n"))
    }

    private func leadingThoughtBlock(in text: String, from startIndex: String.Index) -> (reasoning: String, upperBound: String.Index)? {
        let tagNames = ["thought", "thinking", "think"]
        var tagStart = startIndex
        while tagStart < text.endIndex, text[tagStart].isWhitespace {
            tagStart = text.index(after: tagStart)
        }
        guard tagStart < text.endIndex else { return nil }

        for tagName in tagNames {
            let startTag = "<\(tagName)>"
            guard text[tagStart...].hasPrefix(startTag) else { continue }
            let bodyStart = text.index(tagStart, offsetBy: startTag.count)
            let endTag = "</\(tagName)>"
            guard let endRange = text.range(of: endTag, range: bodyStart..<text.endIndex) else {
                return nil
            }
            return (String(text[bodyStart..<endRange.lowerBound]), endRange.upperBound)
        }
        return nil
    }

    func updateReasoningTimingFromInlineThoughtTags(
        in contentPart: String,
        receivedAt: Date,
        reasoningStartedAt: inout Date?,
        reasoningLastDeltaAt: inout Date?,
        reasoningCompletedAt: inout Date?,
        isInsideInlineReasoning: inout Bool,
        mayStartAtContentStart: inout Bool,
        detectionTail: inout String
    ) {
        guard !contentPart.isEmpty else { return }

        let scanText = (detectionTail + contentPart).lowercased()
        let startTags = ["<thought>", "<thinking>", "<think>"]
        let endTags = ["</thought>", "</thinking>", "</think>"]
        var searchIndex = scanText.startIndex
        var touchedReasoning = false

        while searchIndex < scanText.endIndex {
            if isInsideInlineReasoning {
                touchedReasoning = true
                guard let endRange = earliestTagRange(in: scanText, tags: endTags, from: searchIndex) else {
                    break
                }
                reasoningLastDeltaAt = receivedAt
                reasoningCompletedAt = receivedAt
                isInsideInlineReasoning = false
                searchIndex = endRange.upperBound
            } else {
                guard mayStartAtContentStart else { break }
                guard let firstContentIndex = firstNonWhitespaceIndex(in: scanText, from: searchIndex) else {
                    break
                }
                let remainingText = scanText[firstContentIndex...]
                guard let startTag = startTags.first(where: { remainingText.hasPrefix($0) }) else {
                    if !startTags.contains(where: { $0.hasPrefix(String(remainingText)) }) {
                        mayStartAtContentStart = false
                    }
                    break
                }
                let startTagEnd = scanText.index(firstContentIndex, offsetBy: startTag.count)
                if reasoningStartedAt == nil {
                    reasoningStartedAt = receivedAt
                }
                reasoningCompletedAt = nil
                isInsideInlineReasoning = true
                touchedReasoning = true
                searchIndex = startTagEnd
            }
        }

        if touchedReasoning && isInsideInlineReasoning {
            reasoningLastDeltaAt = receivedAt
        }
        detectionTail = String(scanText.suffix(10))
    }

    private func earliestTagRange(in text: String, tags: [String], from startIndex: String.Index) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        let searchRange = startIndex..<text.endIndex
        for tag in tags {
            guard let range = text.range(of: tag, range: searchRange) else { continue }
            if let current = earliest {
                if range.lowerBound < current.lowerBound {
                    earliest = range
                }
            } else {
                earliest = range
            }
        }
        return earliest
    }

    private func firstNonWhitespaceIndex(in text: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        while index < text.endIndex {
            if !text[index].isWhitespace {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    func inferredToolCallsPlacement(from content: String) -> ToolCallsPlacement {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .afterReasoning
        }
        let lowered = trimmed.lowercased()
        let startsWithThought = lowered.hasPrefix("<thought") || lowered.hasPrefix("<thinking") || lowered.hasPrefix("<think")
        if startsWithThought {
            let hasClosing = lowered.contains("</thought>") || lowered.contains("</thinking>") || lowered.contains("</think>")
            if !hasClosing {
                return .afterReasoning
            }
        }

        let (contentWithoutThought, _) = parseThoughtTags(from: content)
        if !contentWithoutThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .afterContent
        }
        if lowered.contains("<thought") || lowered.contains("<thinking") || lowered.contains("<think") {
            return .afterReasoning
        }
        return .afterContent
    }

    func normalizeEscapedNewlinesIfNeeded(_ text: String) -> String {
        guard text.contains("\\n") || text.contains("\\r") else { return text }
        let hasActualNewline = text.contains("\n") || text.contains("\r")
        guard !hasActualNewline else { return text }
        return text
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
    }
}
