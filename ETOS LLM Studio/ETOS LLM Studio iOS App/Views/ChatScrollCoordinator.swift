// ============================================================================
// ChatScrollCoordinator.swift
// ============================================================================
// iOS 聊天滚动的唯一状态所有者。视图只提交用户意图和几何回执，命令、分页、
// 导航与布局恢复的生命周期都在此处持有，避免多个 SwiftUI @State 互相反馈。
// ============================================================================

import Combine
import Foundation
import SwiftUI

@MainActor
final class ChatScrollCoordinator: ObservableObject {
    @Published var showScrollToBottom = false
    @Published var showScrollNavigationPanel = false
    @Published var shouldKeepBottomPinned = true
    @Published var suppressAutoScrollOnce = false

    @Published var chatScrollViewportWidth: CGFloat = 0
    @Published var chatScrollViewportHeight: CGFloat = 0
    @Published var scrollDistanceToBottom: CGFloat = 0
    @Published var scrollDistanceToTop: CGFloat = 0

    @Published var pendingHistoryResetWorkItem: DispatchWorkItem?
    @Published var pendingBottomSnapTask: Task<Void, Never>?
    @Published var pendingScrollTargetTask: Task<Void, Never>?
    @Published var isHistoryLoadInFlight = false
    @Published var previousMessageNavigationTargetID: UUID?
    @Published var nextMessageNavigationTargetID: UUID?
    @Published var bottomScrollCommandGeneration: UInt = 0
    @Published var isChatLayoutSettling = false
    @Published var isChatScrollUserInteracting = false

    var scrollNavigationHideTask: Task<Void, Never>?
    var chatLayoutSettleTask: Task<Void, Never>?
    var scrollTargetGeneration: UInt = 0
    var pendingAutomaticHistoryLoadRequest: ChatAutomaticHistoryLoadRequest?
    var lastAutomaticHistoryLoadAnchorID: UUID?
    var bottomScrollCommandReleaseTask: Task<Void, Never>?
    var messageNavigationCursorID: UUID?
    var chatNavigationMessageIDs: [UUID] = []
    var chatNavigationIndexByMessageID: [UUID: Int] = [:]
    var awaitsFreshBottomNavigationSnapshot = false
    var bottomNavigationSnapshotBaselineRevision: UInt = 0
    var needsImmediateBottomSnap = true

    let chatScrollPositionController = ChatScrollPositionController()
    let chatHistoryViewportAnchorController = ChatHistoryViewportAnchorController()
    let chatLayoutIntegrityMonitor = ChatLayoutIntegrityMonitor()

    private var childSubscriptions: Set<AnyCancellable> = []

