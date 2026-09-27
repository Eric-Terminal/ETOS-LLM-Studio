import ETOSCore
import SwiftUI
import UIKit

@MainActor
final class ChatSendFlightSources {
    private struct Source {
        weak var anchor: UIView?
    }

    private var sources: [ChatSendPresentationSource: Source] = [:]

    func register(_ view: UIView, id: ChatSendPresentationSource) {
        sources[id] = Source(anchor: view)
    }

    func unregister(_ view: UIView, id: ChatSendPresentationSource) {
        guard sources[id]?.anchor === view else { return }
        sources[id] = nil
    }

    /// 捕获只发生在发送动作中，且只处理本次已挂载、可见的来源。
    func capture(in surface: UIView, ids: [ChatSendPresentationSource]) -> [ChatSendFlightCapture] {
        ids.compactMap { id in
            guard let source = sources[id], let anchor = source.anchor,
                  anchor.window != nil, anchor.window === surface.window else { return nil }
            if id == .text { return captureEditor(at: anchor, in: surface) }
            let frame = anchor.convert(anchor.bounds, to: surface)
            let visible = visibleFrame(of: anchor, in: surface)
            guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
            // 直接接走已显示的独立内容子树，保留异步准备后的字体和当前环境。
            // 完整图像与初始裁切分开保存，半露出的缩略图不会被当成整图放大。
            guard let snapshot = anchor.snapshotView(afterScreenUpdates: false) else { return nil }
            return ChatSendFlightCapture(
                source: id, content: snapshot, frame: visible,
                sourceContentFrame: frame.offsetBy(dx: -visible.minX, dy: -visible.minY)
            )
        }
    }

    private func captureEditor(at anchor: UIView, in surface: UIView) -> ChatSendFlightCapture? {
        guard let editor = findEditor(near: anchor), let input = editor as? UITextInput else { return nil }
        let inputView = input.textInputView ?? editor
        let viewport = surface.convert(visibleFrame(of: anchor, in: surface), to: inputView)
            .intersection(editor.convert(editor.bounds, to: inputView))
        guard !viewport.isNull, viewport.width > 1, viewport.height > 1 else { return nil }

        // 查询可见首尾位置，避免为超长草稿枚举整篇文字；现有文本控件保留字体、换行和滚动位置。
        guard let start = input.closestPosition(to: CGPoint(x: viewport.minX, y: viewport.minY)),
              let end = input.closestPosition(to: CGPoint(x: viewport.maxX, y: viewport.maxY)),
              let range = input.textRange(from: start, to: end) else { return nil }
        let rects = input.selectionRects(for: range).map(\.rect).filter { !$0.isEmpty }
        guard let first = rects.first else { return nil }
        let textRect = rects.dropFirst().reduce(first) { $0.union($1) }
            .insetBy(dx: -1, dy: -1).intersection(viewport)
        guard textRect.width > 1, textRect.height > 1 else { return nil }

        // 只绘制已排版的可见文本层。afterScreenUpdates 会同步提交整个窗口的
        // SwiftUI 更新；改变 tintColor 还会使链接文字重新布局，均不能放在发送触摸中。
        let selectionLayers = selectionInteractions(in: editor).flatMap { interaction in
            [interaction.cursorView.layer, interaction.highlightView.layer]
                + interaction.handleViews.map(\.layer)
        }
        let hiddenStates = selectionLayers.map(\.isHidden)
        let backgroundColor = editor.layer.backgroundColor
        let wasOpaque = editor.layer.isOpaque
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayers.forEach { $0.isHidden = true }
        editor.layer.backgroundColor = nil
        editor.layer.isOpaque = false
        defer {
            for (layer, hidden) in zip(selectionLayers, hiddenStates) { layer.isHidden = hidden }
            editor.layer.backgroundColor = backgroundColor
            editor.layer.isOpaque = wasOpaque
            CATransaction.commit()
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = editor.traitCollection.displayScale
        let renderer = UIGraphicsImageRenderer(bounds: inputView.convert(textRect, to: editor), format: format)
        let image = renderer.image { context in
            editor.layer.render(in: context.cgContext)
        }
        let snapshot = UIImageView(image: image)
        let verticalPosition: CGFloat
        if let scrollView = editor as? UIScrollView {
            let scrollableHeight = scrollView.contentSize.height - scrollView.bounds.height
            verticalPosition = scrollableHeight > 1
                ? min(1, max(0, scrollView.contentOffset.y / scrollableHeight))
                : 0.5
        } else {
            verticalPosition = 0.5
        }
        return ChatSendFlightCapture(
            source: .text,
            content: snapshot,
            frame: inputView.convert(textRect, to: surface),
            contentVerticalPosition: verticalPosition
        )
    }

    private func visibleFrame(of anchor: UIView, in surface: UIView) -> CGRect {
        var frame = anchor.convert(anchor.bounds, to: surface).intersection(surface.bounds)
        var ancestor = anchor.superview
        while let view = ancestor {
            if view.clipsToBounds {
                frame = frame.intersection(view.convert(view.bounds, to: surface))
            }
            ancestor = view.superview
        }
        return frame
    }

    private func findEditor(near anchor: UIView) -> UIView? {
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        func editor(in view: UIView) -> UIView? {
            guard !view.isHidden, view.alpha > 0,
                  view.convert(view.bounds, to: nil).intersects(anchorRect) else { return nil }
            if view is UITextView || view is UITextField { return view }
            for child in view.subviews {
                if let found = editor(in: child) { return found }
            }
            return nil
        }
        var ancestor = anchor.superview
        while let view = ancestor, !(view is UIWindow) {
            if let found = editor(in: view) { return found }
            ancestor = view.superview
        }
        return nil
    }

    private func selectionInteractions(in view: UIView) -> [UITextSelectionDisplayInteraction] {
        view.interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }
            + view.subviews.flatMap { selectionInteractions(in: $0) }
    }
}

