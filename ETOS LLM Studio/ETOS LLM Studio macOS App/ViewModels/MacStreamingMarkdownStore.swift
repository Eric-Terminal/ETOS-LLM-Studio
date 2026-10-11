import ETOSCore
import Foundation

struct MacStreamingMarkdownSnapshot: @unchecked Sendable {
    struct Block: Identifiable {
        let id: ETStreamingMarkdownBlockID
        let text: MacPreparedMessageText
        let spacing: Double
    }
    let blocks: [Block]
    let active: ETStreamingMarkdownActiveBlock?
    let activeText: AttributedString?
    let reveal: MacStreamingReveal?
}

/// 每个窗口拥有独立管线，取消、重试和不同窗口的同一消息不会争用活动块。
actor MacStreamingMarkdownStore {
    private let pipeline = ETStreamingMarkdownPipeline()
    private var blocks: [ETStreamingMarkdownBlockID: MacPreparedMessageText] = [:]
    private var advanced = false
    private var revision = UUID()
    private var reveals: [ETStreamingMarkdownBlockID: MacStreamingReveal] = [:]

    func prepare(_ source: String, messageID: UUID, advanced: Bool) async throws -> MacPreparedMessageText {
        let revision = UUID(); self.revision = revision
        let snapshot = await pipeline.prepare(messageID: messageID, sourceText: source, isFinal: false)
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        if self.advanced != advanced { blocks.removeAll(); self.advanced = advanced }
        var items: [MacStreamingMarkdownSnapshot.Block] = []
        var retained: [ETStreamingMarkdownBlockID: MacPreparedMessageText] = [:]
        for block in snapshot.committedBlocks {
            let text = blocks[block.id] ?? MacPreparedMessageText(block.source, markdown: true, advanced: advanced)
            items.append(.init(id: block.id, text: text, spacing: block.leadingSpacingEm))
            retained[block.id] = text
        }
        blocks = retained
        let reveal = snapshot.activeBlock.map { active -> MacStreamingReveal in
            if let previous = reveals[active.id], previous.source == active.displayText { return previous }
            let prepared = MacStreamingReveal(source: active.displayText, previous: reveals[active.id])
            reveals[active.id] = prepared
            return prepared
        }
        let activeID = snapshot.activeBlock?.id
        reveals = reveals.filter { $0.key.messageID != messageID || $0.key == activeID }
        return MacPreparedMessageText(source, stream: .init(blocks: items, active: snapshot.activeBlock,
            activeText: snapshot.activeBlock.map { AttributedString($0.displayText) }, reveal: reveal))
    }

    func retain(_ messageIDs: Set<UUID>) async {
        blocks = blocks.filter { messageIDs.contains($0.key.messageID) }
        reveals = reveals.filter { messageIDs.contains($0.key.messageID) }
        await pipeline.retain(messageIDs: messageIDs)
    }
}
