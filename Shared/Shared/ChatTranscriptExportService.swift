// ============================================================================
// ChatTranscriptExportService.swift
// ============================================================================
// ChatTranscriptExportService 会话文本导出模块
// - 支持导出 PDF / Markdown / TXT
// - 支持导出完整会话或“截至某条消息”的上文片段
// ============================================================================

import Foundation
import CoreGraphics
import CoreText

public enum ChatTranscriptExportFormat: String, CaseIterable, Sendable {
    case pdf
    case markdown
    case text

    public var fileExtension: String {
        switch self {
        case .pdf:
            return "pdf"
        case .markdown:
            return "md"
        case .text:
            return "txt"
        }
    }

    public var displayName: String {
        switch self {
        case .pdf:
            return "PDF"
        case .markdown:
            return "Markdown"
        case .text:
            return "TXT"
        }
    }
}

public struct ChatTranscriptExportOutput: Sendable {
    public let data: Data
    public let format: ChatTranscriptExportFormat
    public let suggestedFileName: String

    public init(data: Data, format: ChatTranscriptExportFormat, suggestedFileName: String) {
        self.data = data
        self.format = format
        self.suggestedFileName = suggestedFileName
    }
}

public enum ChatTranscriptExportError: LocalizedError {
    case emptyMessages
    case messageNotFound
    case pdfRenderFailed

    public var errorDescription: String? {
        switch self {
        case .emptyMessages:
            return "导出失败：当前会话没有可导出的消息。"
        case .messageNotFound:
            return "导出失败：未找到指定的消息。"
        case .pdfRenderFailed:
            return "导出失败：无法生成 PDF 文件。"
        }
    }
}

public struct ChatTranscriptExportService {
    public init() {}

    public func export(
        session: ChatSession?,
        messages: [ChatMessage],
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool = true,
        upToMessageID: UUID? = nil,
        exportedAt: Date = Date()
    ) throws -> ChatTranscriptExportOutput {
        let scopedMessages = try resolveScopedMessages(messages, upToMessageID: upToMessageID)
        let context = ExportContext(
            session: session,
            messages: scopedMessages,
            format: format,
            includeReasoning: includeReasoning,
            exportedAt: exportedAt,
            upToMessageID: upToMessageID,
            sourceCount: messages.count
        )

        let data: Data
        switch format {
        case .pdf:
            let markdown = buildMarkdown(context)
            data = try makePDF(fromMarkdown: markdown)
        case .markdown:
            let markdown = buildMarkdown(context)
            data = Data(markdown.utf8)
        case .text:
            let plain = buildPlainText(context)
            data = Data(plain.utf8)
        }

        return ChatTranscriptExportOutput(
            data: data,
            format: format,
            suggestedFileName: suggestedFileName(context)
        )
    }

    private func resolveScopedMessages(_ messages: [ChatMessage], upToMessageID: UUID?) throws -> [ChatMessage] {
        guard !messages.isEmpty else {
            throw ChatTranscriptExportError.emptyMessages
        }
        guard let upToMessageID else {
            return messages
        }
        guard let index = messages.firstIndex(where: { $0.id == upToMessageID }) else {
            throw ChatTranscriptExportError.messageNotFound
        }
        let scoped = Array(messages[...index])
        guard !scoped.isEmpty else {
            throw ChatTranscriptExportError.emptyMessages
        }
        return scoped
    }

    private func suggestedFileName(_ context: ExportContext) -> String {
        let sessionName = context.session?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizeFileName(sessionName?.isEmpty == false ? sessionName! : "会话导出")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: context.exportedAt)

        let scopeSuffix: String
        if context.upToMessageID != nil {
            scopeSuffix = "-截至第\(context.messages.count)条"
        } else {
            scopeSuffix = "-完整"
        }

