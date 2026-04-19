// ============================================================================
// OnboardingHubView.swift
// ============================================================================
// ETOS LLM Studio iOS 新手教程中心
//
// 功能特性:
// - 提供统一的新手教程入口
// - 汇总快速开始清单与隐藏交互教程
// - 提供可反复进入的演示练习页
// ============================================================================

import SwiftUI
import Shared

struct OnboardingHubView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let openChat: (() -> Void)?

    @State private var snapshot: OnboardingChecklistSnapshot = .empty
    @State private var isLoadingSnapshot = false

    init(openChat: (() -> Void)? = nil) {
        self.openChat = openChat
    }

    private var snapshotRefreshKey: String {
        let providerCount = viewModel.providers.count
        let sessionCount = viewModel.chatSessions.count
        let currentModelID = viewModel.selectedModel?.id ?? "nil"
        let visited = progressStore.visitedSurfaceIDs.map(\.rawValue).sorted().joined(separator: ",")
        return "\(providerCount)|\(sessionCount)|\(currentModelID)|\(visited)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("先学会隐藏交互，再学完整上手路径。")
                        .etFont(.headline)
                    Text("如果一个页面上看不到按钮，默认先试点一下、长按一下，再试左滑和右滑。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("快速开始") {
                guideRow(
                    title: "第一个提供商与模型",
                    summary: providerGuideSummary,
                    guideID: .firstProvider
                ) {
                    IOSFirstProviderGuideView(snapshot: snapshot)
                        .environmentObject(viewModel)
                }

                guideRow(
                    title: "第一次发起聊天",
                    summary: firstChatGuideSummary,
                    guideID: .firstChat
                ) {
                    IOSFirstChatGuideView(
                        snapshot: snapshot,
                        openChat: openChat
                    )
                    .environmentObject(viewModel)
                }

                guideRow(
                    title: "工具中心入门",
                    summary: toolCenterGuideSummary,
                    guideID: .toolCenterBasics
                ) {
                    IOSToolCenterBasicsGuideView(snapshot: snapshot)
                        .environmentObject(viewModel)
                }
            }

            Section("隐藏操作先学会") {
                guideRow(
                    title: "交互约定",
                    summary: "先点，再长按，再左滑 / 右滑。",
                    guideID: .interactionPrimer
                ) {
                    IOSInteractionPrimerGuideView()
                }

                guideRow(
                    title: "会话管理",
                    summary: "重点学习长按会话项后的改名、分支、移动和删除操作。",
                    guideID: .sessionManagement
                ) {
                    IOSSessionManagementGuideView(snapshot: snapshot)
                }
            }

            Section("按主题学习") {
                NavigationLink {
                    ProviderListView()
                        .environmentObject(viewModel)
                } label: {
                    Label("进入提供商与模型管理", systemImage: "shippingbox")
                }

                NavigationLink {
                    SessionListView()
                        .environmentObject(viewModel)
                } label: {
                    Label("进入会话管理", systemImage: "list.bullet.rectangle")
                }

                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    Label("进入工具中心", systemImage: "slider.horizontal.3")
                }

                Button {
                    openChat?()
                } label: {
                    Label("回到聊天页开始练习", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(openChat == nil)
            }
        }
        .navigationTitle("新手教程")
        .task(id: snapshotRefreshKey) {
            await refreshSnapshot()
        }
    }

    private var providerGuideSummary: String {
        if snapshot.hasVisitedProviderManagement && snapshot.hasProvider && snapshot.hasActivatedModel {
            return "已具备开始聊天所需的提供商与模型。"
        }
        if !snapshot.hasVisitedProviderManagement {
            return "先进入一次“提供商与模型管理”，知道入口在哪。"
        }
        if !snapshot.hasProvider {
            return "当前还没有任何提供商。"
        }
        if !snapshot.hasActivatedModel {
            return "已有提供商，但还没有启用模型。"
        }
        return "继续完成最小配置闭环。"
    }

    private var firstChatGuideSummary: String {
        if snapshot.currentModelDisplayName == nil {
            return "聊天前先确保当前模型可用。"
        }
        if !snapshot.hasSentMessage {
            return "模型已可用，下一步发出第一条消息。"
        }
        return "已经开始聊天，可以继续学习消息长按操作。"
    }

    private var toolCenterGuideSummary: String {
        snapshot.hasVisitedToolCenter
            ? "你已经进入过工具中心，重点看“配置已启用”和“当前会话可用”的区别。"
            : "先认识工具中心怎么看，再排查“为什么开了却不能用”。"
    }

    @ViewBuilder
    private func guideRow<Destination: View>(
        title: String,
        summary: String,
        guideID: OnboardingGuideID,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .etFont(.body.weight(.semibold))
                    Text(summary)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                IOSOnboardingCompletionBadge(isCompleted: guideCompleted(guideID))
            }
            .padding(.vertical, 4)
        }
    }

    private func guideCompleted(_ guideID: OnboardingGuideID) -> Bool {
        progressStore.isGuideCompleted(guideID) || snapshot.isSatisfied(for: guideID)
    }

    private func refreshSnapshot() async {
        isLoadingSnapshot = true
        let providers = viewModel.providers
        let sessions = viewModel.chatSessions
        let currentModel = viewModel.selectedModel
        let visitedSurfaceIDs = progressStore.visitedSurfaceIDs
        let hasSentMessage = await OnboardingChecklistSnapshot.loadHasSentMessage(for: sessions)
        guard !Task.isCancelled else { return }
        let nextSnapshot = OnboardingChecklistSnapshot.capture(
            providers: providers,
            sessions: sessions,
            currentModel: currentModel,
            visitedSurfaceIDs: visitedSurfaceIDs,
            hasSentMessage: hasSentMessage
        )
        snapshot = nextSnapshot
        isLoadingSnapshot = false
        synchronizeAutoCompletion(with: nextSnapshot)
    }

    private func synchronizeAutoCompletion(with snapshot: OnboardingChecklistSnapshot) {
        for guideID in [OnboardingGuideID.firstProvider, .firstChat, .toolCenterBasics] where snapshot.isSatisfied(for: guideID) {
            progressStore.markGuideCompleted(guideID)
        }
    }
}

