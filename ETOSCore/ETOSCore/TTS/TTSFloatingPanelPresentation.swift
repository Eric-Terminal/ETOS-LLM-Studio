// ============================================================================
// TTSFloatingPanelPresentation.swift
// ETOS LLM Studio
//
// 两端共享浮窗的显示规则。延迟请求带独立身份，旧倒计时不能关闭新一轮朗读。
// ============================================================================

import Foundation

public struct TTSFloatingPanelPresentation {
    public static let dismissalDelayNanoseconds: UInt64 = 3_000_000_000

    public private(set) var isVisible = false
    public private(set) var dismissalID: UUID?
    private var status: TTSPlaybackStatus = .idle
    private var isPlaybackActive = false
    private var isDismissalSuspended = false

    public init() {}

    public mutating func updatePlayback(isSpeaking: Bool, status: TTSPlaybackStatus) {
        let statusChanged = self.status != status
        self.status = status
        isPlaybackActive = isSpeaking || status == .playing || status == .paused || status == .buffering

        if isPlaybackActive {
            isVisible = true
            cancelPendingDismissal()
            return
        }

        switch status {
        case .ended:
            scheduleDismissalIfNeeded()
        case .error:
            // 失败提示留给用户处理；已经关闭的旧错误也不会因刷新再次出现。
            cancelPendingDismissal()
            if statusChanged { isVisible = true }
        case .idle:
            dismiss()
        case .playing, .paused, .buffering:
            break
        }
    }

    public mutating func setDismissalSuspended(_ suspended: Bool) {
        isDismissalSuspended = suspended
        if suspended {
            cancelPendingDismissal()
        } else {
            scheduleDismissalIfNeeded()
        }
    }

    public mutating func cancelPendingDismissal() {
        dismissalID = nil
    }

    public mutating func dismiss() {
        isVisible = false
        cancelPendingDismissal()
    }

    public mutating func dismiss(ifMatching id: UUID) {
        guard dismissalID == id else { return }
        dismiss()
    }

    private mutating func scheduleDismissalIfNeeded() {
        // 新页面首次看到历史 ended 状态时不重新弹窗，也不重复延长已有倒计时。
        guard isVisible, !isPlaybackActive, status == .ended,
              !isDismissalSuspended, dismissalID == nil else { return }
        dismissalID = UUID()
    }
}