        let reasoningSuffix = context.includeReasoning ? "-含思考" : "-不含思考"
        return "\(baseName)\(scopeSuffix)\(reasoningSuffix)-\(stamp).\(context.format.fileExtension)"
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "会话导出" : sanitized
    }

    private func buildMarkdown(_ context: ExportContext) -> String {
        var lines: [String] = []
        lines.reserveCapacity(context.messages.count * 8 + 16)

        lines.append("# 会话导出")
        lines.append("")
        lines.append("- 会话名称：\(context.session?.name ?? "未命名会话")")
        lines.append("- 导出时间：\(formattedDateTime(context.exportedAt))")
        lines.append("- 导出范围：\(scopeDescription(context))")
        lines.append("- 思考/推理：\(context.includeReasoning ? "包含" : "不包含")")
        lines.append("- 消息数量：\(context.messages.count)")

        appendPromptLinesIfNeeded(for: context.session, markdownLines: &lines)

        lines.append("")
        lines.append("---")
        lines.append("")

        for (index, message) in context.messages.enumerated() {
            lines.append("## \(index + 1). \(roleTitle(message.role))")
            lines.append("")
            lines.append(messageBodyOrPlaceholder(message.content))
            lines.append("")

            if context.includeReasoning, let reasoning = trimmedOrNil(message.reasoningContent) {
                lines.append("### 推理")
                lines.append("")
                lines.append(reasoning)
                lines.append("")
            }

            appendToolCallsMarkdownIfNeeded(message.toolCalls, lines: &lines)
            appendAttachmentsMarkdownIfNeeded(message, lines: &lines)
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func buildPlainText(_ context: ExportContext) -> String {
        var lines: [String] = []
        lines.reserveCapacity(context.messages.count * 8 + 16)

        lines.append("会话导出")
        lines.append(String(repeating: "=", count: 42))
        lines.append("会话名称：\(context.session?.name ?? "未命名会话")")
        lines.append("导出时间：\(formattedDateTime(context.exportedAt))")
        lines.append("导出范围：\(scopeDescription(context))")
        lines.append("思考/推理：\(context.includeReasoning ? "包含" : "不包含")")
        lines.append("消息数量：\(context.messages.count)")

        appendPromptLinesIfNeeded(for: context.session, plainLines: &lines)
        lines.append("")

        for (index, message) in context.messages.enumerated() {
            lines.append("[\(index + 1)] \(roleTitle(message.role))")
            lines.append(String(repeating: "-", count: 42))
            lines.append(messageBodyOrPlaceholder(message.content))

            if context.includeReasoning, let reasoning = trimmedOrNil(message.reasoningContent) {
                lines.append("")
                lines.append("[推理]")
                lines.append(reasoning)
            }

            appendToolCallsPlainIfNeeded(message.toolCalls, lines: &lines)
            appendAttachmentsPlainIfNeeded(message, lines: &lines)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func appendPromptLinesIfNeeded(for session: ChatSession?, markdownLines lines: inout [String]) {
        guard let session else { return }

        let globalPrompt = UserDefaults.standard.string(forKey: "systemPrompt")
        let topicPrompt = trimmedOrNil(session.topicPrompt)
        let enhancedPrompt = trimmedOrNil(session.enhancedPrompt)

        guard trimmedOrNil(globalPrompt) != nil || topicPrompt != nil || enhancedPrompt != nil else { return }

        lines.append("")
        lines.append("## 提示词")
        lines.append("")

        if let globalPrompt = trimmedOrNil(globalPrompt) {
            lines.append("### 全局系统提示词")
            lines.append("")
            lines.append(globalPrompt)
            lines.append("")
        }
        if let topicPrompt {
            lines.append("### 话题提示词")
            lines.append("")
            lines.append(topicPrompt)
            lines.append("")
        }
        if let enhancedPrompt {
            lines.append("### 增强提示词")
            lines.append("")
            lines.append(enhancedPrompt)
            lines.append("")
        }
    }

    private func appendPromptLinesIfNeeded(for session: ChatSession?, plainLines lines: inout [String]) {
        guard let session else { return }

        let globalPrompt = UserDefaults.standard.string(forKey: "systemPrompt")
        let topicPrompt = trimmedOrNil(session.topicPrompt)
        let enhancedPrompt = trimmedOrNil(session.enhancedPrompt)

        guard trimmedOrNil(globalPrompt) != nil || topicPrompt != nil || enhancedPrompt != nil else { return }

        lines.append("")
        lines.append("提示词")
        lines.append(String(repeating: "-", count: 42))

        if let globalPrompt = trimmedOrNil(globalPrompt) {
            lines.append("[全局系统提示词]")
            lines.append(globalPrompt)
            lines.append("")
        }
        if let topicPrompt {
            lines.append("[话题提示词]")
            lines.append(topicPrompt)
            lines.append("")
        }
        if let enhancedPrompt {
            lines.append("[增强提示词]")
            lines.append(enhancedPrompt)
            lines.append("")
        }
    }

    private func appendToolCallsMarkdownIfNeeded(_ toolCalls: [InternalToolCall]?, lines: inout [String]) {
        guard let toolCalls, !toolCalls.isEmpty else { return }
        lines.append("### 工具调用")
        lines.append("")

        for (idx, call) in toolCalls.enumerated() {
            lines.append("#### \(idx + 1). \(call.toolName)")
            lines.append("")
            lines.append("**参数**")
            lines.append("")
            lines.append("```json")
            lines.append(messageBodyOrPlaceholder(call.arguments))
            lines.append("```")
            lines.append("")

            if let result = trimmedOrNil(call.result) {
                lines.append("**结果**")
                lines.append("")
                lines.append("```text")
                lines.append(result)
                lines.append("```")
                lines.append("")
            }
        }
    }

    private func appendToolCallsPlainIfNeeded(_ toolCalls: [InternalToolCall]?, lines: inout [String]) {
        guard let toolCalls, !toolCalls.isEmpty else { return }
        lines.append("")
        lines.append("[工具调用]")

        for (idx, call) in toolCalls.enumerated() {
            lines.append("- \(idx + 1). \(call.toolName)")
            lines.append("  参数：")
            lines.append(indent(call.arguments, spaces: 4))
            if let result = trimmedOrNil(call.result) {
                lines.append("  结果：")
                lines.append(indent(result, spaces: 4))
            }
        }
    }

    private func appendAttachmentsMarkdownIfNeeded(_ message: ChatMessage, lines: inout [String]) {
        let audio = trimmedOrNil(message.audioFileName)
        let images = (message.imageFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let files = (message.fileFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard audio != nil || !images.isEmpty || !files.isEmpty else { return }

        lines.append("### 附件")
        lines.append("")

        if let audio {
            lines.append("- 音频：\(audio)")
        }
        if !images.isEmpty {
            lines.append("- 图片：\(images.joined(separator: ", "))")
        }
        if !files.isEmpty {
            lines.append("- 文件：\(files.joined(separator: ", "))")
        }
        lines.append("")
    }

    private func appendAttachmentsPlainIfNeeded(_ message: ChatMessage, lines: inout [String]) {
        let audio = trimmedOrNil(message.audioFileName)
        let images = (message.imageFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let files = (message.fileFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard audio != nil || !images.isEmpty || !files.isEmpty else { return }

        lines.append("")
        lines.append("[附件]")
        if let audio {
            lines.append("- 音频：\(audio)")
        }
        if !images.isEmpty {
            lines.append("- 图片：\(images.joined(separator: ", "))")
        }
        if !files.isEmpty {
            lines.append("- 文件：\(files.joined(separator: ", "))")
        }
    }

    private func roleTitle(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return "系统"
        case .user:
            return "用户"
        case .assistant:
            return "助手"
        case .tool:
            return "工具"
        case .error:
            return "错误"
        @unknown default:
            return "未知"
        }
    }

    private func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func scopeDescription(_ context: ExportContext) -> String {
        if context.upToMessageID != nil {
            return "前 \(context.messages.count) / \(context.sourceCount) 条（包含目标消息与其上文）"
        }
        return "完整会话（共 \(context.messages.count) 条）"
    }

    private func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func messageBodyOrPlaceholder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（空内容）" : trimmed
    }

    private func indent(_ raw: String, spaces: Int) -> String {
        let padding = String(repeating: " ", count: max(0, spaces))
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(padding)\($0)" }
            .joined(separator: "\n")
    }

    private func makePDF(fromMarkdown markdownText: String) throws -> Data {
        let content = markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（空内容）" : markdownText
        let outputData = NSMutableData()

        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else {
            throw ChatTranscriptExportError.pdfRenderFailed
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ChatTranscriptExportError.pdfRenderFailed
        }

        let attributed = renderReadyAttributedString(fromMarkdown: content)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let pageRect = mediaBox
        let horizontalMargin: CGFloat = 34
        let verticalMargin: CGFloat = 44
        let textRect = CGRect(
            x: horizontalMargin,
            y: verticalMargin,
            width: pageRect.width - horizontalMargin * 2,
            height: pageRect.height - verticalMargin * 2
        )

        var currentLocation = 0
        let totalLength = attributed.length
        var renderedPageCount = 0

        while currentLocation < totalLength {
            context.beginPDFPage(nil)
            renderedPageCount += 1

            let path = CGMutablePath()
            path.addRect(textRect)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: currentLocation, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)

            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            currentLocation += visible.length
        }

        if renderedPageCount == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }

        context.closePDF()
        return outputData as Data
    }

    private func renderReadyAttributedString(fromMarkdown markdown: String) -> NSAttributedString {
        if #available(iOS 15.0, watchOS 8.0, *) {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            if let parsed = try? AttributedString(markdown: markdown, options: options) {
                return NSAttributedString(parsed)
            }
        }

        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11, nil)
        return NSAttributedString(
            string: markdown,
            attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
            ]
        )
    }

    private struct ExportContext {
        let session: ChatSession?
        let messages: [ChatMessage]
        let format: ChatTranscriptExportFormat
        let includeReasoning: Bool
        let exportedAt: Date
        let upToMessageID: UUID?
        let sourceCount: Int
    }
}
