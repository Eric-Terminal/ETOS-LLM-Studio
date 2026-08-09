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
    struct StreamingViewportTransition: Equatable {
        let startOffsetY: CGFloat
        let targetOffsetY: CGFloat
    }

    @Binding var keepsBottomPinned: Bool
    let isStreaming: Bool
    let streamingDisplayMode: ChatStreamingDisplayMode
    let reduceMotion: Bool
    let onMetricsChange: (CGFloat, CGFloat, Bool) -> Void

    /// 非流式布局仍由原生尺寸锚点处理；流式增长改由 UIKit 观察器连续追随底部。
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
        isStreaming: Bool = false,
        usesNativeSizeChangeAnchor: Bool = false
    ) -> Bool {
        (!usesNativeSizeChangeAnchor || isStreaming)
            && keepsBottomPinned
            && !isUserInteracting
    }

    /// 输入栏或键盘改变可视区域时，底部锁定必须跟着新的视口重新落位。
    nonisolated static func shouldRestoreBottomAfterViewportResize(
        from oldSize: CGSize,
        to newSize: CGSize,
        keepsBottomPinned: Bool,
        isUserInteracting: Bool,
        isStreaming: Bool = false,
        usesNativeSizeChangeAnchor: Bool = false
    ) -> Bool {
        let sizeChanged = abs(oldSize.width - newSize.width) > 0.5
            || abs(oldSize.height - newSize.height) > 0.5
        return sizeChanged && shouldRestoreBottomAfterContentSizeChange(
            keepsBottomPinned: keepsBottomPinned,
            isUserInteracting: isUserInteracting,
            isStreaming: isStreaming,
            usesNativeSizeChangeAnchor: usesNativeSizeChangeAnchor
        )
    }

    /// 流式更新只移动视口；消息高度先立即落位，再从旧底部连续追到新底部。
    nonisolated static func streamingViewportTransition(
        oldContentHeight: CGFloat,
        newContentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        keepsBottomPinned: Bool,
        isStreaming: Bool,
        isUserInteracting: Bool,
        reduceMotion: Bool
    ) -> StreamingViewportTransition? {
        guard keepsBottomPinned,
              isStreaming,
              !isUserInteracting,
              !reduceMotion,
              oldContentHeight > 0,
              viewportHeight > 0,
              abs(newContentHeight - oldContentHeight) > 0.5 else {
            return nil
        }

        let topOffset = -topInset
        let oldMaximumOffset = max(
            topOffset,
            oldContentHeight - viewportHeight + bottomInset
        )
        let newMaximumOffset = max(
            topOffset,
            newContentHeight - viewportHeight + bottomInset
        )
        let newScrollableRange = newMaximumOffset - topOffset
        guard newScrollableRange > 1,
              abs(newMaximumOffset - oldMaximumOffset) > 0.5 else {
            return nil
        }
        return StreamingViewportTransition(
            startOffsetY: oldMaximumOffset,
            targetOffsetY: newMaximumOffset
        )
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
        context.coordinator.onMetricsChange = onMetricsChange
        context.coordinator.keepsBottomPinned = $keepsBottomPinned
        context.coordinator.isStreaming = isStreaming
        context.coordinator.streamingDisplayMode = streamingDisplayMode
        context.coordinator.reduceMotion = reduceMotion
        uiView.coordinator = context.coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
        }
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
        private var pendingStreamingViewportUpdate: DispatchWorkItem?
        private var pendingStreamingStartOffsetY: CGFloat?
        private var pendingDistanceNotification: DispatchWorkItem?
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
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                scheduleDistanceChangeNotification()
                return
            }

            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            pendingStreamingViewportUpdate?.cancel()
            pendingStreamingViewportUpdate = nil
            pendingStreamingStartOffsetY = nil
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
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.scheduleDistanceChangeNotification()
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

        private func handleContentSizeChange(from oldSize: CGSize?, to newSize: CGSize) {
            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            if ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
                keepsBottomPinned: keepsBottomPinned.wrappedValue,
                isUserInteracting: isUserInteracting,
                isStreaming: isStreaming,
                usesNativeSizeChangeAnchor: usesNativeSizeChangeAnchor
            ) {
                restoresBottomAfterContentSizeChange = true
            }

            if let scrollView,
               let oldSize,
               let transition = ChatScrollMetricsObserver.streamingViewportTransition(
                    oldContentHeight: oldSize.height,
                    newContentHeight: newSize.height,
                    viewportHeight: scrollView.bounds.height,
                    topInset: scrollView.adjustedContentInset.top,
                    bottomInset: scrollView.adjustedContentInset.bottom,
                    keepsBottomPinned: keepsBottomPinned.wrappedValue,
                    isStreaming: isStreaming,
                    isUserInteracting: isUserInteracting,
                    reduceMotion: reduceMotion
               ) {
                restoresBottomAfterContentSizeChange = false
                scheduleStreamingViewportUpdate(from: transition.startOffsetY)
            } else if !usesNativeSizeChangeAnchor || isStreaming {
                scheduleBottomPin()
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
                isStreaming: isStreaming,
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

        /// 合并同一布局周期的尺寸变化；连续分片会从当前呈现位置重新定向到最新底部。
        private func scheduleStreamingViewportUpdate(from startOffsetY: CGFloat) {
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            if pendingStreamingStartOffsetY == nil {
                pendingStreamingStartOffsetY = startOffsetY
            }
            guard pendingStreamingViewportUpdate == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamingViewportUpdate = nil
                self.animateStreamingViewportIfNeeded()
            }
            pendingStreamingViewportUpdate = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func animateStreamingViewportIfNeeded() {
            guard let scrollView else {
                pendingStreamingStartOffsetY = nil
                return
            }
            let startOffsetY = pendingStreamingStartOffsetY
            pendingStreamingStartOffsetY = nil
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard isStreaming,
                  keepsBottomPinned.wrappedValue,
                  !reduceMotion,
                  !isUserInteracting,
                  let startOffsetY else {
                return
            }

            let targetOffsetY = maximumOffsetY(in: scrollView)
            guard targetOffsetY - (-scrollView.adjustedContentInset.top) > 1,
                  abs(targetOffsetY - startOffsetY) > 0.5 else {
                return
            }

            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: startOffsetY),
                    animated: false
                )
            }
            UIView.animate(
                withDuration: streamingDisplayMode.viewportFollowDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                    animated: false
                )
            }
            scheduleDistanceChangeNotification()
        }

        private func pinToBottomIfNeeded() {
            guard (!usesNativeSizeChangeAnchor || isStreaming), let scrollView else { return }
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
                let targetOffsetY = maximumOffsetY(in: scrollView)
                if abs(scrollView.contentOffset.y - targetOffsetY) > 0.5 {
                    scrollView.setContentOffset(
                        CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                        animated: false
                    )
                }
            }
            scheduleDistanceChangeNotification()
        }

        private func maximumOffsetY(in scrollView: UIScrollView) -> CGFloat {
            max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
        }

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
