import ETOSCore
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送来源逐段就绪", .serialized)
@MainActor
struct ChatSendFlightReadinessTests {
    @MainActor
    private final class Fixture {
        let window: UIWindow
        let surface: UIView
        let controller = ChatSendFlightController()
        let id = UUID()
        let sessionID = UUID()
        let target = CGRect(x: 140, y: 300, width: 180, height: 60)
        var preparedCount = 0
        var handoffCount = 0
        var completionCount = 0
        var retired: [Set<ChatSendPresentationSource>] = []
        private var targets: [ChatSendPresentationSource: ChatSendFlightTargetCarrier] = [:]
        private var activeID: UUID?

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
            surface = UIView(frame: window.bounds)
            let viewport = UIView(frame: window.bounds)
            let composer = UIView(frame: CGRect(x: 0, y: 720, width: 390, height: 180))
            window.addSubview(viewport)
            window.addSubview(composer)
            window.addSubview(surface)
            controller.surface = surface
            controller.viewportAnchor = viewport
            controller.composerAnchor = composer
            controller.composerContentAnchor = composer
        }

        func begin(
            id: UUID? = nil,
            sources: [ChatSendPresentationSource] = [.text],
            departureBounds: CGRect? = nil,
            at now: CFTimeInterval = 100,
            onPrepared: @escaping (ChatSendPresentation) -> Bool = { _ in true },
            onRetired: @escaping (Set<ChatSendPresentationSource>) -> Void = { _ in }
        ) {
            targets.values.forEach { $0.removeFromSuperview() }
            targets.removeAll()
            activeID = id ?? self.id
            let captures = sources.enumerated().map { index, source in
                ChatSendFlightCapture(
                    source: source, content: UIView(),
                    frame: CGRect(x: 20 + index * 80, y: 800, width: 72, height: 30)
                )
            }
            controller.begin(
                id: id ?? self.id, sessionID: sessionID, captures: captures,
                response: 0.3, damping: 1, backgrounds: [:], departureBounds: departureBounds, at: now,
                onMessagesPrepared: { [weak self] presentation in
                    self?.preparedCount += 1
                    return onPrepared(presentation)
                },
                onSourcesRetired: { [weak self] sources in
                    self?.retired.append(sources)
                    onRetired(sources)
                },
                onHandoff: { [weak self] id, sessionID in
                    guard let self else { return false }
                    handoffCount += 1
                    controller.completeHandoff(for: id, sessionID: sessionID)
                    return true
                },
                onCompletion: { [weak self] in self?.completionCount += 1 }
            )
        }

        func retarget(_ frames: [ChatSendPresentationSource: CGRect], at now: CFTimeInterval) {
            guard let activeID else { return }
            for (source, frame) in frames {
                let view = targets[source] ?? ChatSendFlightTargetCarrier()
                view.frame = frame
                if view.superview == nil { window.addSubview(view) }
                targets[source] = view
                controller.registerTarget(view, for: ChatSendFlightTarget(flightID: activeID, source: source))
            }
            controller.retarget(frames, at: now)
        }