struct ChatSendFlightCapture {
    let source: ChatSendPresentationSource
    let content: UIView
    let frame: CGRect
    var contentVerticalPosition: CGFloat = 0.5
    var sourceContentFrame: CGRect? = nil
}

private struct ChatSendFlightSourcesKey: EnvironmentKey {
    static let defaultValue: ChatSendFlightSources? = nil
}

extension EnvironmentValues {
    var chatSendFlightSources: ChatSendFlightSources? {
        get { self[ChatSendFlightSourcesKey.self] }
        set { self[ChatSendFlightSourcesKey.self] = newValue }
    }
}

struct ChatSendSourceAnchor: UIViewRepresentable {
    @Environment(\.chatSendFlightSources) private var sources
    let id: ChatSendPresentationSource

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.sources = sources
        context.coordinator.id = id
        sources?.register(uiView, id: id)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let id = coordinator.id else { return }
        coordinator.sources?.unregister(uiView, id: id)
    }

    final class Coordinator {
        weak var sources: ChatSendFlightSources?
        var id: ChatSendPresentationSource?
    }
}

/// 附件纯内容拥有独立的真实渲染子树；编辑按钮与玻璃留在外层，不参与快照。
struct ChatSendContentSource<Content: View>: UIViewControllerRepresentable {
    @Environment(\.chatSendFlightSources) private var sources
    let id: ChatSendPresentationSource
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(content.environment(\.self, context.environment)))
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.sizingOptions = .intrinsicContentSize
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        controller.rootView = AnyView(content.environment(\.self, context.environment))
        context.coordinator.sources = sources
        context.coordinator.id = id
        sources?.register(controller.view, id: id)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        ))
    }

    static func dismantleUIViewController(_ controller: UIHostingController<AnyView>, coordinator: Coordinator) {
        guard let id = coordinator.id else { return }
        coordinator.sources?.unregister(controller.view, id: id)
    }

    final class Coordinator {
        weak var sources: ChatSendFlightSources?
        var id: ChatSendPresentationSource?
    }
}
