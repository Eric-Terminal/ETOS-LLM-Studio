import UIKit

@MainActor
final class ChatTimelineEdgePanController: NSObject, UIGestureRecognizerDelegate {
    nonisolated static let activationWidth: CGFloat = 56

    let recognizer: UIPanGestureRecognizer
    private weak var scrollView: UIScrollView?
    private var isEnabled = false
    private var startLocationX: CGFloat?
    private var didReveal = false
    private var onReveal: () -> Void = {}
    private var onEnded: () -> Void = {}

    override convenience init() {
        self.init(recognizer: UIPanGestureRecognizer())
    }

    init(recognizer: UIPanGestureRecognizer) {
        self.recognizer = recognizer
        super.init()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.isEnabled = false
    }

    func update(isEnabled: Bool, onReveal: @escaping () -> Void, onEnded: @escaping () -> Void) {
        self.onReveal = onReveal
        self.onEnded = onEnded
        self.isEnabled = isEnabled
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
        if !isEnabled {
            startLocationX = nil
            didReveal = false
        }
    }

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        removeFromScrollView()
        self.scrollView = scrollView
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handlePan(_:)))
        scrollView.addGestureRecognizer(recognizer)
    }

    func detach() {
        removeFromScrollView()
        onReveal = {}
        onEnded = {}
    }

    private func removeFromScrollView() {
        let previous = scrollView
        scrollView = nil
        startLocationX = nil
        didReveal = false
        recognizer.removeTarget(self, action: #selector(handlePan(_:)))
        recognizer.delegate = nil
        previous?.removeGestureRecognizer(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === recognizer else { return false }
        startLocationX = nil
        didReveal = false
        guard isEnabled, let scrollView else { return false }
        let point = touch.location(in: scrollView)
        let bounds = scrollView.bounds
        // 在识别前排除正文触摸；onChanged 中才判断起点会让中央纵拖也参与仲裁。
        guard bounds.width > 0, bounds.contains(point),
              point.x >= bounds.maxX - Self.activationWidth else { return false }
        startLocationX = point.x - bounds.minX
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, isEnabled,
              startLocationX != nil, let scrollView else { return false }
        let translation = recognizer.translation(in: scrollView)
        // 系统可能在 14pt 前请求开始；这里只判方向，呼出距离仍由实际移动达到后触发。
        return translation.x < 0 && abs(translation.x) > abs(translation.y) * 1.2
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === recognizer && otherGestureRecognizer === scrollView?.panGestureRecognizer
    }

    @objc func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard gestureRecognizer === recognizer, isEnabled, let scrollView else { return }
        switch gestureRecognizer.state {
        case .began, .changed:
            guard !didReveal, let startLocationX else { return }
            let translation = gestureRecognizer.translation(in: scrollView)
            guard ChatView.shouldRevealScrollNavigationForEdgeSwipe(
                startLocationX: startLocationX,
                viewportWidth: scrollView.bounds.width,
                translation: CGSize(width: translation.x, height: translation.y)
            ) else { return }
            didReveal = true
            onReveal()
        case .ended, .cancelled:
            guard startLocationX != nil else { return }
            startLocationX = nil
            didReveal = false
            onEnded()
        default:
            break
        }
    }
}
