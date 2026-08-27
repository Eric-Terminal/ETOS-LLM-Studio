// ============================================================================
// ChatViewLayoutIntegrity.swift
// ============================================================================
// 聊天列表布局一致性审计
// - 只在滚动与内容更新静止后检查可见消息
// - 局部恢复失败时重建消息栈，并按可见消息 frame 恢复阅读锚点
// ============================================================================

import Foundation
import SwiftUI

struct ChatMessageLayoutMetadata: Equatable, Sendable {
    let role: String
    let contentUTF8Length: Int
    let reasoningUTF8Length: Int
    let isAwaitingStaticHandoff: Bool
    let hasPreparedMarkdown: Bool
    let hasPreparedReasoningMarkdown: Bool
    let layoutRevision: UInt
    let recoveryRevision: UInt
    let rendererHandoffRevision: UInt
    let rendererHandoffAt: Date?
    let usesNoBubbleStyle: Bool
    let contentRenderer: ChatBubbleRendererIdentity
    let reasoningRenderer: ChatBubbleRendererIdentity
    let layoutWidthBucket: Int

    nonisolated init(
        role: String,
        contentUTF8Length: Int,
        reasoningUTF8Length: Int,
        isAwaitingStaticHandoff: Bool,
        hasPreparedMarkdown: Bool,
        hasPreparedReasoningMarkdown: Bool,
        layoutRevision: UInt,
        recoveryRevision: UInt,
        rendererHandoffRevision: UInt,
        rendererHandoffAt: Date?,
        usesNoBubbleStyle: Bool,
        contentRenderer: ChatBubbleRendererIdentity,
        reasoningRenderer: ChatBubbleRendererIdentity,
        layoutWidthBucket: Int
    ) {
        self.role = role
        self.contentUTF8Length = contentUTF8Length
        self.reasoningUTF8Length = reasoningUTF8Length
        self.isAwaitingStaticHandoff = isAwaitingStaticHandoff
        self.hasPreparedMarkdown = hasPreparedMarkdown
        self.hasPreparedReasoningMarkdown = hasPreparedReasoningMarkdown
        self.layoutRevision = layoutRevision
        self.recoveryRevision = recoveryRevision
        self.rendererHandoffRevision = rendererHandoffRevision
        self.rendererHandoffAt = rendererHandoffAt
        self.usesNoBubbleStyle = usesNoBubbleStyle
        self.contentRenderer = contentRenderer
        self.reasoningRenderer = reasoningRenderer
        self.layoutWidthBucket = layoutWidthBucket
    }
}

struct ChatMessageLayoutSample: Equatable, Sendable {
    let frame: CGRect
    let metadata: ChatMessageLayoutMetadata

    nonisolated init(frame: CGRect, metadata: ChatMessageLayoutMetadata) {
        self.frame = frame
        self.metadata = metadata
    }
}

struct ChatMessageLayoutFrameSnapshot: Equatable, Sendable {
    var probeRevision: UInt
    var stackRecoveryRevision: UInt
    var samples: [UUID: ChatMessageLayoutSample]
    var contentFrames: [UUID: CGRect]

    nonisolated static let empty = Self(
        probeRevision: 0,
        stackRecoveryRevision: 0,
        samples: [:],
        contentFrames: [:]
    )

    nonisolated init(
        probeRevision: UInt,
        stackRecoveryRevision: UInt,
        samples: [UUID: ChatMessageLayoutSample],
        contentFrames: [UUID: CGRect]
    ) {
        self.probeRevision = probeRevision
        self.stackRecoveryRevision = stackRecoveryRevision
        self.samples = samples
        self.contentFrames = contentFrames
    }
}

struct ChatMessageLayoutOverlap: Equatable, Sendable {
    let upperMessageID: UUID
    let lowerMessageID: UUID
    let overlapHeight: CGFloat

    nonisolated init(upperMessageID: UUID, lowerMessageID: UUID, overlapHeight: CGFloat) {
        self.upperMessageID = upperMessageID
        self.lowerMessageID = lowerMessageID
        self.overlapHeight = overlapHeight
    }
}

struct ChatLayoutViewportAnchor: Equatable, Sendable {
    let messageID: UUID
    let minY: CGFloat

    nonisolated init(messageID: UUID, minY: CGFloat) {
        self.messageID = messageID
        self.minY = minY
    }
}

enum ChatMessageNavigationDirection: Sendable {
    case previous
    case next
}

enum ChatLayoutRecoveryAction: Equatable, Sendable {
    case rebuildMessages
    case rebuildStack
    case stop
}

enum ChatMessageLayoutAudit {
    nonisolated static let coordinateSpaceName = "chatMessageLayoutAudit"
    nonisolated static let minimumOverlapHeight: CGFloat = 2
    nonisolated static let viewportEdgeExclusion: CGFloat = 44

