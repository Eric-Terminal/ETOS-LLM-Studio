import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("时间线边缘手势的原生仲裁")
@MainActor
struct ChatTimelineEdgePanTests {
    @Test("已滚动的真实视口在接收触摸前拒绝中央正文和关闭状态")
    func rejectsCenterBeforeRecognition() throws {
        let fixture = ScrollFixture()
        let controller = ChatTimelineEdgePanController()
        defer { controller.detach() }
        let scroll = fixture.scroll
        let nativePan = scroll.panGestureRecognizer
        let originalDelegate = nativePan.delegate
        let nativeWasEnabled = nativePan.isEnabled
        let existing = scroll.gestureRecognizers ?? []
        controller.update(isEnabled: true, onReveal: {}, onEnded: {})
        controller.attach(to: scroll)
        let pan = controller.recognizer
        try #require(pan.view === scroll && pan.delegate === controller)

        // 同时使用非零横向/纵向 offset，防止把内容坐标当成可见视口坐标。
        let center = LocatedTouch(in: scroll, at: CGPoint(x: scroll.bounds.minX + 178.7, y: scroll.bounds.minY + 226.1))
        let rightEdge = LocatedTouch(in: scroll, at: CGPoint(x: scroll.bounds.minX + 390, y: scroll.bounds.minY + 226.1))
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldReceive: center) == false)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldReceive: rightEdge) == true)
        controller.update(isEnabled: false, onReveal: {}, onEnded: {})
        #expect(!pan.isEnabled)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldReceive: rightEdge) == false)
        #expect(nativePan.isEnabled == nativeWasEnabled)
        #expect(nativePan.delegate === originalDelegate)
        #expect(existing.allSatisfy { original in scroll.gestureRecognizers?.contains { $0 === original } == true })
    }

    @Test("右缘纵拖和右拖在 began 前失败，左拖保留独立呼出距离")
    func rejectsOtherDirectionsBeforeBegan() throws {
        let fixture = ScrollFixture()
        let pan = ActionPan()
        let controller = ChatTimelineEdgePanController(recognizer: pan)
        defer { controller.detach() }
        let scroll = fixture.scroll
        controller.update(isEnabled: true, onReveal: {}, onEnded: {})
        controller.attach(to: scroll)
        let touch = LocatedTouch(in: scroll, at: CGPoint(x: scroll.bounds.maxX - 12, y: scroll.bounds.minY + 200))
        for (translation, expected) in [
            (CGPoint(x: -9, y: 2), true),
            (CGPoint(x: -9, y: 8), false),
            (CGPoint(x: 9, y: 2), false),
            (CGPoint(x: 0, y: 24), false)
        ] {
            try #require(pan.delegate?.gestureRecognizer?(pan, shouldReceive: touch) == true)
            // 直接提供 delegate 所读取的取样，不依赖没有系统触摸序列的 UIPan 内部累计状态。
            pan.actionTranslation = translation
            try #require(pan.translation(in: scroll) == translation)
            #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == expected)
        }
        #expect(!ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 390, viewportWidth: 402, translation: CGSize(width: -9, height: 2)
        ))
        #expect(ChatView.shouldRevealScrollNavigationForEdgeSwipe(
            startLocationX: 390, viewportWidth: 402, translation: CGSize(width: -14, height: 0)
        ))
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: scroll.panGestureRecognizer) == true)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()) == false)
    }

    @Test("回调更新只交给最新页面，越过呼出距离只触发一次，关闭后迟到动作不回调")
    func callbacksRespectGestureAndAttachmentLifetime() throws {
        let fixture = ScrollFixture()
        let pan = ActionPan()
        let controller = ChatTimelineEdgePanController(recognizer: pan)
        defer { controller.detach() }
        var oldReveals = 0
        var currentReveals = 0
        var ended = 0
        controller.update(isEnabled: true, onReveal: { oldReveals += 1 }, onEnded: { ended += 1 })
        controller.attach(to: fixture.scroll)
        let touch = LocatedTouch(in: fixture.scroll, at: CGPoint(
            x: fixture.scroll.bounds.maxX - 12, y: fixture.scroll.bounds.minY + 200
        ))
        try #require(controller.gestureRecognizer(pan, shouldReceive: touch))
        pan.actionState = .began
        pan.actionTranslation = CGPoint(x: -9, y: 1)
        controller.handlePan(pan)
        #expect(oldReveals == 0)

        controller.update(isEnabled: true, onReveal: { currentReveals += 1 }, onEnded: { ended += 1 })
        pan.actionState = .changed
        pan.actionTranslation = CGPoint(x: -14, y: 1)
        controller.handlePan(pan)
        pan.actionTranslation = CGPoint(x: -40, y: 1)
        controller.handlePan(pan)
        #expect(oldReveals == 0 && currentReveals == 1)
        pan.actionState = .ended
        controller.handlePan(pan)
        #expect(ended == 1)

        try #require(controller.gestureRecognizer(pan, shouldReceive: touch))
        controller.update(isEnabled: false, onReveal: { currentReveals += 1 }, onEnded: { ended += 1 })
        pan.actionState = .changed
        controller.handlePan(pan)
        pan.actionState = .cancelled
        controller.handlePan(pan)
        #expect(currentReveals == 1 && ended == 1)

        controller.update(isEnabled: true, onReveal: { currentReveals += 1 }, onEnded: { ended += 1 })
        try #require(controller.gestureRecognizer(pan, shouldReceive: touch))
        let replacement = UIScrollView(frame: fixture.scroll.frame)
        controller.attach(to: replacement)
        pan.actionState = .changed
        controller.handlePan(pan)
        pan.actionState = .ended
        controller.handlePan(pan)
        #expect(currentReveals == 1 && ended == 1)
        #expect(pan.view === replacement)
    }

    @Test("挂载替换只迁移自有识别器，旧控制器拆除不影响新控制器和原生选择")
    func attachmentOwnershipIsIndependent() throws {
        let fixture = ScrollFixture()
        let first = fixture.scroll
        let second = UIScrollView(frame: first.frame)
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 180, height: 100))
        text.isEditable = false
        text.isSelectable = true
        first.addSubview(text)
        let selectionRecognizers = text.gestureRecognizers ?? []
        let longPress = UILongPressGestureRecognizer()
        first.addGestureRecognizer(longPress)
        let nativeDelegate = first.panGestureRecognizer.delegate
        let oldController = ChatTimelineEdgePanController()
        let newController = ChatTimelineEdgePanController()
        defer { oldController.detach(); newController.detach() }
        oldController.update(isEnabled: true, onReveal: {}, onEnded: {})
        oldController.attach(to: first)
        oldController.attach(to: first)
        #expect(first.gestureRecognizers?.filter { $0 === oldController.recognizer }.count == 1)
        oldController.attach(to: second)
        #expect(first.gestureRecognizers?.contains { $0 === oldController.recognizer } == false)
        #expect(oldController.recognizer.view === second)

        weak var retainedByCallback: CallbackOwner?
        do {
            let owner = CallbackOwner()
            retainedByCallback = owner
            newController.update(isEnabled: true, onReveal: { owner.count += 1 }, onEnded: {})
        }
        newController.attach(to: first)
        oldController.detach()
        #expect(oldController.recognizer.view == nil && oldController.recognizer.delegate == nil)
        #expect(newController.recognizer.view === first)
        #expect(first.panGestureRecognizer.delegate === nativeDelegate)
        #expect(longPress.view === first && longPress.isEnabled)
        #expect(text.isSelectable)
        #expect(selectionRecognizers.allSatisfy { original in text.gestureRecognizers?.contains { $0 === original } == true })
        #expect(retainedByCallback != nil)
        newController.detach()
        #expect(newController.recognizer.view == nil)
        #expect(newController.recognizer.delegate == nil)
        #expect(retainedByCallback == nil)
    }
}

@MainActor
private final class ScrollFixture {
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))

    init() {
        // 这里只验证 delegate 与识别器所有权，不需要启动窗口的显示生命周期。
        scroll.contentSize = CGSize(width: 900, height: 2_400)
        scroll.contentOffset = CGPoint(x: 47, y: 1_300)
    }
}

@MainActor
private final class LocatedTouch: UITouch {
    let sourceView: UIView
    let sourcePoint: CGPoint

    init(in view: UIView, at point: CGPoint) {
        sourceView = view
        sourcePoint = point
        super.init()
    }

    override func location(in view: UIView?) -> CGPoint {
        sourceView.convert(sourcePoint, to: view)
    }
}

@MainActor
private final class CallbackOwner {
    var count = 0
}

// 只提供方向取样和 action 状态；delegate 仍走产品实现，系统触摸仲裁另由普通 App 验收。
@MainActor
private final class ActionPan: UIPanGestureRecognizer {
    var actionState: UIGestureRecognizer.State = .possible
    var actionTranslation = CGPoint.zero

    override var state: UIGestureRecognizer.State {
        get { actionState }
        set { actionState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint { actionTranslation }
}
