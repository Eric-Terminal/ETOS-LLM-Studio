// ============================================================================
// ChatViewSendFlight.swift
// ============================================================================
// ETOS LLM Studio
//
// 发送时由一份临时文字快照接管输入内容，在输入栏内立即显色，
// 再以快速横向收拢和缓慢纵向上升两条可打断弹簧飞向真实气泡。
// 落点在布局变化时继续从当前呈现值重定向，最后通过短交叉渐变完成交接；
// 同轮助手回复在用户气泡落位后才显现，保持发送与响应的视觉因果。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

// MARK: - 飞行状态

struct SendFlightState: Equatable {
    let id: UUID
    let startedAt: Date
    let baselineUserMessageID: UUID?
    var targetMessageID: UUID?
    let text: String
    let startColor: Color
    let endColor: Color
    let inputTextColor: Color
    let bubbleTextColor: Color
    let bubbleOpacity: Double
    let cornerRadius: CGFloat
    let startRect: CGRect
    var landingRect: CGRect?
}

// MARK: - 坐标上报

/// 输入编辑器实际文字视口的 frame。
struct InputBarRectKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

/// 新用户消息实际正文气泡的 frame。
struct FlightTargetRectKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

// MARK: - 飞行外观

enum ChatFlightBubbleStyle {
    struct ResolvedStyle {
        let startColor: Color
        let endColor: Color
        let inputTextColor: Color
        let bubbleTextColor: Color
        let bubbleOpacity: Double
    }

    private static let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    private static let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)
    static let cornerRadius: CGFloat = 18

    static func resolvedStyle(
        colorScheme: ColorScheme,
        enableBackground: Bool
    ) -> ResolvedStyle {
        let profile = ChatAppearanceProfileManager.shared.activeProfile
        let bubbleSlot = profile.userBubble
        let startColor = bubbleSlot.isEnabled
            ? ChatAppearanceColorCodec.color(from: bubbleSlot.hex, fallback: telegramBlue)
            : telegramBlue
        let endColor = bubbleSlot.isEnabled
            ? ChatAppearanceColorCodec.darkened(startColor, factor: 0.86)
            : telegramBlueDark
        let textSlot = colorScheme == .dark ? profile.userDarkText : profile.userLightText
        let bubbleTextColor = textSlot.isEnabled
            ? ChatAppearanceColorCodec.color(from: textSlot.hex, fallback: .white)
            : .white

        return ResolvedStyle(
            startColor: startColor,
            endColor: endColor,
            inputTextColor: .primary,
            bubbleTextColor: bubbleTextColor,
            bubbleOpacity: enableBackground ? 0.85 : 1
        )
    }
}

/// 输入文字先保持原色，再在运动中显现气泡材质并过渡为最终文字外观。
struct FlyingBubbleView: View, Animatable {
    let text: String
    let startColor: Color
    let endColor: Color
    let inputTextColor: Color
    let bubbleTextColor: Color
    let bubbleOpacity: Double
    let sourceCornerRadius: CGFloat
    let targetCornerRadius: CGFloat
    let sourceIsExpanded: Bool
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)
        // 展开编辑器先收缩几何再显色，避免整块大面积视口短暂变成用户气泡。
        let materialProgress = sourceIsExpanded
            ? Self.smoothStep(min(max((clampedProgress - 0.62) / 0.28, 0), 1))
            : Self.smoothStep(min(max(clampedProgress / 0.44, 0), 1))
        let targetTextProgress = sourceIsExpanded
            ? Self.smoothStep(min(max((clampedProgress - 0.68) / 0.26, 0), 1))
            : Self.smoothStep(min(max((clampedProgress - 0.08) / 0.48, 0), 1))
        let horizontalInset = Self.interpolate(from: 5, to: 12, progress: materialProgress)
        let cornerRadius = Self.interpolate(
            from: sourceCornerRadius,
            to: targetCornerRadius,
            progress: materialProgress
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack(alignment: .topLeading) {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            startColor.opacity(bubbleOpacity),
                            endColor.opacity(bubbleOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(Double(materialProgress))

            Text(text)
                .etFont(.system(size: 16))
                .foregroundStyle(inputTextColor)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(Double(1 - targetTextProgress))
                .clipped()

            Text(text)
                .etFont(.body)
                .foregroundStyle(bubbleTextColor)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(Double(targetTextProgress))
                .clipped()
        }
        .clipShape(shape)
        .shadow(
            color: Color.black.opacity(0.08 * Double(materialProgress)),
            radius: 3 * materialProgress,
            y: materialProgress
        )
    }

    private static func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }

    private static func smoothStep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

