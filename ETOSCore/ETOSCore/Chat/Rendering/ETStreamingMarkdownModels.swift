// ============================================================================
// ETStreamingMarkdownModels.swift
// ============================================================================
// ETOSCore
//
// 流式 Markdown 的跨平台不可变渲染快照。
// ============================================================================

import Combine
import Foundation

public enum ETStreamingMarkdownChannel: String, Hashable, Sendable {
    case content
    case reasoning
}

public struct ETStreamingMarkdownStreamID: Hashable, Sendable {
    public let messageID: UUID
    public let channel: ETStreamingMarkdownChannel

    public init(messageID: UUID, channel: ETStreamingMarkdownChannel) {
        self.messageID = messageID
        self.channel = channel
    }
}

public struct ETStreamingMarkdownBlockID: Hashable, Sendable {
    public let messageID: UUID
    public let channel: ETStreamingMarkdownChannel
    public let generation: Int
    public let ordinal: Int

    public init(
        messageID: UUID,
        channel: ETStreamingMarkdownChannel = .content,
        generation: Int = 0,
        ordinal: Int
    ) {
        self.messageID = messageID
        self.channel = channel
        self.generation = generation
        self.ordinal = ordinal
    }
}

public enum ETStreamingMarkdownBlockKind: Hashable, Sendable {
    case markdown
    case fencedCode(language: String?)
    case mermaid
}

public struct ETStreamingMarkdownBlock: Identifiable, Hashable, Sendable {
    public let id: ETStreamingMarkdownBlockID
    public let source: String
    public let kind: ETStreamingMarkdownBlockKind
    public let leadingSpacingEm: Double

    public init(
        id: ETStreamingMarkdownBlockID,
        source: String,
        kind: ETStreamingMarkdownBlockKind,
        leadingSpacingEm: Double
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.leadingSpacingEm = leadingSpacingEm
    }
}

public enum ETStreamingMarkdownActivePresentation: Hashable, Sendable {
    case markdownSource
    case code(language: String?)
    case mermaidSource
}

public enum ETStreamingMarkdownUpdateKind: Hashable, Sendable {
    case append(previousUTF16Length: Int)
    case reset
}

public struct ETStreamingMarkdownActiveBlock: Identifiable, Hashable, Sendable {
    public let id: ETStreamingMarkdownBlockID
    public let source: String
    public let displayText: String
    public let presentation: ETStreamingMarkdownActivePresentation
    public let updateKind: ETStreamingMarkdownUpdateKind
    public let leadingSpacingEm: Double

    public init(
        id: ETStreamingMarkdownBlockID,
        source: String,
        displayText: String,
        presentation: ETStreamingMarkdownActivePresentation,
        updateKind: ETStreamingMarkdownUpdateKind,
        leadingSpacingEm: Double
    ) {
        self.id = id
        self.source = source
        self.displayText = displayText
        self.presentation = presentation
        self.updateKind = updateKind
        self.leadingSpacingEm = leadingSpacingEm
    }
}

public struct ETStreamingMarkdownSnapshot: Hashable, Sendable {
    public let messageID: UUID
    public let channel: ETStreamingMarkdownChannel
    public let sourceText: String
    public let revision: Int
    public let committedBlocks: [ETStreamingMarkdownBlock]
    public let activeBlock: ETStreamingMarkdownActiveBlock?
    public let isFinal: Bool

    public init(
        messageID: UUID,
        channel: ETStreamingMarkdownChannel = .content,
        sourceText: String,
        revision: Int,
        committedBlocks: [ETStreamingMarkdownBlock],
        activeBlock: ETStreamingMarkdownActiveBlock?,
        isFinal: Bool
    ) {
        self.messageID = messageID
        self.channel = channel
        self.sourceText = sourceText
        self.revision = revision
        self.committedBlocks = committedBlocks
        self.activeBlock = activeBlock
        self.isFinal = isFinal
    }
}

/// 正文与推理共享同一消息生命周期，但各自独立发布，避免正文增长刷新整颗气泡。
@MainActor
public final class ETStreamingMarkdownRenderState: ObservableObject {
    @Published public private(set) var contentSnapshot: ETStreamingMarkdownSnapshot?
    @Published public private(set) var reasoningSnapshot: ETStreamingMarkdownSnapshot?
    @Published private var staticHandoffSourceTexts: [ETStreamingMarkdownChannel: String] = [:]

    public init() {}

    public func snapshot(for channel: ETStreamingMarkdownChannel) -> ETStreamingMarkdownSnapshot? {
        switch channel {
        case .content:
            return contentSnapshot
        case .reasoning:
            return reasoningSnapshot
        }
    }

    /// 网络结束与静态 Markdown 准备完成并非同一时刻。记录本次交接的最终源码，
    /// 让界面继续沿用最后一帧流式视图，而不是短暂暴露 Markdown 标记。
    public func beginStaticHandoff(sourceText: String, channel: ETStreamingMarkdownChannel) {
        guard staticHandoffSourceTexts[channel] != sourceText else { return }
        staticHandoffSourceTexts[channel] = sourceText
    }

    public func isAwaitingStaticHandoff(
        sourceText: String,
        channel: ETStreamingMarkdownChannel
    ) -> Bool {
        staticHandoffSourceTexts[channel] == sourceText
    }

    /// 静态 Markdown 已发布后释放最终源码，避免历史消息长期重复持有整段文本。
    public func completeStaticHandoff(
        sourceText: String,
        channel: ETStreamingMarkdownChannel
    ) {
        guard staticHandoffSourceTexts[channel] == sourceText else { return }
        staticHandoffSourceTexts.removeValue(forKey: channel)
    }

    public func apply(_ snapshot: ETStreamingMarkdownSnapshot) {
        if !snapshot.isFinal {
            staticHandoffSourceTexts.removeValue(forKey: snapshot.channel)
        }
        switch snapshot.channel {
        case .content:
            guard contentSnapshot != snapshot else { return }
            contentSnapshot = snapshot
        case .reasoning:
            guard reasoningSnapshot != snapshot else { return }
            reasoningSnapshot = snapshot
        }
    }

    public func clear(_ channel: ETStreamingMarkdownChannel? = nil) {
        switch channel {
        case .content:
            contentSnapshot = nil
            staticHandoffSourceTexts.removeValue(forKey: .content)
        case .reasoning:
            reasoningSnapshot = nil
            staticHandoffSourceTexts.removeValue(forKey: .reasoning)
        case nil:
            contentSnapshot = nil
            reasoningSnapshot = nil
            staticHandoffSourceTexts.removeAll()
        }
    }
}
