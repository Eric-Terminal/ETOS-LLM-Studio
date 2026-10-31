import SwiftUI

/// 布局预算来自内容所需空间；键盘只改变高度，不改变会话侧栏是否放得下。
struct ChatAdaptiveLayout: Equatable {
    static let minimumSidebarWidth: CGFloat = 220
    static let minimumConversationWidth: CGFloat = 420
    static let sidebarSpacing: CGFloat = 1

    let size: CGSize
    let canShowSidebar: Bool
    let sidebarWidth: CGFloat
    let sidebarGap: CGFloat
    let composerWidth: CGFloat
    let composerOnLeadingSide: Bool
    let composerHeightLimit: CGFloat
    let composerBottomInset: CGFloat

    var detailWidth: CGFloat { max(1, size.width - sidebarWidth - sidebarGap) }

    static func resolve(size: CGSize, showsSidebar: Bool, division: CGRect? = nil) -> Self {
        let size = CGSize(width: max(1, size.width), height: max(1, size.height))
        let canShowSidebar = size.width >= minimumSidebarWidth + minimumConversationWidth + sidebarSpacing
        var sidebarWidth = canShowSidebar && showsSidebar
            ? min(300, max(minimumSidebarWidth, size.width * 0.3)) : 0
        var gap = sidebarWidth > 0 ? sidebarSpacing : 0
        var composerWidth = size.width - sidebarWidth - gap
        var composerOnLeadingSide = false
        var composerHeight = size.height
        var composerBottomInset: CGFloat = 0

        if let division, division.intersects(CGRect(origin: .zero, size: size)) {
            if division.height > division.width {
                // 部分折叠时让两栏边界贴合折痕，不能把折痕留在编辑器正中。
                if sidebarWidth > 0,
                   division.minX >= minimumSidebarWidth,
                   size.width - division.maxX >= 280 {
                    sidebarWidth = division.minX
                    gap = division.width
                }
                // 侧栏收起或窗口较窄时，仍让编辑器留在折痕一侧。
                let trailingWidth = max(0, size.width - division.maxX)
                let leadingWidth = max(0, division.minX - sidebarWidth - gap)
                composerOnLeadingSide = trailingWidth < 280 && leadingWidth > trailingWidth
                composerWidth = min(size.width - sidebarWidth - gap,
                                    max(1, composerOnLeadingSide ? leadingWidth : trailingWidth))
            } else {
                // 输入区只使用下半屏；消息仍能连续滚动，不为姿态切换重建会话。
                composerHeight = max(0, size.height - division.maxY)
                if composerHeight < 100, division.minY > composerHeight {
                    // 键盘可能占满折痕下方，改用上方尚可见区域，避免把发送按钮压成零高。
                    composerHeight = division.minY
                    composerBottomInset = size.height - division.minY
                }
            }
        }

        return Self(size: size, canShowSidebar: canShowSidebar, sidebarWidth: sidebarWidth,
                    sidebarGap: gap, composerWidth: composerWidth, composerOnLeadingSide: composerOnLeadingSide,
                    composerHeightLimit: composerHeight, composerBottomInset: composerBottomInset)
    }
}

extension ChatView {
    func chatDivision(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *), let region = proxy.reservedRegions(kind: .division).first {
            // 使用逻辑方向坐标，与 HStack 的 leading/trailing 一致，也适用于阿拉伯语。
            return CGRect(
                x: region.frame.minX - region.margins.leading,
                y: region.frame.minY - region.margins.top,
                width: region.frame.width + region.margins.leading + region.margins.trailing,
                height: region.frame.height + region.margins.top + region.margins.bottom
            )
        }
        return nil
    }
}
