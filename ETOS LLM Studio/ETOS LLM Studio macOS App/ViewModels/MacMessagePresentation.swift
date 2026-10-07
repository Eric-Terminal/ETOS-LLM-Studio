// ============================================================================
// MacMessagePresentation.swift
// ============================================================================
// Markdown、回复版本筛选和附件路径在后台准备，聊天行不做解析或磁盘操作。
// ============================================================================

import ETOSCore
import Foundation

struct MacMessagePresentation: Identifiable {
    struct Attachment: Identifiable {
        let id: String
        let url: URL
        let isImage: Bool
    }

    let message: ChatMessage
    let content: AttributedString
    let roleTitle: String
    let reasoning: String?
    let toolCalls: [InternalToolCall]
    let attachments: [Attachment]
    var id: UUID { message.id }

    static func prepare(_ message: ChatMessage, markdown: Bool) -> MacMessagePresentation {
        let content: AttributedString
        if markdown, message.role == .assistant,
           let parsed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full)) {
            content = parsed
        } else { content = AttributedString(message.content) }
        let title: String
        switch message.role {
        case .user: title = NSLocalizedString("你", comment: "")
        case .assistant: title = message.modelReference?.modelDisplayName ?? NSLocalizedString("助手", comment: "")
        case .system: title = NSLocalizedString("系统", comment: "")
        case .tool: title = NSLocalizedString("工具结果", comment: "")
        case .error: title = NSLocalizedString("错误", comment: "")
        }
        var attachments = (message.imageFileNames ?? []).map {
            Attachment(id: "image:\($0)", url: Persistence.getImageDirectory().appendingPathComponent($0), isImage: true)
        }
        attachments += (message.fileFileNames ?? []).map {
            Attachment(id: "file:\($0)", url: Persistence.getFileDirectory().appendingPathComponent($0), isImage: false)
        }
        if let audio = message.audioFileName {
            attachments.append(.init(id: "audio:\(audio)", url: Persistence.getAudioDirectory().appendingPathComponent(audio), isImage: false))
        }
        return MacMessagePresentation(
            message: message,
            content: content,
            roleTitle: title,
            reasoning: message.reasoningContent,
            toolCalls: message.toolCalls ?? [],
            attachments: attachments
        )
    }
}

actor MacMessagePresentationStore {
    private var cache: [UUID: MacMessagePresentation] = [:]
    private var usesMarkdown = false
    private var language = ""

    func prepare(_ messages: [ChatMessage], markdown: Bool, language: String) throws -> [MacMessagePresentation] {
        if usesMarkdown != markdown || self.language != language {
            cache.removeAll()
            usesMarkdown = markdown
            self.language = language
        }
        var updated: [UUID: MacMessagePresentation] = [:]
        let result = try ChatResponseAttemptSupport.visibleMessages(from: messages).map { message in
            try Task.checkCancellation()
            let row: MacMessagePresentation
            if let previous = cache[message.id], previous.message == message {
                row = previous
            } else {
                row = MacMessagePresentation.prepare(message, markdown: markdown)
            }
            updated[message.id] = row
            return row
        }
        cache = updated
        return result
    }
}
