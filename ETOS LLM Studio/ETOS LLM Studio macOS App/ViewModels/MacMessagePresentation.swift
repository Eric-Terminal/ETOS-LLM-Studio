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
    let userPreview: MacPreparedMessageText?
    let palette: MacChatPalette
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
                        preparedReasoning: MacPreparedMessageText? = nil,
                        preparedPreview: MacPreparedMessageText? = nil,
                        palette: MacChatPalette = MacChatPalette(.defaultProfile)) -> MacMessagePresentation {
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
            userPreview: preparedPreview ?? preview.flatMap { $0.isTruncated ? MacPreparedMessageText($0.content, markdown: false) : nil },
            palette: palette,
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
    private var coloredTexts: [UUID: MacColoredTextCacheEntry] = [:]
    private var appearance = ChatAppearanceProfile.defaultProfile
    private var preparationID = UUID()
    private var fontRevision = ""
    private var lineSpacing = FontLibrary.defaultIOSLineSpacingEm
    private let versionIndex = ChatResponseAttemptIndexWorker()

    func prepare(_ messages: [ChatMessage], markdown: Bool, language: String, sessionID: UUID? = nil,
                 roleplay: RoleplayPresentationSnapshot? = nil, rules: [MessageRegexRule] = [],
                 activeResponseID: UUID? = nil,
                 userPreviewLimit: Int = ChatUserMessagePreview.defaultCharacterLimit,
                 appearance: ChatAppearanceProfile = .defaultProfile,
                 lineSpacing: Double = FontLibrary.defaultIOSLineSpacingEm) async throws -> [MacMessagePresentation] {
        let revision = UUID(); preparationID = revision
        let versions = await versionIndex.prepare(messages: messages, sessionID: sessionID).entries
        try Task.checkCancellation()
        guard preparationID == revision else { throw CancellationError() }
        let palette = MacChatPalette(appearance)
        let fontRevision = FontLibrary.adapterCacheToken()
        let usesCustomPresentation = roleplay != nil || !rules.isEmpty
        if usesMarkdown != markdown || self.language != language || self.userPreviewLimit != userPreviewLimit
            || usesCustomPresentation || usedCustomPresentation || self.appearance != appearance
            || self.fontRevision != fontRevision || self.lineSpacing != lineSpacing {
            cache.removeAll()
            usesMarkdown = markdown
            self.language = language
            self.userPreviewLimit = userPreviewLimit
            self.appearance = appearance
            self.fontRevision = fontRevision; self.lineSpacing = lineSpacing
        }
        usedCustomPresentation = usesCustomPresentation
        var updated: [UUID: MacMessagePresentation] = [:]
        var result: [MacMessagePresentation] = []
        var textIDs = Set<UUID>()
        for message in ChatResponseAttemptSupport.visibleMessages(from: messages) {
            try Task.checkCancellation()
            let row: MacMessagePresentation
            if let previous = cache[message.id], previous.message == message, previous.versionInfo == versions[message.id],
               previous.activity.isCurrentResponse == (message.id == activeResponseID) {
                row = previous
            } else {
                let visual = roleplay?.visualContent(message, rules: rules) ?? ChatService.visualMessage(from: message, rules: rules).content
                let extraction = roleplay?.extraction(for: message, content: visual)
                let documents = extraction.map { roleplay?.documents(for: message, extraction: $0) ?? [] } ?? []
                let source = extraction?.remainingText ?? visual
                let outgoing = message.role == .user && message.authorKind == .user
                let base = textCache.prepare(source, messageID: message.id,
                                             markdown: markdown && message.role == .assistant)
                let text = try await prepareColors(base, outgoing: outgoing, appearance: appearance, fontRevision: fontRevision, lineSpacing: lineSpacing)
                let activity = MacMessageActivity(message: message, activeResponseID: activeResponseID)
                var reasoning: MacPreparedMessageText?
                if let source = message.reasoningContent {
                    let base = textCache.prepare(source, messageID: message.id, reasoning: true,
                                                 markdown: markdown && !activity.suppressesReasoningContent)
                    // 活跃思考沿用纯文本预览，不触发规则匹配或额外格式化。
                    reasoning = try await prepareColors(base, outgoing: outgoing, appearance: appearance,
                        fontRevision: fontRevision, lineSpacing: lineSpacing, appliesRules: !activity.suppressesReasoningContent)
                }
                var preview: MacPreparedMessageText?
                if message.role == .user {
                    let candidate = ChatUserMessagePreview(content: source, characterLimit: userPreviewLimit)
                    if candidate.isTruncated {
                        let base = textCache.prepare(candidate.content, messageID: message.id, preview: true, markdown: false)
                        preview = try await prepareColors(base, outgoing: outgoing, appearance: appearance, fontRevision: fontRevision, lineSpacing: lineSpacing)
                    }
                }
                row = MacMessagePresentation.prepare(message, markdown: markdown, versionInfo: versions[message.id],
                                                     renderedContent: extraction?.remainingText ?? visual, roleplayDocuments: documents,
                                                     activeResponseID: activeResponseID, userPreviewLimit: userPreviewLimit,
                                                     preparedText: text, preparedReasoning: reasoning, preparedPreview: preview, palette: palette)
            }
            guard preparationID == revision, FontLibrary.adapterCacheToken() == fontRevision else { throw CancellationError() }
            updated[message.id] = row
            result.append(row)
            textIDs.insert(row.content.id)
            if let id = row.reasoning?.id { textIDs.insert(id) }
            if let id = row.userPreview?.id { textIDs.insert(id) }
        }
        try Task.checkCancellation()
        cache = updated
        textCache.retain(Set(updated.keys))
        coloredTexts = coloredTexts.filter { textIDs.contains($0.key) }
        return result
    }

    func prepareWorkspace(_ messages: [ChatMessage], markdown: Bool, language: String, sessionID: UUID?,
                          scriptSessionIDs: Set<UUID>, service: ChatService,
                          userPreviewLimit: Int = ChatUserMessagePreview.defaultCharacterLimit,
                          appearance: ChatAppearanceProfile = .defaultProfile,
                          lineSpacing: Double = FontLibrary.defaultIOSLineSpacingEm) async throws -> MacRoleplayPresentation {
        let worldbooks = service.loadWorldbooks()
        let context = sessionID.map { RoleplayPresentationSnapshot(sessionID: $0, messages: messages, worldbooks: worldbooks) }
        let rows = try await prepare(messages, markdown: markdown, language: language, sessionID: sessionID,
                                     roleplay: context, rules: MessageRegexRuleStore.currentRules(),
                                     activeResponseID: sessionID.flatMap { service.activeResponseMessageID(for: $0) },
                                     userPreviewLimit: userPreviewLimit, appearance: appearance, lineSpacing: lineSpacing)
        var scripts: [RoleplayPreparedDocument] = []
        for id in scriptSessionIDs {
            try Task.checkCancellation()
            let snapshot = id == sessionID ? context : RoleplayPresentationSnapshot(sessionID: id, messages: service.messagesSnapshot(for: id), worldbooks: worldbooks)
            scripts.append(contentsOf: snapshot?.scriptDocuments() ?? [])
        }
        return MacRoleplayPresentation(rows: rows, scripts: scripts, buttons: context?.buttons() ?? [])
    }

    private func prepareColors(_ text: MacPreparedMessageText, outgoing: Bool,
                               appearance: ChatAppearanceProfile, fontRevision: String, lineSpacing: Double,
                               appliesRules: Bool = true) async throws -> MacPreparedMessageText {
        let light = outgoing ? appearance.userLightTextStyles : appearance.assistantLightTextStyles
        let dark = outgoing ? appearance.userDarkTextStyles : appearance.assistantDarkTextStyles
        if let entry = coloredTexts[text.id], entry.light == light, entry.dark == dark,
           entry.fontRevision == fontRevision, entry.lineSpacing == lineSpacing, entry.appliesRules == appliesRules { return entry.text }
        let typography = await MacTextTypography.prepare(text.source, lineSpacing: lineSpacing)
        let fontRules = appliesRules ? FontLibrary.resolvedTextFontRules() : []
        var lightText: AttributedString?, darkText: AttributedString?
        if appliesRules && (!fontRules.isEmpty || light.customRules.contains(where: { $0.isEnabled && $0.isConfigured })) {
            lightText = await ChatAppearanceTextRuleRenderer.shared.prepare(request: .init(
                source: text.source, usesMarkdown: text.markdown != nil, styleColors: light, fontRules: fontRules,
                fontPointSize: MacTextTypography.baseSize, fontScale: FontLibrary.customFontScale,
                fontFallbackScope: FontLibrary.fallbackScope, semanticFont: .system(size: CGFloat(MacTextTypography.baseSize))))
        }
        try Task.checkCancellation()
        if dark == light { darkText = lightText }
        else if appliesRules && (!fontRules.isEmpty || dark.customRules.contains(where: { $0.isEnabled && $0.isConfigured })) {
            darkText = await ChatAppearanceTextRuleRenderer.shared.prepare(request: .init(
                source: text.source, usesMarkdown: text.markdown != nil, styleColors: dark, fontRules: fontRules,
                fontPointSize: MacTextTypography.baseSize, fontScale: FontLibrary.customFontScale,
                fontFallbackScope: FontLibrary.fallbackScope, semanticFont: .system(size: CGFloat(MacTextTypography.baseSize))))
        }
        try Task.checkCancellation()
        let result = MacPreparedMessageText(base: text, lightRules: lightText, darkRules: darkText, typography: typography)
        coloredTexts[text.id] = .init(light: light, dark: dark, fontRevision: fontRevision, lineSpacing: lineSpacing,
                                    appliesRules: appliesRules, text: result)
        return result
    }
}

struct MacRoleplayPresentation {
    let rows: [MacMessagePresentation]
    let scripts: [RoleplayPreparedDocument]
    let buttons: [RoleplayPreparedButton]
}
