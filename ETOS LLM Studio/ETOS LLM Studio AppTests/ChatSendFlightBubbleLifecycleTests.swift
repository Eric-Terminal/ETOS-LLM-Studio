import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("真实消息气泡的发送承载生命周期", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatSendFlightBubbleLifecycleTests {
    @Test("显现期间准备好 Markdown 并更新布局版本，不拆除正在交接的承载层")
    func markdownPreparationPreservesTheActiveCarrier() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let state = FlightBubbleLifecycleState()
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: state.messageState.message.content)
        let host = UIHostingController(rootView: FlightBubbleLifecycleHost(state: state))
        host.safeAreaRegions = []
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = window.bounds
        let surface = UIView(frame: window.bounds)
        surface.isUserInteractionEnabled = false
        container.view.addSubview(surface)
        let viewport = UIView(frame: window.bounds)
        let composer = UIView(frame: CGRect(x: 0, y: 720, width: 402, height: 154))
        container.view.addSubview(viewport)
        container.view.addSubview(composer)
        state.controller.surface = surface
        state.controller.viewportAnchor = viewport
        state.controller.composerAnchor = composer
        state.controller.composerContentAnchor = composer
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded()
        defer {
            state.controller.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        var handoffCount = 0
        var completionCount = 0
        var acknowledged = false
        var retired = false
        weak var handoffCarrier: ChatSendFlightTargetCarrier?
        let initialRevision = state.messageState.layoutRevision
        state.controller.begin(
            id: state.flightID, sessionID: state.sessionID,
            captures: [.init(source: .text, content: UILabel(), frame: CGRect(x: 160, y: 700, width: 180, height: 36))],
            response: 0.3, damping: 1, backgrounds: [:],
            onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in retired = true },
            onHandoff: { id, sessionID in
                handoffCount += 1
                handoffCarrier = self.carrier(in: host.view)
                // 真实业务会分别发布准备结果与布局版本；两者都不能改变同一次发送的承载身份。
                state.prepared = prepared
                state.messageState.invalidateLayoutAfterRendererHandoff()
                withAnimation(.easeOut(duration: 0.12), completionCriteria: .removed) {
                    state.opacity = 1
                } completion: {
                    acknowledged = true
                    state.controller.completeHandoff(for: id, sessionID: sessionID)
                }
                return true
            },
            onCompletion: {
                completionCount += 1
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    state.target = nil
                    state.opacity = 1
                }
            }
        )
        let floating = try #require(surface.subviews.first)
        state.target = ChatSendFlightTarget(flightID: state.flightID, source: .text)
        state.controller.accept(.init(
            sessionID: state.sessionID,
            messageIDsBySource: [.text: state.messageState.id], responseGroupID: UUID()
        ), for: state.flightID)
        state.controller.updateDisplayedSources([.text], for: state.flightID, sessionID: state.sessionID)

        var retainedDuringAppearance = false
        let deadline = ContinuousClock.now + .seconds(3)
        while completionCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(8))
            if handoffCount == 1, completionCount == 0 {
                let current = carrier(in: host.view)
                #expect(current === handoffCarrier)
                if !acknowledged, floating.superview === current { retainedDuringAppearance = true }
            }
        }
        try #require(handoffCount == 1 && completionCount == 1 && acknowledged && !retired)
        #expect(retainedDuringAppearance)
        #expect(state.prepared == prepared && state.messageState.layoutRevision > initialRevision)
        #expect(state.opacity == 1 && !state.controller.isActive && floating.superview == nil)
        #expect(state.target == nil)
        // 生产完成回调会清除临时目标；承载层应退出，而不是靠永远保留目标维持正文身份。
        let cleanupDeadline = ContinuousClock.now + .seconds(1)
        while carrier(in: host.view) != nil, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(carrier(in: host.view) == nil)
    }

    @Test("清除发送目标只拆临时承载层，已显现正文的原生身份和屏幕位置保持不变")
    func completedFlightPreservesNativeContent() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let state = FlightContentCompletionState()
        let host = UIHostingController(rootView: FlightContentCompletionHost(state: state))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let content = try #require(state.content)
        try #require(content.window === window && carrier(in: host.view) != nil)
        let initialFrame = content.convert(content.bounds, to: window)
        try #require(initialFrame.width > 0 && initialFrame.height > 0)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.target = nil
            state.opacity = 1
        }

        // 只等待 SwiftUI 消费真实状态变化；不强制布局，也不使用产品探针维持正文实例。
        var maximumFrameError: CGFloat = 0
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            try await Task.sleep(for: .milliseconds(8))
            let current = try #require(state.content)
            #expect(current === content && current.window === window)
            let frame = current.convert(current.bounds, to: window)
            maximumFrameError = max(maximumFrameError, max(
                max(abs(frame.minX - initialFrame.minX), abs(frame.minY - initialFrame.minY)),
                max(abs(frame.width - initialFrame.width), abs(frame.height - initialFrame.height))))
        } while carrier(in: host.view) != nil && ContinuousClock.now < deadline
        #expect(carrier(in: host.view) == nil)
        #expect(state.creationCount == 1 && state.target == nil && state.opacity == 1)
        #expect(maximumFrameError <= 0.5)
    }

    private func carrier(in view: UIView) -> ChatSendFlightTargetCarrier? {
        if let carrier = view as? ChatSendFlightTargetCarrier { return carrier }
        return view.subviews.lazy.compactMap { carrier(in: $0) }.first
    }
}

