import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送内容交接", .serialized)
@MainActor
struct ChatSendFlightTests {
    @Test("半露出的落点保留完整几何，淡出期间继续接续目标位移")
    func handoffTracksMovingUnclippedTarget() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        defer { controller.cancel() }
        var handoffCount = 0
        var completionCount = 0
        controller.begin(
            id: UUID(),
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 20))],
            response: 0.2, damping: 1, colors: [UIColor.blue.cgColor, UIColor.blue.cgColor],
            onMessagesPrepared: { _ in },
            onSourcesRetired: { _ in },
            onHandoff: { handoffCount += 1 },
            onCompletion: { completionCount += 1 }
        )
        let target = CGRect(x: 120, y: -100, width: 180, height: 300)
        controller.retarget([.text: target])
        let started = CACurrentMediaTime()
        controller.advance(at: started)
        controller.advance(at: started + 0.6)
        let content = try #require(surface.subviews.first)
        #expect(abs(content.frame.minY - target.minY) < 0.1)
        #expect(abs(content.frame.height - target.height) < 0.1)
        #expect(handoffCount == 1)
        let previousCenter = content.center
        controller.retarget([.text: target.offsetBy(dx: 0, dy: 40)], at: started + 0.6)
        controller.advance(at: started + 0.66)
        #expect(content.center.y > previousCenter.y)
        #expect(content.alpha > 0 && content.alpha < 1)
        controller.advance(at: started + 0.74)
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
                response: 0.3, damping: 1, colors: [],
                onMessagesPrepared: { _ in preparedCount += 1 },
                onSourcesRetired: { _ in },
                onHandoff: {}, onCompletion: { completionCount += 1 }
            )
        }
        begin(oldID)
        controller.cancel()
        #expect(surface.subviews.isEmpty)
        begin(currentID)
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
            defer { controller.cancel() }
            var currentElapsed: Double = 0
            var handoffElapsed: Double?
            var handoffError: CGFloat?
            var completionCount = 0
            let target = CGRect(x: 200, y: 400, width: 120, height: 60)
            let velocity: CGFloat = scenario.phaseOffset > 0 ? -200 : -80
            controller.begin(
                id: UUID(),
                captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 30, y: 780, width: 80, height: 30))],
                response: 0.5, damping: 0.9, colors: [],
                onMessagesPrepared: { _ in }, onSourcesRetired: { _ in },
                onHandoff: {
                    handoffElapsed = currentElapsed
                    handoffError = surface.subviews.first.map {
                        abs($0.center.y - (target.midY + velocity * CGFloat(currentElapsed)))
                    }
                },
                onCompletion: { completionCount += 1 }
            )
            let started = CACurrentMediaTime()
            var nextSampleFrame = 0
            var sampleIndex = 0
            for frame in 0...240 {
                currentElapsed = Double(frame) / 120
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
            #expect(try #require(handoffElapsed) < 1.6)
            #expect(try #require(handoffError) < 0.75)
            #expect(completionCount == 1)
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
        defer { controller.cancel() }
        let missingSource = ChatSendPresentationSource.image(UUID())
        var retired: Set<ChatSendPresentationSource> = []
        var handoffCount = 0
        controller.begin(
            id: UUID(),
            captures: [
                .init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 1_500, width: 80, height: 30)),
                .init(source: missingSource, content: UIView(), frame: CGRect(x: 20, y: 1_400, width: 72, height: 72))
            ],
            response: 0.8, damping: 0.9, colors: [],
            onMessagesPrepared: { _ in }, onSourcesRetired: { retired.formUnion($0) },
            onHandoff: { handoffCount += 1 }, onCompletion: {}
        )
        let started = CACurrentMediaTime()
        for frame in 0...204 {
            let elapsed = Double(frame) / 120
            if frame % 24 == 0 {
                let previousCenter = try #require(surface.subviews.first).center
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
        defer { controller.cancel() }
        let target = CGRect(x: 200, y: 300, width: 120, height: 60)
        let stoppedTarget = target.offsetBy(dx: 0, dy: -24)
        var handoffError: CGFloat?
        controller.begin(
            id: UUID(),
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 780, width: 80, height: 30))],
            response: 0.6, damping: 0.9, colors: [],
            onMessagesPrepared: { _ in }, onSourcesRetired: { _ in },
            onHandoff: { handoffError = surface.subviews.first.map { abs($0.center.y - stoppedTarget.midY) } },
            onCompletion: {}
        )
        let started = CACurrentMediaTime()
        for frame in 0...300 {
            let elapsed = Double(frame) / 120
            if frame <= 36, frame % 4 == 0 {
                controller.retarget([.text: target.offsetBy(dx: 0, dy: CGFloat(-80 * elapsed))], at: started + elapsed)
            }
            controller.advance(at: started + elapsed)
            if !controller.isActive { break }
        }
        #expect(try #require(handoffError) < 0.5)
        #expect(!controller.isActive)
    }

    @Test("单个来源离屏立即报告退役，其他来源继续且最后退出只完成一次")
    func offscreenSourcesRetireIndividually() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let surface = UIView(frame: window.bounds)
        window.addSubview(surface)
        let controller = ChatSendFlightController()
        controller.surface = surface
        let imageSource = ChatSendPresentationSource.image(UUID())
        var retirementBatches: [Set<ChatSendPresentationSource>] = []
        var completionCount = 0
        controller.begin(
            id: UUID(),
            captures: [
                .init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 30)),
                .init(source: imageSource, content: UIView(), frame: CGRect(x: 20, y: 500, width: 72, height: 72))
            ],
            response: 0.3, damping: 1, colors: [],
            onMessagesPrepared: { _ in }, onSourcesRetired: { retirementBatches.append($0) },
            onHandoff: {}, onCompletion: { completionCount += 1 }
        )
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
        defer { controller.cancel() }
        let imageSource = ChatSendPresentationSource.image(UUID())
        let imageView = UIImageView()
        let sourceContentFrame = CGRect(x: -42, y: 0, width: 72, height: 72)
        controller.begin(
            id: UUID(),
            captures: [.init(
                source: imageSource, content: imageView,
                frame: CGRect(x: 0, y: 500, width: 30, height: 72),
                sourceContentFrame: sourceContentFrame
            )],
            response: 0.2, damping: 1, colors: [],
            onMessagesPrepared: { _ in }, onSourcesRetired: { _ in }, onHandoff: {}, onCompletion: {}
        )
        #expect(imageView.frame == sourceContentFrame)
        let started = CACurrentMediaTime()
        controller.retarget([imageSource: CGRect(x: 200, y: 100, width: 144, height: 144)], at: started)
        controller.advance(at: started)
        #expect(imageView.frame == sourceContentFrame)
        controller.advance(at: started + 0.6)
        #expect(abs(imageView.frame.width - 144) < 0.1)
        #expect(abs(imageView.frame.minX) < 0.1)
        #expect(try #require(surface.subviews.first).clipsToBounds)
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
        var completionCount = 0
        controller.begin(
            id: UUID(),
            captures: [.init(source: .text, content: UIView(), frame: CGRect(x: 20, y: 600, width: 80, height: 30))],
            response: 0.3, damping: 1, colors: [],
            onMessagesPrepared: { _ in }, onSourcesRetired: { _ in }, onHandoff: {},
            onCompletion: { completionCount += 1 }
        )
        surface.removeFromSuperview()
        controller.advance(at: CACurrentMediaTime())
        controller.advance(at: CACurrentMediaTime())
        #expect(completionCount == 1)
        #expect(!controller.isActive)
        #expect(surface.subviews.isEmpty)
    }
}
