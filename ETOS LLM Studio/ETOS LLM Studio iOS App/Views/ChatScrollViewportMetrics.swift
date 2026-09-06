// ============================================================================
// ChatScrollViewportMetrics.swift
// ============================================================================
// 聊天滚动的纯度量规则与语义边界。
// ============================================================================

import SwiftUI

extension ChatScrollMetricsObserver {
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

    /// 延迟跟随保留内容高度语义，到真正执行时才使用最新视口换算并钳制合法范围。
    nonisolated static func viewportFollowTargetOffsetY(
        requestedContentHeight: CGFloat?,
        actualContentHeight: CGFloat,
        boundsHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        forcesMinimumOffset: Bool
    ) -> CGFloat {
        let minimumOffsetY = -topInset
        guard !forcesMinimumOffset else { return minimumOffsetY }
        let requestedOffsetY = maximumContentOffsetY(
            contentHeight: requestedContentHeight ?? actualContentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        let actualMaximumOffsetY = maximumContentOffsetY(
            contentHeight: actualContentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return min(requestedOffsetY, actualMaximumOffsetY)
    }

    nonisolated static func anchorAdjustedContentOffsetY(
        currentOffsetY: CGFloat,
        deltaY: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        allowsTemporaryOverflow: Bool = false
    ) -> CGFloat {
        let requestedOffsetY = max(currentOffsetY + deltaY, minimumOffsetY)
        return allowsTemporaryOverflow
            ? requestedOffsetY
            : min(requestedOffsetY, maximumOffsetY)
    }

    /// 翻页保留一小段上下文，让眼睛能从上一屏自然接续，而不是重新寻找阅读位置。
    nonisolated static func viewportPageTargetOffsetY(
        currentOffsetY: CGFloat,
        direction: ChatViewportPageDirection,
        viewportHeight: CGFloat,
        viewportFraction: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        let requestedOffsetY = currentOffsetY
            + direction.offsetMultiplier * viewportHeight * viewportFraction
        return min(max(requestedOffsetY, minimumOffsetY), maximumOffsetY)
    }

    /// SwiftUI 只需要知道交互语义跨过了哪个边界，连续像素距离留在 UIKit 内部。
    nonisolated static func metricRegion(
        distanceToBottom: CGFloat,
        distanceToTop: CGFloat,
        thresholds: ChatScrollMetricThresholds
    ) -> ChatScrollMetricRegion {
        ChatScrollMetricRegion(
            isAtTop: distanceToTop <= thresholds.arrival,
            isNearTopHistoryBoundary: distanceToTop < thresholds.historyLoading,
            isAtBottom: distanceToBottom <= thresholds.arrival,
            isBottomPinned: distanceToBottom < thresholds.bottomPinned,
            isPastBottomButtonThreshold: distanceToBottom > thresholds.bottomButton,
            isNearBottomHistoryBoundary: distanceToBottom < thresholds.historyLoading
        )
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

    /// 一次性滚动命令需要收到真实几何回执，即使当前位置没有产生任何偏移变化。
    nonisolated static func shouldNotifyMetrics(
        forcesRefresh: Bool,
        hasReportedDistance: Bool,
        semanticRegionChanged: Bool,
        interactionChanged: Bool
    ) -> Bool {
        forcesRefresh || !hasReportedDistance || semanticRegionChanged || interactionChanged
    }

    /// 无位移命令只越过去重边界一次，后续回执仍由真实几何变化驱动。
    nonisolated static func shouldForceMetricsRefresh(
        generation: UInt,
        lastServicedGeneration: UInt
    ) -> Bool {
        generation != lastServicedGeneration
    }

}
