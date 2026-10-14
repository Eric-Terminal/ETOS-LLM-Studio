import ETOSCore
import Foundation

struct MacImageGalleryItem: Identifiable, Sendable {
    let sessionID: UUID
    let message: ChatMessage
    let fileName: String
    let sourcePrompt: String
    let url: URL
    var id: String { "\(sessionID)-\(message.id)-\(fileName)" }

    static func prepare(messages: [ChatMessage], sessionID: UUID, directory: URL) -> [Self] {
        var prompt = ""
        var items: [Self] = []
        for message in messages {
            if message.role == .user { prompt = message.content }
            guard message.role == .assistant else { continue }
            var seen = Set<String>()
            for fileName in message.imageFileNames ?? [] where seen.insert(fileName).inserted {
                items.append(Self(sessionID: sessionID, message: message, fileName: fileName,
                    sourcePrompt: prompt, url: directory.appendingPathComponent(fileName)))
            }
        }
        return items.reversed()
    }

    /// 同时维护模型排除标记；没有其他内容时，沿用消息删除流程清理附件引用。
    func removingImage() -> ChatMessage? {
        var edited = message
        let images = (message.imageFileNames ?? []).filter { $0 != fileName }
        let excluded = (message.modelExcludedImageFileNames ?? []).filter { $0 != fileName }
        edited.imageFileNames = images.isEmpty ? nil : images
        edited.modelExcludedImageFileNames = excluded.isEmpty ? nil : excluded
        let hasPayload = (!edited.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ChatMessageAtomicContentSupport.isAttachmentPlaceholder(edited.content))
            || !(edited.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(edited.toolCalls ?? []).isEmpty || !images.isEmpty
            || edited.audioFileName != nil || !(edited.fileFileNames ?? []).isEmpty
        return hasPayload ? edited : nil
    }
}
