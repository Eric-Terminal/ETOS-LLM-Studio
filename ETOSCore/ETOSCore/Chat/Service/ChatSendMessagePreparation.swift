import Foundation
import os.log

/// 后台准备仅接收值，不接触 ChatService 的会话状态、发布器或 UI 回执。
struct ChatSendMessagePreparation: Sendable {
    let content: String
    let requestedAt: Date
    let messages: [ChatMessage]
    let primaryMessage: ChatMessage?
    let imageFileNames: [String]
    let messageIDsBySource: [ChatSendPresentationSource: UUID]

    static func prepare(
        content: String,
        audioAttachment: AudioAttachment?,
        imageAttachments: [ImageAttachment],
        fileAttachments: [FileAttachment],
        placeholders: (audio: String, image: String, file: String, video: String),
        authorKind: ConversationMessageAuthorKind,
        sourceSessionID: UUID?,
        sourceMessageID: UUID?,
        conversationEventID: UUID?
    ) -> Self {
        let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatSendMessagePreparation")
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageContent = MessageRegexRuleTransformer.apply(
            trimmedContent, rules: MessageRegexRuleStore.currentRules(), scope: .user, mode: .persist
        )
        let requestTimestamp = Date()
        var savedAudioFileName: String?
        var savedImages: [(fileName: String, source: ChatSendPresentationSource)] = []
        var savedFiles: [(fileName: String, isVideo: Bool, source: ChatSendPresentationSource)] = []
        var messages: [ChatMessage] = []
        var primaryMessage: ChatMessage?
        var messageIDsBySource: [ChatSendPresentationSource: UUID] = [:]

        if let audioAttachment {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let audioFileName = String(
                format: NSLocalizedString("语音_%@.%@", comment: "Generated audio attachment file name"),
                timestamp,
                audioAttachment.format
            )
            if Persistence.saveAudio(audioAttachment.data, fileName: audioFileName) != nil {
                savedAudioFileName = audioFileName
                logger.info("音频文件已保存: \(audioFileName)")
            }
        }
        for image in imageAttachments {
            if Persistence.saveImage(image.data, fileName: image.fileName) != nil {
                savedImages.append((image.fileName, .image(image.id)))
                logger.info("图片文件已保存: \(image.fileName)")
            }
        }
        for file in fileAttachments {
            let originalName = (file.fileName as NSString).lastPathComponent
            if let targetName = Persistence.saveFileDeduplicatingByName(file.data, preferredFileName: originalName) {
                savedFiles.append((targetName, VideoAttachmentSupport.isVideo(file), .file(file.id)))
                logger.info("文件附件已保存或复用: \(targetName)")
            }
        }

        // 保存与消息发布的分组顺序保持一致；同名复用仍按每个来源身份分别建消息。
        if let savedAudioFileName, let audioAttachment {
            let message = ChatMessage(
                role: .user, content: placeholders.audio, requestedAt: requestTimestamp,
                audioFileName: savedAudioFileName, authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[.audio(audioAttachment.id)] = message.id
        }
        for image in savedImages {
            let message = ChatMessage(
                role: .user, content: placeholders.image, requestedAt: requestTimestamp,
                imageFileNames: [image.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[image.source] = message.id
        }
        for file in savedFiles where file.isVideo {
            let message = ChatMessage(
                role: .user, content: placeholders.video, requestedAt: requestTimestamp,
                fileFileNames: [file.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[file.source] = message.id
        }
        for file in savedFiles where !file.isVideo {
            let message = ChatMessage(
                role: .user, content: placeholders.file, requestedAt: requestTimestamp,
                fileFileNames: [file.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[file.source] = message.id
        }
        if !messageContent.isEmpty {
            let message = ChatMessage(
                role: .user, content: messageContent, requestedAt: requestTimestamp,
                authorKind: authorKind, sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID, conversationEventID: conversationEventID
            )
            messages.append(message)
            primaryMessage = message
            messageIDsBySource[.text] = message.id
        }
        return Self(
            content: messageContent, requestedAt: requestTimestamp,
            messages: messages, primaryMessage: primaryMessage,
            imageFileNames: savedImages.map(\.fileName), messageIDsBySource: messageIDsBySource
        )
    }
}