@MainActor
private final class FlightContentCompletionState: ObservableObject {
    let identity = ChatBubbleLayoutIdentity(
        messageID: UUID(), structuralRevision: 1, isStreaming: false,
        hasPreparedMarkdown: true, hasPreparedReasoningMarkdown: false
    )
    @Published var target: ChatSendFlightTarget? = .init(flightID: UUID(), source: .text)
    @Published var opacity: Double = 0.5
    weak var content: UILabel?
    var creationCount = 0
}

@MainActor
private struct FlightContentCompletionHost: View {
    @ObservedObject var state: FlightContentCompletionState

    var body: some View {
        VStack {
            FlightCompletionNativeContent(state: state)
                .frame(width: 180, height: 60)
                .modifier(ChatSendFlightContentModifier(
                    layoutIdentity: state.identity, opacity: state.opacity, target: state.target
                ))
            Spacer()
        }
        .padding(.top, 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: ChatView.flightCoordinateSpace)
    }
}

private struct FlightCompletionNativeContent: UIViewRepresentable {
    let state: FlightContentCompletionState

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.text = "发送完成后的正文"
        state.content = label
        state.creationCount += 1
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {}
}

@MainActor
private final class FlightBubbleLifecycleState: ObservableObject {
    let controller = ChatSendFlightController()
    let messageState = ChatMessageRenderState(message: ChatMessage(role: .user, content: "**共同承载**中文回归"))
    let flightID = UUID()
    let sessionID = UUID()
    @Published var target: ChatSendFlightTarget?
    @Published var prepared: ETPreparedMarkdownRenderPayload?
    @Published var opacity: Double = 0
}

@MainActor
private struct FlightBubbleLifecycleHost: View {
    @ObservedObject var state: FlightBubbleLifecycleState

    var body: some View {
        VStack {
            ChatBubble(
                messageState: state.messageState, layoutWidth: 370,
                preparedMarkdownPayload: state.prepared,
                isReasoningExpanded: .constant(false), isToolCallsExpanded: .constant(false),
                enableMarkdown: true, enableBackground: false, enableLiquidGlass: false,
                enableNoBubbleUI: false, isCurrentResponse: false,
                mergeWithPrevious: false, mergeWithNext: false,
                onSwitchToPreviousVersion: {}, onSwitchToNextVersion: {},
                sendFlightTarget: state.target, sendFlightContentOpacity: state.opacity
            )
            Spacer()
        }
        .padding(.top, 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: ChatView.flightCoordinateSpace)
        .environment(\.chatSendFlightController, state.controller)
        .onPreferenceChange(FlightTargetRectKey.self) { frames in
            if let frame = frames[state.messageState.id] { state.controller.retarget([.text: frame]) }
        }
    }
}
