// ============================================================================
// ChatViewLayoutIntegrity.swift
// ============================================================================
// 聊天列表布局一致性审计
// - 只在滚动与内容更新静止后检查可见消息
// - 局部恢复失败时重建消息栈，并按可见消息 frame 恢复阅读锚点
// ============================================================================

import Foundation
import Combine
import os.log
import SwiftUI
import UIKit
import ETOSCore

private let chatLayoutIntegrityLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "ChatLayoutIntegrity"
)

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

@MainActor
final class ChatLayoutIntegrityMonitor: ObservableObject {
    @Published private(set) var recoveryRevisionByMessageID: [UUID: UInt] = [:]
    @Published private(set) var layoutProbeRevision: UInt = 0
    @Published private(set) var stackRecoveryRevision: UInt = 0
    @Published private(set) var pendingAnchorAdjustment: ChatScrollAnchorAdjustment?
    @Published private(set) var anchorScrollTargetMessageID: UUID?
    @Published private(set) var isContentFrameProbeActive = false

    private struct MessagePair: Hashable {
        let upperMessageID: UUID
        let lowerMessageID: UUID
    }

    private struct PendingStackRecovery {
        let anchor: ChatLayoutViewportAnchor
        let targetStackRevision: UInt
        let baselineSnapshotRevision: UInt
    }

    private var context = ChatLayoutAuditContext(
        sessionID: nil,
        viewportSize: .zero,
        isChatVisible: false,
        isAppActive: false,
        isUserInteracting: false,
        isSendingMessage: false,
        isLayoutSettling: false,
        isHistoryLoadInFlight: false,
        hasProgrammaticScrollTarget: false,
        hasSendFlight: false,
        scrollAnimationEnabled: false,
        settleDelayNanoseconds: 450_000_000,
        usesNoBubbleUI: false,
        fontScale: 1,
        systemVersion: "unknown"
    )
    private var snapshot = ChatMessageLayoutFrameSnapshot.empty
    private var orderedMessageIDs: [UUID] = []
    private var snapshotRevision: UInt = 0
    private var requestedProbeRevision: UInt?
    private var confirmedHandoffRevisionByMessageID: [UUID: UInt] = [:]
    private var repairAttemptsByPair: [MessagePair: Int] = [:]
    private var stackRepairAttemptsByPair: [MessagePair: Int] = [:]
    private var reportedExhaustedPairs: Set<MessagePair> = []
    private var anonymousAliasByMessageID: [UUID: String] = [:]
    private var pendingStackRecovery: PendingStackRecovery?
    private var auditTask: Task<Void, Never>?
    private var auditGeneration: UInt = 0
    private var suppressAuditForContentFrameRemoval = false

    func recoveryRevision(for messageID: UUID) -> UInt {
        recoveryRevisionByMessageID[messageID, default: 0]
    }

    var currentSnapshotRevision: UInt {
        snapshotRevision
    }

