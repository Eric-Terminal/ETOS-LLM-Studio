// ============================================================================
// ChatTranscriptExportService.swift
// ============================================================================
// ChatTranscriptExportService 会话文本导出模块
// - 支持导出 PDF / Markdown / TXT / PNG 聊天长图
// - 支持导出完整会话、“截至某条消息”的上文片段或任意选中消息
// ============================================================================

import Foundation
import CoreGraphics
import CoreText

public enum ChatTranscriptExportFormat: String, CaseIterable, Sendable {
    case pdf
    case markdown
    case text
    case png

    public var fileExtension: String {
        switch self {
        case .pdf:
            return "pdf"
        case .markdown:
            return "md"
        case .text:
            return "txt"
        case .png:
            return "png"
        }
    }

    public var displayName: String {
        switch self {
        case .pdf:
            return NSLocalizedString("PDF", comment: "Chat transcript export format")
        case .markdown:
            return NSLocalizedString("Markdown", comment: "Chat transcript export format")
        case .text:
            return NSLocalizedString("TXT", comment: "Chat transcript export format")
        case .png:
            return NSLocalizedString("PNG", comment: "Chat transcript export format")
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

public enum ChatTranscriptExportError: LocalizedError, Equatable {
    case emptyMessages
    case messageNotFound
    case pdfRenderFailed
    case imageRenderFailed
    case imageTooLong

    public var errorDescription: String? {
        switch self {
        case .emptyMessages:
            return NSLocalizedString("导出失败：当前会话没有可导出的消息。", comment: "Chat transcript export empty messages error")
        case .messageNotFound:
            return NSLocalizedString("导出失败：未找到指定的消息。", comment: "Chat transcript export missing target message error")
        case .pdfRenderFailed:
            return NSLocalizedString("导出失败：无法生成 PDF 文件。", comment: "Chat transcript export PDF render error")
        case .imageRenderFailed:
            return NSLocalizedString("导出失败：无法生成聊天长图。", comment: "Chat transcript image export render error")
        case .imageTooLong:
            return NSLocalizedString("聊天内容过长，请减少导出的消息数量后重试。", comment: "Chat transcript image export length error")
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
        includeSystemPrompt: Bool = true,
        upToMessageID: UUID? = nil,
        selectedMessageIDs: Set<UUID>? = nil,
        imageStyle: ChatTranscriptImageStyle = ChatTranscriptImageStyle(),
        exportedAt: Date = Date()
    ) throws -> ChatTranscriptExportOutput {
        let resolvedMessages = try resolveScopedMessages(
            messages,
            upToMessageID: upToMessageID,
            selectedMessageIDs: selectedMessageIDs
        )
        // 聊天长图只呈现用户在聊天界面中可见的消息，不泄露系统提示词。
        let effectiveIncludeSystemPrompt = format != .png && includeSystemPrompt
        let scopedMessages = resolvedMessages.filter {
            effectiveIncludeSystemPrompt || $0.role != .system
        }
        guard !scopedMessages.isEmpty else {
            throw ChatTranscriptExportError.emptyMessages
        }
        let context = ExportContext(
            session: session,
            messages: scopedMessages,
            format: format,
            includeReasoning: includeReasoning,
            includeSystemPrompt: effectiveIncludeSystemPrompt,
            exportedAt: exportedAt,
            upToMessageID: upToMessageID,
            selectedMessageIDs: selectedMessageIDs,
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
        case .png:
            data = try ChatTranscriptImageRenderer().render(
                session: session,
                messages: scopedMessages,
                includeReasoning: includeReasoning,
                style: imageStyle
            )
        }

        return ChatTranscriptExportOutput(
            data: data,
            format: format,
            suggestedFileName: suggestedFileName(context)
        )
    }

    private func resolveScopedMessages(
        _ messages: [ChatMessage],
        upToMessageID: UUID?,
        selectedMessageIDs: Set<UUID>?
    ) throws -> [ChatMessage] {
        guard !messages.isEmpty else {
            throw ChatTranscriptExportError.emptyMessages
        }
        if let selectedMessageIDs {
            guard !selectedMessageIDs.isEmpty else {
                throw ChatTranscriptExportError.emptyMessages
            }
            let selectedMessages = messages.filter { selectedMessageIDs.contains($0.id) }
            guard selectedMessages.count == selectedMessageIDs.count else {
                throw ChatTranscriptExportError.messageNotFound
            }
            return selectedMessages
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
        let fallbackName = NSLocalizedString("会话导出", comment: "Chat transcript export fallback file name")
        let baseName = sanitizeFileName(sessionName?.isEmpty == false ? sessionName! : fallbackName)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: context.exportedAt)

        let scopeSuffix: String
        if context.selectedMessageIDs != nil {
            scopeSuffix = String(
                format: NSLocalizedString("-已选%d条", comment: "Chat transcript export file suffix for selected messages"),
                context.messages.count
            )
        } else if context.upToMessageID != nil {
            scopeSuffix = String(
                format: NSLocalizedString("-截至第%d条", comment: "Chat transcript export file suffix for partial scope"),
                context.messages.count
            )
        } else {
            scopeSuffix = NSLocalizedString("-完整", comment: "Chat transcript export file suffix for full scope")
        }

        let reasoningSuffix = context.includeReasoning
            ? NSLocalizedString("-含思考", comment: "Chat transcript export file suffix with reasoning")
            : NSLocalizedString("-不含思考", comment: "Chat transcript export file suffix without reasoning")
        let systemPromptSuffix = context.includeSystemPrompt
            ? NSLocalizedString("-含系统提示", comment: "Chat transcript export file suffix with system prompt")
            : NSLocalizedString("-不含系统提示", comment: "Chat transcript export file suffix without system prompt")
        return "\(baseName)\(scopeSuffix)\(reasoningSuffix)\(systemPromptSuffix)-\(stamp).\(context.format.fileExtension)"
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let sanitized = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? NSLocalizedString("会话导出", comment: "Chat transcript export fallback file name") : sanitized
    }

    private func buildMarkdown(_ context: ExportContext) -> String {
        var lines: [String] = []
        lines.reserveCapacity(context.messages.count * 8 + 16)

        lines.append("# \(localizedExportText("会话导出"))")
        lines.append("")
        lines.append("- \(localizedExportText("会话名称")): \(context.session?.name ?? localizedExportText("未命名会话"))")
        lines.append("- \(localizedExportText("导出时间")): \(formattedDateTime(context.exportedAt))")
        lines.append("- \(localizedExportText("导出范围")): \(scopeDescription(context))")
        lines.append("- \(localizedExportText("思考/推理")): \(context.includeReasoning ? localizedExportText("包含") : localizedExportText("不包含"))")
        lines.append("- \(localizedExportText("系统提示词")): \(context.includeSystemPrompt ? localizedExportText("包含") : localizedExportText("不包含"))")
        lines.append("- \(localizedExportText("消息数量")): \(context.messages.count)")

        appendSystemPromptSnapshotsIfNeeded(context, markdownLines: &lines)

        lines.append("")
        lines.append("---")
        lines.append("")

        for (index, message) in context.messages.enumerated() {
            lines.append("## \(index + 1). \(roleTitle(message.role))")
            lines.append("")
            lines.append(messageBodyOrPlaceholder(message.content))
            lines.append("")

            if context.includeReasoning, let reasoning = trimmedOrNil(message.reasoningContent) {
                lines.append("### \(localizedExportText("推理"))")
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

        lines.append(localizedExportText("会话导出"))
        lines.append(String(repeating: "=", count: 42))
        lines.append("\(localizedExportText("会话名称")): \(context.session?.name ?? localizedExportText("未命名会话"))")
        lines.append("\(localizedExportText("导出时间")): \(formattedDateTime(context.exportedAt))")
        lines.append("\(localizedExportText("导出范围")): \(scopeDescription(context))")
        lines.append("\(localizedExportText("思考/推理")): \(context.includeReasoning ? localizedExportText("包含") : localizedExportText("不包含"))")
        lines.append("\(localizedExportText("系统提示词")): \(context.includeSystemPrompt ? localizedExportText("包含") : localizedExportText("不包含"))")
        lines.append("\(localizedExportText("消息数量")): \(context.messages.count)")

        appendSystemPromptSnapshotsIfNeeded(context, plainLines: &lines)
        lines.append("")

        for (index, message) in context.messages.enumerated() {
            lines.append("[\(index + 1)] \(roleTitle(message.role))")
            lines.append(String(repeating: "-", count: 42))
            lines.append(messageBodyOrPlaceholder(message.content))

            if context.includeReasoning, let reasoning = trimmedOrNil(message.reasoningContent) {
                lines.append("")
                lines.append("[\(localizedExportText("推理"))]")
                lines.append(reasoning)
            }

            appendToolCallsPlainIfNeeded(message.toolCalls, lines: &lines)
            appendAttachmentsPlainIfNeeded(message, lines: &lines)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func appendSystemPromptSnapshotsIfNeeded(_ context: ExportContext, markdownLines lines: inout [String]) {
        guard context.includeSystemPrompt else { return }
        lines.append("")
        lines.append("## \(localizedExportText("实际发送的系统提示词"))")
        lines.append("")

        let snapshots = systemPromptSnapshots(in: context.messages)
        guard !snapshots.isEmpty else {
            lines.append(localizedExportText("此导出范围内没有可用的系统提示词快照。"))
            lines.append("")
            return
        }

        for snapshot in snapshots {
            lines.append("### \(snapshot.messageIndex + 1). \(roleTitle(snapshot.role))")
            lines.append("")
            if let content = snapshot.content {
                lines.append(trimmedOrNil(content) ?? localizedExportText("未发送系统提示词"))
            } else {
                lines.append(localizedExportText("未记录此回复的系统提示词快照。"))
            }
            lines.append("")
        }
    }

    private func appendSystemPromptSnapshotsIfNeeded(_ context: ExportContext, plainLines lines: inout [String]) {
        guard context.includeSystemPrompt else { return }
        lines.append("")
        lines.append(localizedExportText("实际发送的系统提示词"))
        lines.append(String(repeating: "-", count: 42))

        let snapshots = systemPromptSnapshots(in: context.messages)
        guard !snapshots.isEmpty else {
            lines.append(localizedExportText("此导出范围内没有可用的系统提示词快照。"))
            lines.append("")
            return
        }

        for snapshot in snapshots {
            lines.append("[\(snapshot.messageIndex + 1). \(roleTitle(snapshot.role))]")
            if let content = snapshot.content {
                lines.append(trimmedOrNil(content) ?? localizedExportText("未发送系统提示词"))
            } else {
                lines.append(localizedExportText("未记录此回复的系统提示词快照。"))
            }
            lines.append("")
        }
    }

    private func systemPromptSnapshots(in messages: [ChatMessage]) -> [SystemPromptSnapshot] {
        messages.enumerated().compactMap { index, message in
            guard message.role == .assistant || message.role == .error else { return nil }
            return SystemPromptSnapshot(
                messageIndex: index,
                role: message.role,
                content: message.sentSystemPromptSnapshot
            )
        }
    }

    private func appendToolCallsMarkdownIfNeeded(_ toolCalls: [InternalToolCall]?, lines: inout [String]) {
        guard let toolCalls, !toolCalls.isEmpty else { return }
        lines.append("### \(localizedExportText("工具调用"))")
        lines.append("")

        for (idx, call) in toolCalls.enumerated() {
            lines.append("#### \(idx + 1). \(call.toolName)")
            lines.append("")
            lines.append("**\(localizedExportText("参数"))**")
            lines.append("")
            lines.append("```json")
            lines.append(messageBodyOrPlaceholder(call.arguments))
            lines.append("```")
            lines.append("")

            if let result = trimmedOrNil(call.result) {
                lines.append("**\(localizedExportText("结果"))**")
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
        lines.append("[\(localizedExportText("工具调用"))]")

        for (idx, call) in toolCalls.enumerated() {
            lines.append("- \(idx + 1). \(call.toolName)")
            lines.append("  \(localizedExportText("参数")):")
            lines.append(indent(call.arguments, spaces: 4))
            if let result = trimmedOrNil(call.result) {
                lines.append("  \(localizedExportText("结果")):")
                lines.append(indent(result, spaces: 4))
            }
        }
    }

    private func appendAttachmentsMarkdownIfNeeded(_ message: ChatMessage, lines: inout [String]) {
        let audio = trimmedOrNil(message.audioFileName)
        let images = (message.imageFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let files = (message.fileFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard audio != nil || !images.isEmpty || !files.isEmpty else { return }

        lines.append("### \(localizedExportText("附件"))")
        lines.append("")

        if let audio {
            lines.append("- \(localizedExportText("音频")): \(audio)")
        }
        if !images.isEmpty {
            lines.append("- \(localizedExportText("图片")): \(images.joined(separator: ", "))")
        }
        if !files.isEmpty {
            lines.append("- \(localizedExportText("文件")): \(files.joined(separator: ", "))")
        }
        lines.append("")
    }

    private func appendAttachmentsPlainIfNeeded(_ message: ChatMessage, lines: inout [String]) {
        let audio = trimmedOrNil(message.audioFileName)
        let images = (message.imageFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let files = (message.fileFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard audio != nil || !images.isEmpty || !files.isEmpty else { return }

        lines.append("")
        lines.append("[\(localizedExportText("附件"))]")
        if let audio {
            lines.append("- \(localizedExportText("音频")): \(audio)")
        }
        if !images.isEmpty {
            lines.append("- \(localizedExportText("图片")): \(images.joined(separator: ", "))")
        }
        if !files.isEmpty {
            lines.append("- \(localizedExportText("文件")): \(files.joined(separator: ", "))")
        }
    }

    private func roleTitle(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return localizedExportText("系统")
        case .user:
            return localizedExportText("用户")
        case .assistant:
            return localizedExportText("助手")
        case .tool:
            return localizedExportText("工具")
        case .error:
            return localizedExportText("错误")
        @unknown default:
            return localizedExportText("未知")
        }
    }

    private func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func scopeDescription(_ context: ExportContext) -> String {
        if context.selectedMessageIDs != nil {
            return String(
                format: NSLocalizedString("已选 %d / %d 条", comment: "Chat transcript export selected messages scope description"),
                context.messages.count,
                context.sourceCount
            )
        }
        if context.upToMessageID != nil {
            return String(
                format: NSLocalizedString("前 %d / %d 条（包含目标消息与其上文）", comment: "Chat transcript export partial scope description"),
                context.messages.count,
                context.sourceCount
            )
        }
        return String(
            format: NSLocalizedString("完整会话（共 %d 条）", comment: "Chat transcript export full scope description"),
            context.messages.count
        )
    }

    private func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func messageBodyOrPlaceholder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? localizedExportText("（空内容）") : trimmed
    }

    private func indent(_ raw: String, spaces: Int) -> String {
        let padding = String(repeating: " ", count: max(0, spaces))
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(padding)\($0)" }
            .joined(separator: "\n")
    }

    private func makePDF(fromMarkdown markdownText: String) throws -> Data {
        let content = markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localizedExportText("（空内容）") : markdownText
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
        let normalizedMarkdown = markdownForPDFRendering(markdown)
        if #available(iOS 15.0, watchOS 8.0, *) {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            if let parsed = try? AttributedString(markdown: normalizedMarkdown, options: options) {
                return NSAttributedString(parsed)
            }
        }

        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11, nil)
        return NSAttributedString(
            string: normalizedMarkdown,
            attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
            ]
        )
    }

    /// 为 PDF 渲染预处理 Markdown：将软换行提升为硬换行，避免被解析后丢失换行。
    private func markdownForPDFRendering(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return markdown }

        var result: [String] = []
        result.reserveCapacity(lines.count)
        var inCodeFence = false

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFenceLine = trimmed.hasPrefix("```")
            if isFenceLine {
                inCodeFence.toggle()
            }

            let isLastLine = index == lines.count - 1
            if isLastLine {
                result.append(line)
                continue
            }

            let nextLine = lines[index + 1]
            let isParagraphBoundary = line.isEmpty || nextLine.isEmpty
            if isFenceLine || inCodeFence || isParagraphBoundary {
                result.append(line)
            } else {
                result.append("\(line)  ")
            }
        }

        return result.joined(separator: "\n")
    }

    private struct ExportContext {
        let session: ChatSession?
        let messages: [ChatMessage]
        let format: ChatTranscriptExportFormat
        let includeReasoning: Bool
        let includeSystemPrompt: Bool
        let exportedAt: Date
        let upToMessageID: UUID?
        let selectedMessageIDs: Set<UUID>?
        let sourceCount: Int
    }

    private struct SystemPromptSnapshot {
        let messageIndex: Int
        let role: MessageRole
        let content: String?
    }

    private func localizedExportText(_ key: String) -> String {
        NSLocalizedString(key, comment: "Chat transcript export text")
    }
}
