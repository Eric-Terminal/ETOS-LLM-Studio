// ============================================================================
// MessageExcerptAttachmentSupport.swift
// ============================================================================
// 将历史消息选区包装为带来源元数据的文本附件。
// ============================================================================

import Foundation

public enum MessageExcerptAttachmentSupport {
    public static func makeAttachment(
        selectedText: String,
        sourceMessage: ChatMessage
    ) -> FileAttachment? {
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let fileName = "excerpt_from_previous_\(sourceMessage.role.rawValue)_message.txt"
        let document = """
        ---
        etos_attachment_type: previous_message_excerpt
        source_role: \(sourceMessage.role.rawValue)
        source_message_id: \(sourceMessage.id.uuidString)
        selection_scope: excerpt
        content_type: quoted_reference
        ---

        \(selectedText)
        """
        return FileAttachment(
            data: Data(document.utf8),
            mimeType: "text/plain",
            fileName: fileName
        )
    }
}