    nonisolated static func firstOverlap(
        orderedMessageIDs: [UUID],
        frames: [UUID: CGRect],
        viewportHeight: CGFloat,
        minimumOverlapHeight: CGFloat = ChatMessageLayoutAudit.minimumOverlapHeight,
        viewportEdgeExclusion: CGFloat = ChatMessageLayoutAudit.viewportEdgeExclusion
    ) -> ChatMessageLayoutOverlap? {
        guard orderedMessageIDs.count > 1, viewportHeight > 0 else { return nil }

        for index in 0..<(orderedMessageIDs.count - 1) {
            let upperMessageID = orderedMessageIDs[index]
            let lowerMessageID = orderedMessageIDs[index + 1]
            guard let upperFrame = frames[upperMessageID],
                  let lowerFrame = frames[lowerMessageID],
                  isUsable(upperFrame),
                  isUsable(lowerFrame) else {
                continue
            }

            let intersectionStart = max(upperFrame.minY, lowerFrame.minY)
            let intersectionEnd = min(upperFrame.maxY, lowerFrame.maxY)
            let overlapHeight = intersectionEnd - intersectionStart
            guard overlapHeight > minimumOverlapHeight else { continue }

            // scrollTransition 会在视口边缘对进出场消息施加合法位移。
            let overlapMidpoint = (intersectionStart + intersectionEnd) / 2
            let safeMinimumY = min(viewportEdgeExclusion, viewportHeight / 3)
            let safeMaximumY = max(safeMinimumY, viewportHeight - safeMinimumY)
            guard overlapMidpoint >= safeMinimumY, overlapMidpoint <= safeMaximumY else {
                continue
            }

            return ChatMessageLayoutOverlap(
                upperMessageID: upperMessageID,
                lowerMessageID: lowerMessageID,
                overlapHeight: overlapHeight
            )
        }

        return nil
    }

    nonisolated static func effectiveFrames(
        samples: [UUID: ChatMessageLayoutSample],
        contentFrames: [UUID: CGRect]
    ) -> [UUID: CGRect] {
        var frames = samples.mapValues(\.frame)
        for (messageID, contentFrame) in contentFrames where isUsable(contentFrame) {
            if let rowFrame = frames[messageID], isUsable(rowFrame) {
                frames[messageID] = rowFrame.union(contentFrame)
            } else {
                frames[messageID] = contentFrame
            }
        }
        return frames
    }

    nonisolated static func viewportAnchor(
        orderedMessageIDs: [UUID],
        frames: [UUID: CGRect],
        viewportHeight: CGFloat
    ) -> ChatLayoutViewportAnchor? {
        guard viewportHeight > 0 else { return nil }
        let viewportMidY = viewportHeight / 2
        var bestCandidate: (anchor: ChatLayoutViewportAnchor, distance: CGFloat)?

        for messageID in orderedMessageIDs {
            guard let frame = frames[messageID], isUsable(frame) else { continue }
            let visibleStart = max(frame.minY, 0)
            let visibleEnd = min(frame.maxY, viewportHeight)
            guard visibleEnd > visibleStart else { continue }

            let visibleMidY = (visibleStart + visibleEnd) / 2
            let distance = abs(visibleMidY - viewportMidY)
            if bestCandidate == nil || distance < bestCandidate!.distance {
                bestCandidate = (
                    ChatLayoutViewportAnchor(messageID: messageID, minY: frame.minY),
                    distance
                )
            }
        }

        return bestCandidate?.anchor
    }

    /// 从已上报的可见 frame 中解析最靠前的真实气泡，避免扫描完整历史。
    nonisolated static func navigationAnchorMessageID(
        indexByMessageID: [UUID: Int],
        frames: [UUID: CGRect],
        viewportHeight: CGFloat,
        retainedAnchorID: UUID?,
        topRevealInset: CGFloat = 0
    ) -> UUID? {
        if let retainedAnchorID, indexByMessageID[retainedAnchorID] != nil {
            return retainedAnchorID
        }
        guard viewportHeight > topRevealInset else { return nil }

        var bestCandidate: (messageID: UUID, index: Int)?
        for (messageID, frame) in frames {
            guard let index = indexByMessageID[messageID],
                  isUsable(frame),
                  frame.maxY > topRevealInset + 0.5,
                  frame.minY < viewportHeight else {
                continue
            }
            if bestCandidate == nil || index < bestCandidate!.index {
                bestCandidate = (messageID, index)
            }
        }
        return bestCandidate?.messageID
    }