    /// 回底完成后主动请求一帧新几何，避免相邻导航复用滚动前的气泡位置。
    func requestFreshNavigationSnapshot() -> UInt {
        let baselineRevision = snapshotRevision
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            layoutProbeRevision &+= 1
        }
        return baselineRevision
    }

    func updateContext(_ newContext: ChatLayoutAuditContext) {
        if context.sessionID != newContext.sessionID {
            reset()
        }
        guard context != newContext else { return }
        context = newContext
        if newContext.isUserInteracting {
            pendingStackRecovery = nil
            pendingAnchorAdjustment = nil
            anchorScrollTargetMessageID = nil
        }
        scheduleAuditIfPossible()
    }

    func updateSnapshot(
        _ newSnapshot: ChatMessageLayoutFrameSnapshot,
        orderedMessageIDs: [UUID]
    ) {
        guard snapshot != newSnapshot || self.orderedMessageIDs != orderedMessageIDs else { return }
        snapshot = newSnapshot
        self.orderedMessageIDs = orderedMessageIDs
        snapshotRevision &+= 1

        if suppressAuditForContentFrameRemoval, newSnapshot.contentFrames.isEmpty {
            suppressAuditForContentFrameRemoval = false
            return
        }

        if completeStackRecoveryIfPossible() {
            return
        }
        if let requestedProbeRevision,
           newSnapshot.probeRevision >= requestedProbeRevision {
            // 这是审计主动请求的下一次布局样本，保留当前审计任务继续比较。
            return
        }
        guard !context.isBlocked else { return }
        scheduleAuditIfPossible()
    }

    func adjacentMessageID(
        in navigationMessageIDs: [UUID],
        viewportHeight: CGFloat,
        retainedAnchorID: UUID?,
        direction: ChatMessageNavigationDirection
    ) -> UUID? {
        ChatMessageLayoutAudit.adjacentMessageID(
            orderedMessageIDs: navigationMessageIDs,
            frames: ChatMessageLayoutAudit.effectiveFrames(
                samples: snapshot.samples,
                contentFrames: snapshot.contentFrames
            ),
            viewportHeight: viewportHeight,
            retainedAnchorID: retainedAnchorID,
            direction: direction
        )
    }

    func navigationAnchorMessageID(
        in indexByMessageID: [UUID: Int],
        viewportHeight: CGFloat,
        retainedAnchorID: UUID?
    ) -> UUID? {
        ChatMessageLayoutAudit.navigationAnchorMessageID(
            indexByMessageID: indexByMessageID,
            frames: ChatMessageLayoutAudit.effectiveFrames(
                samples: snapshot.samples,
                contentFrames: snapshot.contentFrames
            ),
            viewportHeight: viewportHeight,
            retainedAnchorID: retainedAnchorID
        )
    }

    func completeAnchorAdjustment(id: UUID) {
        guard pendingAnchorAdjustment?.id == id else { return }
        pendingAnchorAdjustment = nil
        scheduleAuditIfPossible()
    }

    func stop() {
        cancelAudit()
        pendingStackRecovery = nil
        pendingAnchorAdjustment = nil
        anchorScrollTargetMessageID = nil
        snapshot = .empty
        orderedMessageIDs.removeAll(keepingCapacity: true)
        confirmedHandoffRevisionByMessageID.removeAll(keepingCapacity: true)
        repairAttemptsByPair.removeAll(keepingCapacity: true)
        stackRepairAttemptsByPair.removeAll(keepingCapacity: true)
        reportedExhaustedPairs.removeAll(keepingCapacity: true)
        anonymousAliasByMessageID.removeAll(keepingCapacity: true)
        isContentFrameProbeActive = false
        suppressAuditForContentFrameRemoval = false
    }

    private func reset() {
        cancelAudit()
        snapshot = .empty
        orderedMessageIDs.removeAll(keepingCapacity: true)
        snapshotRevision = 0
        confirmedHandoffRevisionByMessageID.removeAll(keepingCapacity: true)
        repairAttemptsByPair.removeAll(keepingCapacity: true)
        stackRepairAttemptsByPair.removeAll(keepingCapacity: true)
        reportedExhaustedPairs.removeAll(keepingCapacity: true)
        anonymousAliasByMessageID.removeAll(keepingCapacity: true)
        pendingStackRecovery = nil

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            recoveryRevisionByMessageID = [:]
            layoutProbeRevision = 0
            stackRecoveryRevision = 0
            pendingAnchorAdjustment = nil
            anchorScrollTargetMessageID = nil
            isContentFrameProbeActive = false
        }
        suppressAuditForContentFrameRemoval = false
    }

    private func scheduleAuditIfPossible() {
        cancelAudit()
        guard !context.isBlocked,
              pendingStackRecovery == nil,
              pendingAnchorAdjustment == nil,
              context.viewportSize.height > 0,
              orderedMessageIDs.count > 1,
              snapshot.samples.count > 1 else {
            return
        }

        auditGeneration &+= 1
        let generation = auditGeneration
        let settleDelay = context.settleDelayNanoseconds
        auditTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == auditGeneration {
                    requestedProbeRevision = nil
                    auditTask = nil
                    deactivateContentFrameProbe()
                }
            }

            try? await Task.sleep(nanoseconds: settleDelay)
            guard canContinueAudit(generation: generation) else { return }

            let firstBaselineSnapshotRevision = snapshotRevision
            let firstProbeRevision = requestFreshLayoutProbe()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard canContinueAudit(generation: generation),
                  ChatMessageLayoutAudit.isFreshVerificationSample(
                    baselineSnapshotRevision: firstBaselineSnapshotRevision,
                    currentSnapshotRevision: snapshotRevision,
                    requestedProbeRevision: firstProbeRevision,
                    reportedProbeRevision: snapshot.probeRevision
                  ) else {
                return
            }

            let firstOverlap = await detectOverlap()
            confirmCurrentRendererHandoffs()
            guard let firstOverlap else { return }

            let secondBaselineSnapshotRevision = snapshotRevision
            let secondProbeRevision = requestFreshLayoutProbe()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard canContinueAudit(generation: generation),
                  ChatMessageLayoutAudit.isFreshVerificationSample(
                    baselineSnapshotRevision: secondBaselineSnapshotRevision,
                    currentSnapshotRevision: snapshotRevision,
                    requestedProbeRevision: secondProbeRevision,
                    reportedProbeRevision: snapshot.probeRevision
                  ) else {
                return
            }

            let secondOverlap = await detectOverlap()
            guard let secondOverlap,
                  firstOverlap.upperMessageID == secondOverlap.upperMessageID,
                  firstOverlap.lowerMessageID == secondOverlap.lowerMessageID else {
                return
            }

            repair(secondOverlap)
        }
    }

    private func requestFreshLayoutProbe() -> UInt {
        let nextRevision = layoutProbeRevision &+ 1
        requestedProbeRevision = nextRevision
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isContentFrameProbeActive = true
            layoutProbeRevision = nextRevision
        }
        return nextRevision
    }

    private func cancelAudit() {
        auditGeneration &+= 1
        auditTask?.cancel()
        auditTask = nil
        requestedProbeRevision = nil
        deactivateContentFrameProbe()
    }

    private func deactivateContentFrameProbe() {
        guard isContentFrameProbeActive else { return }
        suppressAuditForContentFrameRemoval = true
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isContentFrameProbeActive = false
        }
    }

    private func canContinueAudit(generation: UInt) -> Bool {
        !Task.isCancelled
            && generation == auditGeneration
            && !context.isBlocked
            && pendingStackRecovery == nil
            && pendingAnchorAdjustment == nil
            && context.viewportSize.height > 0
    }

    private func detectOverlap() async -> ChatMessageLayoutOverlap? {
        let orderedMessageIDs = orderedMessageIDs
        let samples = snapshot.samples
        let contentFrames = snapshot.contentFrames
        let viewportHeight = context.viewportSize.height
        return await Task.detached(priority: .utility) {
            let frames = ChatMessageLayoutAudit.effectiveFrames(
                samples: samples,
                contentFrames: contentFrames
            )
            return ChatMessageLayoutAudit.firstOverlap(
                orderedMessageIDs: orderedMessageIDs,
                frames: frames,
                viewportHeight: viewportHeight
            )
        }.value
    }

    private func confirmCurrentRendererHandoffs() {
        for (messageID, sample) in snapshot.samples {
            let revision = sample.metadata.rendererHandoffRevision
            if revision > confirmedHandoffRevisionByMessageID[messageID, default: 0] {
                confirmedHandoffRevisionByMessageID[messageID] = revision
            }
        }
    }

    private func repair(_ overlap: ChatMessageLayoutOverlap) {
        let pair = MessagePair(
            upperMessageID: overlap.upperMessageID,
            lowerMessageID: overlap.lowerMessageID
        )
        let localAttempts = repairAttemptsByPair[pair, default: 0]
        let stackAttempts = stackRepairAttemptsByPair[pair, default: 0]
        switch ChatMessageLayoutAudit.recoveryAction(
            localAttempts: localAttempts,
            stackAttempts: stackAttempts
        ) {
        case .rebuildMessages:
            repairAttemptsByPair[pair] = localAttempts + 1
            rebuildMessages(overlap, attempt: localAttempts + 1)
        case .rebuildStack:
            guard let anchor = ChatMessageLayoutAudit.viewportAnchor(
                orderedMessageIDs: orderedMessageIDs,
                frames: ChatMessageLayoutAudit.effectiveFrames(
                    samples: snapshot.samples,
                    contentFrames: snapshot.contentFrames
                ),
                viewportHeight: context.viewportSize.height
            ) else {
                log(overlap, pair: pair, stage: "stack-anchor-missing", attempt: stackAttempts + 1)
                return
            }
            stackRepairAttemptsByPair[pair] = stackAttempts + 1
            rebuildStack(overlap, pair: pair, anchor: anchor, attempt: stackAttempts + 1)
        case .stop:
            if reportedExhaustedPairs.insert(pair).inserted {
                log(overlap, pair: pair, stage: "recovery-exhausted", attempt: stackAttempts)
            }
        }
    }

    private func rebuildMessages(_ overlap: ChatMessageLayoutOverlap, attempt: Int) {
        var revisions = recoveryRevisionByMessageID
        revisions[overlap.upperMessageID, default: 0] &+= 1
        revisions[overlap.lowerMessageID, default: 0] &+= 1

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            recoveryRevisionByMessageID = revisions
        }

        let pair = MessagePair(
            upperMessageID: overlap.upperMessageID,
            lowerMessageID: overlap.lowerMessageID
        )
        log(overlap, pair: pair, stage: "message-rebuild", attempt: attempt)
    }

    private func rebuildStack(
        _ overlap: ChatMessageLayoutOverlap,
        pair: MessagePair,
        anchor: ChatLayoutViewportAnchor,
        attempt: Int
    ) {
        let nextStackRevision = stackRecoveryRevision &+ 1
        pendingStackRecovery = PendingStackRecovery(
            anchor: anchor,
            targetStackRevision: nextStackRevision,
            baselineSnapshotRevision: snapshotRevision
        )

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            stackRecoveryRevision = nextStackRevision
        }
        log(overlap, pair: pair, stage: "stack-rebuild", attempt: attempt)
    }

    @discardableResult
    private func completeStackRecoveryIfPossible() -> Bool {
        guard let pendingStackRecovery,
              snapshot.stackRecoveryRevision >= pendingStackRecovery.targetStackRevision,
              snapshotRevision > pendingStackRecovery.baselineSnapshotRevision else {
            return pendingStackRecovery != nil
        }

        let effectiveFrames = ChatMessageLayoutAudit.effectiveFrames(
            samples: snapshot.samples,
            contentFrames: snapshot.contentFrames
        )
        guard let restoredFrame = effectiveFrames[pendingStackRecovery.anchor.messageID] else {
            if anchorScrollTargetMessageID != pendingStackRecovery.anchor.messageID {
                anchorScrollTargetMessageID = pendingStackRecovery.anchor.messageID
            }
            return true
        }

        self.pendingStackRecovery = nil
        let deltaY = restoredFrame.minY - pendingStackRecovery.anchor.minY
        anchorScrollTargetMessageID = nil
        pendingAnchorAdjustment = ChatScrollAnchorAdjustment(deltaY: deltaY)
        return true
    }

    private func log(
        _ overlap: ChatMessageLayoutOverlap,
        pair: MessagePair,
        stage: String,
        attempt: Int
    ) {
        let diagnostic = ChatLayoutDiagnosticFormatter.description(
            stage: stage,
            upperAlias: anonymousAlias(for: pair.upperMessageID),
            lowerAlias: anonymousAlias(for: pair.lowerMessageID),
            upperSample: snapshot.samples[pair.upperMessageID],
            lowerSample: snapshot.samples[pair.lowerMessageID],
            upperContentFrame: snapshot.contentFrames[pair.upperMessageID],
            lowerContentFrame: snapshot.contentFrames[pair.lowerMessageID],
            overlapHeight: overlap.overlapHeight,
            attempt: attempt,
            context: context
        )
        chatLayoutIntegrityLogger.warning("\(diagnostic, privacy: .public)")
    }

    private func anonymousAlias(for messageID: UUID) -> String {
        if let alias = anonymousAliasByMessageID[messageID] {
            return alias
        }
        let alias = "m\(anonymousAliasByMessageID.count + 1)"
        anonymousAliasByMessageID[messageID] = alias
        return alias
    }
}
