// ============================================================================
// ChatLongConversationRuntimeTests.swift
// ============================================================================
// 托管真实 ChatView 与 UIScrollView，验证长会话离底阅读和历史扩窗行为。
// ============================================================================

import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

struct ChatLongConversationRuntimeTests {

    @MainActor
    @Test("四键跨越历史边界时只换入相邻消息")
    func testAdjacentNavigationPreservesConfiguredHistoryWindowSize() async throws {
        let fixture = await makeFixture(
            automaticHistoryLoading: false,
            timelineNavigationEnabled: true,
            markdownEnabled: true,
            lazyLoadMessageCount: 4,
            messageCount: 20,
            paragraphCount: 20
        )
        defer { fixture.dispose() }

        let initialIDs = fixture.viewModel.displayMessages.map(\.id)
        let navigationIDs = fixture.viewModel.messageNavigationIDs()
        let firstVisibleID = try #require(initialIDs.first)
        let firstVisibleIndex = try #require(navigationIDs.firstIndex(of: firstVisibleID))
        #expect(firstVisibleIndex > 0)
        let targetID = navigationIDs[firstVisibleIndex - 1]

        #expect(fixture.viewModel.shiftHistoryWindow(
            toward: targetID,
            weightedBatchSize: 1,
            preservesCurrentWindowSize: true
        ))

        let shiftedIDs = fixture.viewModel.displayMessages.map(\.id)
        #expect(initialIDs.count == 4)
        #expect(shiftedIDs.count == 4)
        #expect(shiftedIDs.first == targetID)
        #expect(shiftedIDs.dropFirst() == initialIDs.dropLast())
    }

    @MainActor
    @Test("四条超长 Markdown 消息启用时间线导航后仍允许停留在顶部")
    func testFourLongMarkdownMessagesRemainAtTopDuringUserInteraction() async throws {
        let fixture = await makeFixture(
            automaticHistoryLoading: false,
            timelineNavigationEnabled: true,
            markdownEnabled: true,
            lazyLoadMessageCount: 4,
            messageCount: 4,
            paragraphCount: 60
        )
        defer { fixture.dispose() }
        let scrollView = try #require(fixture.chatScrollView)
        let maximumOffset = maximumContentOffsetY(of: scrollView)
        #expect(maximumOffset > 2_000)

        _ = fixture.coordinator.prepareForUserPan(
            isMessageJumpInFlight: false,
            bottomScrollTarget: .bottom
        )
        fixture.coordinator.shouldKeepBottomPinned = false
        let slightlyAwayFromBottomOffset = maximumOffset - 12
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: slightlyAwayFromBottomOffset),
            animated: false
        )
        fixture.coordinator.updateInteractionState(false)
        await settleLayout(fixture.host.view, duration: 0.35)

        #expect(abs(scrollView.contentOffset.y - slightlyAwayFromBottomOffset) < 2)
        #expect(!fixture.coordinator.shouldKeepBottomPinned)

        let readingOffset = minimumContentOffsetY(of: scrollView) + 24
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: readingOffset),
            animated: false
        )
        await settleLayout(fixture.host.view, duration: 0.25)
        let settledReadingOffset = scrollView.contentOffset.y

        _ = fixture.coordinator.prepareForUserPan(
            isMessageJumpInFlight: false,
            bottomScrollTarget: .bottom
        )
        fixture.coordinator.shouldKeepBottomPinned = false
        let acceptedLateBottomCommand = fixture.coordinator.chatScrollPositionController
            .issueCommand(to: .bottom, anchor: .bottom)

        #expect(!acceptedLateBottomCommand)
        #expect(!fixture.coordinator.chatScrollPositionController.hasActiveCommand)
        fixture.coordinator.updateInteractionState(false)
        await settleLayout(fixture.host.view, duration: 0.6)

        #expect(abs(scrollView.contentOffset.y - settledReadingOffset) < 2)
        #expect(!fixture.coordinator.shouldKeepBottomPinned)
    }

    @MainActor
    @Test("长会话离开底部后细小滚动不会形成状态反馈或自行回底")
    func testLongConversationRemainsStableAwayFromBottom() async throws {
        let fixture = await makeFixture(automaticHistoryLoading: true)
        defer { fixture.dispose() }
        let scrollView = try #require(fixture.chatScrollView)
        let maximumOffset = maximumContentOffsetY(of: scrollView)
        #expect(maximumOffset > 500)

        fixture.coordinator.updateInteractionState(true)
        _ = fixture.coordinator.prepareForUserPan(
            isMessageJumpInFlight: false,
            bottomScrollTarget: .bottom
        )
        fixture.coordinator.chatScrollPositionController.releaseCommand()
        fixture.coordinator.shouldKeepBottomPinned = false
        let readingOffset = max(
            minimumContentOffsetY(of: scrollView),
            maximumOffset * 0.45
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: readingOffset),
            animated: false
        )
        fixture.coordinator.updateInteractionState(false)
        await settleLayout(fixture.host.view, duration: 0.25)

        var coordinatorChangeCount = 0
        let changeSubscription = fixture.coordinator.objectWillChange.sink {
            coordinatorChangeCount += 1
        }
        defer { changeSubscription.cancel() }

        for pixelDelta in stride(from: CGFloat(1), through: 20, by: 1) {
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: readingOffset + pixelDelta
                ),
                animated: false
            )
        }
        await settleLayout(fixture.host.view, duration: 0.25)
        let settledOffset = scrollView.contentOffset.y
        let settledChangeCount = coordinatorChangeCount
        await settleLayout(fixture.host.view, duration: 0.5)

        #expect(abs(settledOffset - (readingOffset + 20)) < 2)
        #expect(abs(scrollView.contentOffset.y - settledOffset) < 1)
        #expect(coordinatorChangeCount - settledChangeCount <= 1)
        #expect(!fixture.coordinator.shouldKeepBottomPinned)
    }

    @MainActor
    @Test("真实聊天视图在自动和手动历史扩窗时保持同一阅读位置")
    func testHistoryLoadingPreservesViewportInBothModes() async throws {
        for usesAutomaticHistory in [true, false] {
            let fixture = await makeFixture(
                automaticHistoryLoading: usesAutomaticHistory
            )
            defer { fixture.dispose() }
            let scrollView = try #require(fixture.chatScrollView)

            fixture.coordinator.updateInteractionState(true)
            _ = fixture.coordinator.prepareForUserPan(
                isMessageJumpInFlight: false,
                bottomScrollTarget: .bottom
            )
            fixture.coordinator.chatScrollPositionController.releaseCommand()
            fixture.coordinator.shouldKeepBottomPinned = false
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: minimumContentOffsetY(of: scrollView) + 8
                ),
                animated: false
            )
            fixture.coordinator.updateInteractionState(false)
            await settleLayout(fixture.host.view, duration: 0.35)

            let displayedIDs = fixture.viewModel.displayMessages.map(\.id)
            let originalOffset = scrollView.contentOffset.y
            let originalFrames = measuredMessageFrames(
                in: fixture.coordinator.chatHistoryViewportAnchorController
            )
            guard let anchorID = displayedIDs.first(where: { originalFrames[$0] != nil }) else {
                Issue.record(
                    "\(usesAutomaticHistory ? "自动" : "手动")历史模式没有上报可见消息几何。"
                )
                continue
            }
            var emittedAdjustmentDelta: CGFloat?
            let adjustmentSubscription = fixture.coordinator
                .chatHistoryViewportAnchorController
                .$pendingAdjustment
                .compactMap { $0?.deltaY }
                .sink { emittedAdjustmentDelta = $0 }
            defer { adjustmentSubscription.cancel() }
            let didBeginMutation = usesAutomaticHistory
                ? fixture.coordinator.beginAutomaticHistoryMutation(
                    anchorMessageID: anchorID,
                    displayedMessageIDs: displayedIDs
                )
                : fixture.coordinator.beginManualHistoryMutation(
                    anchorMessageID: anchorID,
                    displayedMessageIDs: displayedIDs
                )
            guard didBeginMutation else {
                Issue.record(
                    "\(usesAutomaticHistory ? "自动" : "手动")历史模式未能取得已测量锚点。"
                )
                continue
            }

            let originalDisplayedCount = fixture.viewModel.displayMessages.count
            let didLoad = usesAutomaticHistory
                ? fixture.viewModel.loadMoreAutomaticHistoryIfNeeded()
                : fixture.viewModel.loadMoreHistoryChunk()
            fixture.coordinator.finishHistoryMutation(didLoad: didLoad)
            #expect(didLoad)
            #expect(fixture.viewModel.displayMessages.count > originalDisplayedCount)

            await waitForHistoryAdjustment(in: fixture)
            let adjustmentDelta = try #require(emittedAdjustmentDelta)
            let appliedOffsetDelta = scrollView.contentOffset.y - originalOffset

            #expect(abs(appliedOffsetDelta - adjustmentDelta) < 4)
            #expect(!fixture.coordinator.isHistoryLoadInFlight)
            #expect(!fixture.coordinator.chatHistoryViewportAnchorController.isRestoringAnchor)
        }
    }

    @MainActor
    private func makeFixture(
        automaticHistoryLoading: Bool,
        timelineNavigationEnabled: Bool = false,
        markdownEnabled: Bool = false,
        lazyLoadMessageCount: Int = 5,
        messageCount: Int = 60,
        paragraphCount: Int = 8
    ) async -> HostedChatFixture {
        let appConfig = AppConfigStore.shared
        let savedConfiguration = SavedChatConfiguration(appConfig: appConfig)
        appConfig.chatTimelineNavigationEnabled = timelineNavigationEnabled
        appConfig.chatScrollAnimationEnabled = false
        appConfig.enableMarkdown = markdownEnabled
        appConfig.enableAdvancedRenderer = false
        appConfig.enableBackground = false
        appConfig.automaticHistoryLoadingEnabled = automaticHistoryLoading
        appConfig.lazyLoadMessageCount = lazyLoadMessageCount

        let chatService = ChatService()
        let viewModel = ChatViewModel(chatService: chatService)
        let session = ChatSession(
            id: UUID(),
            name: "长会话滚动运行态测试",
            isTemporary: true
        )
        let messages = makeMessages(
            count: messageCount,
            paragraphCount: paragraphCount
        )
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)
        chatService.messagesForSessionSubject.send(messages)
        await settleMainQueue(duration: 0.2)

        let coordinator = ChatScrollCoordinator()
        let rootView = AnyView(
            NavigationStack {
                ChatView(scrollCoordinator: coordinator)
                    .environmentObject(viewModel)
            }
        )
        let host = UIHostingController(rootView: rootView)
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        await settleLayout(host.view, duration: 0.8)

        return HostedChatFixture(
            window: window,
            host: host,
            viewModel: viewModel,
            coordinator: coordinator,
            savedConfiguration: savedConfiguration
        )
    }

    @MainActor
    private func waitForHistoryAdjustment(
        in fixture: HostedChatFixture
    ) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            await settleLayout(fixture.host.view, duration: 0.1)
            if !fixture.coordinator.isHistoryLoadInFlight {
                break
            }
        }
        await settleLayout(fixture.host.view, duration: 0.25)
    }

    @MainActor
    private func measuredMessageFrames(
        in controller: ChatHistoryViewportAnchorController
    ) -> [UUID: CGRect] {
        let mirror = Mirror(reflecting: controller)
        guard let frames = mirror.children.first(where: { $0.label == "rowFrames" })?.value
                as? [UUID: CGRect] else {
            return [:]
        }
        return frames.filter { _, frame in
            frame.width > 0 && frame.height > 0
        }
    }

    @MainActor
    private func settleLayout(_ view: UIView, duration: TimeInterval) async {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        await settleMainQueue(duration: duration)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    @MainActor
    private func settleMainQueue(duration: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeMessages(count: Int, paragraphCount: Int) -> [ChatMessage] {
        (0..<count).map { index in
            let paragraphs = (0..<paragraphCount).map { paragraphIndex in
                """
                ### 第 \(paragraphIndex + 1) 段

                这是用于超长 Markdown 会话滚动验收的正文，包含 **强调内容**、`inline code` 与自然换行。
                """
            }.joined(separator: "\n\n")
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: """
                第 \(index + 1) 条测试消息

                \(paragraphs)
                """
            )
        }
    }

    @MainActor
    private func minimumContentOffsetY(of scrollView: UIScrollView) -> CGFloat {
        -scrollView.adjustedContentInset.top
    }

    @MainActor
    private func maximumContentOffsetY(of scrollView: UIScrollView) -> CGFloat {
        max(
            minimumContentOffsetY(of: scrollView),
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
    }
}

@MainActor
private final class HostedChatFixture {
    let window: UIWindow
    let host: UIHostingController<AnyView>
    let viewModel: ChatViewModel
    let coordinator: ChatScrollCoordinator
    let savedConfiguration: SavedChatConfiguration

    init(
        window: UIWindow,
        host: UIHostingController<AnyView>,
        viewModel: ChatViewModel,
        coordinator: ChatScrollCoordinator,
        savedConfiguration: SavedChatConfiguration
    ) {
        self.window = window
        self.host = host
        self.viewModel = viewModel
        self.coordinator = coordinator
        self.savedConfiguration = savedConfiguration
    }

    var chatScrollView: UIScrollView? {
        allScrollViews(in: host.view)
            .filter { scrollView in
                scrollView.bounds.width > 300
                    && scrollView.bounds.height > 300
                    && scrollView.contentSize.height > scrollView.bounds.height + 100
            }
            .max { lhs, rhs in
                lhs.contentSize.height - lhs.bounds.height
                    < rhs.contentSize.height - rhs.bounds.height
            }
    }

    func dispose() {
        window.isHidden = true
        window.rootViewController = nil
        savedConfiguration.restore(to: AppConfigStore.shared)
    }

    private func allScrollViews(in view: UIView) -> [UIScrollView] {
        let current = view as? UIScrollView
        return (current.map { [$0] } ?? [])
            + view.subviews.flatMap(allScrollViews(in:))
    }
}

@MainActor
private struct SavedChatConfiguration {
    let chatTimelineNavigationEnabled: Bool
    let chatScrollAnimationEnabled: Bool
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableBackground: Bool
    let automaticHistoryLoadingEnabled: Bool
    let lazyLoadMessageCount: Int

    init(appConfig: AppConfigStore) {
        chatTimelineNavigationEnabled = appConfig.chatTimelineNavigationEnabled
        chatScrollAnimationEnabled = appConfig.chatScrollAnimationEnabled
        enableMarkdown = appConfig.enableMarkdown
        enableAdvancedRenderer = appConfig.enableAdvancedRenderer
        enableBackground = appConfig.enableBackground
        automaticHistoryLoadingEnabled = appConfig.automaticHistoryLoadingEnabled
        lazyLoadMessageCount = appConfig.lazyLoadMessageCount
    }

    func restore(to appConfig: AppConfigStore) {
        appConfig.chatTimelineNavigationEnabled = chatTimelineNavigationEnabled
        appConfig.chatScrollAnimationEnabled = chatScrollAnimationEnabled
        appConfig.enableMarkdown = enableMarkdown
        appConfig.enableAdvancedRenderer = enableAdvancedRenderer
        appConfig.enableBackground = enableBackground
        appConfig.automaticHistoryLoadingEnabled = automaticHistoryLoadingEnabled
        appConfig.lazyLoadMessageCount = lazyLoadMessageCount
    }
}
