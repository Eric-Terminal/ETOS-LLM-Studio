// ============================================================================
// ChatScrollPositionController.swift
// ============================================================================
// SwiftUI 会把当前可见位置持续写回 scrollPosition 绑定。本控制器将这类只读观测
// 与应用主动发出的滚动命令隔离，避免用户滚动和命令清理互相写回形成反馈环。
// ============================================================================

import Combine
import SwiftUI

@MainActor
final class ChatScrollPositionController: ObservableObject {
    @Published private(set) var targetAnchor: UnitPoint = .bottom
    @Published private(set) var activeCommandTarget: ChatScrollTargetID?

    private var observedPositionID: ChatScrollTargetID?
    private var isUserInteracting = false

    var positionBinding: Binding<ChatScrollTargetID?> {
        Binding(
            get: { [weak self] in self?.observedPositionID },
            set: { [weak self] newValue in
                self?.acceptObservedPosition(newValue)
            }
        )
    }

    var hasActiveCommand: Bool {
        activeCommandTarget != nil
    }

    /// 命令执行期间绑定必须保持目标不变；中途的可见项回写不能反向改写命令。
    func acceptObservedPosition(_ positionID: ChatScrollTargetID?) {
        guard activeCommandTarget == nil else { return }
        observedPositionID = positionID
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
        observedPositionID = target
        return true
    }

    func updateUserInteraction(_ isUserInteracting: Bool) {
        self.isUserInteracting = isUserInteracting
        if isUserInteracting {
            // nil 表示当前没有应用指定的锚点，避免旧目标随视图刷新重新生效。
            observedPositionID = nil
            releaseCommand()
        }
    }

    /// 释放所有权不清空 scrollPosition。绑定继续承载系统观测值，不再制造 nil/ID 往返。
    func releaseCommand(expectedTarget: ChatScrollTargetID? = nil) {
        if let expectedTarget, activeCommandTarget != expectedTarget {
            return
        }
        guard activeCommandTarget != nil else { return }
        activeCommandTarget = nil
    }

    func reset() {
        activeCommandTarget = nil
        observedPositionID = nil
        targetAnchor = .bottom
        isUserInteracting = false
    }
}
