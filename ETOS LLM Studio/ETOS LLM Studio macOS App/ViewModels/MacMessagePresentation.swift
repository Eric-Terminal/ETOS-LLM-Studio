// ============================================================================
// MacMessagePresentation.swift
// ============================================================================
// Markdown、回复版本筛选和附件路径在后台准备，聊天行不做解析或磁盘操作。
// ============================================================================

import ETOSCore
import Foundation

struct MacMessagePresentation: Identifiable {
    struct VersionOption: Identifiable {
        let id: Int
        let title: String
    }

    struct Attachment: Identifiable {
        let id: String
        let url: URL
        let isImage: Bool
    }

    let message: ChatMessage
    let content: MacPreparedMessageText
    let userPreview: AttributedString?
    let roleTitle: String
    let reasoning: MacPreparedMessageText?
    let toolCalls: [InternalToolCall]
    let attachments: [Attachment]
    let widget: CompletedToolWidget?
    let versionInfo: ChatResponseAttemptVersionInfo?
    let versionOptions: [VersionOption]
    let versionIndex: Int
    let versionLabel: String
    let canRewrite: Bool
    let activity: MacMessageActivity
    let roleplayDocuments: [RoleplayPreparedDocument]
    var id: UUID { message.id }

    static func prepare(_ message: ChatMessage, markdown: Bool, versionInfo: ChatResponseAttemptVersionInfo? = nil,
                        renderedContent: String? = nil, roleplayDocuments: [RoleplayPreparedDocument] = [],
                        activeResponseID: UUID? = nil,
                        userPreviewLimit: Int = ChatUserMessagePreview.defaultCharacterLimit,
                        preparedText: MacPreparedMessageText? = nil,
                        preparedReasoning: MacPreparedMessageText? = nil) -> MacMessagePresentation {
        let text = renderedContent ?? message.content
        let content = preparedText ?? MacPreparedMessageText(text, markdown: markdown && message.role == .assistant)
        let preview = message.role == .user ? ChatUserMessagePreview(content: text, characterLimit: userPreviewLimit) : nil
        let activity = MacMessageActivity(message: message, activeResponseID: activeResponseID)
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
        let count = versionInfo?.totalCount ?? message.getAllVersions().count
        let index = versionInfo?.currentIndex ?? message.getCurrentVersionIndex()
        return MacMessagePresentation(
            message: message,
            content: content,
            userPreview: preview.flatMap { $0.isTruncated ? AttributedString($0.content) : nil },
            roleTitle: title,
            reasoning: preparedReasoning ?? message.reasoningContent.map {
                MacPreparedMessageText($0, markdown: markdown && !activity.suppressesReasoningContent)
            },
            toolCalls: message.toolCalls ?? [],
            attachments: attachments,
            widget: CompletedToolWidget(message: message),
            versionInfo: versionInfo,
            versionOptions: count > 1 ? (0..<count).map {
                VersionOption(id: $0, title: String(format: NSLocalizedString("版本 %d", comment: ""), $0 + 1))
            } : [],
            versionIndex: index,
            versionLabel: String(format: NSLocalizedString("切换版本 (%d/%d)", comment: ""), index + 1, count),
            canRewrite: message.role == .assistant && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            activity: activity,
            roleplayDocuments: roleplayDocuments
        )
    }
}

