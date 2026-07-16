// ============================================================================
// ChatViewSendFlight.swift
// ============================================================================
// ETOS LLM Studio
//
// 发送时由一份临时文字快照接管输入内容，再飞向新消息的真实正文气泡。
// 起点、终点都来自实际布局测量；位置、尺寸与材质使用同一条可打断弹簧，
// 最后通过短交叉渐变交还给真实气泡，避免错位、橡皮形变和落点闪接。
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
    let sourceUsesBottomAlignment: Bool
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)
        let materialProgress = Self.smoothStep(
            min(max((clampedProgress - 0.08) / 0.62, 0), 1)
        )
        let targetTextProgress = Self.smoothStep(
            min(max((clampedProgress - 0.18) / 0.64, 0), 1)
        )
        let horizontalInset = Self.interpolate(from: 5, to: 12, progress: materialProgress)
        let cornerRadius = Self.interpolate(
            from: sourceCornerRadius,
            to: targetCornerRadius,
            progress: materialProgress
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let sourceAlignment: Alignment = sourceUsesBottomAlignment ? .bottomLeading : .topLeading

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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sourceAlignment)
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
    /// 将现有“响应/阻尼”设置映射为带初速度的物理弹簧，让起飞拥有连续惯性。
    private var sendFlightSpring: Animation {
        let response = max(0.2, appConfig.chatSendAnimationSpringResponse)
        let dampingRatio = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        let angularFrequency = 2 * Double.pi / response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * dampingRatio * angularFrequency
        return .interpolatingSpring(
            mass: 1,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: 0.72
        )
    }

    /// 列表在飞行中继续校正布局时，从当前呈现位置平顺追随新落点。
    private var sendFlightRetargetSpring: Animation {
        .spring(
            response: max(0.18, appConfig.chatSendAnimationSpringResponse * 0.48),
            dampingFraction: 0.92
        )
    }

    private var sendFlightFallbackDuration: Double { 1.6 }
    private var sendFlightHandoffDuration: Double { 0.14 }
    private var sendFlightVisibleDuration: Double {
        let response = max(0.2, appConfig.chatSendAnimationSpringResponse)
        let damping = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        return min(1.3, max(0.42, response * (1.35 + (1 - damping) * 0.65)))
    }

    func beginSendFlight(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendSpring = Animation.spring(response: 0.38, dampingFraction: 0.72)
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
            flightPresentationRect = inputBarRect
            flightVisualProgress = 0
            flightHandoffProgress = 0
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

        needsImmediateBottomSnap = true
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

        if isFirstLanding {
            withAnimation(sendFlightSpring) {
                flightPresentationRect = rect
                flightVisualProgress = 1
            }
            scheduleSendFlightHandoff(flightID: state.id)
        } else {
            withAnimation(sendFlightRetargetSpring) {
                flightPresentationRect = rect
            }
        }
    }

    func isSendFlightTarget(_ messageID: UUID) -> Bool {
        flightState?.targetMessageID == messageID
    }

    func sendFlightTargetOpacity(for messageID: UUID) -> Double {
        guard flightState?.targetMessageID == messageID else { return 1 }
        return Double(flightHandoffProgress)
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
                sourceUsesBottomAlignment: state.startRect.height > 72,
                progress: flightVisualProgress
            )
            .id(state.id)
            .frame(
                width: max(flightPresentationRect.width, 1),
                height: max(flightPresentationRect.height, 1)
            )
            .position(
                x: flightPresentationRect.midX,
                y: flightPresentationRect.midY
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
            guard !Task.isCancelled else { return }
            clearSendFlightWithoutAnimation(flightID: flightID)
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
            flightPresentationRect = .zero
            flightVisualProgress = 0
            flightHandoffProgress = 0
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