    /// 连续点击沿用上一目标；首次点击则以顶部下方第一条仍可见的气泡为锚点。
    nonisolated static func adjacentMessageID(
        orderedMessageIDs: [UUID],
        frames: [UUID: CGRect],
        viewportHeight: CGFloat,
        retainedAnchorID: UUID?,
        direction: ChatMessageNavigationDirection,
        topRevealInset: CGFloat = 0
    ) -> UUID? {
        guard !orderedMessageIDs.isEmpty, viewportHeight > topRevealInset else { return nil }

        let indexByMessageID = Dictionary(
            uniqueKeysWithValues: orderedMessageIDs.enumerated().map { ($0.element, $0.offset) }
        )
        guard let anchorMessageID = navigationAnchorMessageID(
            indexByMessageID: indexByMessageID,
            frames: frames,
            viewportHeight: viewportHeight,
            retainedAnchorID: retainedAnchorID,
            topRevealInset: topRevealInset
        ), let anchorIndex = indexByMessageID[anchorMessageID] else { return nil }

        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = anchorIndex - 1
        case .next:
            targetIndex = anchorIndex + 1
        }
        guard orderedMessageIDs.indices.contains(targetIndex) else { return nil }
        return orderedMessageIDs[targetIndex]
    }

    nonisolated static func recoveryAction(
        localAttempts: Int,
        stackAttempts: Int,
        maximumLocalAttempts: Int = 2,
        maximumStackAttempts: Int = 1
    ) -> ChatLayoutRecoveryAction {
        if localAttempts < maximumLocalAttempts { return .rebuildMessages }
        if stackAttempts < maximumStackAttempts { return .rebuildStack }
        return .stop
    }

    nonisolated static func isFreshVerificationSample(
        baselineSnapshotRevision: UInt,
        currentSnapshotRevision: UInt,
        requestedProbeRevision: UInt,
        reportedProbeRevision: UInt
    ) -> Bool {
        currentSnapshotRevision > baselineSnapshotRevision
            && reportedProbeRevision >= requestedProbeRevision
    }

    nonisolated private static func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.minX.isFinite
            && frame.minY.isFinite
            && frame.maxX.isFinite
            && frame.maxY.isFinite
    }
}

struct ChatMessageLayoutFramePreferenceKey: PreferenceKey {
    static var defaultValue = ChatMessageLayoutFrameSnapshot.empty

    static func reduce(
        value: inout ChatMessageLayoutFrameSnapshot,
        nextValue: () -> ChatMessageLayoutFrameSnapshot
    ) {
        let next = nextValue()
        value.probeRevision = max(value.probeRevision, next.probeRevision)
        value.stackRecoveryRevision = max(
            value.stackRecoveryRevision,
            next.stackRecoveryRevision
        )
        value.samples.merge(next.samples, uniquingKeysWith: { _, newest in newest })
        value.contentFrames.merge(
            next.contentFrames,
            uniquingKeysWith: { _, newest in newest }
        )
    }
}

