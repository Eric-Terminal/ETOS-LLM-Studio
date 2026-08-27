// ============================================================================
// ChatHistoryViewportAnchorController.swift
// ============================================================================
// 历史窗口扩展会改变 LazyVStack 的内容高度。本控制器以扩窗前后的同一消息行
// 为几何锚点，只生成一次原生 contentOffset 修正，不参与常规滚动位置绑定。
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

    private struct PendingMutation {
        let id: UUID
        let messageID: UUID
        let originalMinY: CGFloat
        let displayedMessageIDs: [UUID]
        let baselineSnapshotRevision: UInt
    }

    private var rowFrames: [UUID: CGRect] = [:]
    private var snapshotRevision: UInt = 0
    private var pendingMutation: PendingMutation?
    private var pendingAdjustmentTask: Task<Void, Never>?

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

        scheduleAdjustment(
            mutationID: pendingMutation.id,
            restoredMinY: restoredFrame.minY
        )
    }

    /// 只有拿到当前屏幕中的真实行 frame 后才允许改变历史窗口。
    func beginMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID]
    ) -> Bool {
        guard pendingMutation == nil,
              pendingAdjustment == nil,
              let frame = rowFrames[anchorMessageID],
              Self.isUsable(frame) else {
            return false
        }

        pendingMutation = PendingMutation(
            id: UUID(),
            messageID: anchorMessageID,
            originalMinY: frame.minY,
            displayedMessageIDs: displayedMessageIDs,
            baselineSnapshotRevision: snapshotRevision
        )
        return true
    }

    @discardableResult
    func completeAdjustment(id: UUID) -> Bool {
        guard pendingAdjustment?.id == id else { return false }
        pendingAdjustment = nil
        return true
    }

    func cancel() {
        pendingAdjustmentTask?.cancel()
        pendingAdjustmentTask = nil
        pendingMutation = nil
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
                allowsTemporaryOverflow: true
            )
        }
    }
}
