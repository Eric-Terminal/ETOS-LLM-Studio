import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送内容交接", .serialized)
@MainActor
struct ChatSendFlightTests {
    @discardableResult
    private func targetAnchor(
        for controller: ChatSendFlightController, id: UUID, source: ChatSendPresentationSource = .text,
        frame: CGRect, in window: UIWindow
    ) -> ChatSendFlightTargetCarrier {
        let view = ChatSendFlightTargetCarrier(frame: frame)
        window.addSubview(view)
        controller.registerTarget(view, for: ChatSendFlightTarget(flightID: id, source: source))
        return view
    }

    private func installLayoutAnchors(on controller: ChatSendFlightController, in window: UIWindow) {
        let viewport = UIView(frame: window.bounds)
        let composer = UIView(frame: CGRect(x: 0, y: window.bounds.height - 180, width: window.bounds.width, height: 180))
        viewport.isUserInteractionEnabled = false
        composer.isUserInteractionEnabled = false
        window.addSubview(viewport)
        window.addSubview(composer)
        controller.viewportAnchor = viewport
        controller.composerAnchor = composer
        controller.composerContentAnchor = composer
    }

    @Test("半露出的落点保留完整几何，淡出期间继续接续目标位移")
    func handoffTracksMovingUnclippedTarget() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        var handoffCount = 0
        var completionCount = 0
        let id = UUID()
        controller.begin(
            id: id,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 20))],
            response: 0.2, damping: 1, backgrounds: [:],
            onMessagesPrepared: { _ in true },
            onSourcesRetired: { _ in },
            onHandoff: { id, sessionID in
                handoffCount += 1
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            },
            onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id)
        let target = CGRect(x: 120, y: -100, width: 180, height: 300)
        let anchor = targetAnchor(for: controller, id: id, frame: target, in: window)
        let content = try #require(surface.subviews.first)
        controller.retarget([.text: target])
        let started = CACurrentMediaTime()
        controller.advance(at: started)
        controller.advance(at: started + 0.6)
        #expect(content.superview === anchor)
        #expect(abs(content.convert(content.bounds, to: surface).minY - target.minY) < 0.1)
        #expect(abs(content.frame.height - target.height) < 0.1)
        #expect(handoffCount == 1)
        let previousCenter = content.convert(content.bounds, to: surface).midY
        anchor.frame = target.offsetBy(dx: 0, dy: 40)
        controller.retarget([.text: target.offsetBy(dx: 0, dy: 40)], at: started + 0.6)
        controller.advance(at: started + 0.66)
        #expect(content.convert(content.bounds, to: surface).midY > previousCenter)
        #expect(content.alpha > 0 && content.alpha < 1)
        controller.advance(at: started + 0.74)
        // 显现后的位移由真实目标承载，不重新启动一段追赶弹簧。
        controller.advance(at: started + 1.2)
        #expect(completionCount == 1)
        #expect(!controller.isActive)
        #expect(surface.subviews.isEmpty)
    }

    @Test("取消后旧发送身份不能覆盖新一轮，未落盘来源及时释放")
    func cancelledSubmissionCannotRebindNewFlight() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let oldID = UUID()
        let currentID = UUID()
        let imageSource = ChatSendPresentationSource.image(UUID())
        var preparedCount = 0
        var completionCount = 0
        func begin(_ id: UUID) {
            controller.begin(
                id: id,
                captures: [
                    .init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 20)),
                    .init(source: imageSource, content: UIView(), frame: CGRect(x: 20, y: 500, width: 72, height: 72))
                ],
                response: 0.3, damping: 1, backgrounds: [:],
                onMessagesPrepared: { _ in preparedCount += 1; return true },
                onSourcesRetired: { _ in },
                onHandoff: { _, _ in true }, onCompletion: { completionCount += 1 }
            )
        }
        begin(oldID)
        controller.cancel()
        #expect(surface.subviews.isEmpty)
        begin(currentID)
        controller.completeHandoff(for: oldID, sessionID: nil)
        #expect(controller.isActive)
        let presentation = ChatSendPresentation(
            sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()
        )
        controller.accept(presentation, for: oldID)
        #expect(preparedCount == 0)
        #expect(controller.capturedSources == Set([.text, imageSource]))
        controller.accept(presentation, for: currentID)
        #expect(preparedCount == 1)
        #expect(controller.capturedSources == Set([.text]))
        controller.cancel()
        #expect(completionCount == 0)
        #expect(surface.subviews.isEmpty)
    }

    @Test("较低且不均匀的几何回执仍能在持续滚动中对齐并完成发送")
    func movingLandingCompletesWithSparseGeometry() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let scenarios: [(pattern: [Int], phaseOffset: Double, hasRepeatedReports: Bool)] = [
            ([4], 0, false),
            ([3, 5, 2, 6], 0, false),
            ([4], 0.008, false),
            ([4], 0.008, true),
            ([3, 5, 2, 6], 0.008, true)
        ]
        for scenario in scenarios {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
            let surface = UIView(frame: window.bounds)
            window.addSubview(surface)
            let controller = ChatSendFlightController()
            controller.surface = surface
            installLayoutAnchors(on: controller, in: window)
            defer { controller.cancel() }
            var currentElapsed: Double = 0
            var handoffElapsed: Double?
            var handoffError: CGFloat?
            var completionCount = 0
            let target = CGRect(x: 200, y: 400, width: 120, height: 60)
            let velocity: CGFloat = scenario.phaseOffset > 0 ? -200 : -80
            let id = UUID()
            let sourceContent = UIView()
            controller.begin(
                id: id,
                captures: [.init(source: .text, content: sourceContent, frame: CGRect(x: 30, y: 780, width: 80, height: 30))],
                response: 0.5, damping: 0.9, backgrounds: [:],
                onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
                onHandoff: { id, sessionID in
                    handoffElapsed = currentElapsed
                    handoffError = sourceContent.superview.map {
                        abs($0.convert($0.bounds, to: surface).midY - (target.midY + velocity * CGFloat(currentElapsed)))
                    }
                    controller.completeHandoff(for: id, sessionID: sessionID)
                    return true
                },
                onCompletion: { completionCount += 1 }
            )
            let started = CACurrentMediaTime()
            let anchor = targetAnchor(for: controller, id: id, frame: target, in: window)
            controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started)
            var nextSampleFrame = 0
            var sampleIndex = 0
            for frame in 0...240 {
                currentElapsed = Double(frame) / 120
                anchor.frame = target.offsetBy(dx: 0, dy: velocity * CGFloat(currentElapsed))
                if frame == nextSampleFrame {
                    // 独立错相场景不补帧内回执：8ms × 200pt/s 会留下 1.6pt 的 raw-target 误差。
                    let sampledElapsed = max(0, currentElapsed - scenario.phaseOffset)
                    let sampledTarget = target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed))
                    controller.retarget(
                        [.text: sampledTarget],
                        at: started + sampledElapsed
                    )
                    if scenario.hasRepeatedReports, frame > 0 {
                        controller.retarget([.text: sampledTarget], at: started + sampledElapsed + 0.001)
                        controller.retarget(
                            [.text: target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed + 0.002) + 0.2)],
                            at: started + sampledElapsed + 0.002
                        )
                        controller.retarget(
                            [.text: target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed + 0.003))],
                            at: started + sampledElapsed + 0.003
                        )
                    }
                    nextSampleFrame += scenario.pattern[sampleIndex % scenario.pattern.count]
                    sampleIndex += 1
                }
                controller.advance(at: started + currentElapsed)
                if !controller.isActive { break }
            }
            #expect(try #require(
                handoffElapsed,
                "回执帧间隔=\(scenario.pattern)，错相=\(scenario.phaseOffset)，重复回执=\(scenario.hasRepeatedReports)，结束时刻=\(currentElapsed)，仍活动=\(controller.isActive)"
            ) < 1.6)
            #expect(
                try #require(handoffError) < 0.75,
                "回执帧间隔=\(scenario.pattern)，错相=\(scenario.phaseOffset)，重复回执=\(scenario.hasRepeatedReports)"
            )
            #expect(
                completionCount == 1,
                "回执帧间隔=\(scenario.pattern)，错相=\(scenario.phaseOffset)，重复回执=\(scenario.hasRepeatedReports)"
            )
        }
    }

    @Test("合法落点反复重定向不会被全局超时截断，缺失来源仍按时退出")
    func onlyMissingLandingsExpire() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1_800)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let missingSource = ChatSendPresentationSource.image(UUID())
        var retired: Set<ChatSendPresentationSource> = []
        var handoffCount = 0
        let id = UUID()
        controller.begin(
            id: id,
            captures: [
                .init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 1_500, width: 80, height: 30)),
                .init(source: missingSource, content: UIView(), frame: CGRect(x: 20, y: 1_400, width: 72, height: 72))
            ],
            response: 0.8, damping: 0.9, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { retired.formUnion($0) },
            onHandoff: { id, sessionID in
                handoffCount += 1
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            }, onCompletion: {}
        )
        let started = CACurrentMediaTime()
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID(), missingSource: UUID()], responseGroupID: UUID()), for: id, at: started)
        let anchor = targetAnchor(for: controller, id: id, frame: .zero, in: window)
        for frame in 0...204 {
            let elapsed = Double(frame) / 120
            if frame % 24 == 0 {
                let previousCenter = try #require(surface.subviews.first).center
                anchor.frame = CGRect(x: 200, y: frame % 48 == 0 ? 200 : 1_000, width: 140, height: 60)
                controller.retarget(
                    [.text: CGRect(x: 200, y: frame % 48 == 0 ? 200 : 1_000, width: 140, height: 60)],
                    at: started + elapsed
                )
                #expect(surface.subviews.first?.center == previousCenter)
            }
            controller.advance(at: started + elapsed)
        }
        #expect(retired == [missingSource])
        #expect(controller.capturedSources == [.text])
        #expect(handoffCount == 0)
        #expect(controller.isActive)

        for frame in 205...480 {
            controller.advance(at: started + Double(frame) / 120)
            if !controller.isActive { break }
        }
        #expect(handoffCount == 1)
        #expect(!controller.isActive)
    }

    @Test("移动目标突然停下后停止外推并在真实位置交接")
    func stoppedLandingConvergesToActualGeometry() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let target = CGRect(x: 200, y: 300, width: 120, height: 60)
        let stoppedTarget = target.offsetBy(dx: 0, dy: -24)
        var handoffError: CGFloat?
        let id = UUID()
        let sourceContent = UIView()
        controller.begin(
            id: id,
            captures: [.init(source: .text, content: sourceContent, frame: CGRect(x: 20, y: 780, width: 80, height: 30))],
            response: 0.6, damping: 0.9, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { id, sessionID in
                handoffError = sourceContent.superview.map { abs($0.convert($0.bounds, to: surface).midY - stoppedTarget.midY) }
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            },
            onCompletion: {}
        )
        let started = CACurrentMediaTime()
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started)
        let anchor = targetAnchor(for: controller, id: id, frame: target, in: window)
        for frame in 0...300 {
            let elapsed = Double(frame) / 120
            anchor.frame = target.offsetBy(dx: 0, dy: CGFloat(-80 * min(elapsed, 0.3)))
            if frame <= 36, frame % 4 == 0 {
                controller.retarget([.text: target.offsetBy(dx: 0, dy: CGFloat(-80 * elapsed))], at: started + elapsed)
            }
            controller.advance(at: started + elapsed)
            if !controller.isActive { break }
        }
        #expect(try #require(handoffError) < 0.5)
        #expect(!controller.isActive)
    }

    @Test("不均匀错相回执停止后，同值布局通知不延长外推，内容在真实终点交接")
    func irregularLandingStopsDespiteRepeatedReports() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let pattern = [3, 5, 2, 6]
        let phaseOffset = 0.008
        let velocity: CGFloat = -200
        let target = CGRect(x: 200, y: 400, width: 120, height: 60)
        // 第 32 帧刚收到跨 6 帧的回执，确保停止前已记录 50ms 的较慢采样间隔。
        let stopFrame = 32
        let lastReportedElapsed = Double(stopFrame) / 120 - phaseOffset + 0.003
        let stoppedTarget = target.offsetBy(dx: 0, dy: velocity * CGFloat(lastReportedElapsed))
        var currentElapsed: Double = 0
        var handoffElapsed: Double?
        var handoffError: CGFloat?
        var handoffCount = 0
        var completionCount = 0
        let id = UUID()
        let sourceContent = UIView()
        controller.begin(
            id: id,
            captures: [.init(source: .text, content: sourceContent, frame: CGRect(x: 30, y: 780, width: 80, height: 30))],
            response: 0.6, damping: 0.9, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { id, sessionID in
                handoffCount += 1
                handoffElapsed = currentElapsed
                handoffError = sourceContent.superview.map { abs($0.convert($0.bounds, to: surface).midY - stoppedTarget.midY) }
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            },
            onCompletion: { completionCount += 1 }
        )
        let started = CACurrentMediaTime()
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started)
        let anchor = targetAnchor(for: controller, id: id, frame: target, in: window)
        var nextSampleFrame = 0
        var sampleIndex = 0
        for frame in 0...stopFrame {
            currentElapsed = Double(frame) / 120
            anchor.frame = target.offsetBy(dx: 0, dy: velocity * CGFloat(min(currentElapsed, lastReportedElapsed)))
            if frame == nextSampleFrame {
                let sampledElapsed = max(0, currentElapsed - phaseOffset)
                let sampledTarget = target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed))
                controller.retarget([.text: sampledTarget], at: started + sampledElapsed)
                if frame > 0 {
                    controller.retarget([.text: sampledTarget], at: started + sampledElapsed + 0.001)
                    controller.retarget(
                        [.text: target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed + 0.002) + 0.2)],
                        at: started + sampledElapsed + 0.002
                    )
                    controller.retarget(
                        [.text: target.offsetBy(dx: 0, dy: velocity * CGFloat(sampledElapsed + 0.003))],
                        at: started + sampledElapsed + 0.003
                    )
                }
                nextSampleFrame += pattern[sampleIndex % pattern.count]
                sampleIndex += 1
            }
            controller.advance(at: started + currentElapsed)
        }
        #expect(handoffCount == 0)
        #expect(controller.isActive)
        anchor.frame = stoppedTarget

        for frame in (stopFrame + 1)...300 {
            currentElapsed = Double(frame) / 120
            if frame % 4 == 0 {
                controller.retarget([.text: stoppedTarget], at: started + currentElapsed)
            }
            controller.advance(at: started + currentElapsed)
            if !controller.isActive { break }
        }
        #expect(try #require(handoffElapsed) < 1.6)
        #expect(try #require(handoffError) < 0.5)
        #expect(handoffCount == 1)
        #expect(completionCount == 1)
        #expect(surface.subviews.isEmpty)
    }

    @Test("首次屏外落点等待进入视口，持续屏外的来源仍按原截止退役", arguments: [false, true])
    func initialOffscreenLandingWaitsForVisibility(becomesVisible: Bool) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let id = UUID()
        let sessionID = UUID()
        let sourceFrame = CGRect(x: 20, y: 800, width: 80, height: 30)
        let target = CGRect(x: 130, y: 300, width: 180, height: 60)
        let started: CFTimeInterval = 100
        var preparedCount = 0
        var handoffCount = 0
        var handoffError: CGFloat?
        var completionCount = 0
        var retirementBatches: [Set<ChatSendPresentationSource>] = []
        let sourceContent = UIView()
        controller.begin(
            id: id, sessionID: sessionID,
            captures: [.init(source: .text, content: sourceContent, frame: sourceFrame)],
            response: 0.35, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in preparedCount += 1; return true },
            onSourcesRetired: { retirementBatches.append($0) },
            onHandoff: { id, sessionID in
                handoffCount += 1
                handoffError = sourceContent.superview.map { abs($0.convert($0.bounds, to: surface).midY - target.midY) }
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            }, onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started)
        controller.updateDisplayedSources([.text], for: id, sessionID: sessionID, at: started)
        let flyingView = try #require(surface.subviews.first)
        controller.retarget([.text: target.offsetBy(dx: 0, dy: 650)], at: started + 0.1)
        controller.advance(at: started + 1.4)
        #expect(preparedCount == 1)
        #expect(controller.isActive && controller.capturedSources == [.text])
        #expect(surface.subviews.first === flyingView && flyingView.frame.maxY < sourceFrame.maxY)
        #expect(handoffCount == 0 && completionCount == 0 && retirementBatches.isEmpty)

        if becomesVisible {
            let beforeRetarget = flyingView.frame
            targetAnchor(for: controller, id: id, frame: target, in: window)
            controller.retarget([.text: target], at: started + 1.5)
            #expect(flyingView.frame == beforeRetarget)
            // 截止前已得到可见落点，之后不能再被缺落点计时淘汰。
            controller.advance(at: started + 3)
            #expect(handoffCount == 1 && completionCount == 0)
            #expect(try #require(handoffError) < 0.5)
            #expect(retirementBatches.isEmpty && flyingView.alpha == 1)
            controller.advance(at: started + 3.13)
        } else {
            // 屏外 frame 反复上报不能延长原截止，也不能被当成已接受的落点。
            controller.retarget([.text: target.offsetBy(dx: 0, dy: -400)], at: started + 1.59)
            controller.advance(at: started + 1.59)
            #expect(controller.isActive && retirementBatches.isEmpty)
            controller.retarget([.text: target.offsetBy(dx: 0, dy: 650)], at: started + 1.61)
            #expect(handoffCount == 0 && retirementBatches == [[.text]])
        }
        #expect(completionCount == 1)
        #expect(!controller.isActive && surface.subviews.isEmpty)
        controller.retarget([.text: target], at: started + 4)
        controller.advance(at: started + 4)
        #expect(completionCount == 1 && !controller.isActive && surface.subviews.isEmpty)
    }

    @Test("接受过可见落点的单个来源离屏立即报告退役，其他来源继续且最后退出只完成一次")
    func offscreenSourcesRetireIndividually() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let imageSource = ChatSendPresentationSource.image(UUID())
        var retirementBatches: [Set<ChatSendPresentationSource>] = []
        var completionCount = 0
        let id = UUID()
        controller.begin(
            id: id,
            captures: [
                .init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 30)),
                .init(source: imageSource, content: UIView(), frame: CGRect(x: 20, y: 500, width: 72, height: 72))
            ],
            response: 0.3, damping: 1, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { retirementBatches.append($0) },
            onHandoff: { _, _ in true }, onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID(), imageSource: UUID()], responseGroupID: UUID()), for: id)
        controller.retarget([
            .text: CGRect(x: 20, y: 300, width: 80, height: 30),
            imageSource: CGRect(x: 20, y: 400, width: 72, height: 72)
        ])
        #expect(retirementBatches.isEmpty && surface.subviews.count == 2)
        controller.retarget([.text: CGRect(x: 20, y: -100, width: 80, height: 30)])
        #expect(retirementBatches == [[.text]])
        #expect(controller.capturedSources == [imageSource])
        #expect(completionCount == 0)
        controller.retarget([imageSource: CGRect(x: 20, y: 800, width: 72, height: 72)])
        #expect(retirementBatches == [[.text], [imageSource]])
        #expect(completionCount == 1)
        #expect(surface.subviews.isEmpty)
    }

    @Test("半露出的图片来源保留完整内容并连续展开")
    func clippedImageSourceKeepsItsFullContent() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let imageSource = ChatSendPresentationSource.image(UUID())
        let imageView = UIImageView()
        let sourceContentFrame = CGRect(x: -42, y: 0, width: 72, height: 72)
        let started = CACurrentMediaTime()
        let id = UUID()
        controller.begin(
            id: id,
            captures: [.init(
                source: imageSource, content: imageView,
                frame: CGRect(x: 0, y: 500, width: 30, height: 72),
                sourceContentFrame: sourceContentFrame
            )],
            response: 0.2, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in }, onHandoff: { _, _ in true }, onCompletion: {}
        )
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [imageSource: UUID()], responseGroupID: UUID()), for: id, at: started)
        targetAnchor(for: controller, id: id, source: imageSource, frame: CGRect(x: 200, y: 100, width: 144, height: 144), in: window)
        #expect(imageView.frame == sourceContentFrame)
        controller.retarget([imageSource: CGRect(x: 200, y: 100, width: 144, height: 144)], at: started)
        controller.advance(at: started)
        #expect(imageView.frame == sourceContentFrame)
        controller.advance(at: started + 0.6)
        #expect(abs(imageView.frame.width - 144) < 0.1)
        #expect(abs(imageView.frame.minX) < 0.1)
        #expect(try #require(imageView.superview).clipsToBounds)
    }

    @Test("原生表面离开窗口后结束飞行且完成回执只发送一次")
    func detachedSurfaceCompletesWithoutLeavingSnapshots() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        var completionCount = 0
        controller.begin(
            id: UUID(),
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in }, onHandoff: { _, _ in true },
            onCompletion: { completionCount += 1 }
        )
        surface.removeFromSuperview()
        controller.advance(at: CACurrentMediaTime())
        controller.advance(at: CACurrentMediaTime())
        #expect(completionCount == 1)
        #expect(!controller.isActive)
        #expect(surface.subviews.isEmpty)
    }

    @Test("消息身份与落点延迟时来源已离开输入区，新输入保留且重定向速度连续", arguments: [0.08, 0.8])
    func delayedLandingLeavesComposerWithoutHidingNewInput(arrival: Double) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        controller.composerAnchor?.frame = CGRect(x: 0, y: 650, width: 390, height: 250)
        let sourceFrame = CGRect(x: 30, y: 800, width: 220, height: 30)
        let capturedText = UILabel()
        capturedText.text = "本轮发送的内容"
        let newInput = UITextField(frame: sourceFrame)
        newInput.text = "发送后新输入的内容"
        window.addSubview(newInput)
        let id = UUID()
        let sessionID = UUID()
        let started: CFTimeInterval = 100
        var preparedCount = 0
        var handoffCount = 0
        controller.begin(
            id: id, sessionID: sessionID,
            captures: [.init(source: .text, content: capturedText, frame: sourceFrame)],
            response: 0.6, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in preparedCount += 1; return true }, onSourcesRetired: { _ in },
            onHandoff: { id, sessionID in
                handoffCount += 1
                controller.completeHandoff(for: id, sessionID: sessionID)
                return true
            }, onCompletion: {}
        )
        let flyingView = try #require(capturedText.superview)
        #expect(flyingView.frame == sourceFrame)
        let sampleInterval = 0.00001
        controller.advance(at: started + arrival - sampleInterval)
        let beforePrevious = flyingView.center.y
        controller.advance(at: started + arrival)
        let beforeRetarget = flyingView.center.y
        let velocityBefore = (beforeRetarget - beforePrevious) / sampleInterval
        #expect(beforeRetarget < sourceFrame.midY)
        #expect(velocityBefore < -1)
        #expect(preparedCount == 0 && handoffCount == 0)
        if arrival > 0.5 { #expect(flyingView.frame.maxY < 651) }

        controller.accept(.init(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started + arrival)
        #expect(preparedCount == 1)
        let target = CGRect(x: 130, y: 300, width: 200, height: 80)
        targetAnchor(for: controller, id: id, frame: target, in: window)
        controller.retarget([.text: target], at: started + arrival)
        #expect(flyingView.center.y == beforeRetarget)
        controller.advance(at: started + arrival + sampleInterval)
        let velocityAfter = (flyingView.center.y - beforeRetarget) / sampleInterval
        #expect(abs(velocityAfter - velocityBefore) < 0.3)
        #expect(newInput.text == "发送后新输入的内容")
        #expect(newInput.frame == sourceFrame && newInput.alpha == 1)
        #expect(newInput.isEnabled && newInput.isUserInteractionEnabled)
        #expect(!surface.isUserInteractionEnabled)
        controller.advance(at: started + arrival + 1.5)
        #expect(flyingView.frame.maxY < 650)
        #expect(handoffCount == 1)
        controller.advance(at: started + arrival + 1.64)
        #expect(!controller.isActive)
    }

    @Test("首帧晚到时身份或落点回执也会先淘汰过期来源", arguments: ["prepared", "target", "frame"])
    func lateFirstCallbackCannotReviveExpiredSource(ingress: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let id = UUID()
        let sessionID = UUID()
        let started: CFTimeInterval = 100
        var preparedCount = 0
        var completionCount = 0
        var retirementBatches: [Set<ChatSendPresentationSource>] = []
        controller.begin(
            id: id, sessionID: sessionID,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.5, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in preparedCount += 1; return true }, onSourcesRetired: { retirementBatches.append($0) },
            onHandoff: { _, _ in true }, onCompletion: { completionCount += 1 }
        )
        let presentation = ChatSendPresentation(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID())
        let target = CGRect(x: 130, y: 300, width: 180, height: 60)
        // 三个入口都直接到达截止之后，此前故意不推进显示帧。
        switch ingress {
        case "prepared": controller.accept(presentation, for: id, at: started + 1.7)
        case "target": controller.retarget([.text: target], at: started + 1.7)
        default: controller.advance(at: started + 1.7)
        }
        controller.accept(presentation, for: id, at: started + 1.8)
        controller.retarget([.text: target], at: started + 1.8)
        controller.advance(at: started + 1.9)
        #expect(preparedCount == 0)
        #expect(retirementBatches == [[.text]])
        #expect(completionCount == 1)
        #expect(!controller.isActive && surface.subviews.isEmpty)

        // 截止前已获得真实落点时，即便第一帧很晚才推进也不能被缺落点超时误杀。
        let nextID = UUID()
        controller.begin(
            id: nextID, sessionID: sessionID,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.5, damping: 1, backgrounds: [:], at: started + 10,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { retirementBatches.append($0) },
            onHandoff: { _, _ in true }, onCompletion: { completionCount += 1 }
        )
        controller.accept(presentation, for: nextID, at: started + 10)
        targetAnchor(for: controller, id: nextID, frame: target, in: window)
        controller.retarget([.text: target], at: started + 11.59)
        controller.advance(at: started + 13)
        #expect(controller.isActive && controller.capturedSources == [.text])
        #expect(retirementBatches == [[.text]] && completionCount == 1)
    }

    @Test("真实层完成回执和当前落点同时就绪后才淡出，旧会话回执不能提前退役")
    func handoffWaitsForCurrentPresentationAndAlignment() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let id = UUID()
        let sessionID = UUID()
        let started: CFTimeInterval = 100
        var handoffCount = 0
        var completionCount = 0
        controller.begin(
            id: id, sessionID: sessionID,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [:], at: started,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { _, _ in handoffCount += 1; return true }, onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: started)
        let target = CGRect(x: 130, y: 300, width: 180, height: 60)
        let anchor = targetAnchor(for: controller, id: id, frame: target, in: window)
        let flyingView = try #require(surface.subviews.first)
        controller.retarget([.text: target], at: started)
        controller.advance(at: started + 0.8)
        #expect(flyingView.superview === anchor)
        #expect(handoffCount == 1)
        controller.advance(at: started + 1.3)
        #expect(controller.isActive && flyingView.alpha == 1)
        #expect(completionCount == 0)
        controller.completeHandoff(for: UUID(), sessionID: sessionID)
        controller.completeHandoff(for: id, sessionID: UUID())
        controller.advance(at: started + 1.4)
        #expect(flyingView.alpha == 1 && completionCount == 0)

        let movedTarget = target.offsetBy(dx: 0, dy: 100)
        anchor.frame = movedTarget
        controller.retarget([.text: movedTarget], at: started + 1.4)
        controller.completeHandoff(for: id, sessionID: sessionID)
        controller.advance(at: started + 1.45)
        #expect(flyingView.alpha == 1 && completionCount == 0)
        #expect(abs(flyingView.convert(flyingView.bounds, to: surface).midY - movedTarget.midY) < 0.5)
        controller.advance(at: started + 1.49)
        #expect(flyingView.alpha > 0 && flyingView.alpha < 1)
        anchor.frame = movedTarget.offsetBy(dx: 0, dy: 20)
        controller.retarget([.text: anchor.frame], at: started + 1.49)
        controller.completeHandoff(for: id, sessionID: sessionID)
        controller.advance(at: started + 1.53)
        #expect(flyingView.convert(flyingView.bounds, to: surface) == anchor.frame)
        #expect(flyingView.alpha < 0.7)
        controller.advance(at: started + 1.6)
        #expect(completionCount == 1 && handoffCount == 1)
        #expect(!controller.isActive && surface.subviews.isEmpty && flyingView.superview == nil)

        let nextID = UUID()
        controller.begin(
            id: nextID, sessionID: sessionID,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [:], at: started + 4,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { _, _ in handoffCount += 1; return true }, onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: nextID, at: started + 4)
        targetAnchor(for: controller, id: nextID, frame: target, in: window)
        let nextFlyingView = try #require(surface.subviews.first)
        controller.retarget([.text: target], at: started + 4)
        controller.advance(at: started + 4.8)
        #expect(handoffCount == 2 && controller.isActive)
        controller.cancel()
        controller.completeHandoff(for: nextID, sessionID: sessionID)
        controller.advance(at: started + 5)
        #expect(!controller.isActive && surface.subviews.isEmpty && nextFlyingView.superview == nil)
        #expect(completionCount == 1)
    }

    @Test("目标锚点按发送身份和原生实例注销，移除后不会继续隐藏真实消息")
    func nativeTargetIdentityAndLifetimeArePreserved() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let id = UUID()
        let frame = CGRect(x: 120, y: 300, width: 180, height: 60)
        var handoffCount = 0
        var completionCount = 0
        var retired: Set<ChatSendPresentationSource> = []
        controller.begin(
            id: id, captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [:], at: 100,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { retired.formUnion($0) },
            onHandoff: { _, _ in handoffCount += 1; return true }, onCompletion: { completionCount += 1 }
        )
        controller.accept(.init(sessionID: UUID(), messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: 100)
        let oldAnchor = targetAnchor(for: controller, id: id, frame: frame, in: window)
        var anchor: ChatSendFlightTargetCarrier? = targetAnchor(for: controller, id: id, frame: frame, in: window)
        let target = ChatSendFlightTarget(flightID: id, source: .text)
        controller.unregisterTarget(oldAnchor, for: target)
        controller.registerTarget(oldAnchor, for: ChatSendFlightTarget(flightID: UUID(), source: .text))
        if let anchor { controller.unregisterTarget(anchor, for: ChatSendFlightTarget(flightID: UUID(), source: .text)) }
        // 锚点有效后，迟到的屏外布局终值不能覆盖呈现采样或错误退役来源。
        controller.retarget([.text: frame.offsetBy(dx: 0, dy: 1_000)], at: 100)
        let flying = try #require(surface.subviews.first)
        controller.advance(at: 100.8)
        #expect(handoffCount == 1 && retired.isEmpty)
        #expect(flying.superview === anchor)
        anchor?.frame = frame.insetBy(dx: -10, dy: -15).offsetBy(dx: 20, dy: 30)
        // 此虚拟时钟用例显式交给 carrier 的布局入口；真实动画相位由独立宿主像素用例验证。
        anchor?.layoutSubviews()
        controller.advance(at: 100.85)
        #expect(flying.convert(flying.bounds, to: surface) == anchor?.frame)
        weak let released = anchor
        anchor?.removeFromSuperview()
        anchor = nil
        // UIKit/当前 CA 事务可短暂保留刚拆除的视图；释放验证需跨过真实 RunLoop，而非要求同步 deinit。
        let releaseDeadline = ContinuousClock.now + .seconds(1)
        while released != nil, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(released == nil)
        controller.advance(at: 100.9)
        #expect(retired == [.text] && completionCount == 1)
        #expect(!controller.isActive && surface.subviews.isEmpty)
    }

    @Test("页面拒绝交接时立即释放原生来源并通过完成回执放行真实消息")
    func rejectedHandoffReleasesPresentation() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let id = UUID()
        let sessionID = UUID()
        var handoffCount = 0
        var completionCount = 0
        var hiddenMessage = true
        controller.begin(
            id: id, sessionID: sessionID,
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
            response: 0.3, damping: 1, backgrounds: [:], at: 100,
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
            onHandoff: { _, _ in handoffCount += 1; return false },
            onCompletion: { completionCount += 1; hiddenMessage = false }
        )
        controller.accept(.init(sessionID: sessionID, messageIDsBySource: [.text: UUID()], responseGroupID: UUID()), for: id, at: 100)
        targetAnchor(for: controller, id: id, frame: CGRect(x: 130, y: 300, width: 180, height: 60), in: window)
        controller.retarget([.text: CGRect(x: 130, y: 300, width: 180, height: 60)], at: 100)
        controller.advance(at: 100.8)
        controller.completeHandoff(for: id, sessionID: sessionID)
        controller.advance(at: 101)
        #expect(handoffCount == 1 && completionCount == 1)
        #expect(!hiddenMessage && !controller.isActive && surface.subviews.isEmpty)
    }

    @Test("表面拆除或替换延后释放SwiftUI所有权，旧表面和旧回执不能取消新发送", arguments: [false, true])
    func surfaceLifecycleReleasesOnlyItsOwnFlight(replacementComesFirst: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        let oldSurface = UIView(frame: window.bounds)
        let nextSurface = UIView(frame: window.bounds)
        window.addSubview(oldSurface)
        window.addSubview(nextSurface)
        let controller = ChatSendFlightController()
        controller.attach(to: oldSurface)
        installLayoutAnchors(on: controller, in: window)
        defer { controller.cancel() }
        let coordinator = ChatSendFlightSurface.Coordinator(controller: controller)
        let oldID = UUID()
        let nextID = UUID()
        var visibleFlightID: UUID? = oldID
        var completionCount = 0

        await withCheckedContinuation { continuation in
            controller.begin(
                id: oldID,
                captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
                response: 0.3, damping: 1, backgrounds: [:],
                onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in }, onHandoff: { _, _ in true },
                onCompletion: {
                    completionCount += 1
                    // 与真实页面相同，迟到的旧发送完成不能清掉新一轮的显示状态。
                    if visibleFlightID == oldID { visibleFlightID = nil }
                    continuation.resume()
                }
            )
            if replacementComesFirst {
                controller.attach(to: nextSurface)
            } else {
                ChatSendFlightSurface.dismantleUIView(oldSurface, coordinator: coordinator)
            }
            #expect(!controller.isActive && oldSurface.subviews.isEmpty)
            #expect(completionCount == 0 && visibleFlightID == oldID)
            controller.attach(to: nextSurface)
            visibleFlightID = nextID
            controller.begin(
                id: nextID,
                captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 800, width: 80, height: 30))],
                response: 0.3, damping: 1, backgrounds: [:],
                onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in }, onHandoff: { _, _ in true },
                onCompletion: { completionCount += 1 }
            )
            ChatSendFlightSurface.dismantleUIView(oldSurface, coordinator: coordinator)
            #expect(controller.isActive && controller.surface === nextSurface)
            #expect(nextSurface.subviews.count == 1)
        }
        #expect(completionCount == 1 && visibleFlightID == nextID)
        #expect(controller.isActive && controller.surface === nextSurface)
        #expect(nextSurface.subviews.count == 1)
    }
}
