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

enum ChatBubbleRendererIdentity: String, Hashable, Sendable {
    case none
    case plainText
    case streamingUIKit
    case nativeMarkdown
    case webMarkdown
    case roleplayHTML

    nonisolated static func resolved(
        hasContent: Bool,
        enableMarkdown: Bool,
        isStreaming: Bool,
        isAwaitingStaticHandoff: Bool,
        hasPreparedMarkdown: Bool,
        usesWebRenderer: Bool,
        hasRoleplayHTML: Bool = false
    ) -> Self {
        if hasRoleplayHTML { return .roleplayHTML }
        guard hasContent else { return .none }
        if isStreaming || isAwaitingStaticHandoff { return .streamingUIKit }
        guard enableMarkdown, hasPreparedMarkdown else { return .plainText }
        return usesWebRenderer ? .webMarkdown : .nativeMarkdown
    }
}

/// 只在会改变气泡高度的结构切换时重建视觉子树。
struct ChatBubbleLayoutIdentity: Hashable {
    let messageID: UUID
    let structuralRevision: UInt
    let layoutRecoveryRevision: UInt
    let isStreaming: Bool
    let hasPreparedMarkdown: Bool
    let hasPreparedReasoningMarkdown: Bool
    let usesNoBubbleStyle: Bool
    let contentRenderer: ChatBubbleRendererIdentity
    let reasoningRenderer: ChatBubbleRendererIdentity
    let layoutWidthBucket: Int

    init(
        messageID: UUID,
        structuralRevision: UInt,
        layoutRecoveryRevision: UInt = 0,
        isStreaming: Bool,
        isStaticMarkdownHandoffInProgress: Bool = false,
        hasPreparedMarkdown: Bool,
        hasPreparedReasoningMarkdown: Bool,
        usesNoBubbleStyle: Bool = false,
        contentRenderer: ChatBubbleRendererIdentity = .plainText,
        reasoningRenderer: ChatBubbleRendererIdentity = .none,
        layoutWidthBucket: Int = 0
    ) {
        let preservesStreamingView = isStreaming || isStaticMarkdownHandoffInProgress
        self.messageID = messageID
        self.structuralRevision = preservesStreamingView ? 0 : structuralRevision
        self.layoutRecoveryRevision = layoutRecoveryRevision
        self.isStreaming = preservesStreamingView
        // 交接期间冻结完整身份，避免任一通道先完成时重建另一通道的流式子树。
        self.hasPreparedMarkdown = preservesStreamingView ? false : hasPreparedMarkdown
        self.hasPreparedReasoningMarkdown = preservesStreamingView ? false : hasPreparedReasoningMarkdown
        self.usesNoBubbleStyle = usesNoBubbleStyle
        self.contentRenderer = preservesStreamingView ? .streamingUIKit : contentRenderer
        self.reasoningRenderer = preservesStreamingView ? .streamingUIKit : reasoningRenderer
        self.layoutWidthBucket = layoutWidthBucket
    }