// MARK: - ChatView 飞行编排

extension ChatView {
    private var sendFlightResponse: Double {
        min(max(appConfig.chatSendAnimationSpringResponse, 0.2), 0.8)
    }

    private var sendFlightConfiguredDamping: Double {
        let configured = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        return (configured - 0.4) / 0.6
    }

    private var sendFlightVerticalDamping: Double {
        0.76 + sendFlightConfiguredDamping * 0.18
    }

    private var sendFlightHorizontalResponse: Double {
        min(0.34, max(0.14, sendFlightResponse * 0.42))
    }

    /// 参考录屏中横向收拢约为纵向响应的 42%，并保留轻微越界惯性。
    private var sendFlightHorizontalSpring: Animation {
        .spring(
            response: sendFlightHorizontalResponse,
            dampingFraction: 0.60 + sendFlightConfiguredDamping * 0.30
        )
    }

    /// 宽度保留轻微收缩惯性，但比横向位置更高阻尼，防止短气泡过度压缩。
    private var sendFlightWidthSpring: Animation {
        .spring(
            response: sendFlightHorizontalResponse,
            dampingFraction: 0.68 + sendFlightConfiguredDamping * 0.22
        )
    }

    /// 纵向保持完整响应时间，避免短距离内瞬间弹到落点。
    private var sendFlightVerticalSpring: Animation {
        .spring(
            response: sendFlightResponse,
            dampingFraction: sendFlightVerticalDamping
        )
    }

    private var sendFlightPreludeSpring: Animation {
        .spring(
            response: min(0.16, max(0.10, sendFlightResponse * 0.27)),
            dampingFraction: 1
        )
    }

    private var sendFlightMaterialSpring: Animation {
        .spring(
            response: min(0.28, max(0.16, sendFlightResponse * 0.48)),
            dampingFraction: 0.96
        )
    }

    /// 展开编辑器与短气泡的高度差很大，高度使用独立高阻尼避免过度压扁。
    private var sendFlightHeightSpring: Animation {
        .spring(
            response: min(0.30, max(0.16, sendFlightResponse * 0.44)),
            dampingFraction: 0.96
        )
    }

    private var sendFlightFallbackDuration: Double { 1.6 }
    private var sendFlightHandoffDuration: Double {
        min(0.11, max(0.08, sendFlightResponse * 0.22))
    }
    private var sendFlightReplyRevealDuration: Double { 0.16 }
    private var sendFlightVisibleDuration: Double {
        min(0.75, max(0.28, sendFlightResponse * 0.9))
    }

    func beginSendFlight(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendSpring = Animation.spring(
            response: sendFlightResponse,
            dampingFraction: sendFlightVerticalDamping
        )
        let hasAttachments = viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty

        guard !accessibilityReduceMotion,
              isUsableSendFlightRect(inputBarRect),
              !hasAttachments,
              !trimmed.isEmpty else {
            withAnimation(accessibilityReduceMotion ? .easeOut(duration: 0.12) : sendSpring) {
                viewModel.sendMessage()
            }
            return
        }

        let flightID = UUID()
        let style = ChatFlightBubbleStyle.resolvedStyle(
            colorScheme: colorScheme,
            enableBackground: viewModel.enableBackground
        )
        let baseline = viewModel.displayMessages.last { $0.message.role == .user }?.id

        pendingFlightCleanupTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightPresentationX = inputBarRect.midX
            flightPresentationY = inputBarRect.midY
            flightPresentationWidth = inputBarRect.width
            flightPresentationHeight = inputBarRect.height
            flightVisualProgress = 0
            flightHandoffProgress = 0
            flightReplyRevealProgress = 0
            flightState = SendFlightState(
                id: flightID,
                startedAt: Date(),
                baselineUserMessageID: baseline,
                targetMessageID: nil,
                text: trimmed,
                startColor: style.startColor,
                endColor: style.endColor,
                inputTextColor: style.inputTextColor,
                bubbleTextColor: style.bubbleTextColor,
                bubbleOpacity: style.bubbleOpacity,
                cornerRadius: ChatFlightBubbleStyle.cornerRadius,
                startRect: inputBarRect,
                landingRect: nil
            )
        }
        scheduleSendFlightFallback(flightID: flightID)
        scheduleSendFlightPrelude(flightID: flightID)

