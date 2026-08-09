// ============================================================================
// ChatViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 ChatView 共享的轻量辅助类型、背景视图和滚动观察器。
// ============================================================================

import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers
import ETOSCore

enum TelegramColors {
    static let navBarText = Color.primary
    static let navBarSubtitle = Color.secondary
    static let inputBackground = Color(uiColor: .systemBackground)
    static let inputFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .separator)
    static let attachButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let sendButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let scrollButtonBackground = Color(uiColor: .systemBackground)
    static let scrollButtonShadow = Color.black.opacity(0.15)
}

struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

func resolvedFileMimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext),
       let mimeType = type.preferredMIMEType {
        return mimeType
    }
    return "application/octet-stream"
}

struct ChatExportSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?

    init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ChatPickerSheet: String, Identifiable {
    case session
    case model

    var id: String { rawValue }
}

struct MessageActionSheetPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
}

struct MessageVersionDeletePayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let index: Int
}

enum MessageActionExportScope: String, CaseIterable, Identifiable {
    case fullSession
    case upToMessage

    var id: String { rawValue }
}

struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}

/// 只在会改变气泡高度的结构切换时重建视觉子树。
struct ChatBubbleLayoutIdentity: Hashable {
    let messageID: UUID
    let structuralRevision: UInt
    let isStreaming: Bool
    let hasPreparedMarkdown: Bool
    let hasPreparedReasoningMarkdown: Bool

    init(
        messageID: UUID,
        structuralRevision: UInt,
        isStreaming: Bool,
        isStaticMarkdownHandoffInProgress: Bool = false,
        hasPreparedMarkdown: Bool,
        hasPreparedReasoningMarkdown: Bool
    ) {
        let preservesStreamingView = isStreaming || isStaticMarkdownHandoffInProgress
        self.messageID = messageID
        self.structuralRevision = preservesStreamingView ? 0 : structuralRevision
        self.isStreaming = preservesStreamingView
        // 交接期间冻结完整身份，避免任一通道先完成时重建另一通道的流式子树。
        self.hasPreparedMarkdown = preservesStreamingView ? false : hasPreparedMarkdown
        self.hasPreparedReasoningMarkdown = preservesStreamingView ? false : hasPreparedReasoningMarkdown
    }
}

enum ChatScrollTargetID: Hashable {
    case message(UUID)
    case bottom
}

struct SafeAreaBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// iOS 18 起由 SwiftUI 在同一轮布局中处理尺寸变化锚点；旧系统继续使用 UIKit 观察器兜底。
    @ViewBuilder
    func chatDefaultSizeChangeScrollAnchor(_ anchor: UnitPoint?) -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(anchor, for: .sizeChanges)
        } else {
            self
        }
    }

    /// 现代系统直接使用滚动阶段中断吸底，避免等到偏移量变化后才发现用户已经接管。
    @ViewBuilder
    func chatOnUserScrollPhaseChange(
        _ action: @escaping (_ distanceToBottom: CGFloat, _ isUserInteracting: Bool) -> Void
    ) -> some View {
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, newPhase, context in
                let distanceToBottom = max(
                    context.geometry.contentSize.height - context.geometry.visibleRect.maxY,
                    0
                )
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    action(distanceToBottom, true)
                case .idle:
                    action(distanceToBottom, false)
                case .animating:
                    break
                }
            }
        } else {
            self
        }
    }
}

struct ChatScrollMetricsObserver: UIViewRepresentable {
    @Binding var keepsBottomPinned: Bool
    let isStreaming: Bool
    let streamingDisplayMode: ChatStreamingDisplayMode
    let reduceMotion: Bool
    let onMetricsChange: (CGFloat, CGFloat, Bool) -> Void