    nonisolated static func widthBucket(for width: CGFloat?) -> Int {
        guard let width, width.isFinite, width > 0 else { return 0 }
        return Int((width / 8).rounded())
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
    /// iOS 18 起由 SwiftUI 在同一轮布局中处理静态尺寸变化；流式期间会主动关闭该锚点。
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

struct ChatScrollAnchorAdjustment: Equatable, Identifiable, Sendable {
    let id: UUID
    let deltaY: CGFloat

    nonisolated init(id: UUID = UUID(), deltaY: CGFloat) {
        self.id = id
        self.deltaY = deltaY
    }
}

struct ChatScrollMetricsObserver: UIViewRepresentable {
    @Binding var keepsBottomPinned: Bool
    let isStreaming: Bool
    let streamingDisplayMode: ChatStreamingDisplayMode
    let reduceMotion: Bool
    let anchorAdjustment: ChatScrollAnchorAdjustment?
    let onAnchorAdjustmentApplied: (UUID) -> Void
    let onMetricsChange: (CGFloat, CGFloat, Bool) -> Void

    /// iOS 18 起静态尺寸变化使用原生锚点；流式期间暂时交由 UIKit 单独接管偏移。
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

    /// 内容没有超出视口时不存在可滚动距离，不能让偏移动画与零点回弹竞争。
    nonisolated static func streamingContentOverflowsViewport(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        contentHeight - boundsHeight + bottomInset > 1
    }

    nonisolated static func maximumContentOffsetY(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, contentHeight - boundsHeight + bottomInset)
    }

    nonisolated static func anchorAdjustedContentOffsetY(
        currentOffsetY: CGFloat,
        deltaY: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        min(max(currentOffsetY + deltaY, minimumOffsetY), maximumOffsetY)
    }

    /// 流式动画从用户当前看见的位置出发，只允许继续靠近最终底部。
    nonisolated static func shouldAnimateStreamingFollow(
        contentOverflowsViewport: Bool,
        visibleOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        let offsetDelta = targetOffsetY - visibleOffsetY
        return !reduceMotion
            && contentOverflowsViewport
            && visibleOffsetY.isFinite
            && targetOffsetY.isFinite
            && offsetDelta > 0.5
    }

    /// 高度重排只能让视口保持或继续向底部推进，不能把临时收缩写成反向滚动。
    nonisolated static func shouldApplyStreamingFollow(
        visibleOffsetY: CGFloat,
        targetOffsetY: CGFloat
    ) -> Bool {
        visibleOffsetY.isFinite
            && targetOffsetY.isFinite
            && targetOffsetY >= visibleOffsetY - 0.5
    }

    /// MarkdownUI 的大幅中间高度通常会在随后几轮布局中回落，不能立即作为滚动终点。
    nonisolated static func requiresStreamingLayoutSettle(heightDelta: CGFloat) -> Bool {
        abs(heightDelta) > 160
    }

    /// 连续输出不能让屏幕位置长期落后于真实底部，否则气泡会钻入输入栏后方。
    nonisolated static func streamingFollowStartOffset(
        visibleOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        minimumOffsetY: CGFloat,
        maximumLag: CGFloat = 12
    ) -> CGFloat {
        let clampedVisible = min(max(visibleOffsetY, minimumOffsetY), targetOffsetY)
        return max(clampedVisible, targetOffsetY - max(maximumLag, 0))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            keepsBottomPinned: $keepsBottomPinned,
            isStreaming: isStreaming,
            streamingDisplayMode: streamingDisplayMode,
            reduceMotion: reduceMotion,
            anchorAdjustment: anchorAdjustment,
            onAnchorAdjustmentApplied: onAnchorAdjustmentApplied,
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
        coordinator.anchorAdjustment = anchorAdjustment
        coordinator.onAnchorAdjustmentApplied = onAnchorAdjustmentApplied
        uiView.coordinator = coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
            coordinator.applyAnchorAdjustmentIfNeeded()
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
        var anchorAdjustment: ChatScrollAnchorAdjustment?
        var onAnchorAdjustmentApplied: (UUID) -> Void
        let usesNativeSizeChangeAnchor: Bool
        weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var pendingBottomPin: DispatchWorkItem?
        private var pendingStreamingFollow: DispatchWorkItem?
        private var pendingStreamingLayoutSettle: DispatchWorkItem?
        private var pendingStreamingLayoutTargetOffsetY: CGFloat?
        private var pendingDistanceNotification: DispatchWorkItem?
        private var lastBoundsSize: CGSize?
        private var restoresBottomAfterContentSizeChange = false
        private var restoresBottomAfterViewportResize = false
        private var lastDistanceToBottom: CGFloat = 0
        private var lastDistanceToTop: CGFloat = 0
        private var hasReportedDistance = false
        private var lastReportedInteractionState = false
        private var lastAppliedAnchorAdjustmentID: UUID?

        init(
            keepsBottomPinned: Binding<Bool>,
            isStreaming: Bool,
            streamingDisplayMode: ChatStreamingDisplayMode,
            reduceMotion: Bool,
            anchorAdjustment: ChatScrollAnchorAdjustment?,
            onAnchorAdjustmentApplied: @escaping (UUID) -> Void,
            usesNativeSizeChangeAnchor: Bool,
            onMetricsChange: @escaping (CGFloat, CGFloat, Bool) -> Void
        ) {
            self.keepsBottomPinned = keepsBottomPinned
            self.isStreaming = isStreaming
            self.streamingDisplayMode = streamingDisplayMode
            self.reduceMotion = reduceMotion
            self.anchorAdjustment = anchorAdjustment
            self.onAnchorAdjustmentApplied = onAnchorAdjustmentApplied
            self.usesNativeSizeChangeAnchor = usesNativeSizeChangeAnchor
            self.onMetricsChange = onMetricsChange
        }

        private var reliesOnNativeSizeChangeAnchor: Bool {
            usesNativeSizeChangeAnchor && !isStreaming
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                scheduleDistanceChangeNotification()
                applyAnchorAdjustmentIfNeeded()
                return
            }

            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            pendingStreamingFollow?.cancel()
            pendingStreamingFollow = nil
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutTargetOffsetY = nil
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            lastBoundsSize = scrollView.bounds.size
            restoresBottomAfterContentSizeChange = false
            restoresBottomAfterViewportResize = false
            hasReportedDistance = false
            lastDistanceToBottom = 0
            lastDistanceToTop = 0
            lastReportedInteractionState = false
            lastAppliedAnchorAdjustmentID = nil
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
            applyAnchorAdjustmentIfNeeded()
        }

        func detach() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            boundsObservation?.invalidate()
            boundsObservation = nil
            pendingBottomPin?.cancel()
            pendingBottomPin = nil
            pendingStreamingFollow?.cancel()
            pendingStreamingFollow = nil
            pendingStreamingLayoutSettle?.cancel()
            pendingStreamingLayoutSettle = nil
            pendingStreamingLayoutTargetOffsetY = nil
            pendingDistanceNotification?.cancel()
            pendingDistanceNotification = nil
            lastAppliedAnchorAdjustmentID = nil
            scrollView = nil
        }

