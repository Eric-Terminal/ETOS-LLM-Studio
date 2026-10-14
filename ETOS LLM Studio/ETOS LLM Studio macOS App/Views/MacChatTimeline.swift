import ETOSCore
import SwiftUI

@MainActor
struct MacChatTimeline<Content: View>: View {
    let isActive: Bool
    let hasMessages: Bool
    let sendRevision: UUID
    let onUserInteraction: () -> Void
    @Binding var viewportHeight: CGFloat
    @Binding var viewportBounds: CGRect
    @ViewBuilder var content: () -> Content
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = MacChatFollowState()
    @State private var bounds = CGRect.zero

    var body: some View {
        ScrollView {
            content()
                .environment(\.macChatIsUserScrolling, follow.isInteracting)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: MacChatViewport.self) { geometry in
            MacChatViewport(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height, visibleHeight: geometry.visibleRect.height,
                topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom)
        } action: { _, viewport in
            viewportHeight = viewport.height
            let shouldFollow = follow.observe(viewport)
            publishVisibleBounds()
            if shouldFollow, isActive { scrollToLatest(animated: !reduceMotion) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacMessageEntryMotion.coordinateSpace)) } action: {
            bounds = $0
            publishVisibleBounds()
        }
        .onScrollPhaseChange { _, phase in
            guard isActive else { _ = follow.interaction(false); return }
            let interacting = phase == .tracking || phase == .interacting || phase == .decelerating
            if interacting && !follow.isInteracting { onUserInteraction() }
            if follow.interaction(interacting), isActive { scrollToLatest(animated: false) }
        }
        .onChange(of: sendRevision) { _, _ in
            guard isActive else { return }
            follow.navigate(toLatest: true)
            scrollToLatest(animated: !reduceMotion)
        }
        .onChange(of: isActive) { _, active in
            if !active { _ = follow.interaction(false) }
            else if follow.followsLatest { scrollToLatest(animated: false) }
        }
        .safeAreaInset(edge: .bottom) {
            if isActive, hasMessages, configuration.chatTimelineNavigationEnabled, follow.viewport.height > 0 {
                HStack {
                    Spacer()
                    Button { navigate(.top) } label: { Label(NSLocalizedString("滚动到顶部", comment: ""), systemImage: "arrow.up.to.line") }
                        .disabled(!follow.viewport.canGoUp)
                        .help(NSLocalizedString("滚动到顶部", comment: ""))
                    Button { navigate(.up) } label: { Label(NSLocalizedString("上一页", comment: ""), systemImage: "chevron.up") }
                        .disabled(!follow.viewport.canGoUp)
                        .help(NSLocalizedString("上一页", comment: ""))
                    Button { navigate(.down) } label: { Label(NSLocalizedString("下一页", comment: ""), systemImage: "chevron.down") }
                        .disabled(!follow.viewport.canGoDown)
                        .help(NSLocalizedString("下一页", comment: ""))
                    Button { navigate(.bottom) } label: { Label(NSLocalizedString("滚动到底部", comment: ""), systemImage: "arrow.down.to.line") }
                        .disabled(!follow.viewport.canGoDown && follow.followsLatest)
                        .help(NSLocalizedString("滚动到底部", comment: ""))
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .padding().background(.bar)
            }
        }
        .focusable()
        .accessibilityLabel(NSLocalizedString("对话", comment: ""))
        .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { press in
            // 只处理获得焦点的聊天滚动区，不占用输入框的光标和选区快捷键。
            guard isActive, hasMessages, configuration.chatTimelineNavigationEnabled else { return .ignored }
            switch press.key {
            case .home: navigate(.top)
            case .end: navigate(.bottom)
            case .pageUp: navigate(.up)
            case .pageDown: navigate(.down)
            default: return .ignored
            }
            return .handled
        }
    }

    private enum Direction: Equatable { case top, up, down, bottom }

    private func publishVisibleBounds() {
        // 入场只能认领真正露出的消息区域，不把底部导航栏下的预加载行算作可见。
        viewportBounds = CGRect(x: bounds.minX, y: bounds.minY - follow.viewport.minimum,
                                width: bounds.width, height: follow.viewport.height)
    }

    private func navigate(_ direction: Direction) {
        guard isActive else { return }
        onUserInteraction()
        follow.navigate(toLatest: direction == .bottom)
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.25)
        withAnimation(animation) {
            switch direction {
            case .top: position.scrollTo(edge: .top)
            case .bottom: position.scrollTo(edge: .bottom)
            case .up: position.scrollTo(y: follow.viewport.page(down: false))
            case .down: position.scrollTo(y: follow.viewport.page(down: true))
            }
        }
    }

    private func scrollToLatest(animated: Bool) {
        let duration = ChatStreamingDisplayMode.normalized(configuration.chatStreamingDisplayMode).viewportFollowDuration
        withAnimation(animated ? .smooth(duration: duration) : nil) { position.scrollTo(edge: .bottom) }
    }
}

private struct MacChatIsUserScrollingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var macChatIsUserScrolling: Bool {
        get { self[MacChatIsUserScrollingKey.self] }
        set { self[MacChatIsUserScrollingKey.self] = newValue }
    }
}
