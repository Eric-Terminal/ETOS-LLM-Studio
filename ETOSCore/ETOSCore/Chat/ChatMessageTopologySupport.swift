// ============================================================================
// ChatMessageTopologySupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义会话轮次边界与消息原子化规则，作为删除、重试和版本切换的共同语义。
// ============================================================================

import Foundation

public struct ChatConversationTurn: Equatable, Sendable {
    public let range: Range<Int>
    public let userRange: Range<Int>?

    public var responseRange: Range<Int> {
        guard let userRange else { return range }
        return userRange.upperBound..<range.upperBound
    }

    public var responseGroupAnchorIndex: Int? {
        userRange.map { $0.index(before: $0.endIndex) }
    }
}

/// 用户一次点击发送可能产生多条连续 user 消息；它们必须共同构成同一轮输入。
public enum ChatConversationTurnSupport {
    public static func turns(in messages: [ChatMessage]) -> [ChatConversationTurn] {
        guard !messages.isEmpty else { return [] }

        var turns: [ChatConversationTurn] = []
        var turnStart = messages.startIndex
        var firstUserIndex: Int?
        var hasResponseAfterUser = false

        for index in messages.indices {
            let message = messages[index]
            if message.role == .user {
                if firstUserIndex == nil {
                    if index > turnStart {
                        turns.append(
                            ChatConversationTurn(
                                range: turnStart..<index,
                                userRange: nil
                            )
                        )
                        turnStart = index
                    }
                    firstUserIndex = index
                    hasResponseAfterUser = false
                } else if hasResponseAfterUser {
                    let userStart = firstUserIndex ?? turnStart
                    turns.append(
                        ChatConversationTurn(
                            range: turnStart..<index,
                            userRange: userStart..<firstResponseIndex(
                                from: userStart,
                                before: index,
                                in: messages
                            )
                        )
                    )
                    turnStart = index
                    firstUserIndex = index
                    hasResponseAfterUser = false
                }
            } else if firstUserIndex != nil {
                hasResponseAfterUser = true
            }
        }

        if let firstUserIndex {
            turns.append(
                ChatConversationTurn(
                    range: turnStart..<messages.endIndex,
                    userRange: firstUserIndex..<firstResponseIndex(
                        from: firstUserIndex,
                        before: messages.endIndex,
                        in: messages
                    )
                )
            )
        } else if turnStart < messages.endIndex {
            turns.append(
                ChatConversationTurn(
                    range: turnStart..<messages.endIndex,
                    userRange: nil
                )
            )
        }

        return turns
    }

    public static func turn(
        containingMessageID messageID: UUID,
        in messages: [ChatMessage]
    ) -> ChatConversationTurn? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        return turns(in: messages).first { $0.range.contains(index) }
    }

    private static func firstResponseIndex(
        from userStart: Int,
        before upperBound: Int,
        in messages: [ChatMessage]
    ) -> Int {
        guard userStart < upperBound else { return upperBound }
        return messages[userStart..<upperBound]
            .firstIndex(where: { $0.role != .user }) ?? upperBound
    }
}

/// 每个正文、音频、图片或文件都对应独立 ChatMessage，确保它们可独立删除和进入上下文。
public enum ChatMessageAtomicContentSupport {
    private static let attachmentPlaceholders: Set<String> = [
        "[语音消息]", "[語音訊息]", "[Audio]", "[音声メッセージ]", "[Mensaje de audio]", "[Message audio]", "[رسالة صوتية]", "[Аудиосообщение]",
        "[图片]", "[圖片]", "[Image]", "[画像]", "[Imagen]", "[صورة]", "[Изображение]",
        "[文件]", "[檔案]", "[File]", "[ファイル]", "[Archivo]", "[Fichier]", "[ملف]", "[Файл]",
        "[视频]", "[影片]", "[Video]", "[ビデオ]", "[Vídeo]", "[Vidéo]", "[فيديو]", "[Видео]"
    ]

