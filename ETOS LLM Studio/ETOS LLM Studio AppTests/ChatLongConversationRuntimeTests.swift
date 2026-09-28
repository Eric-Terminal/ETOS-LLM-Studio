// ============================================================================
// ChatLongConversationRuntimeTests.swift
// ============================================================================
// 托管真实 ChatView 与 UIScrollView，验证长会话离底阅读和历史扩窗行为。
// ============================================================================

import Combine
import Darwin
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChatLongConversationRuntimeTests {

    @MainActor
    @Test("四条窗口在长草稿收缩和长消息追加后，流式期间及静态末行都真实可见")
    func testLongSendKeepsRealizedRowsVisibleBeforeStreamingEnds() async throws {
        // 仅测试宿主启用已有代码预览用例使用的 AX 桥；SwiftUI 环境值不会生成自动化节点。
        // 保留原状态并在退出时恢复，不让观测初始化改变后续用例或正式 App 的行为。
        let libraryPath = (ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? "")
            + "/usr/lib/libAccessibility.dylib"
        let library = try #require(dlopen(libraryPath, RTLD_LAZY), "无法加载测试用无障碍自动化桥")
        defer { dlclose(library) }
        let readAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSAutomationEnabled")),
            to: (@convention(c) () -> Int32).self
        )
        let setAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSSetAutomationEnabled")),
            to: (@convention(c) (Int32) -> Void).self
        )
        let previousAutomation = readAutomation()
        setAutomation(1)
        defer { setAutomation(previousAutomation) }
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let savedDraft = config.chatComposerDraft
        let savedComposerStyle = config.chatComposerStyle
        let savedPreviewLimit = config.userMessagePreviewCharacterLimit
        config.chatComposerDraft = ""
        config.chatComposerStyle = ChatComposerStyle.capsule.rawValue
        config.userMessagePreviewCharacterLimit = 1_000
        do {
            defer {
                config.chatComposerDraft = savedDraft
                config.chatComposerStyle = savedComposerStyle
                config.userMessagePreviewCharacterLimit = savedPreviewLimit
            }
            let longBody = (1...32).map { "第 \($0) 行：输入收缩后的滚动可见性。" }.joined(separator: "\n")
            let seed = [
                ChatMessage(role: .user, content: "较早的短消息"),
                ChatMessage(role: .assistant, content: "较早的短回复"),
                ChatMessage(role: .user, content: longBody + "\n旧长消息尾标"),
                ChatMessage(role: .assistant, content: "种子回复可见尾标")
            ]
            let fixture = try await makeFixture(
                automaticHistoryLoading: false,
                markdownEnabled: true,
                advancedRendererEnabled: true,
                lazyLoadMessageCount: 4,
                initialMessages: seed,
                windowSize: CGSize(width: 402, height: 874)
            )
            defer {
                fixture.chatService.runningSessionIDsSubject.send([])
                fixture.dispose()
            }
            let scrollView = try #require(fixture.chatScrollView)
            let sessionID = try #require(fixture.viewModel.currentSession?.id)
            try #require(maximumContentOffsetY(of: scrollView) - minimumContentOffsetY(of: scrollView) > 100, "种子长消息必须产生超过 100pt 的真实滚动跨度")
            try #require(fixture.viewModel.displayMessages.map(\.id) == seed.map(\.id))
            // 只在发送前确认测试宿主已提供 AX 节点；发送后的缺行不能靠重复查询等到恢复。
            let initialAXReady = await waitForRuntimeCondition {
                !tailVisibleAccessibilityFrames(containing: "种子回复可见尾标", in: fixture.host.view, viewportOf: scrollView).isEmpty
                    && !tailVisibleAccessibilityFrames(containing: "旧长消息尾标", in: fixture.host.view, viewportOf: scrollView).isEmpty
            }
            // 先锁定 AX 判断再记录截图，附件采集不能反向改变本次判断。
            let initialSeedFrames = tailVisibleAccessibilityFrames(containing: "种子回复可见尾标", in: fixture.host.view, viewportOf: scrollView)
            let initialUserFrames = tailVisibleAccessibilityFrames(containing: "旧长消息尾标", in: fixture.host.view, viewportOf: scrollView)
            recordVisibilityEvidence(
                stage: "初始种子", fixture: fixture, scrollView: scrollView,
                userFrames: initialUserFrames, replyFrames: initialSeedFrames
            )
            try #require(initialAXReady, "发送前必须能观测到种子用户消息与回复的 AX 节点")
            try #require(!initialSeedFrames.isEmpty)

            let userTail = "新长消息可见尾标"
            let draft = longBody + "\n" + userTail
            fixture.viewModel.userInput = draft
            let expanded = await waitForRuntimeCondition {
                fixture.editableTextView(containing: draft).map { $0.bounds.height > 80 } == true
            }
            try #require(expanded, "长草稿必须在真实输入控件中展开，不能跳过输入收缩刺激")
            let editor = try #require(fixture.editableTextView(containing: draft))
            let expandedHeight = editor.bounds.height
            // 初始挂载之后不再强制布局。清空真实草稿，再让原有后台快照和滚动桥消费新行。
            let user = ChatMessage(role: .user, content: draft)
            var reply = ChatMessage(role: .assistant, content: "")
            reply.isReceivingStream = true
            var published = seed + [user, reply]
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                fixture.viewModel.userInput = ""
                fixture.chatService.runningSessionIDsSubject.send([sessionID])
                fixture.chatService.messagesForSessionSubject.send(published)
            }
            let expectedIDs = Array(published.suffix(4).map(\.id))
            let inserted = await waitForRuntimeCondition {
                fixture.viewModel.isSendingMessage
                    && fixture.viewModel.displayMessageIDs == expectedIDs
                    && (editor.window == nil || editor.bounds.height < expandedHeight - 20)
            }
            try #require(inserted, "同一宿主必须完成四条窗口替换和输入收缩")
            try #require(fixture.chatScrollView === scrollView)

            // 故障曾在自然结束前数秒出现，因此先保持 receiving=true 检查，不能只验静态终态。
            let streamingTail = "流式回复可见尾标"
            reply.content = streamingTail
            published[published.count - 1] = reply
            fixture.chatService.messagesForSessionSubject.send(published)
            let streamed = await waitForRuntimeCondition {
                fixture.viewModel.messageStateByID[reply.id]?.message.content == streamingTail
                    && fixture.viewModel.streamingMarkdownPrepareTasks.isEmpty
            }
            try #require(streamed)
            // 给现有一次性定位与跟随自然收敛，不读取 AX 轮询、加观察器或主动滚动来促成实现。
            await settleMainQueue(duration: 1.2)
            let streamingUserFrames = tailVisibleAccessibilityFrames(containing: userTail, in: fixture.host.view, viewportOf: scrollView)
            let streamingReplyFrames = tailVisibleAccessibilityFrames(containing: streamingTail, in: fixture.host.view, viewportOf: scrollView)
            recordVisibilityEvidence(
                stage: "流式中", fixture: fixture, scrollView: scrollView,
                userFrames: streamingUserFrames, replyFrames: streamingReplyFrames
            )
            #expect(fixture.viewModel.isSendingMessage)
            #expect(fixture.viewModel.messageStateByID[reply.id]?.message.isReceivingStream == true)
            #expect(!streamingUserFrames.isEmpty)
            #expect(!streamingReplyFrames.isEmpty)

            reply.content += "，静态完成尾标。"
            reply.isReceivingStream = false
            published[published.count - 1] = reply
            fixture.chatService.messagesForSessionSubject.send(published)
            fixture.chatService.runningSessionIDsSubject.send([])
            let finished = await waitForRuntimeCondition {
                !fixture.viewModel.isSendingMessage
                    && fixture.viewModel.preparedMarkdownByMessageID[reply.id]?.sourceText == reply.content
                    && fixture.viewModel.messageStateByID[reply.id]?.streamingMarkdownState.isAwaitingStaticHandoff(channel: .content) == false
                    && !fixture.coordinator.isStreamingViewportFollowing
                    && !fixture.coordinator.isChatLayoutSettling
                    && !fixture.coordinator.chatScrollPositionController.hasActiveCommand
            }
            try #require(finished, "正文、静态准备与滚动所有权必须真正结束")
            await settleMainQueue(duration: 0.15)
            let finalUserFrames = tailVisibleAccessibilityFrames(containing: userTail, in: fixture.host.view, viewportOf: scrollView)
            let finalReplyFrames = tailVisibleAccessibilityFrames(containing: "静态完成尾标", in: fixture.host.view, viewportOf: scrollView)
            recordVisibilityEvidence(
                stage: "静态完成", fixture: fixture, scrollView: scrollView,
                userFrames: finalUserFrames, replyFrames: finalReplyFrames
            )
            #expect(fixture.viewModel.displayMessageIDs == expectedIDs)
            #expect(fixture.viewModel.messageStateByID[reply.id]?.visualMessage.content == reply.content)
            #expect(fixture.chatScrollView === scrollView)
            #expect(!finalUserFrames.isEmpty)
            #expect(!finalReplyFrames.isEmpty)
            #expect(abs(scrollView.contentOffset.y - maximumContentOffsetY(of: scrollView)) < 4)
        } catch {
            await config.flushPendingWrites()
            throw error
        }
        await config.flushPendingWrites()
    }

    @MainActor
    @Test("四键跨越历史边界时只换入相邻消息")
    func testAdjacentNavigationPreservesConfiguredHistoryWindowSize() async throws {
        let fixture = try await makeFixture(
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
        let fixture = try await makeFixture(
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

        // 初始定位尚未释放时，手势也必须走真实视图回调并取消该指令。
        #expect(fixture.coordinator.chatScrollPositionController.issueCommand(to: .bottom, anchor: .bottom))
        try fixture.beginUserPan()
        #expect(!fixture.coordinator.chatScrollPositionController.hasActiveCommand)
        #expect(fixture.coordinator.pendingScrollTargetTask == nil)
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

        try fixture.beginUserPan()
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
        let fixture = try await makeFixture(automaticHistoryLoading: true)
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

        let monitor = fixture.coordinator.chatLayoutIntegrityMonitor
        let initialProbeRevision = monitor.layoutProbeRevision
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
        // 微滚动会触发一次必要的布局审计；新测量完成后才开始检查稳态反馈。
        let auditDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < auditDeadline,
              monitor.layoutProbeRevision <= initialProbeRevision || monitor.isContentFrameProbeActive {
            await settleMainQueue(duration: 0.02)
        }
        try #require(monitor.layoutProbeRevision > initialProbeRevision, "本次滚动必须完成新一轮布局测量")
        try #require(!monitor.isContentFrameProbeActive, "布局测量必须在有界等待内结束")
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
            let fixture = try await makeFixture(
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
        advancedRendererEnabled: Bool = false,
        lazyLoadMessageCount: Int = 5,
        messageCount: Int = 60,
        paragraphCount: Int = 8,
        initialMessages: [ChatMessage]? = nil,
        windowSize: CGSize = CGSize(width: 390, height: 844)
    ) async throws -> HostedChatFixture {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let appConfig = AppConfigStore.shared
        await appConfig.waitForPersistentStoreLoaded()
        let savedConfiguration = SavedChatConfiguration(appConfig: appConfig)
        var fixtureCreated = false
        defer {
            // 准备阶段抛错也必须恢复配置，不能让一次失败改变后续用例的渲染模式。
            if !fixtureCreated { savedConfiguration.restore(to: appConfig) }
        }
        appConfig.chatTimelineNavigationEnabled = timelineNavigationEnabled
        appConfig.chatScrollAnimationEnabled = false
        appConfig.enableMarkdown = markdownEnabled
        appConfig.enableAdvancedRenderer = advancedRendererEnabled
        appConfig.enableBackground = false
        appConfig.automaticHistoryLoadingEnabled = automaticHistoryLoading
        appConfig.lazyLoadMessageCount = lazyLoadMessageCount

        let chatService = ChatService()
        await chatService.waitForInitialPersistenceStateIfNeeded()
        let viewModel = ChatViewModel(chatService: chatService)
        let session = ChatSession(
            id: UUID(),
            name: "长会话滚动运行态测试",
            isTemporary: true
        )
        let messages = initialMessages ?? makeMessages(
            count: messageCount,
            paragraphCount: paragraphCount
        )
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)
        chatService.messagesForSessionSubject.send(messages)
        // 等待真实消息快照与其派生任务；这组用例验证滚动行为，不把机器负载当作解析时限。
        // 整个用例仍受 Suite 的时间限制约束，任务没有清理或消息未发布时不会静默通过。
        while viewModel.allMessagesForSession != messages {
            try await Task.sleep(for: .milliseconds(10))
        }
        for task in Array(viewModel.visualMessagePrepareTasks.values) {
            await task.value
        }
        for task in Array(viewModel.markdownPrepareTasks.values) {
            await task.value
        }
        for task in Array(viewModel.reasoningMarkdownPrepareTasks.values) {
            await task.value
        }
        try #require(viewModel.allMessagesForSession == messages)
        try #require(viewModel.visualMessagePrepareTasks.isEmpty)
        try #require(viewModel.markdownPrepareTasks.isEmpty)
        try #require(viewModel.reasoningMarkdownPrepareTasks.isEmpty)

        let coordinator = ChatScrollCoordinator()
        let rootView = AnyView(
            NavigationStack {
                ChatView(scrollCoordinator: coordinator)
                    .environmentObject(viewModel)
                    // 这些用例模拟前台阅读，独立宿主必须显式提供活跃场景环境。
                    .environment(\.scenePhase, .active)
            }
        )
        let host = UIHostingController(rootView: rootView)
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        await settleLayout(host.view, duration: 0.8)

        fixtureCreated = true
        return HostedChatFixture(
            window: window,
            host: host,
            chatService: chatService,
            viewModel: viewModel,
            coordinator: coordinator,
            savedConfiguration: savedConfiguration
        )
    }

    @MainActor
    private func waitForRuntimeCondition(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            await settleMainQueue(duration: 0.02)
        }
        return condition()
    }

    @MainActor
    private func tailVisibleAccessibilityFrames(
        containing text: String, in root: UIView, viewportOf scrollView: UIScrollView
    ) -> [CGRect] {
        guard let window = scrollView.window else { return [] }
        let visibleBounds = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let viewport = window.convert(scrollView.convert(visibleBounds, to: window), to: window.screen.coordinateSpace)
        // AX 树由 SwiftUI 宿主提供，UIKit 滚动子树只用于确定真实可视边界。
        // 长段上半部相交不能证明末行可见；匹配尾标的元素末端必须仍在视口内。
        return accessibilityObjects(root).compactMap { object in
            let label = object.accessibilityLabel ?? ""
            let value = object.accessibilityValue ?? ""
            let frame = object.accessibilityFrame
            guard (label.contains(text) || value.contains(text)),
                  !frame.isEmpty, !frame.isNull, frame.intersects(viewport),
                  frame.maxY > viewport.minY, frame.maxY <= viewport.maxY else { return nil }
            return frame
        }
    }

    @MainActor
    private func accessibilityObjects(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        let children: [NSObject]
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else if object.accessibilityElementCount() > 0 && object.accessibilityElementCount() < 1_000 {
            children = (0..<object.accessibilityElementCount()).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        } else {
            children = (object as? UIView)?.subviews ?? []
        }
        return [object] + children.flatMap { accessibilityObjects($0, depth: depth + 1) }
    }

    @MainActor
    private func recordVisibilityEvidence(
        stage: String, fixture: HostedChatFixture, scrollView: UIScrollView,
        userFrames: [CGRect], replyFrames: [CGRect]
    ) {
        let frames = measuredMessageFrames(in: fixture.coordinator.chatHistoryViewportAnchorController)
        let visibleBounds = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let viewport = fixture.window.convert(
            scrollView.convert(visibleBounds, to: fixture.window),
            to: fixture.window.screen.coordinateSpace
        )
        let details = "阶段=\(stage) display=\(fixture.viewModel.displayMessages.count) historyRows=\(frames.count) "
            + "size=\(scrollView.contentSize) offset=\(scrollView.contentOffset) insets=\(scrollView.adjustedContentInset) "
            + "viewport=\(viewport) "
            + "following=\(fixture.coordinator.isStreamingViewportFollowing) axUser=\(userFrames) axReply=\(replyFrames)"
        Attachment.record(Data(details.utf8), named: "长消息可见性-\(stage).txt")
        // 仅记录已经提交的图层，不调用 afterScreenUpdates 或 layoutIfNeeded 补做布局。
        let png = UIGraphicsImageRenderer(bounds: fixture.window.bounds).pngData { context in
            fixture.window.layer.render(in: context.cgContext)
        }
        Attachment.record(png, named: "长消息可见性-\(stage).png")
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
            return ChatMessage(
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
    let chatService: ChatService
    let viewModel: ChatViewModel
    let coordinator: ChatScrollCoordinator
    let savedConfiguration: SavedChatConfiguration

    init(
        window: UIWindow,
        host: UIHostingController<AnyView>,
        chatService: ChatService,
        viewModel: ChatViewModel,
        coordinator: ChatScrollCoordinator,
        savedConfiguration: SavedChatConfiguration
    ) {
        self.window = window
        self.host = host
        self.chatService = chatService
        self.viewModel = viewModel
        self.coordinator = coordinator
        self.savedConfiguration = savedConfiguration
    }

    var chatScrollView: UIScrollView? {
        // 输入栏 inset 也会形成滚动跨度；按内容高度筛选既会漏掉聊天区，也可能误选编辑器。
        scrollMetricsObservers(in: host.view)
            .compactMap { $0.coordinator?.scrollView }
            .first { $0.window === window }
    }

    func editableTextView(containing text: String) -> UITextView? {
        allScrollViews(in: host.view).compactMap { $0 as? UITextView }.first {
            $0.isEditable && $0.text == text
        }
    }

    func dispose() {
        window.isHidden = true
        window.rootViewController = nil
        savedConfiguration.restore(to: AppConfigStore.shared)
    }

    func beginUserPan() throws {
        let observer = try #require(scrollMetricsObservers(in: host.view).first {
            $0.coordinator?.scrollView === chatScrollView
        })
        let bridge = try #require(observer.coordinator)
        // prepareForUserPan 只返回取消决定；实际 ChatView 回调还会释放任务与定位目标。
        bridge.onUserPanBegan()
        bridge.keepsBottomPinned.wrappedValue = false
    }

    private func scrollMetricsObservers(in view: UIView) -> [ChatScrollMetricsObserver.ObserverView] {
        (view as? ChatScrollMetricsObserver.ObserverView).map { [$0] }
            ?? view.subviews.flatMap { scrollMetricsObservers(in: $0) }
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