    init() {
        chatScrollPositionController.objectWillChange
            .merge(
                with: chatHistoryViewportAnchorController.objectWillChange,
                chatLayoutIntegrityMonitor.objectWillChange
            )
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childSubscriptions)
    }

    var keepsBottomPinnedBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.shouldKeepBottomPinned ?? false },
            set: { [weak self] in self?.shouldKeepBottomPinned = $0 }
        )
    }

    var pendingAnchorAdjustment: ChatScrollAnchorAdjustment? {
        chatHistoryViewportAnchorController.pendingAdjustment
            ?? chatLayoutIntegrityMonitor.pendingAnchorAdjustment
    }

    var hasPendingOrActiveScrollCommand: Bool {
        pendingScrollTargetTask != nil || chatScrollPositionController.hasActiveCommand
    }

    func beginAutomaticHistoryMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID]
    ) -> Bool {
        guard lastAutomaticHistoryLoadAnchorID != anchorMessageID,
              beginHistoryMutation(
                anchorMessageID: anchorMessageID,
                displayedMessageIDs: displayedMessageIDs
              ) else {
            return false
        }
        lastAutomaticHistoryLoadAnchorID = anchorMessageID
        return true
    }

    func beginManualHistoryMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID]
    ) -> Bool {
        beginHistoryMutation(
            anchorMessageID: anchorMessageID,
            displayedMessageIDs: displayedMessageIDs
        )
    }

    func finishHistoryMutation(didLoad: Bool) {
        guard !didLoad else { return }
        suppressAutoScrollOnce = false
        cancelHistoryAnchorRestoration()
    }

    @discardableResult
    func completeAnchorAdjustment(id: UUID) -> Bool {
        if chatHistoryViewportAnchorController.completeAdjustment(id: id) {
            isHistoryLoadInFlight = false
            return true
        }
        chatLayoutIntegrityMonitor.completeAnchorAdjustment(id: id)
        return false
    }

    func cancelAutomaticHistoryNavigation() {
        cancelHistoryAnchorRestoration()
        pendingAutomaticHistoryLoadRequest = nil
        lastAutomaticHistoryLoadAnchorID = nil
    }

    func cancelHistoryAnchorRestoration() {
        isHistoryLoadInFlight = false
        chatHistoryViewportAnchorController.cancel()
    }

    @discardableResult
    func updateInteractionState(_ isUserInteracting: Bool) -> Bool {
        chatScrollPositionController.updateUserInteraction(isUserInteracting)
        guard isChatScrollUserInteracting != isUserInteracting else { return false }
        isChatScrollUserInteracting = isUserInteracting
        if isUserInteracting {
            scrollNavigationHideTask?.cancel()
            scrollNavigationHideTask = nil
            if chatHistoryViewportAnchorController.isRestoringAnchor {
                cancelHistoryAnchorRestoration()
            }
        }
        return true
    }

    func prepareForUserPan(
        isMessageJumpInFlight: Bool,
        bottomScrollTarget: ChatScrollTargetID
    ) -> Bool {
        awaitsFreshBottomNavigationSnapshot = false
        messageNavigationCursorID = nil
        cancelHistoryAnchorRestoration()
        pendingAutomaticHistoryLoadRequest = nil

        let hadScrollTarget = chatScrollPositionController.hasActiveCommand
        let hadActiveBottomTarget =
            chatScrollPositionController.activeCommandTarget == bottomScrollTarget
        let shouldCancelCommand = Self.shouldCancelProgrammaticScrollOnPanBegan(
            hasPendingHistoryReset: pendingHistoryResetWorkItem != nil,
            hasPendingBottomSnap: pendingBottomSnapTask != nil,
            hasPendingTargetTask: pendingScrollTargetTask != nil,
            hasScrollTarget: hadScrollTarget,
            hasActiveBottomTarget: hadActiveBottomTarget,
            isMessageJumpInFlight: isMessageJumpInFlight
        )
        _ = updateInteractionState(true)
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        if shouldCancelCommand {
            needsImmediateBottomSnap = false
        }
        return shouldCancelCommand
    }

    func prepareForDisappearance() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        chatLayoutSettleTask?.cancel()
        chatLayoutSettleTask = nil
        isChatLayoutSettling = false
        chatLayoutIntegrityMonitor.stop()
        cancelAutomaticHistoryNavigation()
        awaitsFreshBottomNavigationSnapshot = false
        bottomNavigationSnapshotBaselineRevision = 0
        messageNavigationCursorID = nil
        scrollNavigationHideTask?.cancel()
        scrollNavigationHideTask = nil
        showScrollNavigationPanel = false
    }

    nonisolated static func shouldCancelProgrammaticScrollOnPanBegan(
        hasPendingHistoryReset: Bool,
        hasPendingBottomSnap: Bool,
        hasPendingTargetTask: Bool,
        hasScrollTarget: Bool,
        hasActiveBottomTarget: Bool,
        isMessageJumpInFlight: Bool
    ) -> Bool {
        hasPendingHistoryReset
            || hasPendingBottomSnap
            || hasPendingTargetTask
            || hasScrollTarget
            || hasActiveBottomTarget
            || isMessageJumpInFlight
    }

    func resetForSessionChange() {
        pendingHistoryResetWorkItem?.cancel()
        pendingHistoryResetWorkItem = nil
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = nil
        bottomScrollCommandReleaseTask?.cancel()
        bottomScrollCommandReleaseTask = nil
        chatLayoutSettleTask?.cancel()
        chatLayoutSettleTask = nil
        scrollNavigationHideTask?.cancel()
        scrollNavigationHideTask = nil
        awaitsFreshBottomNavigationSnapshot = false
        bottomNavigationSnapshotBaselineRevision = 0
        lastAutomaticHistoryLoadAnchorID = nil
        isHistoryLoadInFlight = false
        pendingAutomaticHistoryLoadRequest = nil
        suppressAutoScrollOnce = false
        chatHistoryViewportAnchorController.reset()
        chatScrollPositionController.reset()
        messageNavigationCursorID = nil
        chatNavigationMessageIDs = []
        chatNavigationIndexByMessageID = [:]
        previousMessageNavigationTargetID = nil
        nextMessageNavigationTargetID = nil
        isChatLayoutSettling = false
        isChatScrollUserInteracting = false
        scrollDistanceToBottom = 0
        scrollDistanceToTop = 0
        shouldKeepBottomPinned = true
        showScrollToBottom = false
        showScrollNavigationPanel = false
        needsImmediateBottomSnap = true
    }

    private func beginHistoryMutation(
        anchorMessageID: UUID,
        displayedMessageIDs: [UUID]
    ) -> Bool {
        guard !isHistoryLoadInFlight,
              chatHistoryViewportAnchorController.beginMutation(
                anchorMessageID: anchorMessageID,
                displayedMessageIDs: displayedMessageIDs
              ) else {
            return false
        }
        suppressAutoScrollOnce = true
        shouldKeepBottomPinned = false
        isHistoryLoadInFlight = true
        return true
    }
}