struct ChatMessageLayoutFrameReporter: View {
    let messageID: UUID
    let metadata: ChatMessageLayoutMetadata
    let probeRevision: UInt
    let stackRecoveryRevision: UInt

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatMessageLayoutFramePreferenceKey.self,
                value: ChatMessageLayoutFrameSnapshot(
                    probeRevision: probeRevision,
                    stackRecoveryRevision: stackRecoveryRevision,
                    samples: [
                        messageID: ChatMessageLayoutSample(
                            frame: proxy.frame(
                                in: .named(ChatMessageLayoutAudit.coordinateSpaceName)
                            ),
                            metadata: metadata
                        )
                    ],
                    contentFrames: [:]
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ChatMessageRenderedContentFrameReporter: View {
    let messageID: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatMessageLayoutFramePreferenceKey.self,
                value: ChatMessageLayoutFrameSnapshot(
                    probeRevision: 0,
                    stackRecoveryRevision: 0,
                    samples: [:],
                    contentFrames: [
                        messageID: proxy.frame(
                            in: .named(ChatMessageLayoutAudit.coordinateSpaceName)
                        )
                    ]
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ChatLayoutAuditContext: Equatable {
    let sessionID: UUID?
    let viewportSize: CGSize
    let isChatVisible: Bool
    let isAppActive: Bool
    let isUserInteracting: Bool
    let isSendingMessage: Bool
    let isLayoutSettling: Bool
    let isHistoryLoadInFlight: Bool
    let hasProgrammaticScrollTarget: Bool
    let hasSendFlight: Bool
    let scrollAnimationEnabled: Bool
    let settleDelayNanoseconds: UInt64
    let usesNoBubbleUI: Bool
    let fontScale: Double
    let systemVersion: String

    nonisolated init(
        sessionID: UUID?,
        viewportSize: CGSize,
        isChatVisible: Bool,
        isAppActive: Bool,
        isUserInteracting: Bool,
        isSendingMessage: Bool,
        isLayoutSettling: Bool,
        isHistoryLoadInFlight: Bool,
        hasProgrammaticScrollTarget: Bool,
        hasSendFlight: Bool,
        scrollAnimationEnabled: Bool,
        settleDelayNanoseconds: UInt64,
        usesNoBubbleUI: Bool,
        fontScale: Double,
        systemVersion: String
    ) {
        self.sessionID = sessionID
        self.viewportSize = viewportSize
        self.isChatVisible = isChatVisible
        self.isAppActive = isAppActive
        self.isUserInteracting = isUserInteracting
        self.isSendingMessage = isSendingMessage
        self.isLayoutSettling = isLayoutSettling
        self.isHistoryLoadInFlight = isHistoryLoadInFlight
        self.hasProgrammaticScrollTarget = hasProgrammaticScrollTarget
        self.hasSendFlight = hasSendFlight
        self.scrollAnimationEnabled = scrollAnimationEnabled
        self.settleDelayNanoseconds = settleDelayNanoseconds
        self.usesNoBubbleUI = usesNoBubbleUI
        self.fontScale = fontScale
        self.systemVersion = systemVersion
    }

    var isBlocked: Bool {
        !isChatVisible
            || !isAppActive
            || isUserInteracting
            || isSendingMessage
            || isLayoutSettling
            || isHistoryLoadInFlight
            || hasProgrammaticScrollTarget
            || hasSendFlight
    }
}

enum ChatLayoutDiagnosticFormatter {
    nonisolated static func description(
        stage: String,
        upperAlias: String,
        lowerAlias: String,
        upperSample: ChatMessageLayoutSample?,
        lowerSample: ChatMessageLayoutSample?,
        upperContentFrame: CGRect?,
        lowerContentFrame: CGRect?,
        overlapHeight: CGFloat,
        attempt: Int,
        context: ChatLayoutAuditContext
    ) -> String {
        let upper = messageDescription(
            alias: upperAlias,
            sample: upperSample,
            contentFrame: upperContentFrame
        )
        let lower = messageDescription(
            alias: lowerAlias,
            sample: lowerSample,
            contentFrame: lowerContentFrame
        )
        let fontScale = String(format: "%.2f", context.fontScale)
        return "stage=\(stage) attempt=\(attempt) overlap=\(number(overlapHeight)) "
            + "upper={\(upper)} lower={\(lower)} "
            + "viewport={w:\(number(context.viewportSize.width)),h:\(number(context.viewportSize.height))} "
            + "fontScale=\(fontScale) system=\(context.systemVersion) "
            + "noBubble=\(context.usesNoBubbleUI) appActive=\(context.isAppActive) "
            + "userInteracting=\(context.isUserInteracting) streaming=\(context.isSendingMessage) "
            + "layoutSettling=\(context.isLayoutSettling) historyLoading=\(context.isHistoryLoadInFlight) "
            + "programmaticScroll=\(context.hasProgrammaticScrollTarget) sendFlight=\(context.hasSendFlight) "
            + "scrollAnimation=\(context.scrollAnimationEnabled)"
    }

    nonisolated private static func messageDescription(
        alias: String,
        sample: ChatMessageLayoutSample?,
        contentFrame: CGRect?
    ) -> String {
        guard let sample else { return "id:\(alias),missing:true" }
        let metadata = sample.metadata
        let handoffAge = metadata.rendererHandoffAt.map {
            String(max(0, Int(Date().timeIntervalSince($0) * 1_000)))
        } ?? "none"
        let renderedContentFrame = contentFrame.map { frame($0) } ?? "none"
        return "id:\(alias),role:\(metadata.role),contentBytes:\(metadata.contentUTF8Length),"
            + "reasoningBytes:\(metadata.reasoningUTF8Length),rowFrame:\(frame(sample.frame)),"
            + "contentFrame:\(renderedContentFrame),"
            + "awaitingHandoff:\(metadata.isAwaitingStaticHandoff),"
            + "prepared:\(metadata.hasPreparedMarkdown),"
            + "reasoningPrepared:\(metadata.hasPreparedReasoningMarkdown),"
            + "layoutRevision:\(metadata.layoutRevision),recoveryRevision:\(metadata.recoveryRevision),"
            + "handoffRevision:\(metadata.rendererHandoffRevision),handoffAgeMs:\(handoffAge),"
            + "noBubble:\(metadata.usesNoBubbleStyle),contentRenderer:\(metadata.contentRenderer.rawValue),"
            + "reasoningRenderer:\(metadata.reasoningRenderer.rawValue),widthBucket:\(metadata.layoutWidthBucket)"
    }

    nonisolated private static func frame(_ frame: CGRect) -> String {
        "{x:\(number(frame.minX)),y:\(number(frame.minY)),w:\(number(frame.width)),h:\(number(frame.height))}"
    }

    nonisolated private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