struct IOSOnboardingHintCard: View {
    let title: String
    let message: String
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    init(
        title: String,
        message: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(title, systemImage: "sparkles")
                    .etFont(.headline)
                Spacer()
                Button("关闭") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(message)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let actionTitle, let onAction {
                    Button(actionTitle) {
                        onAction()
                    }
                    .buttonStyle(.bordered)
                }

                Button("知道了") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .listRowBackground(Color.clear)
    }
}

private struct IOSOnboardingCompletionBadge: View {
    let isCompleted: Bool

    var body: some View {
        Text(isCompleted ? "已完成" : "未完成")
            .etFont(.caption.weight(.semibold))
            .foregroundStyle(isCompleted ? .green : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isCompleted ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12))
            )
    }
}

private struct IOSGuideHeaderView: View {
    let title: String
    let summary: String
    let isCompleted: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .etFont(.title3.weight(.semibold))
                Text(summary)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                IOSOnboardingCompletionBadge(isCompleted: isCompleted)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct IOSInteractionPrimerGuideView: View {
    @ObservedObject private var progressStore = OnboardingProgressStore.shared
    @State private var didUseLongPress = false
    @State private var didUseLeadingSwipe = false
    @State private var didUseTrailingSwipe = false

    private var isCompleted: Bool {
        didUseLongPress && didUseLeadingSwipe && didUseTrailingSwipe
    }

    var body: some View {
        List {
            IOSGuideHeaderView(
                title: "交互约定",
                summary: "在 ETOS 里，如果一个组件上没有直接露出按钮，默认先点一下，再长按一下；列表项再试左滑和右滑。",
                isCompleted: progressStore.isGuideCompleted(.interactionPrimer)
            )

            Section("先记住这句话") {
                Text("看不到按钮时，先试长按；列表项再试左滑和右滑。")
                Text("这不是技巧补充，而是很多页面的默认交互入口。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("试一试：长按这条示例项") {
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .foregroundStyle(.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("样例：长按我")
                        Text(didUseLongPress ? "已完成长按练习" : "长按后任选一个动作")
                            .etFont(.caption)
                            .foregroundStyle(didUseLongPress ? .green : .secondary)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("我知道长按会弹出菜单了") {
                        didUseLongPress = true
                    }
                    Button("这里通常会放更多操作") {
                        didUseLongPress = true
                    }
                }
            }

            Section {
                IOSSwipePracticeRow(
                    title: "样例：左右滑我",
                    subtitle: swipePracticeSubtitle,
                    onLeadingAction: {
                        didUseLeadingSwipe = true
                    },
                    onTrailingAction: {
                        didUseTrailingSwipe = true
                    }
                )
            } header: {
                Text("试一试：左右滑这条示例项")
            } footer: {
                Text("左滑和右滑往往代表不同操作，不要只试一个方向。")
            }

            if isCompleted {
                Section {
                    Text("你已经完成了交互约定练习。后面看到会话、消息、提供商列表时，先把这套动作试一遍。")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("交互约定")
        .onAppear {
            progressStore.markGuideSeen(.interactionPrimer)
        }
        .onChange(of: isCompleted) { _, newValue in
            guard newValue else { return }
            progressStore.markGuideCompleted(.interactionPrimer)
        }
    }

    private var swipePracticeSubtitle: String {
        if didUseLeadingSwipe && didUseTrailingSwipe {
            return "左右滑练习已完成"
        }
        if didUseLeadingSwipe {
            return "已完成左滑，再试右滑"
        }
        if didUseTrailingSwipe {
            return "已完成右滑，再试左滑"
        }
        return "先试左滑，再试右滑"
    }
}

private struct IOSFirstProviderGuideView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot

    var body: some View {
        List {
            IOSGuideHeaderView(
                title: "第一个提供商与模型",
                summary: "先把“可聊天”这件事配通，再谈其他高级能力。",
                isCompleted: snapshot.isSatisfied(for: .firstProvider) || progressStore.isGuideCompleted(.firstProvider)
            )

            Section("完成这 4 件事") {
                checklistRow("进入一次“提供商与模型管理”", completed: snapshot.hasVisitedProviderManagement)
                checklistRow("至少保存一个提供商", completed: snapshot.hasProvider)
                checklistRow("至少启用一个模型", completed: snapshot.hasActivatedModel)
                checklistRow("知道“模型顺序 / 专用模型”入口在哪", completed: snapshot.hasVisitedProviderManagement)
            }

            Section("常见问题") {
                Text("已经添加了提供商，但聊天页仍然没有模型时，先检查模型开关是否已启用。")
                Text("如果模型列表顺序不顺手，可以去“模型顺序”里调整。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("直接去做") {
                NavigationLink {
                    ProviderListView()
                        .environmentObject(viewModel)
                } label: {
                    Label("进入提供商与模型管理", systemImage: "shippingbox")
                }
            }
        }
        .navigationTitle("第一个提供商")
        .onAppear {
            progressStore.markGuideSeen(.firstProvider)
            if snapshot.isSatisfied(for: .firstProvider) {
                progressStore.markGuideCompleted(.firstProvider)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(_ title: String, completed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed ? .green : .secondary)
            Text(title)
        }
    }
}

private struct IOSFirstChatGuideView: View {
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot
    let openChat: (() -> Void)?

    @State private var practicedMessageLongPress = false

    private var isCompleted: Bool {
        snapshot.isSatisfied(for: .firstChat) || progressStore.isGuideCompleted(.firstChat)
    }

    var body: some View {
        List {
            IOSGuideHeaderView(
                title: "第一次发起聊天",
                summary: "先确认当前模型，再发出第一条消息。消息出来以后，记得长按一下看看更多动作。",
                isCompleted: isCompleted
            )

            Section("完成这 4 件事") {
                checklistRow("当前已经有可用模型", completed: snapshot.currentModelDisplayName != nil)
                checklistRow("已经进入过聊天页", completed: snapshot.hasVisitedChat)
                checklistRow("至少有一个真实会话", completed: snapshot.hasNonTemporarySession)
                checklistRow("至少发出过一条消息", completed: snapshot.hasSentMessage)
            }

            if let currentModelDisplayName = snapshot.currentModelDisplayName {
                Section("当前模型") {
                    Text(currentModelDisplayName)
                }
            }

            Section {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("样例：长按消息")
                        Text(practicedMessageLongPress ? "已完成消息长按练习" : "长按后任选一个动作")
                            .etFont(.caption)
                            .foregroundStyle(practicedMessageLongPress ? .green : .secondary)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("编辑") {
                        practicedMessageLongPress = true
                    }
                    Button("导出整个会话") {
                        practicedMessageLongPress = true
                    }
                    Button("朗读消息") {
                        practicedMessageLongPress = true
                    }
                }
            } header: {
                Text("别漏掉这个隐藏动作")
            } footer: {
                Text("真实聊天里，很多消息操作都在长按菜单里。")
            }

            Section("直接去做") {
                Button {
                    openChat?()
                } label: {
                    Label("回到聊天页开始发送", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(openChat == nil)
            }
        }
        .navigationTitle("第一次聊天")
        .onAppear {
            progressStore.markGuideSeen(.firstChat)
            if snapshot.isSatisfied(for: .firstChat) {
                progressStore.markGuideCompleted(.firstChat)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(_ title: String, completed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed ? .green : .secondary)
            Text(title)
        }
    }
}

private struct IOSSessionManagementGuideView: View {
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot

    @State private var practicedRename = false
    @State private var practicedMove = false
    @State private var practicedBranch = false
    @State private var practicedDeleteLast = false
    @State private var practicedDelete = false

    private var isCompleted: Bool {
        practicedRename && practicedMove && practicedBranch && practicedDeleteLast && practicedDelete
    }

    var body: some View {
        List {
            IOSGuideHeaderView(
                title: "会话管理",
                summary: "iOS 端会话管理的重点操作主要藏在“长按会话项”里，不要只点进去看内容。",
                isCompleted: progressStore.isGuideCompleted(.sessionManagement)
            )

            Section("你最常找的动作") {
                checklistRow("想改会话名：长按会话项 → 重命名", completed: practicedRename)
                checklistRow("想移到文件夹：长按会话项 → 移动到文件夹", completed: practicedMove)
                checklistRow("想从当前状态分支：长按会话项 → 创建分支", completed: practicedBranch)
                checklistRow("想只撤回一步：长按会话项 → 删除最后一条消息", completed: practicedDeleteLast)
                checklistRow("想彻底删除：长按会话项 → 删除会话", completed: practicedDelete)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("样例：项目整理")
                        Text(sessionPracticeSubtitle)
                            .etFont(.caption)
                            .foregroundStyle(isCompleted ? .green : .secondary)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("重命名") {
                        practicedRename = true
                    }

                    Menu("移动到文件夹") {
                        Button("工作 / 当前项目") {
                            practicedMove = true
                        }
                        Button("未分类") {
                            practicedMove = true
                        }
                    }

                    Button("创建提示词分支") {
                        practicedBranch = true
                    }

                    Button("删除最后一条消息") {
                        practicedDeleteLast = true
                    }

                    Button(role: .destructive) {
                        practicedDelete = true
                    } label: {
                        Label("删除会话", systemImage: "trash")
                    }
                }
            } header: {
                Text("试一试：长按这条示例会话")
            } footer: {
                Text("真实会话列表里，先长按，再找动作。不要只盯着可见按钮。")
            }

            if snapshot.hasVisitedSessionManagement {
                Section("你已经进过真实会话管理页") {
                    Text("现在重点是把长按菜单里的动作实际试一遍。")
                        .foregroundStyle(.secondary)
                }
            }

            if isCompleted {
                Section {
                    Text("会话管理练习已完成。下次找不到操作时，先对会话项长按。")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("会话管理")
        .onAppear {
            progressStore.markGuideSeen(.sessionManagement)
        }
        .onChange(of: isCompleted) { _, newValue in
            guard newValue else { return }
            progressStore.markGuideCompleted(.sessionManagement)
        }
    }

    private var sessionPracticeSubtitle: String {
        let completedCount = [
            practicedRename,
            practicedMove,
            practicedBranch,
            practicedDeleteLast,
            practicedDelete
        ]
        .filter { $0 }
        .count
        return "已练习 \(completedCount) / 5 项"
    }

    @ViewBuilder
    private func checklistRow(_ title: String, completed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed ? .green : .secondary)
            Text(title)
        }
    }
}

private struct IOSToolCenterBasicsGuideView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot

    var body: some View {
        List {
            IOSGuideHeaderView(
                title: "工具中心入门",
                summary: "工具中心最重要的不是“开关在哪”，而是看懂“配置已启用”和“当前会话可用”的区别。",
                isCompleted: snapshot.isSatisfied(for: .toolCenterBasics) || progressStore.isGuideCompleted(.toolCenterBasics)
            )

            Section("先看这 3 点") {
                checklistRow("已经进入过工具中心", completed: snapshot.hasVisitedToolCenter)
                checklistRow("知道要先看汇总区", completed: snapshot.hasVisitedToolCenter)
                checklistRow("知道世界书隔离会屏蔽部分工具", completed: snapshot.hasVisitedToolCenter)
            }

            Section("遇到“明明开了却不能用”时") {
                Text("先看“当前会话可用”，不要只看“配置已启用”。")
                Text("如果有世界书隔离发送提示，记忆、MCP、Agent Skills、快捷指令可能会被会话策略屏蔽。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("直接去做") {
                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    Label("进入工具中心", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle("工具中心入门")
        .onAppear {
            progressStore.markGuideSeen(.toolCenterBasics)
            if snapshot.isSatisfied(for: .toolCenterBasics) {
                progressStore.markGuideCompleted(.toolCenterBasics)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(_ title: String, completed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed ? .green : .secondary)
            Text(title)
        }
    }
}

private struct IOSSwipePracticeRow: View {
    let title: String
    let subtitle: String
    let onLeadingAction: () -> Void
    let onTrailingAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(subtitle)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("左滑动作") {
                onLeadingAction()
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onTrailingAction()
            } label: {
                Text("右滑动作")
            }
        }
    }
}
