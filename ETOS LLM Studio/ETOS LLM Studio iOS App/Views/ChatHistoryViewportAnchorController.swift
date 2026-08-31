// ============================================================================
// ChatHistoryViewportAnchorController.swift
// ============================================================================
// 历史窗口变化会改变 LazyVStack 的内容高度。本控制器以换窗前后的同一消息行
// 为几何锚点，通过原生 contentOffset 抵消布局位移，不参与常规滚动位置绑定。
// ============================================================================

import Combine
import CoreGraphics
import Foundation
import SwiftUI

enum ChatHistoryAnchorLayout {
    nonisolated static let coordinateSpaceName = "chatHistoryAnchorContent"
}

struct ChatHistoryAnchorFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct ChatHistoryAnchorFrameReporter: View {
    let messageID: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatHistoryAnchorFramePreferenceKey.self,
                value: [
                    messageID: proxy.frame(
                        in: .named(ChatHistoryAnchorLayout.coordinateSpaceName)
                    )
                ]
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class ChatHistoryViewportAnchorController: ObservableObject {
    @Published private(set) var pendingAdjustment: ChatScrollAnchorAdjustment?

    private enum MutationMode: Equatable {
        case settledOnce
        case continuousUntilSettled
    }

    private struct PendingMutation {
        let id: UUID
        let messageID: UUID
        let originalMinY: CGFloat
        let displayedMessageIDs: [UUID]
        let baselineSnapshotRevision: UInt
        let mode: MutationMode
        let allowsDuringProgrammaticScroll: Bool
        var compensatedMinY: CGFloat
        var isSettled: Bool
    }

    private var rowFrames: [UUID: CGRect] = [:]
    private var snapshotRevision: UInt = 0
    private var pendingMutation: PendingMutation?
    private var pendingAdjustmentTask: Task<Void, Never>?
    private var pendingAdjustmentTargetMinY: CGFloat?

    var isRestoringAnchor: Bool {
        pendingMutation != nil || pendingAdjustment != nil
    }

    func updateFrames(
        _ newFrames: [UUID: CGRect],
        displayedMessageIDs: [UUID]
    ) {
        rowFrames = newFrames
        snapshotRevision &+= 1

        guard let pendingMutation,
              pendingAdjustment == nil,
              snapshotRevision > pendingMutation.baselineSnapshotRevision,
              displayedMessageIDs != pendingMutation.displayedMessageIDs,
              let restoredFrame = newFrames[pendingMutation.messageID],
              Self.isUsable(restoredFrame) else {
            return
        }

        switch pendingMutation.mode {
        case .settledOnce:
            scheduleAdjustment(
                mutationID: pendingMutation.id,
                restoredMinY: restoredFrame.minY
            )
        case .continuousUntilSettled:
            handleContinuousFrame(
                mutationID: pendingMutation.id,
                restoredMinY: restoredFrame.minY
            )
        }
    }

    /// 只有拿到当前屏幕中的真实行 frame 后才允许改变历史窗口。
    func beginMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID],
        allowsDuringProgrammaticScroll: Bool = false
    ) -> Bool {
        startMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: displayedMessageIDs,
            mode: .settledOnce,
            allowsDuringProgrammaticScroll: allowsDuringProgrammaticScroll
        ) != nil
    }

    /// 四键跨窗时逐帧抵消列表换页产生的位移，稳定后再交给最终滚动动画。
    func beginContinuousMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID]
    ) -> UUID? {
        startMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: displayedMessageIDs,
            mode: .continuousUntilSettled,
            allowsDuringProgrammaticScroll: true
        )
    }

    func isContinuousMutationSettled(id: UUID) -> Bool {
        pendingMutation?.id == id
            && pendingMutation?.mode == .continuousUntilSettled
            && pendingMutation?.isSettled == true
    }

    func finishContinuousMutation(id: UUID) {
        guard pendingMutation?.id == id,
              pendingMutation?.mode == .continuousUntilSettled,
              pendingMutation?.isSettled == true,
              pendingAdjustment == nil else {
            return
        }
        clearMutationState()
    }

    func cancelMutation(id: UUID) {
        guard pendingMutation?.id == id else { return }
        clearMutationState()
        pendingAdjustment = nil
    }

    private func startMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID],
        mode: MutationMode,
        allowsDuringProgrammaticScroll: Bool
    ) -> UUID? {
        guard pendingMutation == nil,
              pendingAdjustment == nil,
              let frame = rowFrames[anchorMessageID],
              Self.isUsable(frame) else {
            return nil
        }

        let mutationID = UUID()
        pendingMutation = PendingMutation(
            id: mutationID,
            messageID: anchorMessageID,
            originalMinY: frame.minY,
            displayedMessageIDs: displayedMessageIDs,
            baselineSnapshotRevision: snapshotRevision,
            mode: mode,
            allowsDuringProgrammaticScroll: allowsDuringProgrammaticScroll,
            compensatedMinY: frame.minY,
            isSettled: false
        )
        return mutationID
    }

    @discardableResult
    func completeAdjustment(id: UUID) -> Bool {
        guard pendingAdjustment?.id == id else { return false }
        pendingAdjustment = nil
        guard var pendingMutation,
              pendingMutation.mode == .continuousUntilSettled else {
            pendingAdjustmentTargetMinY = nil
            return true
        }

        if let targetMinY = pendingAdjustmentTargetMinY {
            pendingMutation.compensatedMinY = targetMinY
            self.pendingMutation = pendingMutation
        }
        pendingAdjustmentTargetMinY = nil

        if let latestMinY = rowFrames[pendingMutation.messageID]?.minY {
            handleContinuousFrame(
                mutationID: pendingMutation.id,
                restoredMinY: latestMinY
            )
        }
        return true
    }

    func cancel() {
        clearMutationState()
        pendingAdjustment = nil
    }

    func reset() {
        cancel()
        rowFrames.removeAll(keepingCapacity: true)
        snapshotRevision = 0
    }

    nonisolated private static func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.minY.isFinite
            && frame.maxY.isFinite
    }

    private func handleContinuousFrame(
        mutationID: UUID,
        restoredMinY: CGFloat
    ) {
        guard let pendingMutation,
              pendingMutation.id == mutationID,
              pendingMutation.mode == .continuousUntilSettled else {
            return
        }

        if pendingMutation.isSettled {
            var activeMutation = pendingMutation
            activeMutation.isSettled = false
            self.pendingMutation = activeMutation
        }
        pendingAdjustmentTask?.cancel()
        pendingAdjustmentTask = nil
        guard pendingAdjustment == nil else { return }

        let deltaY = restoredMinY - pendingMutation.compensatedMinY
        guard abs(deltaY) > 0.5 else {
            scheduleContinuousSettlement(mutationID: mutationID)
            return
        }

        let adjustment = ChatScrollAnchorAdjustment(
            deltaY: deltaY,
            allowsTemporaryOverflow: true,
            allowsDuringProgrammaticScroll: true
        )
        pendingAdjustmentTargetMinY = restoredMinY
        pendingAdjustment = adjustment
    }

    private func scheduleContinuousSettlement(mutationID: UUID) {
        pendingAdjustmentTask?.cancel()
        pendingAdjustmentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let self,
                  let pendingMutation = self.pendingMutation,
                  pendingMutation.id == mutationID,
                  pendingMutation.mode == .continuousUntilSettled,
                  self.pendingAdjustment == nil,
                  let currentMinY = self.rowFrames[pendingMutation.messageID]?.minY,
                  abs(currentMinY - pendingMutation.compensatedMinY) <= 0.5 else {
                return
            }
            var settledMutation = pendingMutation
            settledMutation.isSettled = true
            self.pendingMutation = settledMutation
            self.pendingAdjustmentTask = nil
        }
    }

    private func clearMutationState() {
        pendingAdjustmentTask?.cancel()
        pendingAdjustmentTask = nil
        pendingMutation = nil
        pendingAdjustmentTargetMinY = nil
    }

    /// LazyVStack 扩窗时可能在同一轮布局中先上报过渡 frame。
    /// 只在几何短暂静止后生成一次偏移，避免用半成品快照拉偏阅读位置。
    private func scheduleAdjustment(
        mutationID: UUID,
        restoredMinY: CGFloat
    ) {
        pendingAdjustmentTask?.cancel()
        pendingAdjustmentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let self,
                  let pendingMutation = self.pendingMutation,
                  pendingMutation.id == mutationID,
                  self.pendingAdjustment == nil else {
                return
            }
            self.pendingAdjustmentTask = nil
            self.pendingMutation = nil
            self.pendingAdjustment = ChatScrollAnchorAdjustment(
                deltaY: restoredMinY - pendingMutation.originalMinY,
                allowsTemporaryOverflow: true,
                allowsDuringProgrammaticScroll:
                    pendingMutation.allowsDuringProgrammaticScroll
            )
        }
    }
}
