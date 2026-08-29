// ============================================================================
// ChatScrollPositionController.swift
// ============================================================================
// 只保存应用主动发出的一次性滚动命令；视图消费后不会把目标长期绑定到视口。
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
        let revision: UInt
        let target: ChatScrollTargetID
        let anchor: UnitPoint
        let owner: ChatScrollCommandOwner
        let animation: Animation?
    }

    @Published private var activeCommand: Command?

    private var isUserInteracting = false
    private var nextCommandRevision: UInt = 0
    private var lastTargetAnchor: UnitPoint = .bottom

    var activeCommandRevision: UInt? {
        activeCommand?.revision
    }

    var targetAnchor: UnitPoint {
        activeCommand?.anchor ?? lastTargetAnchor
    }

    var activeCommandTarget: ChatScrollTargetID? {
        activeCommand?.target
    }

    var activeCommandOwner: ChatScrollCommandOwner? {
        activeCommand?.owner
    }

    var activeCommandAnimation: Animation? {
        activeCommand?.animation
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
        animation: Animation? = nil,
        allowsDuringUserInteraction: Bool = false
    ) -> Bool {
        guard allowsDuringUserInteraction || !isUserInteracting else { return false }
        // 布局自愈只能填补空闲视口，不能覆盖用户刚触发的时间线导航。
        if owner == .layoutRecovery,
           activeCommand?.owner == .viewportNavigation {
            return false
        }
        nextCommandRevision &+= 1
        lastTargetAnchor = anchor
        activeCommand = Command(
            revision: nextCommandRevision,
            target: target,
            anchor: anchor,
            owner: owner,
            animation: animation
        )
        return true
    }

    func updateUserInteraction(_ isUserInteracting: Bool) {
        self.isUserInteracting = isUserInteracting
        if isUserInteracting {
            releaseCommand()
        }
    }

    /// 释放只结束命令所有权；一次性滚动已经由视图消费，不需要保留目标位置。
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