        func applyAnchorAdjustmentIfNeeded() {
            guard let anchorAdjustment,
                  anchorAdjustment.id != lastAppliedAnchorAdjustmentID,
                  let scrollView else {
                return
            }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard !isUserInteracting else { return }

            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let targetOffsetY = ChatScrollMetricsObserver.anchorAdjustedContentOffsetY(
                currentOffsetY: scrollView.contentOffset.y,
                deltaY: anchorAdjustment.deltaY,
                minimumOffsetY: minimumOffsetY,
                maximumOffsetY: maximumOffsetY
            )
            lastAppliedAnchorAdjustmentID = anchorAdjustment.id
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                    animated: false
                )
            }
            scheduleDistanceChangeNotification()
            onAnchorAdjustmentApplied(anchorAdjustment.id)
        }

        private func handleContentSizeChange(from oldSize: CGSize?, to newSize: CGSize) {
            let isUserInteracting = scrollView?.isDragging == true
                || scrollView?.isTracking == true
                || scrollView?.isDecelerating == true
            let didHandleStreamingChange: Bool
            if let oldSize {
                let heightDelta = newSize.height - oldSize.height
                if isStreaming,
                   (pendingStreamingLayoutSettle != nil
                    || ChatScrollMetricsObserver.requiresStreamingLayoutSettle(
                        heightDelta: heightDelta
                    )) {
                    scheduleStreamingLayoutSettle()
                    didHandleStreamingChange = true
                } else {
                    didHandleStreamingChange = followStreamingContentSizeChange()
                }
            } else {
                didHandleStreamingChange = false
            }
            if !didHandleStreamingChange,
               ChatScrollMetricsObserver.shouldRestoreBottomAfterContentSizeChange(
                   keepsBottomPinned: keepsBottomPinned.wrappedValue,
                   isUserInteracting: isUserInteracting,
                   usesNativeSizeChangeAnchor: reliesOnNativeSizeChangeAnchor
               ) {
                restoresBottomAfterContentSizeChange = true
            }
            if !reliesOnNativeSizeChangeAnchor && !didHandleStreamingChange {
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
                usesNativeSizeChangeAnchor: reliesOnNativeSizeChangeAnchor
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
            guard !reliesOnNativeSizeChangeAnchor, let scrollView else { return }
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
                let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                    contentHeight: scrollView.contentSize.height,
                    boundsHeight: scrollView.bounds.height,
                    topInset: scrollView.adjustedContentInset.top,
                    bottomInset: scrollView.adjustedContentInset.bottom
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

        /// KVO 发生在 SwiftUI 布局栈内；这里只合并通知，避免动画误捕获尚未稳定的 bounds.size。
        @discardableResult
        private func followStreamingContentSizeChange() -> Bool {
            guard isStreaming, scrollView != nil else { return false }
            scheduleStreamingFollow()
            return true
        }

        private func scheduleStreamingFollow() {
            guard pendingStreamingFollow == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamingFollow = nil
                self.followSettledStreamingContent()
            }
            pendingStreamingFollow = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        /// MarkdownUI 会在同一批内容内先后给出高、低两套测量值；窗口内只追最低安全底部。
        /// 保留已经开始的向上动画，避免每次测量都删除动画后让视口永久停在原位。
        private func scheduleStreamingLayoutSettle() {
            guard let scrollView else { return }
            pendingStreamingFollow?.cancel()
            pendingStreamingFollow = nil
            let candidateTargetOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            if let pendingStreamingLayoutTargetOffsetY {
                self.pendingStreamingLayoutTargetOffsetY = min(
                    pendingStreamingLayoutTargetOffsetY,
                    candidateTargetOffsetY
                )
            } else {
                pendingStreamingLayoutTargetOffsetY = candidateTargetOffsetY
            }
            guard pendingStreamingLayoutSettle == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStreamingLayoutSettle = nil
                let safeTargetOffsetY = self.pendingStreamingLayoutTargetOffsetY
                self.pendingStreamingLayoutTargetOffsetY = nil
                self.followSettledStreamingContent(targetOffsetY: safeTargetOffsetY)
            }
            pendingStreamingLayoutSettle = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: workItem)
        }

        /// 从呈现层接续运动并替换旧动画，确保任意时刻只有一个滚动所有者。
        private func followSettledStreamingContent(targetOffsetY requestedTargetOffsetY: CGFloat? = nil) {
            guard let scrollView else { return }
            let isUserInteracting = scrollView.isDragging
                || scrollView.isTracking
                || scrollView.isDecelerating
            guard isStreaming, keepsBottomPinned.wrappedValue, !isUserInteracting else { return }

            let maximumOffsetY = ChatScrollMetricsObserver.maximumContentOffsetY(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let targetOffsetY = min(requestedTargetOffsetY ?? maximumOffsetY, maximumOffsetY)
            let contentOverflowsViewport = ChatScrollMetricsObserver.streamingContentOverflowsViewport(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            let visibleOffsetY = scrollView.layer.presentation()?.bounds.origin.y
                ?? scrollView.bounds.origin.y
            guard ChatScrollMetricsObserver.shouldApplyStreamingFollow(
                visibleOffsetY: visibleOffsetY,
                targetOffsetY: targetOffsetY
            ) else {
                return
            }
            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let startOffsetY = ChatScrollMetricsObserver.streamingFollowStartOffset(
                visibleOffsetY: visibleOffsetY,
                targetOffsetY: targetOffsetY,
                minimumOffsetY: minimumOffsetY
            )
            let shouldAnimate = ChatScrollMetricsObserver.shouldAnimateStreamingFollow(
                contentOverflowsViewport: contentOverflowsViewport,
                visibleOffsetY: startOffsetY,
                targetOffsetY: targetOffsetY,
                reduceMotion: reduceMotion
            )

            // removeAllAnimations 与模型层回写发生在同一提交前，屏幕不会看见中间跳帧。
            scrollView.layer.removeAllAnimations()
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: startOffsetY),
                    animated: false
                )
            }
            let targetOffset = CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY)
            if shouldAnimate {
                UIView.animate(
                    withDuration: streamingDisplayMode.viewportFollowDuration,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    scrollView.setContentOffset(targetOffset, animated: false)
                }
            } else {
                UIView.performWithoutAnimation {
                    scrollView.setContentOffset(targetOffset, animated: false)
                }
            }
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
