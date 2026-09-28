import SwiftUI
import UIKit
import ETOSCore

struct ChatSendFlightTarget: Hashable {
    let flightID: UUID
    let source: ChatSendPresentationSource
}

/// 内容因布局版本重建时，交接承载层仍保留；清除发送目标也不改变正文身份。
struct ChatSendFlightContentModifier: ViewModifier {
    let layoutIdentity: ChatBubbleLayoutIdentity
    let opacity: Double
    let target: ChatSendFlightTarget?

    func body(content: Content) -> some View {
        content
            .id(layoutIdentity)
            .opacity(opacity)
            .overlay {
                if let target {
                    GeometryReader { proxy in
                        ChatSendFlightTargetAnchor(target: target).preference(
                            key: FlightTargetRectKey.self,
                            value: [layoutIdentity.messageID: proxy.frame(in: .named(ChatView.flightCoordinateSpace))]
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .geometryGroup()
    }
}

private struct ChatSendFlightControllerKey: EnvironmentKey {
    static let defaultValue: ChatSendFlightController? = nil
}

extension EnvironmentValues {
    var chatSendFlightController: ChatSendFlightController? {
        get { self[ChatSendFlightControllerKey.self] }
        set { self[ChatSendFlightControllerKey.self] = newValue }
    }
}

/// 飞行时提供真实锚点，交接后承载同一个覆盖层；位置变化交给共同祖先，不跨提交复制屏幕几何。
@MainActor
final class ChatSendFlightTargetCarrier: UIView {
    private weak var flightView: UIView?
    private var layoutFlight: ((CGRect) -> Void)?

    func install(_ view: UIView, layout: @escaping (CGRect) -> Void) {
        flightView = view
        layoutFlight = layout
        addSubview(view)
        layout(bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let flightView, flightView.superview === self else {
            layoutFlight = nil
            return
        }
        // 仅布局已归本地承载的原生层，不能反向发布 SwiftUI 状态。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutFlight?(bounds)
        CATransaction.commit()
    }
}

struct ChatSendFlightTargetAnchor: UIViewRepresentable {
    @Environment(\.chatSendFlightController) private var controller
    let target: ChatSendFlightTarget

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatSendFlightTargetCarrier {
        let view = ChatSendFlightTargetCarrier()
        view.isUserInteractionEnabled = false
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: ChatSendFlightTargetCarrier, context: Context) {
        if context.coordinator.target != target || context.coordinator.controller !== controller {
            context.coordinator.unregister(uiView)
        }
        context.coordinator.controller = controller
        context.coordinator.target = target
        controller?.registerTarget(uiView, for: target)
    }

    static func dismantleUIView(_ uiView: ChatSendFlightTargetCarrier, coordinator: Coordinator) {
        coordinator.unregister(uiView)
    }

    @MainActor
    final class Coordinator {
        weak var controller: ChatSendFlightController?
        var target: ChatSendFlightTarget?

        func unregister(_ view: ChatSendFlightTargetCarrier) {
            if let target { controller?.unregisterTarget(view, for: target) }
        }
    }
}

/// 锚点只提供已布局的 UIKit 几何；飞行不订阅根视图的逐帧位置状态。
struct ChatSendFlightLayoutAnchor: UIViewRepresentable {
    enum Region { case composer, composerContent, viewport }

    let controller: ChatSendFlightController
    let region: Region

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        register(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { register(uiView) }

    private func register(_ view: UIView) {
        switch region {
        case .composer: controller.composerAnchor = view
        case .composerContent: controller.composerContentAnchor = view
        case .viewport: controller.viewportAnchor = view
        }
    }
}

extension ChatSendFlightController {
    var departureBounds: CGRect? {
        guard let surface, let composerAnchor, let composerContentAnchor, let viewportAnchor,
              let window = surface.window,
              composerAnchor.window === window, composerContentAnchor.window === window,
              viewportAnchor.window === window else { return nil }
        let viewport = viewportAnchor.convert(viewportAnchor.bounds, to: surface).intersection(surface.bounds)
        let composer = composerAnchor.convert(composerAnchor.bounds, to: surface)
        let content = composerContentAnchor.convert(composerContentAnchor.bounds, to: surface)
        // 胶囊展开在固定占位之外；外层仍保留附件边界，不能只测输入框或占位其中之一。
        let bottom = min(viewport.maxY, composer.minY, content.minY)
        guard !viewport.isNull, viewport.width > 1, bottom > viewport.minY else { return nil }
        return CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: bottom - viewport.minY)
    }
}
