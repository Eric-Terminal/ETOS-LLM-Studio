// ============================================================================
// ChatScrollPositionController.swift
// ============================================================================
// SwiftUI 会把当前可见位置持续写回 scrollPosition 绑定。本控制器只向绑定暴露
// 应用主动发出的命令，避免被动位置在其他状态刷新时被回放成新的滚动目标。
// ============================================================================

import Combine
import SwiftUI

enum ChatScrollCommandOwner: Equatable {
    case viewportNavigation
    case layoutRecovery
}

@MainActor
final class ChatScrollPositionController: ObservableObject {
    private struct Command {
        let target: ChatScrollTargetID
        let anchor: UnitPoint
        let owner: ChatScrollCommandOwner
    }

    @Published private var activeCommand: Command?

    private var isUserInteracting = false
    private var lastTargetAnchor: UnitPoint = .bottom

    var targetAnchor: UnitPoint {
        activeCommand?.anchor ?? lastTargetAnchor
    }

    var activeCommandTarget: ChatScrollTargetID? {
        activeCommand?.target
    }

    var activeCommandOwner: ChatScrollCommandOwner? {
        activeCommand?.owner
    }

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
        owner: ChatScrollCommandOwner = .viewportNavigation,
        allowsDuringUserInteraction: Bool = false
    ) -> Bool {
        guard allowsDuringUserInteraction || !isUserInteracting else { return false }
        // 布局自愈只能填补空闲视口，不能覆盖用户刚触发的时间线导航。
        if owner == .layoutRecovery,
           activeCommand?.owner == .viewportNavigation {
            return false
        }
        lastTargetAnchor = anchor
        activeCommand = Command(target: target, anchor: anchor, owner: owner)
        return true
    }

    func updateUserInteraction(_ isUserInteracting: Bool) {
        self.isUserInteracting = isUserInteracting
        if isUserInteracting {
            releaseCommand()
        }
    }

    /// 释放后绑定立即回到 nil，后续视图刷新不会重新执行已经完成的目标。
    func releaseCommand(
        expectedTarget: ChatScrollTargetID? = nil,
        expectedOwner: ChatScrollCommandOwner? = nil
    ) {
        guard let activeCommand else { return }
        if let expectedTarget, activeCommand.target != expectedTarget { return }
        if let expectedOwner, activeCommand.owner != expectedOwner { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.activeCommand = nil
        }
    }

    func reset() {
        activeCommand = nil
        lastTargetAnchor = .bottom
        isUserInteracting = false
    }
}