    public static func atomized(_ message: ChatMessage) -> [ChatMessage] {
        let imageFileNames = message.imageFileNames ?? []
        let fileFileNames = message.fileFileNames ?? []
        let attachmentCount = (message.audioFileName == nil ? 0 : 1)
            + imageFileNames.count
            + fileFileNames.count
        guard attachmentCount > 0 else { return [message] }

        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSubstantiveContent = !trimmedContent.isEmpty
            && !attachmentPlaceholders.contains(trimmedContent)
        let hasCorePayload = hasSubstantiveContent
            || !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.toolCalls ?? []).isEmpty
            || message.role == .error
        let isUserAudioTranscription = message.role == .user
            && message.audioFileName != nil
            && imageFileNames.isEmpty
            && fileFileNames.isEmpty
            && message.reasoningContent == nil
            && (message.toolCalls ?? []).isEmpty

        guard attachmentCount > 1 || (hasCorePayload && !isUserAudioTranscription) else {
            return [message]
        }

        var components: [ChatMessage] = []

        if let audioFileName = message.audioFileName {
            let isMetadataCarrier = !hasCorePayload && components.count == attachmentCount - 1
            components.append(
                attachmentComponent(
                    from: message,
                    id: isMetadataCarrier ? message.id : UUID(),
                    content: NSLocalizedString("[语音消息]", comment: "Audio message placeholder"),
                    audioFileName: audioFileName,
                    carriesResponseMetadata: isMetadataCarrier
                )
            )
        }

        let excludedImages = Set(message.modelExcludedImageFileNames ?? [])
        for imageFileName in imageFileNames {
            let isMetadataCarrier = !hasCorePayload && components.count == attachmentCount - 1
            components.append(
                attachmentComponent(
                    from: message,
                    id: isMetadataCarrier ? message.id : UUID(),
                    content: NSLocalizedString("[图片]", comment: "Image message placeholder"),
                    imageFileName: imageFileName,
                    excludesImageFromModel: excludedImages.contains(imageFileName),
                    carriesResponseMetadata: isMetadataCarrier
                )
            )
        }

        for fileFileName in fileFileNames {
            let isVideo = VideoAttachmentSupport.isVideo(fileName: fileFileName)
            let isMetadataCarrier = !hasCorePayload && components.count == attachmentCount - 1
            components.append(
                attachmentComponent(
                    from: message,
                    id: isMetadataCarrier ? message.id : UUID(),
                    content: isVideo
                        ? NSLocalizedString("[视频]", comment: "Video message placeholder")
                        : NSLocalizedString("[文件]", comment: "File message placeholder"),
                    fileFileName: fileFileName,
                    carriesResponseMetadata: isMetadataCarrier
                )
            )
        }

        if hasCorePayload {
            var core = message
            core.audioFileName = nil
            core.imageFileNames = nil
            core.modelExcludedImageFileNames = nil
            core.fileFileNames = nil
            core.videoAnalysisResults = nil
            components.append(core)
        }

        return components
    }

    public static func isAttachmentPlaceholder(_ content: String) -> Bool {
        attachmentPlaceholders.contains(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func attachmentComponent(
        from source: ChatMessage,
        id: UUID,
        content: String,
        audioFileName: String? = nil,
        imageFileName: String? = nil,
        excludesImageFromModel: Bool = false,
        fileFileName: String? = nil,
        carriesResponseMetadata: Bool
    ) -> ChatMessage {
        var component = source
        component.id = id
        component.clearContentVersions()
        component.content = content
        component.reasoningContent = nil
        component.reasoningProviderSpecificFields = nil
        component.toolCalls = nil
        component.toolCallsPlacement = nil
        component.audioFileName = audioFileName
        component.imageFileNames = imageFileName.map { [$0] }
        component.modelExcludedImageFileNames = excludesImageFromModel ? imageFileName.map { [$0] } : nil
        component.fileFileNames = fileFileName.map { [$0] }
        component.videoAnalysisResults = fileFileName.map { fileName in
            (source.videoAnalysisResults ?? []).filter { $0.fileName == fileName }
        }.flatMap { $0.isEmpty ? nil : $0 }

        if !carriesResponseMetadata {
            component.providerResponseMetadata = nil
            component.tokenUsage = nil
            component.costEstimate = nil
            component.fullErrorContent = nil
            component.sentSystemPromptSnapshot = nil
            component.responseMetrics = nil
        }
        return component
    }
}