        func presentation(_ sources: [ChatSendPresentationSource] = [.text]) -> ChatSendPresentation {
            .init(
                sessionID: sessionID,
                messageIDsBySource: Dictionary(uniqueKeysWithValues: sources.map { ($0, UUID()) }),
                responseGroupID: UUID()
            )
        }
    }

    @Test("草稿先清空收缩后仍沿捕获时的输入边界离场，不在原位等身份")
    func capturedDepartureSurvivesSynchronousComposerCollapse() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let departure = try #require(f.controller.departureBounds)
        #expect(departure.maxY == 720)
        f.controller.composerContentAnchor?.frame.origin.y = 860
        f.begin(departureBounds: departure)
        let floating = try #require(f.surface.subviews.first)
        f.controller.advance(at: 100.15)
        #expect(floating.frame.maxY < 800)
        f.controller.advance(at: 101.5)
        #expect(abs(floating.frame.maxY - departure.maxY) < 0.5)
        #expect(f.preparedCount == 0 && f.handoffCount == 0 && f.retired.isEmpty)
        #expect(f.controller.isActive)
    }

    @Test("身份准备耗时不挤占展示与布局机会，晚到的真实落点仍连续交接")
    func delayedReadinessGetsIndependentBudgets() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        f.controller.accept(f.presentation(), for: f.id, at: 101.35)
        f.controller.advance(at: 101.7)
        #expect(f.controller.isActive && f.retired.isEmpty)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 101.9)
        let content = try #require(f.surface.subviews.first)
        f.retarget([.text: f.target], at: 102)
        f.controller.advance(at: 103.5)
        #expect(f.handoffCount == 1 && f.completionCount == 0)
        #expect(abs(content.convert(content.bounds, to: f.surface).midY - f.target.midY) < 0.5)
        f.controller.advance(at: 103.64)
        #expect(!f.controller.isActive && f.completionCount == 1 && f.retired.isEmpty)
    }

    @Test("每个就绪阶段在固定截止退役，所有入口都拒绝迟到回执", arguments: ["identity", "display", "layout"], ["accept", "display", "target", "frame"])
    func stageDeadlineIsEnforcedAtEveryIngress(stage: String, ingress: String) throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        let presentation = f.presentation()
        var deadline: CFTimeInterval = 100 + 1.6
        if stage != "identity" {
            f.controller.accept(presentation, for: f.id, at: 101.5)
            deadline = 101.5 + 1.6
        }
        if stage == "layout" {
            f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 103)
            deadline = 103 + 1.6
            f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: deadline - 0.02)
        }
        // 屏外几何不能冒充已就绪，也不能给任何阶段续期。
        f.retarget([.text: f.target.offsetBy(dx: 0, dy: 1_000)], at: deadline - 0.01)
        f.controller.advance(at: deadline - 0.01)
        #expect(f.controller.isActive && f.retired.isEmpty)
        switch ingress {
        case "accept": f.controller.accept(presentation, for: f.id, at: deadline)
        case "display": f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: deadline)
        case "target": f.retarget([.text: f.target], at: deadline)
        default: f.controller.advance(at: deadline)
        }
        f.controller.accept(presentation, for: f.id, at: deadline + 0.1)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: deadline + 0.1)
        f.retarget([.text: f.target], at: deadline + 0.1)
        #expect(f.preparedCount == (stage == "identity" ? 0 : 1))
        #expect(f.retired == [[.text]] && f.completionCount == 1 && f.handoffCount == 0)
        #expect(!f.controller.isActive && f.surface.subviews.isEmpty)
    }

    @Test("展示与几何不能绕过身份，错误发送或会话回执也不能推进来源")
    func outOfOrderSignalsCannotBypassIdentity() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        f.controller.accept(f.presentation(), for: UUID(), at: 100.2)
        f.controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: f.id, at: 100.2)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 100.3)
        f.retarget([.text: f.target], at: 100.4)
        f.controller.advance(at: 101.5)
        #expect(f.preparedCount == 0 && f.handoffCount == 0)
        #expect(try #require(f.surface.subviews.first).frame.maxY > 700)
        f.controller.advance(at: 100 + 1.6)
        #expect(f.retired == [[.text]] && f.completionCount == 1)
    }

    @Test("身份确认后的真实几何可先于展示事件到达，晚展示不会重置已落点来源")
    func targetCanPrecedeDisplayAfterIdentity() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        f.controller.accept(f.presentation(), for: f.id, at: 100.2)
        f.retarget([.text: f.target], at: 100.3)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 103)
        f.controller.advance(at: 103)
        #expect(f.handoffCount == 1 && f.retired.isEmpty)
        f.controller.advance(at: 103.13)
        #expect(f.completionCount == 1 && !f.controller.isActive)
    }

    @Test("唯一布局回执早于锚点挂载时，显示帧接续真实布局且不能绕过身份")
    func targetMountCompletesReadinessWithoutAnotherLayoutReceipt() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        let anchor = ChatSendFlightTargetCarrier(frame: f.target)
        f.controller.registerTarget(anchor, for: ChatSendFlightTarget(flightID: f.id, source: .text))
        f.window.addSubview(anchor)
        f.controller.advance(at: 100.2)
        #expect(f.handoffCount == 0 && f.preparedCount == 0)
        #expect(try #require(f.surface.subviews.first).frame.maxY > 700)
        anchor.removeFromSuperview()
        f.controller.accept(f.presentation(), for: f.id, at: 100.3)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 100.3)
        // 唯一回执到达时原生几何还不可读；后续只挂载锚点，不补发几何或展示事件。
        f.controller.retarget([.text: f.target], at: 100.4)
        f.controller.advance(at: 100.4)
        #expect(f.handoffCount == 0 && f.retired.isEmpty)
        let flying = try #require(f.surface.subviews.first)
        f.window.addSubview(anchor)
        f.controller.advance(at: 100.5)
        f.controller.advance(at: 101.3)
        #expect(f.handoffCount == 1 && f.retired.isEmpty)
        #expect(flying.superview === anchor && flying.convert(flying.bounds, to: f.surface) == f.target)
        f.controller.advance(at: 101.45)
        #expect(f.completionCount == 1 && !f.controller.isActive)
    }

    @Test("重复身份不重新筛来源，重复或未知展示不延长布局截止")
    func repeatedSignalsDoNotRebindOrRenew() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let image = ChatSendPresentationSource.image(UUID())
        f.begin(sources: [.text, image])
        f.controller.accept(f.presentation([.text, image]), for: f.id, at: 100.2)
        f.controller.accept(f.presentation([]), for: f.id, at: 101.5)
        #expect(f.preparedCount == 1 && f.controller.capturedSources == [.text, image])
        f.controller.updateDisplayedSources([.text], for: UUID(), sessionID: f.sessionID, at: 101.5)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: UUID(), at: 101.5)
        f.controller.updateDisplayedSources([.file(UUID())], for: f.id, sessionID: f.sessionID, at: 101.5)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 101.7)
        f.controller.advance(at: 100.2 + 1.6)
        #expect(f.retired == [[image]] && f.controller.capturedSources == [.text])
        let deadline: CFTimeInterval = 101.7 + 1.6
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: deadline - 0.1)
        f.controller.advance(at: deadline)
        #expect(f.retired == [[image], [.text]] && f.completionCount == 1)
    }

    @Test("交接后目标承载层被替换时退役旧覆盖，旧注销不能处置新锚点")
    func replacedCarrierRetiresTheViewFromItsOriginalParent() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin()
        f.controller.accept(f.presentation(), for: f.id, at: 100.2)
        let target = ChatSendFlightTarget(flightID: f.id, source: .text)
        let oldCarrier = ChatSendFlightTargetCarrier(frame: f.target)
        f.window.addSubview(oldCarrier)
        f.controller.registerTarget(oldCarrier, for: target)
        f.controller.retarget([.text: f.target], at: 100.2)
        let floating = try #require(f.surface.subviews.first)
        f.controller.advance(at: 101)
        #expect(f.handoffCount == 1 && floating.superview === oldCarrier)
        let replacement = ChatSendFlightTargetCarrier(frame: f.target)
        f.window.addSubview(replacement)
        f.controller.registerTarget(replacement, for: target)
        f.controller.unregisterTarget(oldCarrier, for: target)
        f.controller.advance(at: 101.05)
        #expect(f.retired == [[.text]] && f.completionCount == 1)
        #expect(floating.superview == nil && oldCarrier.subviews.isEmpty && replacement.subviews.isEmpty)
        #expect(!f.controller.isActive)
    }

    @Test("附件独立等展示与布局，缺失来源退出不影响已有落点")
    func sourcesRetireIndependently() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let image = ChatSendPresentationSource.image(UUID())
        let file = ChatSendPresentationSource.file(UUID())
        f.begin(sources: [.text, image, file])
        f.controller.accept(f.presentation([.text, image, file]), for: f.id, at: 100.2)
        f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 100.3)
        f.controller.updateDisplayedSources([.text, image], for: f.id, sessionID: f.sessionID, at: 100.8)
        f.retarget([.text: f.target], at: 101.7)
        f.controller.advance(at: 100.2 + 1.6)
        #expect(f.retired == [[file]] && f.controller.capturedSources == [.text, image])
        #expect(f.handoffCount == 0)
        f.controller.advance(at: 100.8 + 1.6)
        #expect(f.retired == [[file], [image]] && f.controller.capturedSources == [.text])
        #expect(f.handoffCount == 1)
        f.controller.advance(at: 102.55)
        #expect(f.completionCount == 1 && !f.controller.isActive)
    }

    @Test("已展示或落点来源退出完整显示集合立即退役，未出现来源继续等候", arguments: ["layout", "landed", "target-first"], [false, true])
    func sourceLeavingDisplayWindowRetires(stage: String, keepsPendingSource: Bool) throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let image = ChatSendPresentationSource.image(UUID())
        let sources: [ChatSendPresentationSource] = keepsPendingSource ? [image, .text] : [image]
        f.begin(sources: sources)
        f.controller.accept(f.presentation(sources), for: f.id, at: 100.2)
        if stage != "target-first" {
            f.controller.updateDisplayedSources([image], for: f.id, sessionID: f.sessionID, at: 100.3)
        }
        if stage != "layout" { f.retarget([image: f.target], at: 100.4) }
        f.controller.updateDisplayedSources([], for: f.id, sessionID: f.sessionID, at: 100.5)
        #expect(f.retired == [[image]] && f.handoffCount == 0)
        #expect(f.controller.capturedSources == (keepsPendingSource ? [.text] : []))
        #expect(f.surface.subviews.count == (keepsPendingSource ? 1 : 0))
        // 已退出来源不能被迟到几何或再次出现的 ID 复活。
        f.retarget([image: f.target], at: 100.6)
        f.controller.updateDisplayedSources(Set(sources), for: f.id, sessionID: f.sessionID, at: 100.6)
        #expect(f.retired == [[image]])
        if keepsPendingSource {
            #expect(f.controller.isActive && f.completionCount == 0)
            f.retarget([.text: f.target], at: 100.7)
            f.controller.advance(at: 102)
            f.controller.advance(at: 102.13)
            #expect(f.handoffCount == 1)
        }
        #expect(f.completionCount == 1 && !f.controller.isActive && f.surface.subviews.isEmpty)
    }

    @Test("页面拒绝身份绑定立即放行真实消息")
    func rejectedIdentityFinishesImmediately() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin(onPrepared: { _ in false })
        f.controller.accept(f.presentation(), for: f.id, at: 100.2)
        #expect(f.preparedCount == 1 && f.completionCount == 1 && f.handoffCount == 0)
        #expect(!f.controller.isActive && f.surface.subviews.isEmpty)
    }

    @Test("身份回调内同步展示与落点不会在返回后倒退阶段", arguments: [false, true])
    func synchronousReadinessInsideIdentityIsRetained(includesTarget: Bool) throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        f.begin(onPrepared: { _ in
            f.controller.updateDisplayedSources([.text], for: f.id, sessionID: f.sessionID, at: 100.4)
            if includesTarget { f.retarget([.text: f.target], at: 100.4) }
            // 重入 identity 不能重新执行 UI 回调或清掉刚确认的映射。
            f.controller.accept(f.presentation([]), for: f.id, at: 100.4)
            return true
        })
        f.controller.accept(f.presentation(), for: f.id, at: 100.2)
        f.controller.advance(at: 101.9)
        #expect(f.preparedCount == 1 && f.retired.isEmpty && f.controller.isActive)
        if includesTarget {
            #expect(f.handoffCount == 1)
            f.controller.advance(at: 102.1)
            #expect(f.completionCount == 1 && f.retired.isEmpty)
        } else {
            #expect(f.handoffCount == 0)
            f.controller.advance(at: 100.4 + 1.6)
            #expect(f.retired == [[.text]] && f.completionCount == 1)
        }
    }

    @Test("旧身份回调开始新发送后再拒绝绑定，不能结束新发送")
    func rejectedOldCallbackCannotFinishReplacement() throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let nextID = UUID()
        f.begin(onPrepared: { _ in
            f.begin(id: nextID, at: 100.3)
            return false
        })
        f.controller.accept(f.presentation(), for: f.id, at: 100.2)
        f.controller.accept(f.presentation([]), for: f.id, at: 100.4)
        #expect(f.preparedCount == 1 && f.completionCount == 0 && f.controller.isActive)
        #expect(f.controller.capturedSources == [.text] && f.surface.subviews.count == 1)
        f.controller.accept(f.presentation(), for: nextID, at: 100.4)
        f.retarget([.text: f.target], at: 100.5)
        f.controller.advance(at: 102)
        f.controller.advance(at: 102.13)
        #expect(f.preparedCount == 2 && f.handoffCount == 1 && f.completionCount == 1)
    }

    @Test("退役回调重入开始新发送，旧筛源、超时或窗口退出不能继续处置它", arguments: ["unmapped", "deadline", "window"])
    func retiringCallbackCannotMutateReplacement(trigger: String) throws {
        let f = try Fixture()
        defer { f.controller.cancel() }
        let nextID = UUID()
        let callbackTime: CFTimeInterval = trigger == "deadline" ? 100 + 1.6 : (trigger == "window" ? 100.5 : 100.2)
        f.begin(onRetired: { _ in f.begin(id: nextID, at: callbackTime) })
        if trigger == "deadline" {
            f.controller.advance(at: callbackTime)
        } else if trigger == "window" {
            f.controller.accept(f.presentation(), for: f.id, at: 100.2)
            f.retarget([.text: f.target], at: 100.4)
            f.controller.updateDisplayedSources([], for: f.id, sessionID: f.sessionID, at: callbackTime)
        } else {
            f.controller.accept(f.presentation([]), for: f.id, at: callbackTime)
        }
        let previousPreparedCount = trigger == "window" ? 1 : 0
        #expect(f.retired == [[.text]] && f.preparedCount == previousPreparedCount && f.completionCount == 0)
        #expect(f.controller.isActive && f.surface.subviews.count == 1)
        f.controller.accept(f.presentation(), for: nextID, at: callbackTime + 0.1)
        #expect(f.preparedCount == previousPreparedCount + 1 && f.controller.capturedSources == [.text])
    }
}