        // 保留列表自身的平滑吸底，让已有消息与飞行气泡同时为新消息让出空间。
        withAnimation(sendSpring) {
            viewModel.sendMessage()
        }
    }

    func lockFlightTargetIfNeeded() {
        guard var state = flightState, state.targetMessageID == nil else { return }
        guard let newUserMessage = flightTargetCandidate(for: state) else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.targetMessageID = newUserMessage.id
            flightState = state
        }
    }

    func handleInputBarRect(_ rect: CGRect?) {
        guard let rect, isUsableSendFlightRect(rect) else { return }
        inputBarRect = rect
    }

    func handleFlightTargetRect(_ rect: CGRect?) {
        guard let rect, isUsableSendFlightRect(rect) else { return }
        guard var state = flightState, state.targetMessageID != nil else { return }
        guard sendFlightRectsDiffer(state.landingRect, rect) else { return }

        let isFirstLanding = state.landingRect == nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.landingRect = rect
            flightState = state
        }

        withAnimation(sendFlightHorizontalSpring) {
            flightPresentationX = rect.midX
        }
        withAnimation(sendFlightVerticalSpring) {
            flightPresentationY = rect.midY
        }
        withAnimation(sendFlightWidthSpring) {
            flightPresentationWidth = rect.width
        }
        withAnimation(sendFlightHeightSpring) {
            flightPresentationHeight = rect.height
        }
        withAnimation(sendFlightMaterialSpring) {
            flightVisualProgress = 1
        }
        if isFirstLanding {
            scheduleSendFlightHandoff(flightID: state.id)
        }
    }

    func isSendFlightTarget(_ messageID: UUID) -> Bool {
        flightState?.targetMessageID == messageID
    }

    func sendFlightMessageOpacity(for message: ChatMessage) -> Double {
        guard let state = flightState else { return 1 }
        if state.targetMessageID == message.id {
            return Double(flightHandoffProgress)
        }
        guard Self.shouldDeferReplyDuringSendFlight(
            message,
            targetMessageID: state.targetMessageID,
            baselineUserMessageID: state.baselineUserMessageID,
            flightStartedAt: state.startedAt
        ) else {
            return 1
        }
        return Double(flightReplyRevealProgress)
    }

    /// 目标 ID 上报前用请求时间识别新回复，上报后改用回复组精确关联，避免首帧闪现。
    static func shouldDeferReplyDuringSendFlight(
        _ message: ChatMessage,
        targetMessageID: UUID?,
        baselineUserMessageID: UUID?,
        flightStartedAt: Date
    ) -> Bool {
        switch message.role {
        case .assistant, .tool, .error:
            break
        case .system, .user:
            return false
        }

        guard let responseGroupID = message.responseGroupID else { return false }
        if let targetMessageID {
            return responseGroupID == targetMessageID
        }

        if let baselineUserMessageID, responseGroupID == baselineUserMessageID {
            return false
        }
        guard let requestedAt = message.requestedAt else { return false }
        return requestedAt >= flightStartedAt.addingTimeInterval(-0.2)
    }

    @ViewBuilder
    var flightOverlayLayer: some View {
        if let state = flightState {
            FlyingBubbleView(
                text: state.text,
                startColor: state.startColor,
                endColor: state.endColor,
                inputTextColor: state.inputTextColor,
                bubbleTextColor: state.bubbleTextColor,
                bubbleOpacity: state.bubbleOpacity,
                sourceCornerRadius: min(state.startRect.height / 2, 22),
                targetCornerRadius: state.cornerRadius,
                sourceIsExpanded: state.startRect.height > 72,
                progress: flightVisualProgress
            )
            .id(state.id)
            .frame(
                width: max(flightPresentationWidth, 1),
                height: max(flightPresentationHeight, 1)
            )
            .position(
                x: flightPresentationX,
                y: flightPresentationY
            )
            .opacity(Double(max(0, 1 - flightHandoffProgress)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(40)
        }
    }

    private func scheduleSendFlightFallback(flightID: UUID) {
        pendingFlightCleanupTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(sendFlightFallbackDuration * 1_000_000_000)
            )
            guard !Task.isCancelled, flightState?.id == flightID else { return }

            // 几何上报失败时也先淡出飞行层并放行回复，避免超时后整组内容突现。
            withAnimation(.easeOut(duration: sendFlightReplyRevealDuration)) {
                flightHandoffProgress = 1
                flightReplyRevealProgress = 1
            }
            try? await Task.sleep(
                nanoseconds: UInt64(sendFlightReplyRevealDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            clearSendFlightWithoutAnimation(flightID: flightID)
        }
    }

    private func scheduleSendFlightPrelude(flightID: UUID) {
        Task { @MainActor in
            // 先让 Overlay 以起点几何呈现一帧，避免初始值与动画终值被合并。
            await Task.yield()
            guard let state = flightState,
                  state.id == flightID,
                  state.landingRect == nil else { return }

            withAnimation(sendFlightPreludeSpring) {
                flightPresentationY = state.startRect.midY
                    - min(3, state.startRect.height * 0.07)
                flightVisualProgress = 0.36
            }
        }
    }

    private func scheduleSendFlightHandoff(flightID: UUID) {
        pendingFlightCleanupTask?.cancel()
        pendingFlightCleanupTask = Task { @MainActor in
            let handoffDelay = max(0, sendFlightVisibleDuration - sendFlightHandoffDuration)
            try? await Task.sleep(nanoseconds: UInt64(handoffDelay * 1_000_000_000))
            guard !Task.isCancelled, flightState?.id == flightID else { return }

            withAnimation(.easeOut(duration: sendFlightHandoffDuration)) {
                flightHandoffProgress = 1
            }

            try? await Task.sleep(
                nanoseconds: UInt64(sendFlightHandoffDuration * 1_000_000_000)
            )
            guard !Task.isCancelled, flightState?.id == flightID else { return }

            // 用户气泡完成交接后再放行同轮回复，避免助手先悬在空白落点下方。
            withAnimation(.easeOut(duration: sendFlightReplyRevealDuration)) {
                flightReplyRevealProgress = 1
            }

            try? await Task.sleep(
                nanoseconds: UInt64(sendFlightReplyRevealDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            clearSendFlightWithoutAnimation(flightID: flightID)
        }
    }

    private func clearSendFlightWithoutAnimation(flightID: UUID) {
        guard flightState?.id == flightID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightState = nil
            flightPresentationX = 0
            flightPresentationY = 0
            flightPresentationWidth = 0
            flightPresentationHeight = 0
            flightVisualProgress = 0
            flightHandoffProgress = 0
            flightReplyRevealProgress = 0
            pendingFlightCleanupTask?.cancel()
            pendingFlightCleanupTask = nil
        }
    }

    private func flightTargetCandidate(for state: SendFlightState) -> ChatMessageRenderState? {
        let messages = viewModel.displayMessages
        let searchRange: ArraySlice<ChatMessageRenderState>
        if let baseline = state.baselineUserMessageID,
           let baselineIndex = messages.lastIndex(where: { $0.id == baseline }) {
            searchRange = messages[messages.index(after: baselineIndex)...]
        } else {
            searchRange = messages[...]
        }
        return searchRange.first { isFlightTargetCandidate($0.message, for: state) }
    }

    private func isFlightTargetCandidate(_ message: ChatMessage, for state: SendFlightState) -> Bool {
        guard message.role == .user, message.id != state.baselineUserMessageID else { return false }
        guard message.content.trimmingCharacters(in: .whitespacesAndNewlines) == state.text else {
            return false
        }
        guard let requestedAt = message.requestedAt else { return true }
        return requestedAt >= state.startedAt.addingTimeInterval(-0.2)
    }

    private func isUsableSendFlightRect(_ rect: CGRect) -> Bool {
        rect.width > 1
            && rect.height > 1
            && rect.minX.isFinite
            && rect.minY.isFinite
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }

    private func sendFlightRectsDiffer(_ current: CGRect?, _ next: CGRect) -> Bool {
        guard let current else { return true }
        let tolerance: CGFloat = 0.5
        return abs(current.minX - next.minX) > tolerance
            || abs(current.minY - next.minY) > tolerance
            || abs(current.width - next.width) > tolerance
            || abs(current.height - next.height) > tolerance
    }

    static var flightCoordinateSpace: String { "chatFlight" }
}
