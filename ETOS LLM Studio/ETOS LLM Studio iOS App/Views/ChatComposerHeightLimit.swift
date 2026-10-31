import SwiftUI

/// 高度预算来自当前聊天列，包含键盘压缩后的可用空间。
enum ComposerViewportSizing {
    static func expandedTextHeight(availableHeight: CGFloat, fontScale: CGFloat) -> CGFloat {
        let preferredHeight = max(160 * fontScale, min(availableHeight * 0.3, 360 * fontScale))
        // 输入区外侧的上下留白与底部间距不能挤掉编辑器或发送按钮。
        return min(preferredHeight, max(0, availableHeight - 22))
    }

    static func requestControlsHeight(
        availableHeight: CGFloat,
        estimatedContentHeight: CGFloat,
        inputHeight: CGFloat
    ) -> CGFloat {
        let maximumHeight = min(availableHeight * 0.38, 340, max(0, availableHeight - inputHeight - 23))
        return min(maximumHeight, max(124, estimatedContentHeight))
    }
}

/// 只限制布局提案，不像 maxHeight frame 那样把紧凑输入区撑满键盘上方空间。
struct ChatComposerHeightLimit: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = maximumHeight.isFinite
            ? min(proposal.height ?? maximumHeight, maximumHeight)
            : proposal.height
        return subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
