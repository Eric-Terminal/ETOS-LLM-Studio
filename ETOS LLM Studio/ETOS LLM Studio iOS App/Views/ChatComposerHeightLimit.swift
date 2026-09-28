import SwiftUI

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
