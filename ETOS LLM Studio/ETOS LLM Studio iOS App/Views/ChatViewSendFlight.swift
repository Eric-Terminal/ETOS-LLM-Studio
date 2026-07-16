// ============================================================================
// ChatViewSendFlight.swift
// ============================================================================
// ETOS LLM Studio
//
// 发送时由一份临时文字快照接管输入内容，先在输入栏内显色并向右收拢，
// 再从当前呈现位置飞向新消息的真实正文气泡。落点在布局变化时可继续重定向，
// 最后通过短交叉渐变交还给真实气泡，避免等待后瞬移和落点闪接。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

// MARK: - 飞行状态

enum SendFlightPhase: Equatable {
    case launching
    case landing
}

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
    var phase: SendFlightPhase
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

    /// 参考录屏的前约 100ms：先给按下发送即时的材质和收拢反馈。
    private var sendFlightCompressionDuration: Double {
        min(0.14, max(0.06, sendFlightResponse * 0.22))
    }

    private var sendFlightLandingResponse: Double {
        max(0.18, sendFlightResponse - sendFlightCompressionDuration)
    }

    /// 设置中的回弹仍然有效，但限制在不会出现橡皮抖动的惯性区间。
    private var sendFlightLandingDamping: Double {
        let configured = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        let normalized = (configured - 0.4) / 0.6
        return 0.82 + normalized * 0.14
    }

    private var sendFlightPreludeSpring: Animation {
        .spring(
            response: min(0.22, max(0.14, sendFlightCompressionDuration * 1.8)),
            dampingFraction: 0.96
        )
    }

    private var sendFlightCompressionSpring: Animation {
        .spring(
            response: min(0.28, max(0.16, sendFlightCompressionDuration * 1.8)),
            dampingFraction: 0.94
        )
    }

    /// 收拢动画被落位弹簧打断时，SwiftUI 会从当前呈现值接续运动。
    private var sendFlightLandingSpring: Animation {
        .spring(
            response: sendFlightLandingResponse,
            dampingFraction: sendFlightLandingDamping
        )
    }

    /// 列表在飞行中继续校正布局时，从当前呈现位置平顺追随新落点。
    private var sendFlightRetargetSpring: Animation {
        .spring(
            response: max(0.16, sendFlightLandingResponse * 0.46),
            dampingFraction: 0.94
        )
    }

    private var sendFlightFallbackDuration: Double { 1.6 }
    private var sendFlightHandoffDuration: Double {
        min(0.11, max(0.08, sendFlightLandingResponse * 0.28))
    }
    private var sendFlightVisibleDuration: Double {
        sendFlightLandingResponse
    }

    func beginSendFlight(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendSpring = Animation.spring(
            response: sendFlightResponse,
            dampingFraction: sendFlightLandingDamping
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
                landingRect: nil,
                phase: .launching
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

        if state.phase == .launching {
            withAnimation(sendFlightCompressionSpring) {
                flightPresentationRect = sendFlightCompressionRect(
                    from: state.startRect,
                    to: rect
                )
                flightVisualProgress = 0.86
            }
            if isFirstLanding {
                scheduleSendFlightLanding(flightID: state.id)
            }
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
                sourceIsExpanded: state.startRect.height > 72,
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

    private func scheduleSendFlightPrelude(flightID: UUID) {
        Task { @MainActor in
            // 先让 Overlay 以起点几何呈现一帧，避免初始值与动画终值被合并。
            await Task.yield()
            guard let state = flightState,
                  state.id == flightID,
                  state.phase == .launching,
                  state.landingRect == nil else { return }

            withAnimation(sendFlightPreludeSpring) {
                flightPresentationRect = sendFlightPreludeRect(from: state.startRect)
                flightVisualProgress = 0.36
            }
        }
    }

    private func scheduleSendFlightLanding(flightID: UUID) {
        guard let state = flightState, state.id == flightID else { return }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        let remainingCompression = max(0, sendFlightCompressionDuration - elapsed)

        Task { @MainActor in
            if remainingCompression > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(remainingCompression * 1_000_000_000)
                )
            } else {
                await Task.yield()
            }
            guard var currentState = flightState,
                  currentState.id == flightID,
                  currentState.phase == .launching,
                  let landingRect = currentState.landingRect else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentState.phase = .landing
                flightState = currentState
            }
            withAnimation(sendFlightLandingSpring) {
                flightPresentationRect = landingRect
                flightVisualProgress = 1
            }
            scheduleSendFlightHandoff(flightID: flightID)
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

    private func sendFlightPreludeRect(from source: CGRect) -> CGRect {
        guard source.height <= 72 else { return source }
        let width = max(source.height, source.width * 0.9)
        let trailingShift = min(10, source.height * 0.2)
        return CGRect(
            x: source.maxX + trailingShift - width,
            y: source.minY,
            width: width,
            height: source.height
        )
    }

    private func sendFlightCompressionRect(from source: CGRect, to target: CGRect) -> CGRect {
        let y = source.height > 72
            ? source.minY
            : source.midY - target.height / 2
        return CGRect(
            x: target.minX,
            y: y,
            width: target.width,
            height: target.height
        )
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
