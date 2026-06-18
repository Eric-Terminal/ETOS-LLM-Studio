//
//  ChatViewSendFlight.swift
//  ETOS LLM Studio
//
//  发送飞行动画（iMessage 风格「输入框 → 气泡」Overlay hero）。
//
//  原理：点击发送时，在聊天根 ZStack 顶层放一个临时飞行气泡，先停在输入框 shell（起点）；
//  待真实用户气泡异步插入并测到其落点后，用欠阻尼弹簧把飞行气泡从输入框变形飞到真实落点
//  （带 overshoot 回弹）；飞行期间真实气泡隐身，结束时无动画切回真实气泡。
//
//  关键设计：
//  - 落点用「真实测量」而非估算 —— 落点随对话长短在屏幕不同高度（初始对话靠上、长对话靠下），
//    只有量真实 frame 才不会飞错位、落地闪现。
//  - 起飞由 `.animation(value: landingRect)` 驱动：真实落点一测到即起飞，不经异步派发，
//    不会被发送瞬间的列表重算阻塞（避免「僵在输入框」）。
//  - 测「整行」frame（在 ChatView 层，不侵入气泡渲染）：行右缘=气泡右缘、行顶=气泡顶，
//    气泡尺寸用文本同步估算，组合出准确落点。
//

import SwiftUI
import ETOSCore
import UIKit

// MARK: - 飞行状态

/// 一次发送飞行的状态快照。targetMessageID 为空表示消息尚未异步插入；
/// landingRect 为空表示真实落点尚未测到（飞行气泡停在输入框等待）。
struct SendFlightState: Equatable {
    /// 本次飞行的唯一标识，用于异步回调中校验是否被新的发送覆盖。
    let id: UUID
    /// 发送动作开始时间，用来在目标锁定前识别新插入的同文本用户消息。
    let startedAt: Date
    /// 发送瞬间列表里最后一条用户消息 id，用来识别「新插入」的那条。
    let baselineUserMessageID: UUID?
    /// 已锁定的真实气泡 id（即新插入的用户消息）。
    var targetMessageID: UUID?
    /// 飞行气泡显示的文本（用户已输入内容）。
    let text: String
    /// 气泡渐变起止色（复刻真实用户气泡外观）。
    let startColor: Color
    let endColor: Color
    /// 气泡圆角。
    let cornerRadius: CGFloat
    /// 起点：输入框 shell 在 chatFlight 坐标空间内的 frame。
    let startRect: CGRect
    /// 终点：根据真实落点行 frame 推算的气泡 frame（测到后填入，触发起飞）。
    var landingRect: CGRect?
}

// MARK: - 坐标上报 PreferenceKey

/// 输入框 shell 的 frame（飞行起点），由 composer 持续上报。
struct InputBarRectKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// 飞行目标「整行」的 frame（用于推算真实落点），仅由飞行目标消息上报。
struct FlightTargetRectKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - 飞行气泡外观

/// 飞行气泡复刻真实用户气泡的渐变配色，跟随外观 profile（默认 Telegram 蓝）。
enum ChatFlightBubbleStyle {
    static let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    static let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)
    /// 气泡圆角，与真实用户气泡保持一致的观感。
    static let cornerRadius: CGFloat = 20

    /// 依据当前外观 profile 解析用户气泡的渐变起止色。
    static func resolvedColors() -> (start: Color, end: Color) {
        let slot = ChatAppearanceProfileManager.shared.activeProfile.userBubble
        guard slot.isEnabled else { return (telegramBlue, telegramBlueDark) }
        let start = ChatAppearanceColorCodec.color(from: slot.hex, fallback: telegramBlue)
        let end = ChatAppearanceColorCodec.darkened(start, factor: 0.86)
        return (start, end)
    }
}

