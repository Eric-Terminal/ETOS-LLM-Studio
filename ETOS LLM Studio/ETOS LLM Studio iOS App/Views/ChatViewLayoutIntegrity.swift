// ============================================================================
// ChatViewLayoutIntegrity.swift
// ============================================================================
// 聊天列表布局一致性审计
// - 只在滚动与内容更新静止后检查可见消息
// - 确认相邻消息持续重叠时，触发无动画的局部重测量
// ============================================================================

import Foundation
import os.log
import SwiftUI

private let chatLayoutIntegrityLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "ChatLayoutIntegrity"
)

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

            // scrollTransition 会在视口边缘对进出场消息施加合法位移。只审计交叠中心位于
            // 安全区域的情况，避免把弹性过渡当成持久布局错误。
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
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct ChatMessageLayoutFrameReporter: View {
    let messageID: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatMessageLayoutFramePreferenceKey.self,
                value: [
                    messageID: proxy.frame(
                        in: .named(ChatMessageLayoutAudit.coordinateSpaceName)
                    )
                ]
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ChatLayoutAuditContext: Equatable {
    let sessionID: UUID?
    let viewportHeight: CGFloat
    let isBlocked: Bool
    let settleDelayNanoseconds: UInt64
    let usesNoBubbleUI: Bool
}

@MainActor
final class ChatLayoutIntegrityMonitor: ObservableObject {
    @Published private(set) var recoveryRevisionByMessageID: [UUID: UInt] = [:]

    private struct MessagePair: Hashable {
        let upperMessageID: UUID
        let lowerMessageID: UUID
    }

    private var context = ChatLayoutAuditContext(
        sessionID: nil,
        viewportHeight: 0,
        isBlocked: true,
        settleDelayNanoseconds: 450_000_000,
        usesNoBubbleUI: false
    )
    private var frames: [UUID: CGRect] = [:]
    private var orderedMessageIDs: [UUID] = []
    private var repairAttemptsByPair: [MessagePair: Int] = [:]
    private var reportedExhaustedPairs: Set<MessagePair> = []
    private var auditTask: Task<Void, Never>?
    private var auditGeneration: UInt = 0

    func recoveryRevision(for messageID: UUID) -> UInt {
        recoveryRevisionByMessageID[messageID, default: 0]
    }

    func updateContext(_ newContext: ChatLayoutAuditContext) {
        if context.sessionID != newContext.sessionID {
            reset(for: newContext.sessionID)
        }
        guard context != newContext else { return }
        context = newContext
        scheduleAuditIfPossible()
    }

    func updateFrames(_ newFrames: [UUID: CGRect], orderedMessageIDs: [UUID]) {
        guard frames != newFrames || self.orderedMessageIDs != orderedMessageIDs else { return }
        frames = newFrames
        self.orderedMessageIDs = orderedMessageIDs
        // 拖动和减速阶段只保留最新快照，不为每一帧反复创建延迟任务。
        guard !context.isBlocked else { return }
        scheduleAuditIfPossible()
    }

    func stop() {
        cancelAudit()
        frames.removeAll(keepingCapacity: true)
        orderedMessageIDs.removeAll(keepingCapacity: true)
    }

    private func reset(for sessionID: UUID?) {
        cancelAudit()
        frames.removeAll(keepingCapacity: true)
        orderedMessageIDs.removeAll(keepingCapacity: true)
        repairAttemptsByPair.removeAll(keepingCapacity: true)
        reportedExhaustedPairs.removeAll(keepingCapacity: true)
        guard !recoveryRevisionByMessageID.isEmpty else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            recoveryRevisionByMessageID = [:]
        }
    }

    private func scheduleAuditIfPossible() {
        cancelAudit()
        guard !context.isBlocked,
              context.viewportHeight > 0,
              orderedMessageIDs.count > 1,
              frames.count > 1 else {
            return
        }

        auditGeneration &+= 1
        let generation = auditGeneration
        auditTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: context.settleDelayNanoseconds)
            guard canContinueAudit(generation: generation) else { return }

            let firstSample = await detectOverlap()
            guard let firstSample else {
                auditTask = nil
                return
            }

            // 再跨过数个刷新周期复核一次。正常弹簧或 UIKit 尺寸回报会在此期间
            // 改变 preference 并取消本任务，只有卡死的布局会保留同一组重叠。
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard canContinueAudit(generation: generation),
                  let secondSample = await detectOverlap(),
                  firstSample.upperMessageID == secondSample.upperMessageID,
                  firstSample.lowerMessageID == secondSample.lowerMessageID else {
                return
            }

            repair(secondSample)
            auditTask = nil
        }
    }

    private func cancelAudit() {
        auditGeneration &+= 1
        auditTask?.cancel()
        auditTask = nil
    }

    private func canContinueAudit(generation: UInt) -> Bool {
        !Task.isCancelled
            && generation == auditGeneration
            && !context.isBlocked
            && context.viewportHeight > 0
    }

    private func detectOverlap() async -> ChatMessageLayoutOverlap? {
        let orderedMessageIDs = orderedMessageIDs
        let frames = frames
        let viewportHeight = context.viewportHeight
        return await Task.detached(priority: .utility) {
            ChatMessageLayoutAudit.firstOverlap(
                orderedMessageIDs: orderedMessageIDs,
                frames: frames,
                viewportHeight: viewportHeight
            )
        }.value
    }

    private func repair(_ overlap: ChatMessageLayoutOverlap) {
        let pair = MessagePair(
            upperMessageID: overlap.upperMessageID,
            lowerMessageID: overlap.lowerMessageID
        )
        let attempt = repairAttemptsByPair[pair, default: 0]
        guard attempt < 2 else {
            if reportedExhaustedPairs.insert(pair).inserted {
                chatLayoutIntegrityLogger.error(
                    "相邻消息布局重测量仍未消除重叠，停止自动重试：upper=\(pair.upperMessageID.uuidString, privacy: .public) lower=\(pair.lowerMessageID.uuidString, privacy: .public)"
                )
            }
            return
        }
        repairAttemptsByPair[pair] = attempt + 1

        var revisions = recoveryRevisionByMessageID
        revisions[overlap.upperMessageID, default: 0] &+= 1
        revisions[overlap.lowerMessageID, default: 0] &+= 1

        // 自愈只更换受影响气泡的测量身份，不参与任何正常入场、滚动或手势动画。
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            recoveryRevisionByMessageID = revisions
        }

        let overlapDescription = String(format: "%.1f", overlap.overlapHeight)
        chatLayoutIntegrityLogger.warning(
            "检测到相邻消息持续重叠，已执行局部重测量：upper=\(overlap.upperMessageID.uuidString, privacy: .public) lower=\(overlap.lowerMessageID.uuidString, privacy: .public) overlap=\(overlapDescription, privacy: .public) attempt=\(attempt + 1, privacy: .public) noBubble=\(context.usesNoBubbleUI, privacy: .public)"
        )
    }
}

extension ChatView {
    var chatLayoutAuditContext: ChatLayoutAuditContext {
        let transitionSettleDelay = appConfig.chatScrollAnimationEnabled
            ? max(0.45, appConfig.chatScrollAnimationSpringResponse)
            : 0.35
        return ChatLayoutAuditContext(
            sessionID: viewModel.currentSession?.id,
            viewportHeight: chatScrollViewportHeight,
            isBlocked: !isChatVisible
                || scenePhase != .active
                || isChatScrollUserInteracting
                || viewModel.isSendingMessage
                || isChatLayoutSettling
                || isAutomaticHistoryLoadInFlight
                || chatScrollTarget != nil
                || flightState != nil,
            settleDelayNanoseconds: UInt64(transitionSettleDelay * 1_000_000_000),
            usesNoBubbleUI: viewModel.enableNoBubbleUI
        )
    }

    func updateChatScrollInteractionState(_ isUserInteracting: Bool) {
        guard isChatScrollUserInteracting != isUserInteracting else { return }
        isChatScrollUserInteracting = isUserInteracting
    }
}
