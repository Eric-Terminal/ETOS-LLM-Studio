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
        let messageID: UUID
        let originalMinY: CGFloat
        let displayedMessageIDs: [UUID]
        let baselineSnapshotRevision: UInt
    }

    private var rowFrames: [UUID: CGRect] = [:]
    private var snapshotRevision: UInt = 0
    private var pendingMutation: PendingMutation?

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

        self.pendingMutation = nil
        pendingAdjustment = ChatScrollAnchorAdjustment(
            deltaY: restoredFrame.minY - pendingMutation.originalMinY
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
}
