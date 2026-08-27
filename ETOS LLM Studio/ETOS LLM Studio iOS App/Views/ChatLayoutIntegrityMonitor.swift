// ============================================================================
// ChatLayoutIntegrityMonitor.swift
// ============================================================================
// 调度布局审计，并在确认重叠后执行局部或整栈恢复。
// ============================================================================

import Combine
import Foundation
import os.log
import SwiftUI

private let chatLayoutIntegrityLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "ChatLayoutIntegrity"
)

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
