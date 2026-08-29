// ============================================================================
// ChatScrollPositionController.swift
// ============================================================================
// SwiftUI 会把当前可见位置持续写回 scrollPosition 绑定。本控制器只向绑定暴露
// 应用主动发出的命令，避免被动位置在其他状态刷新时被回放成新的滚动目标。
// ============================================================================

import Combine
import SwiftUI

@MainActor
final class ChatScrollPositionController: ObservableObject {
    @Published private(set) var targetAnchor: UnitPoint = .bottom
    @Published private(set) var activeCommandTarget: ChatScrollTargetID?

    private var isUserInteracting = false

    var positionBinding: Binding<ChatScrollTargetID?> {
        Binding(
            get: { [weak self] in self?.activeCommandTarget },
            set: { _ in }
        )
    }

    var hasActiveCommand: Bool {
        activeCommandTarget != nil
    }

    /// 拖动与惯性减速属于同一次直接操控；期间到达的自动命令不能重新夺回视口。
    @discardableResult
    func issueCommand(
        to target: ChatScrollTargetID,
        anchor: UnitPoint,
        allowsDuringUserInteraction: Bool = false
    ) -> Bool {
        guard allowsDuringUserInteraction || !isUserInteracting else { return false }
        targetAnchor = anchor
        activeCommandTarget = target
        return true
    }

    func updateUserInteraction(_ isUserInteracting: Bool) {
        self.isUserInteracting = isUserInteracting
        if isUserInteracting {
            releaseCommand()
        }
    }

    /// 释放后绑定立即回到 nil，后续视图刷新不会重新执行已经完成的目标。
    func releaseCommand(expectedTarget: ChatScrollTargetID? = nil) {
        if let expectedTarget, activeCommandTarget != expectedTarget {
            return
        }
        guard activeCommandTarget != nil else { return }
        activeCommandTarget = nil
    }

    func reset() {
        activeCommandTarget = nil
        targetAnchor = .bottom
        isUserInteracting = false
    }
}