/// 飞行中的临时气泡：对角渐变背景 + 圆角 + 白字纯文本（复刻真实用户气泡）。
/// 外部通过 `.frame(width:height:).position(...)` 驱动位置与尺寸的插值变形。
struct FlyingBubbleView: View {
    let text: String
    let startColor: Color
    let endColor: Color
    let cornerRadius: CGFloat

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [startColor, endColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - ChatView 飞行编排

extension ChatView {

    /// 分轴弹簧：x 快（先靠右）、y 慢（后靠上+Q弹），形成曲线弧轨迹（贴近 iMessage）。
    /// 尺寸弹簧高阻尼，避免弹缩变扁。
    private var flightSpringX: Animation {
        .spring(response: appConfig.chatSendAnimationSpringResponse * 0.72,
                dampingFraction: max(0.38, appConfig.chatSendAnimationSpringDamping * 0.82))
    }
    private var flightSpringY: Animation {
        .spring(response: appConfig.chatSendAnimationSpringResponse,
                dampingFraction: appConfig.chatSendAnimationSpringDamping)
    }
    private var flightSpringSize: Animation {
        .spring(response: appConfig.chatSendAnimationSpringResponse * 0.55,
                dampingFraction: 0.82)
    }
    /// 落点迟迟没有上报时的兜底清理时长，防止飞行层残留。
    private var flightCleanupFallbackDuration: Double { 1.4 }
    /// 飞行可见时长，用于安排落地交接（覆盖 y 轴弹簧回弹收尾）。
    private var flightVisibleDuration: Double { 0.65 }

    /// 点击发送：飞行气泡停在输入框；真实落点测到后由 handleFlightTargetRect 起飞。
    /// 起点无效时回退为普通发送（不飞行）。
    func beginSendFlight(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 沿用原发送 spring，驱动助手占位气泡的入场动画。
        let sendSpring = Animation.spring(response: 0.38, dampingFraction: 0.72)

        // 起点无效（未测得输入框 frame）或无文本时，退回普通发送。
        guard inputBarRect.width > 1, inputBarRect.height > 1, !trimmed.isEmpty else {
            withAnimation(sendSpring) { viewModel.sendMessage() }
            return
        }

        let flightID = UUID()
        let startedAt = Date()
        let colors = ChatFlightBubbleStyle.resolvedColors()
        let baseline = viewModel.displayMessages.last { $0.message.role == .user }?.id

        // 飞行气泡初始锁定在输入框位置（起点）；真实落点测到后由 handleFlightTargetRect 驱动飞向落点。
        flightAnimPosX = inputBarRect.midX
        flightAnimPosY = inputBarRect.midY
        flightAnimWidth = inputBarRect.width
        flightAnimHeight = inputBarRect.height

        flightState = SendFlightState(
            id: flightID,
            startedAt: startedAt,
            baselineUserMessageID: baseline,
            targetMessageID: nil,
            text: trimmed,
            startColor: colors.start,
            endColor: colors.end,
            cornerRadius: ChatFlightBubbleStyle.cornerRadius,
            startRect: inputBarRect,
            landingRect: nil
        )
        scheduleFlightCleanup(flightID: flightID, delay: flightCleanupFallbackDuration)

        // 让本次插入走「瞬间吸底」，新真实气泡尽快定位到落点，缩短飞行气泡的等待时间。
        needsImmediateBottomSnap = true

        // 异步插入消息；用户气泡此刻起隐身（见 isHiddenForFlight），由飞行层接管视觉。
        withAnimation(sendSpring) {
            viewModel.sendMessage()
        }
    }

    /// 消息插入后调用：找到新出现的用户消息并锁定（驱动隐身与落点上报）。
    func lockFlightTargetIfNeeded() {
        guard var state = flightState, state.targetMessageID == nil else { return }
        guard let newUserMessage = flightTargetCandidate(for: state) else { return }

        state.targetMessageID = newUserMessage.id
        flightState = state
    }

    /// 输入框持续上报的 frame（飞行起点来源）。
    func handleInputBarRect(_ rect: CGRect?) {
        guard let rect, rect.width > 1, rect.height > 1 else { return }
        inputBarRect = rect
    }

    /// 目标整行上报 frame：推算真实落点，用「分轴弹簧」触发起飞 / 校正。
    /// x 快（先靠右）、y 慢（后靠上+Q弹回弹）、尺寸高阻尼（防压扁），形成曲线弧轨迹。
    func handleFlightTargetRect(_ rowFrame: CGRect?) {
        guard let rowFrame, rowFrame.width > 1, rowFrame.height > 1 else { return }
        guard var state = flightState, state.targetMessageID != nil else { return }

        let size = estimatedFlyingBubbleSize(text: state.text, maxWidth: max(80, rowFrame.width * 0.92))
        let landing = CGRect(
            x: rowFrame.maxX - size.width,
            y: rowFrame.minY,
            width: size.width,
            height: size.height
        )
        guard state.landingRect != landing else { return }

        let isFirstLanding = (state.landingRect == nil)
        state.landingRect = landing
        flightState = state

        // 分轴起/校正飞行 — x 先到、y 后到 ≈ 弧线轨迹
        withAnimation(flightSpringX) { flightAnimPosX = landing.midX }
        withAnimation(flightSpringY) { flightAnimPosY = landing.midY }
        withAnimation(flightSpringSize) {
            flightAnimWidth = landing.width
            flightAnimHeight = landing.height
        }

        if isFirstLanding {
            scheduleFlightCleanup(flightID: state.id, delay: flightVisibleDuration)
        }
    }

    private func scheduleFlightCleanup(flightID: UUID, delay: Double) {
        pendingFlightCleanupTask?.cancel()
        pendingFlightCleanupTask = Task { @MainActor in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            clearFlightWithoutAnimation(flightID: flightID)
        }
    }

    private func clearFlightWithoutAnimation(flightID: UUID) {
        guard flightState?.id == flightID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightState = nil
            pendingFlightCleanupTask?.cancel()
            pendingFlightCleanupTask = nil
        }
    }

    /// 指定消息当前是否因飞行而需要隐身（真实气泡让位给飞行气泡）。
    func isHiddenForFlight(_ message: ChatMessage) -> Bool {
        guard let state = flightState else { return false }
        if state.targetMessageID == message.id { return true }
        guard state.targetMessageID == nil else { return false }
        return isFlightTargetCandidate(message, for: state)
    }

    /// 飞行覆盖层：置于聊天根 ZStack 顶层。位置与尺寸由分轴弹簧独立驱动，
    /// x 快（先靠右）、y 慢（后靠上+回弹）、尺寸高阻尼（不压扁），形成灵动弧线。
    @ViewBuilder
    var flightOverlayLayer: some View {
        if let state = flightState {
            FlyingBubbleView(
                text: state.text,
                startColor: state.startColor,
                endColor: state.endColor,
                cornerRadius: state.cornerRadius
            )
            .id(state.id)
            .frame(width: max(flightAnimWidth, 1), height: max(flightAnimHeight, 1))
            .position(x: flightAnimPosX, y: flightAnimPosY)
            .allowsHitTesting(false)
            .zIndex(40)
        }
    }

    /// 落点上报器：仅挂在飞行目标消息上（单条测量），上报其整行 frame。
    @ViewBuilder
    func flightTargetReporter(for messageID: UUID) -> some View {
        if let state = flightState, state.targetMessageID == messageID {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FlightTargetRectKey.self,
                    value: proxy.frame(in: .named(ChatView.flightCoordinateSpace))
                )
            }
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
        guard message.content.trimmingCharacters(in: .whitespacesAndNewlines) == state.text else { return false }
        guard let requestedAt = message.requestedAt else { return true }
        return requestedAt >= state.startedAt.addingTimeInterval(-0.2)
    }

    /// 同步估算飞行气泡（≈ 真实用户气泡）的自然尺寸，用于推算落点的气泡大小。
    /// 文本短、测量极快，仅在落点上报时执行，不在渲染链路。
    private func estimatedFlyingBubbleSize(text: String, maxWidth: CGFloat) -> CGSize {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let horizontalPadding: CGFloat = 12 * 2
        let verticalPadding: CGFloat = 8 * 2
        let textMaxWidth = max(1, maxWidth - horizontalPadding)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: textMaxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return CGSize(
            width: ceil(bounding.width) + horizontalPadding,
            height: ceil(bounding.height) + verticalPadding
        )
    }

    /// 飞行坐标空间名称（起点与终点 frame 统一到此空间）。
    static var flightCoordinateSpace: String { "chatFlight" }
}
