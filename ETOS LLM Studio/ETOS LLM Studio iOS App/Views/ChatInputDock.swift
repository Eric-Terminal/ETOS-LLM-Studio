import SwiftUI

/// 整个底部停靠区共用预算，终端预览和角色脚本不能把输入控件推到折痕或键盘后面。
struct ChatInputDock<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        // 禁用外层滚动会连带禁用 TextEditor 和问答区，只让尺寸决定是否需要外层回弹。
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight > 0 ? contentHeight : maximumHeight, maximumHeight))
    }
}
