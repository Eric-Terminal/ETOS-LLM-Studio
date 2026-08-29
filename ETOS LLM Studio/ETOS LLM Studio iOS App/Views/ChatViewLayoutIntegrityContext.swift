// ============================================================================
// ChatViewLayoutIntegrityContext.swift
// ============================================================================
// 将聊天界面运行状态投影为布局审计上下文。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore

extension ChatView {
    var chatLayoutAuditContext: ChatLayoutAuditContext {
        let transitionSettleDelay = appConfig.chatScrollAnimationEnabled
            ? max(0.45, appConfig.chatScrollAnimationSpringResponse)
            : 0.35
        return ChatLayoutAuditContext(
            sessionID: viewModel.currentSession?.id,
            viewportSize: CGSize(
                width: scrollCoordinator.chatScrollViewportWidth,
                height: scrollCoordinator.chatScrollViewportHeight
            ),
            isChatVisible: isChatVisible,
            isAppActive: scenePhase == .active,
            isUserInteracting: scrollCoordinator.isChatScrollUserInteracting,
            isSendingMessage: viewModel.isSendingMessage,
            isLayoutSettling: scrollCoordinator.isChatLayoutSettling,
            isHistoryLoadInFlight: scrollCoordinator.isHistoryLoadInFlight,
            hasProgrammaticScrollTarget: hasChatProgrammaticScrollOwnership,
            hasExclusiveViewportCommand: hasExclusiveChatViewportCommand,
            hasSendFlight: flightState != nil,
            scrollAnimationEnabled: appConfig.chatScrollAnimationEnabled,
            settleDelayNanoseconds: UInt64(transitionSettleDelay * 1_000_000_000),
            usesNoBubbleUI: viewModel.enableNoBubbleUI,
            fontScale: FontLibrary.effectiveFontScale(
                appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            ),
            systemVersion: UIDevice.current.systemVersion
        )
    }

    func updateChatScrollInteractionState(_ isUserInteracting: Bool) {
        if isUserInteracting {
            let shouldCancelCommand = scrollCoordinator.prepareForUserPan(
                isMessageJumpInFlight: isMessageJumpInFlight,
                bottomScrollTarget: bottomScrollTarget
            )
            if shouldCancelCommand {
                cancelPendingScrollTargetCommand()
            }
            return
        }
        guard scrollCoordinator.updateInteractionState(false) else { return }
        refreshMessageNavigationTargets()
        scheduleScrollNavigationPanelHide()
    }
}