actor MacMessagePresentationStore {
    private var cache: [UUID: MacMessagePresentation] = [:]
    private var usesMarkdown = false
    private var language = ""
    private var usedCustomPresentation = false
    private var userPreviewLimit = ChatUserMessagePreview.defaultCharacterLimit
    private var textCache = MacMessageTextCache()
    private let versionIndex = ChatResponseAttemptIndexWorker()

    func prepare(_ messages: [ChatMessage], markdown: Bool, language: String, sessionID: UUID? = nil,
                 roleplay: RoleplayPresentationSnapshot? = nil, rules: [MessageRegexRule] = [],
                 activeResponseID: UUID? = nil,
                 userPreviewLimit: Int = ChatUserMessagePreview.defaultCharacterLimit) async throws -> [MacMessagePresentation] {
        let versions = await versionIndex.prepare(messages: messages, sessionID: sessionID).entries
        try Task.checkCancellation()
        let usesCustomPresentation = roleplay != nil || !rules.isEmpty
        if usesMarkdown != markdown || self.language != language || self.userPreviewLimit != userPreviewLimit
            || usesCustomPresentation || usedCustomPresentation {
            cache.removeAll()
            usesMarkdown = markdown
            self.language = language
            self.userPreviewLimit = userPreviewLimit
        }
        usedCustomPresentation = usesCustomPresentation
        var updated: [UUID: MacMessagePresentation] = [:]
        let result = try ChatResponseAttemptSupport.visibleMessages(from: messages).map { message in
            try Task.checkCancellation()
            let row: MacMessagePresentation
            if let previous = cache[message.id], previous.message == message, previous.versionInfo == versions[message.id],
               previous.activity.isCurrentResponse == (message.id == activeResponseID) {
                row = previous
            } else {
                let visual = roleplay?.visualContent(message, rules: rules) ?? ChatService.visualMessage(from: message, rules: rules).content
                let extraction = roleplay?.extraction(for: message, content: visual)
                let documents = extraction.map { roleplay?.documents(for: message, extraction: $0) ?? [] } ?? []
                let text = textCache.prepare(extraction?.remainingText ?? visual, messageID: message.id,
                                             markdown: markdown && message.role == .assistant)
                let activity = MacMessageActivity(message: message, activeResponseID: activeResponseID)
                let reasoning = message.reasoningContent.map {
                    textCache.prepare($0, messageID: message.id, reasoning: true,
                                      markdown: markdown && !activity.suppressesReasoningContent)
                }
                row = MacMessagePresentation.prepare(message, markdown: markdown, versionInfo: versions[message.id],
                                                     renderedContent: extraction?.remainingText ?? visual, roleplayDocuments: documents,
                                                     activeResponseID: activeResponseID, userPreviewLimit: userPreviewLimit,
                                                     preparedText: text, preparedReasoning: reasoning)
            }
            updated[message.id] = row
            return row
        }
        cache = updated
        textCache.retain(Set(updated.keys))
        return result
    }

    func prepareWorkspace(_ messages: [ChatMessage], markdown: Bool, language: String, sessionID: UUID?,
                          scriptSessionIDs: Set<UUID>, service: ChatService,
                          userPreviewLimit: Int = ChatUserMessagePreview.defaultCharacterLimit) async throws -> MacRoleplayPresentation {
        let worldbooks = service.loadWorldbooks()
        let context = sessionID.map { RoleplayPresentationSnapshot(sessionID: $0, messages: messages, worldbooks: worldbooks) }
        let rows = try await prepare(messages, markdown: markdown, language: language, sessionID: sessionID,
                                     roleplay: context, rules: MessageRegexRuleStore.currentRules(),
                                     activeResponseID: sessionID.flatMap { service.activeResponseMessageID(for: $0) },
                                     userPreviewLimit: userPreviewLimit)
        var scripts: [RoleplayPreparedDocument] = []
        for id in scriptSessionIDs {
            try Task.checkCancellation()
            let snapshot = id == sessionID ? context : RoleplayPresentationSnapshot(sessionID: id, messages: service.messagesSnapshot(for: id), worldbooks: worldbooks)
            scripts.append(contentsOf: snapshot?.scriptDocuments() ?? [])
        }
        return MacRoleplayPresentation(rows: rows, scripts: scripts, buttons: context?.buttons() ?? [])
    }
}

struct MacRoleplayPresentation {
    let rows: [MacMessagePresentation]
    let scripts: [RoleplayPreparedDocument]
    let buttons: [RoleplayPreparedButton]
}