    /// iOS 18 起尺寸变化锚点与布局同帧生效，UIKit 观察器只能上报位置，不能再次改写偏移。
    nonisolated static var usesNativeSizeChangeAnchor: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }

    /// 内容增长前已经锁定底部时，不能用增长后的距离反过来取消本次吸底。
    nonisolated static func shouldRestoreBottomAfterContentSizeChange(
        keepsBottomPinned: Bool,
        isUserInteracting: Bool,
        usesNativeSizeChangeAnchor: Bool = false
    ) -> Bool {
        !usesNativeSizeChangeAnchor && keepsBottomPinned && !isUserInteracting
    }

    /// 输入栏或键盘改变可视区域时，底部锁定必须跟着新的视口重新落位。
    nonisolated static func shouldRestoreBottomAfterViewportResize(
        from oldSize: CGSize,
        to newSize: CGSize,
        keepsBottomPinned: Bool,
        isUserInteracting: Bool,
        usesNativeSizeChangeAnchor: Bool = false
    ) -> Bool {
        let sizeChanged = abs(oldSize.width - newSize.width) > 0.5
            || abs(oldSize.height - newSize.height) > 0.5
        return sizeChanged && shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: keepsBottomPinned,
            isUserInteracting: isUserInteracting,
            usesNativeSizeChangeAnchor: usesNativeSizeChangeAnchor
        )
    }

    /// 视觉补偿只覆盖尚未呈现完的增长量，并设置上限，避免极端 Markdown 重排拖出大段尾随距离。
    nonisolated static func streamingPresentationStartTranslation(
        currentTranslation: CGFloat,
        contentHeightDelta: CGFloat,
        maximumLag: CGFloat = 44
    ) -> CGFloat {
        guard contentHeightDelta > 0, maximumLag > 0 else { return 0 }
        return min(max(currentTranslation, 0) + contentHeightDelta, maximumLag)
    }

    /// 同一轮布局可能连续上报多次高度变化；取模型层与呈现层中较大的补偿，避免丢失尚未播放的位移。
    nonisolated static func streamingPresentationBaseTranslation(
        presentationTranslation: CGFloat?,
        modelTranslation: CGFloat
    ) -> CGFloat {
        max(max(presentationTranslation ?? 0, modelTranslation), 0)
    }

    nonisolated static func streamingViewportMaskHeight(
        boundsHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        min(max(boundsHeight - max(bottomInset, 0), 0), max(boundsHeight, 0))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            keepsBottomPinned: $keepsBottomPinned,
            isStreaming: isStreaming,
            streamingDisplayMode: streamingDisplayMode,
            reduceMotion: reduceMotion,
            usesNativeSizeChangeAnchor: Self.usesNativeSizeChangeAnchor,
            onMetricsChange: onMetricsChange
        )
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMetricsChange = onMetricsChange
        coordinator.keepsBottomPinned = $keepsBottomPinned
        coordinator.isStreaming = isStreaming
        coordinator.streamingDisplayMode = streamingDisplayMode
        coordinator.reduceMotion = reduceMotion
        uiView.coordinator = coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
            coordinator.refreshStreamingPresentationState()
        }
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.coordinator = nil
    }

    final class Coordinator {
        var onMetricsChange: (CGFloat, CGFloat, Bool) -> Void
        var keepsBottomPinned: Binding<Bool>
        var isStreaming: Bool
        var streamingDisplayMode: ChatStreamingDisplayMode
        var reduceMotion: Bool
        let usesNativeSizeChangeAnchor: Bool
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var pendingBottomPin: DispatchWorkItem?
        private var pendingStreamingPresentation: DispatchWorkItem?
        private var pendingDistanceNotification: DispatchWorkItem?
        private let streamingViewportMask = CAShapeLayer()
        private var lastBoundsSize: CGSize?
        private var restoresBottomAfterContentSizeChange = false
        private var restoresBottomAfterViewportResize = false
        private var lastDistanceToBottom: CGFloat = 0
        private var lastDistanceToTop: CGFloat = 0
        private var hasReportedDistance = false
        private var lastReportedInteractionState = false

        init(
            keepsBottomPinned: Binding<Bool>,
            isStreaming: Bool,
            streamingDisplayMode: ChatStreamingDisplayMode,
            reduceMotion: Bool,
            usesNativeSizeChangeAnchor: Bool,
            onMetricsChange: @escaping (CGFloat, CGFloat, Bool) -> Void
        ) {
            self.keepsBottomPinned = keepsBottomPinned
            self.isStreaming = isStreaming
            self.streamingDisplayMode = streamingDisplayMode
            self.reduceMotion = reduceMotion
            self.usesNativeSizeChangeAnchor = usesNativeSizeChangeAnchor
            self.onMetricsChange = onMetricsChange
            streamingViewportMask.fillColor = UIColor.black.cgColor
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                scheduleDistanceChangeNotification()
                return
            }

            clearStreamingPresentation(in: self.scrollView)
            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            pendingStreamingPresentation?.cancel()
            pendingStreamingPresentation = nil
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            lastBoundsSize = scrollView.bounds.size
            restoresBottomAfterContentSizeChange = false
            restoresBottomAfterViewportResize = false
            hasReportedDistance = false
            lastDistanceToBottom = 0
            lastDistanceToTop = 0
            lastReportedInteractionState = false
            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scrollView, _ in
                guard let self else { return }
                if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
                    self.clearStreamingPresentation(in: scrollView)
                } else {
                    self.updateStreamingViewportMask(in: scrollView)
                }
                self.scheduleDistanceChangeNotification()
            }
            contentSizeObservation = scrollView.observe(
                \.contentSize,
                options: [.initial, .old, .new]
            ) { [weak self] scrollView, change in
                self?.handleContentSizeChange(
                    from: change.oldValue,
                    to: change.newValue ?? scrollView.contentSize
                )
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] scrollView, _ in
                self?.handleBoundsChange(scrollView.bounds.size)
            }
        }

        func detach() {
            clearStreamingPresentation(in: scrollView)
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            boundsObservation?.invalidate()
            boundsObservation = nil
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            pendingStreamingPresentation?.cancel()
            pendingStreamingPresentation = nil
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            scrollView = nil
        }

        private func handleContentSizeChange(from oldSize: CGSize?, to newSize: CGSize) {
            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            if ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
                keepsBottomPinned: keepsBottomPinned.wrappedValue,
                isUserInteracting: isUserInteracting,
                usesNativeSizeChangeAnchor: usesNativeSizeChangeAnchor
            ) {
                restoresBottomAfterContentSizeChange = true
            }
            if !usesNativeSizeChangeAnchor {
                scheduleBottomPin()
            }
            if let oldSize {
                prepareStreamingPresentation(contentHeightDelta: newSize.height - oldSize.height)
            }
            scheduleDistanceChangeNotification()
        }

        private func handleBoundsChange(_ newSize: CGSize) {
            defer {
                lastBoundsSize = newSize
                scheduleDistanceChangeNotification()
            }
            guard let lastBoundsSize else { return }

            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            guard ChatScrollMetricsObserver.shouldRestoreBottomAfterViewportResize(
                from: lastBoundsSize,
                to: newSize,
                keepsBottomPinned: keepsBottomPinned.wrappedValue,
                isUserInteracting: isUserInteracting,
                usesNativeSizeChangeAnchor: usesNativeSizeChangeAnchor
            ) else {
                return
            }

            // 先记住尺寸变化前的贴底意图，避免随后上报的新距离覆盖判断依据。
            restoresBottomAfterViewportResize = true
            scheduleBottomPin()
        }

        /// contentSize 的 KVO 正处在 UIKit/SwiftUI 布局栈内，不能同步改 contentOffset。
        /// 合并到下一轮主循环可避免删除高气泡时发生重入布局。
        private func scheduleBottomPin() {
            guard pendingBottomPin == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingBottomPin = nil
                self.pinToBottomIfNeeded()
            }
            pendingBottomPin = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func pinToBottomIfNeeded() {
            guard !usesNativeSizeChangeAnchor, let scrollView else { return }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            let shouldRestoreAfterContentSizeChange = restoresBottomAfterContentSizeChange
            restoresBottomAfterContentSizeChange = false
            let shouldRestoreAfterResize = restoresBottomAfterViewportResize
            restoresBottomAfterViewportResize = false
            let wasPinnedBeforeLayoutChange = hasReportedDistance
                && ETScrollBottomPinPolicy.shouldKeepPinned(
                    keepsBottomPinned: keepsBottomPinned.wrappedValue,
                    previousDistanceToBottom: lastDistanceToBottom,
                    isUserInteracting: isUserInteracting
                )
            let shouldPin = keepsBottomPinned.wrappedValue
                && !isUserInteracting
                && (shouldRestoreAfterContentSizeChange
                    || shouldRestoreAfterResize
                    || wasPinnedBeforeLayoutChange)

            if shouldPin {
                let maximumOffsetY = max(
                    -scrollView.adjustedContentInset.top,
                    scrollView.contentSize.height
                        - scrollView.bounds.height
                        + scrollView.adjustedContentInset.bottom
                )
                if abs(scrollView.contentOffset.y - maximumOffsetY) > 0.5 {
                    scrollView.setContentOffset(
                        CGPoint(x: scrollView.contentOffset.x, y: maximumOffsetY),
                        animated: false
                    )
                }
            }
            scheduleDistanceChangeNotification()
        }

        /// 原生吸底改变真实位置的同一轮先写入反向补偿，首帧仍停留在用户刚才看到的位置。
        private func prepareStreamingPresentation(contentHeightDelta: CGFloat) {
            guard usesNativeSizeChangeAnchor,
                  contentHeightDelta > 0.5,
                  let scrollView else {
                return
            }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard isStreaming,
                  keepsBottomPinned.wrappedValue,
                  !reduceMotion,
                  !isUserInteracting else {
                clearStreamingPresentation(in: scrollView)
                return
            }

            updateStreamingViewportMask(in: scrollView)
            let layer = scrollView.layer
            let currentTranslation = ChatScrollMetricsObserver.streamingPresentationBaseTranslation(
                presentationTranslation: layer.presentation()?.sublayerTransform.m42,
                modelTranslation: layer.sublayerTransform.m42
            )
            let startTranslation = ChatScrollMetricsObserver.streamingPresentationStartTranslation(
                currentTranslation: currentTranslation,
                contentHeightDelta: contentHeightDelta
            )
            guard startTranslation > 0.5 else { return }

            layer.removeAnimation(forKey: Self.streamingRiseAnimationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = CATransform3DMakeTranslation(0, startTranslation, 0)
            CATransaction.commit()

            scheduleStreamingPresentationPlayback()
        }

        /// 下一轮主循环再从已提交的反向补偿播放到真实位置，避免最终位置提前闪现一帧。
        private func scheduleStreamingPresentationPlayback() {
            guard pendingStreamingPresentation == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamingPresentation = nil
                self.playStreamingPresentation()
            }
            pendingStreamingPresentation = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func playStreamingPresentation() {
            guard let scrollView else { return }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard isStreaming,
                  keepsBottomPinned.wrappedValue,
                  !reduceMotion,
                  !isUserInteracting else {
                clearStreamingPresentation(in: scrollView)
                return
            }

            let layer = scrollView.layer
            let startTranslation = layer.sublayerTransform.m42
            guard startTranslation > 0.5 else { return }

            layer.removeAnimation(forKey: Self.streamingRiseAnimationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
            animation.fromValue = startTranslation
            animation.toValue = 0
            animation.duration = streamingDisplayMode.viewportFollowDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: Self.streamingRiseAnimationKey)
        }

        func refreshStreamingPresentationState() {
            guard let scrollView else { return }
            if isStreaming && keepsBottomPinned.wrappedValue && !reduceMotion {
                updateStreamingViewportMask(in: scrollView)
            } else {
                clearStreamingPresentation(in: scrollView)
            }
        }

        private func updateStreamingViewportMask(in scrollView: UIScrollView) {
            guard isStreaming,
                  keepsBottomPinned.wrappedValue,
                  !reduceMotion else {
                if scrollView.layer.mask === streamingViewportMask {
                    scrollView.layer.mask = nil
                }
                return
            }

            let layerBounds = scrollView.layer.bounds
            let visibleHeight = ChatScrollMetricsObserver.streamingViewportMaskHeight(
                boundsHeight: layerBounds.height,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            streamingViewportMask.frame = layerBounds
            streamingViewportMask.path = UIBezierPath(
                rect: CGRect(x: 0, y: 0, width: layerBounds.width, height: visibleHeight)
            ).cgPath
            if scrollView.layer.mask !== streamingViewportMask {
                scrollView.layer.mask = streamingViewportMask
            }
            CATransaction.commit()
        }

        private func clearStreamingPresentation(in scrollView: UIScrollView?) {
            pendingStreamingPresentation?.cancel()
            pendingStreamingPresentation = nil
            guard let scrollView else { return }
            scrollView.layer.removeAnimation(forKey: Self.streamingRiseAnimationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollView.layer.sublayerTransform = CATransform3DIdentity
            if scrollView.layer.mask === streamingViewportMask {
                scrollView.layer.mask = nil
            }
            CATransaction.commit()
        }

        private static let streamingRiseAnimationKey = "etos.chat.streaming-rise"

        private func scheduleDistanceChangeNotification() {
            guard pendingDistanceNotification == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDistanceNotification = nil
                self.notifyDistanceChange()
            }
            pendingDistanceNotification = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func notifyDistanceChange() {
            guard let scrollView else { return }
            let visibleMaxY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(scrollView.contentSize.height - visibleMaxY, 0)
            let distanceToTop = max(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, 0)
            let isUserInteracting = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
            guard !hasReportedDistance
                    || abs(lastDistanceToBottom - distanceToBottom) > 0.5
                    || abs(lastDistanceToTop - distanceToTop) > 0.5
                    || lastReportedInteractionState != isUserInteracting else {
                return
            }
            lastDistanceToBottom = distanceToBottom
            lastDistanceToTop = distanceToTop
            hasReportedDistance = true
            lastReportedInteractionState = isUserInteracting
            onMetricsChange(distanceToBottom, distanceToTop, isUserInteracting)
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToScrollViewIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
        }

        func attachToScrollViewIfNeeded() {
            guard let coordinator, let scrollView = enclosingScrollView() else { return }
            coordinator.attach(to: scrollView)
        }

        private func enclosingScrollView() -> UIScrollView? {
            var currentSuperview = superview
            while let view = currentSuperview {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                currentSuperview = view.superview
            }
            return nil
        }
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { _ in
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.1, blue: 0.12)]
                        : [Color(red: 0.85, green: 0.9, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                TelegramPatternView()
                    .opacity(colorScheme == .dark ? 0.03 : 0.05)
            }
        }
        .ignoresSafeArea()
    }
}

struct TelegramPatternView: View {
    var body: some View {
        Canvas { context, size in
            let patternSize: CGFloat = 60
            let iconSize: CGFloat = 16

            for row in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                for col in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                    let offset = Int(row / patternSize) % 2 == 0 ? 0 : patternSize / 2
                    let x = col + offset
                    let y = row

                    let iconIndex = Int(x + y) % 4
                    let symbolName: String
                    switch iconIndex {
                    case 0: symbolName = "bubble.left.fill"
                    case 1: symbolName = "heart.fill"
                    case 2: symbolName = "star.fill"
                    default: symbolName = "paperplane.fill"
                    }

                    if let symbol = context.resolveSymbol(id: symbolName) {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                    } else {
                        let rect = CGRect(x: x - iconSize / 2, y: y - iconSize / 2, width: iconSize, height: iconSize)
                        context.fill(Circle().path(in: rect), with: .color(.gray))
                    }
                }
            }
        } symbols: {
            Image(systemName: "bubble.left.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")

            Image(systemName: "heart.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")

            Image(systemName: "star.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")

            Image(systemName: "paperplane.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}
