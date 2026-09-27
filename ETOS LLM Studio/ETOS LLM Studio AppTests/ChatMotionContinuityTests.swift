// ============================================================================
// ChatMotionContinuityTests.swift
// ============================================================================

import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct ChatMotionContinuityTests {
    @Test("流式目标持续增长时位置和速度不会重新起步")
    func retargetPreservesMotion() {
        var spring = ChatMotionSpring(position: 100, target: 124, responseDuration: 0.2)
        spring.advance(by: 1.0 / 60)
        let previousPosition = spring.position
        let previousVelocity = spring.velocity
        #expect(previousVelocity > 0)

        spring.retarget(to: 180)
        #expect(spring.position == previousPosition)
        #expect(spring.velocity == previousVelocity)
        spring.advance(by: 1.0 / 120)
        #expect(spring.position > previousPosition)
        #expect(spring.position < spring.target)
    }

    @Test("大幅内容增长不会先瞬移到距底部十二点的位置")
    func largeGrowthStartsAtActualPosition() {
        var spring = ChatMotionSpring(position: 52, target: 360, responseDuration: 0.2)
        #expect(spring.position == 52)
        spring.advance(by: 1.0 / 120)
        #expect(spring.position > 52)
        #expect(spring.position < 100)
    }

    @Test("弹簧解析轨迹在不同刷新率下保持一致")
    func trajectoryDoesNotDependOnRefreshRate() {
        for dampingRatio: CGFloat in [0.8, 1, 1.2] {
            var sixtyHz = ChatMotionSpring(
                position: 0,
                velocity: 20,
                target: 100,
                responseDuration: 0.3,
                dampingRatio: dampingRatio
            )
            var oneTwentyHz = sixtyHz
            var skippedFrames = sixtyHz
            for _ in 0..<12 { sixtyHz.advance(by: 1.0 / 60) }
            for _ in 0..<24 { oneTwentyHz.advance(by: 1.0 / 120) }
            skippedFrames.advance(by: 0.2)
            #expect(abs(sixtyHz.position - oneTwentyHz.position) < 0.000_001)
            #expect(abs(sixtyHz.velocity - oneTwentyHz.velocity) < 0.000_001)
            #expect(abs(sixtyHz.position - skippedFrames.position) < 0.000_001)
            #expect(abs(sixtyHz.velocity - skippedFrames.velocity) < 0.000_001)
        }
    }

    @Test("临界阻尼流式跟随向底部收敛且不会越界")
    func criticalSpringSettlesWithoutOvershoot() {
        var spring = ChatMotionSpring(position: 52, target: 200, responseDuration: 0.2)
        var previousPosition = spring.position
        for _ in 0..<120 {
            spring.advance(by: 1.0 / 120)
            #expect(spring.position >= previousPosition)
            #expect(spring.position <= spring.target)
            previousPosition = spring.position
        }
        #expect(spring.isSettled)
        spring.finish()
        #expect(spring.position == 200)
        #expect(spring.velocity == 0)
    }

    @MainActor
    @Test("键盘布局需要系统完成与最新几何两个回执")
    func keyboardWaitsForActualCompletionAndGeometry() {
        let coordinator = ChatScrollCoordinator()
        coordinator.beginLayoutTransition(keepBottomPinned: true, awaitsKeyboardCompletion: true)
        let firstRevision = coordinator.layoutTransitionRevision
        coordinator.completeLayoutTransition(revision: firstRevision)
        #expect(coordinator.isChatLayoutSettling)

        coordinator.keyboardLayoutTransitionDidEnd()
        let finalRevision = coordinator.layoutTransitionRevision
        #expect(finalRevision != firstRevision)
        coordinator.completeLayoutTransition(revision: firstRevision)
        #expect(coordinator.isChatLayoutSettling)
        coordinator.completeLayoutTransition(revision: finalRevision)
        #expect(!coordinator.isChatLayoutSettling)
    }

    @MainActor
    @Test("输入栏连续改高只接受最新布局回执")
    func composerLayoutRejectsStaleCompletion() {
        let coordinator = ChatScrollCoordinator()
        coordinator.beginLayoutTransition(keepBottomPinned: false)
        let oldRevision = coordinator.layoutTransitionRevision
        coordinator.beginLayoutTransition(keepBottomPinned: false)
        coordinator.completeLayoutTransition(revision: oldRevision)
        #expect(coordinator.isChatLayoutSettling)
        coordinator.completeLayoutTransition(revision: coordinator.layoutTransitionRevision)
        #expect(!coordinator.isChatLayoutSettling)
        #expect(!coordinator.shouldKeepBottomPinned)
    }

    @MainActor
    @Test("离开聊天后旧键盘回执不能再次启动布局交接")
    func disappearanceInvalidatesKeyboardLifecycle() {
        let coordinator = ChatScrollCoordinator()
        coordinator.beginLayoutTransition(keepBottomPinned: true, awaitsKeyboardCompletion: true)
        coordinator.prepareForDisappearance()
        let revision = coordinator.layoutTransitionRevision
        coordinator.keyboardLayoutTransitionDidEnd()
        #expect(coordinator.layoutTransitionRevision == revision)
        #expect(!coordinator.isChatLayoutSettling)
    }

    @Test("流式收尾尚未落位时原生尺寸锚点继续让出所有权")
    func nativeAnchorWaitsForFinalMotion() {
        #expect(ChatView.chatSizeChangeScrollAnchor(
            keepsBottomPinned: true,
            isStreaming: false,
            isStreamingViewportFollowing: true
        ) == nil)
        #expect(ChatView.chatSizeChangeScrollAnchor(
            keepsBottomPinned: true,
            isStreaming: false,
            isStreamingViewportFollowing: false
        ) == .bottom)
    }

    @Test("自动跟随与发送落点不会叠加滚动波浪")
    func automaticMotionOwnsBubblePosition() {
        #expect(ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 20,
            isEnabled: true,
            isConnectedToAdjacentBubble: false,
            isAutomaticViewportMotionActive: true
        ) == 0)
        #expect(ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 20,
            isEnabled: true,
            isConnectedToAdjacentBubble: false,
            isSendFlightTarget: true
        ) == 0)
        #expect(ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 20,
            isEnabled: false,
            isConnectedToAdjacentBubble: false
        ) == 0)
        #expect(ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 20,
            isEnabled: true,
            isConnectedToAdjacentBubble: false
        ) == 10)
    }
}
