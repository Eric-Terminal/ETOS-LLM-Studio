// ============================================================================
// OnboardingHubView.swift
// ============================================================================
// ETOS LLM Studio Watch 新手教程中心
//
// 功能特性:
// - 提供统一的新手教程入口
// - 汇总快速开始清单与隐藏交互教程
// - 提供可反复进入的 watchOS 演示练习页
// ============================================================================

import SwiftUI
import Shared

struct OnboardingHubView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let openChat: (() -> Void)?

    @State private var snapshot: OnboardingChecklistSnapshot = .empty

    init(viewModel: ChatViewModel, openChat: (() -> Void)? = nil) {
        self.viewModel = viewModel
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
                HStack(alignment: .center, spacing: 10) {
                    Image("AppIconDisplay")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ETOS 新手教程")
                            .etFont(.headline)
                            .foregroundStyle(.white)
                        Text("先练左滑、右滑和长按，再学具体入口。")
                            .etFont(.caption2)
                            .foregroundStyle(WatchOnboardingPalette.secondaryText)
                    }
                }
                .watchOnboardingCard(horizontal: 12, vertical: 12)
            }

            Section("快速开始") {
                guideRow(
                    title: "第一个提供商与模型",
                    summary: providerGuideSummary,
                    guideID: .firstProvider
                ) {
                    WatchFirstProviderGuideView(viewModel: viewModel, snapshot: snapshot)
                }

                guideRow(
                    title: "第一次发起聊天",
                    summary: firstChatGuideSummary,
                    guideID: .firstChat
                ) {
                    WatchFirstChatGuideView(snapshot: snapshot, openChat: openChat)
                }

                guideRow(
                    title: "工具中心入门",
                    summary: toolCenterGuideSummary,
                    guideID: .toolCenterBasics
                ) {
                    WatchToolCenterBasicsGuideView(viewModel: viewModel, snapshot: snapshot)
                }
            }

            Section("隐藏操作先学会") {
                guideRow(
                    title: "交互约定",
                    summary: "左滑看更多，右滑常常是删除。",
                    guideID: .interactionPrimer
                ) {
                    WatchInteractionPrimerGuideView()
                }

                guideRow(
                    title: "会话管理",
                    summary: "会话列表很多动作都藏在左滑“更多”里。",
                    guideID: .sessionManagement
                ) {
                    WatchSessionManagementGuideView(snapshot: snapshot)
                }
            }

            Section("按主题学习") {
                Text("真实会话管理请从设置里的历史会话进入。教程页只带你先练手势，不会改动现有会话。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                Button {
                    openChat?()
                } label: {
                    Label("回到聊天页开始练习", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(openChat == nil)
            }
        }
        .navigationTitle("新手教程")
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
        .task(id: snapshotRefreshKey) {
            await refreshSnapshot()
        }
    }

    private var providerGuideSummary: String {
        if snapshot.hasVisitedProviderManagement && snapshot.hasProvider && snapshot.hasActivatedModel {
            return "已经具备聊天所需模型。"
        }
        if !snapshot.hasProvider {
            return "先添加一个提供商。"
        }
        if !snapshot.hasActivatedModel {
            return "别忘了启用模型。"
        }
        return "先记住入口，再把配置配通。"
    }

    private var firstChatGuideSummary: String {
        if snapshot.currentModelDisplayName == nil {
            return "先确认当前模型可用。"
        }
        if !snapshot.hasSentMessage {
            return "下一步发出第一条消息。"
        }
        return "已经开始聊天，可以继续学消息操作。"
    }

    private var toolCenterGuideSummary: String {
        snapshot.hasVisitedToolCenter
            ? "你已经进过工具中心。"
            : "先学会怎么看“实际可用”。"
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
            HStack(alignment: .center, spacing: 8) {
                WatchOnboardingIconBadge(
                    systemName: guideSymbol(for: guideID),
                    tint: guideColor(for: guideID)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundStyle(.white)
                    Text(summary)
                        .etFont(.caption2)
                        .foregroundStyle(WatchOnboardingPalette.secondaryText)
                }
                Spacer()
                WatchOnboardingCompletionBadge(isCompleted: guideCompleted(guideID))
                Image(systemName: "chevron.right")
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(WatchOnboardingPalette.secondaryText)
            }
            .watchOnboardingCard(horizontal: 12, vertical: 12)
        }
        .buttonStyle(.plain)
    }

    private func guideCompleted(_ guideID: OnboardingGuideID) -> Bool {
        progressStore.isGuideCompleted(guideID) || snapshot.isSatisfied(for: guideID)
    }

    private func refreshSnapshot() async {
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
        synchronizeAutoCompletion(with: nextSnapshot)
    }

    private func synchronizeAutoCompletion(with snapshot: OnboardingChecklistSnapshot) {
        for guideID in [OnboardingGuideID.firstProvider, .firstChat, .toolCenterBasics] where snapshot.isSatisfied(for: guideID) {
            progressStore.markGuideCompleted(guideID)
        }
    }

    private func guideSymbol(for guideID: OnboardingGuideID) -> String {
        switch guideID {
        case .interactionPrimer:
            return "hand.draw.fill"
        case .firstProvider:
            return "shippingbox.fill"
        case .firstChat:
            return "bubble.left.and.bubble.right.fill"
        case .sessionManagement:
            return "text.bubble.fill"
        case .toolCenterBasics:
            return "slider.horizontal.3"
        }
    }

    private func guideColor(for guideID: OnboardingGuideID) -> Color {
        switch guideID {
        case .interactionPrimer:
            return .purple
        case .firstProvider:
            return .blue
        case .firstChat:
            return .mint
        case .sessionManagement:
            return .orange
        case .toolCenterBasics:
            return .yellow
        }
    }
}

struct WatchOnboardingHintCard: View {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("AppIconDisplay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .etFont(.headline)
                        .foregroundStyle(.white)
                    Text("先试一遍，再回真实页面。")
                        .etFont(.caption2)
                        .foregroundStyle(WatchOnboardingPalette.secondaryText)
                }
            }
            Text(message)
                .etFont(.caption2)
                .foregroundStyle(WatchOnboardingPalette.secondaryText)
            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                }
                .tint(.white)
            }
            Button("知道了") {
                onDismiss()
            }
            .tint(.accentColor)
        }
        .watchOnboardingCard(horizontal: 12, vertical: 12)
    }
}

private struct WatchOnboardingCompletionBadge: View {
    let isCompleted: Bool

    var body: some View {
        Text(isCompleted ? "完成" : "待做")
            .etFont(.caption2.weight(.semibold))
            .foregroundStyle(isCompleted ? .white : WatchOnboardingPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isCompleted ? Color.green.opacity(0.88) : WatchOnboardingPalette.switchOff)
            )
    }
}

private struct WatchGuideHeaderView: View {
    let title: String
    let summary: String
    let isCompleted: Bool

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                Image("AppIconDisplay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .etFont(.headline)
                        .foregroundStyle(.white)
                    Text(summary)
                        .etFont(.caption2)
                        .foregroundStyle(WatchOnboardingPalette.secondaryText)
                    WatchOnboardingCompletionBadge(isCompleted: isCompleted)
                }
            }
            .watchOnboardingCard(horizontal: 12, vertical: 12)
        }
    }
}

private struct WatchOnboardingIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.24))
            Image(systemName: systemName)
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
    }
}

private struct WatchOnboardingStatusRow: View {
    let title: String
    let completed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(title)
                .etFont(.caption)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            WatchOnboardingSwitchIndicator(isOn: completed)
        }
        .watchOnboardingCard(horizontal: 10, vertical: 10)
    }
}

private struct WatchOnboardingSwitchIndicator: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green.opacity(0.88) : WatchOnboardingPalette.switchOff)
                .frame(width: 36, height: 22)

            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .padding(3)
        }
    }
}

private enum WatchOnboardingPalette {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let border = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.68)
    static let switchOff = Color.white.opacity(0.18)
}

private struct WatchOnboardingCardModifier: ViewModifier {
    let horizontal: CGFloat
    let vertical: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(WatchOnboardingPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(WatchOnboardingPalette.border, lineWidth: 1)
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func watchOnboardingCard(horizontal: CGFloat = 12, vertical: CGFloat = 12) -> some View {
        modifier(WatchOnboardingCardModifier(horizontal: horizontal, vertical: vertical))
    }
}

private struct WatchInteractionPrimerGuideView: View {
    @ObservedObject private var progressStore = OnboardingProgressStore.shared
    @State private var openedMoreActions = false
    @State private var usedDeleteSwipe = false
    @State private var openedMessageActions = false

    private var isCompleted: Bool {
        openedMoreActions && usedDeleteSwipe && openedMessageActions
    }

    var body: some View {
        List {
            WatchGuideHeaderView(
                title: "交互约定",
                summary: "watch 端先试左滑看更多，再试右滑。很多按钮不会直接摆在界面上。",
                isCompleted: progressStore.isGuideCompleted(.interactionPrimer)
            )

            Section("先记住") {
                Text("左滑看更多，右滑常常是删除。")
                    .foregroundStyle(.white)
                Text("消息和会话列表都要先试这两个方向。")
                    .etFont(.caption2)
                    .foregroundStyle(WatchOnboardingPalette.secondaryText)
            }

            Section("试一试：左滑看更多") {
                WatchSwipeMorePracticeRow(
                    title: "样例：左滑我",
                    subtitle: openedMoreActions ? "已完成左滑练习" : "左滑进入“更多”",
                    actionTitle: "更多",
                    destination: WatchPracticeActionsSheet(
                        title: "更多操作",
                        buttons: [
                            .init(title: "知道了，这里会放更多动作") {
                                openedMoreActions = true
                            }
                        ]
                    )
                )
            }

            Section("试一试：右滑删除") {
                WatchDeletePracticeRow(
                    title: "样例：右滑我",
                    subtitle: usedDeleteSwipe ? "已完成右滑练习" : "右滑触发删除动作",
                    onDelete: {
                        usedDeleteSwipe = true
                    }
                )
            }

            Section("试一试：消息也要左滑") {
                WatchSwipeMorePracticeRow(
                    title: "样例：左滑消息",
                    subtitle: openedMessageActions ? "已完成消息操作练习" : "左滑打开消息操作",
                    actionTitle: "消息操作",
                    destination: WatchPracticeActionsSheet(
                        title: "消息操作",
                        buttons: [
                            .init(title: "编辑") {
                                openedMessageActions = true
                            },
                            .init(title: "导出") {
                                openedMessageActions = true
                            }
                        ]
                    )
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
        .navigationTitle("交互约定")
        .onAppear {
            progressStore.markGuideSeen(.interactionPrimer)
        }
        .onChange(of: isCompleted) { _, newValue in
            guard newValue else { return }
            progressStore.markGuideCompleted(.interactionPrimer)
        }
    }
}

private struct WatchFirstProviderGuideView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot

    var body: some View {
        List {
            WatchGuideHeaderView(
                title: "第一个提供商与模型",
                summary: "先把模型配通，聊天页才会真正可用。",
                isCompleted: snapshot.isSatisfied(for: .firstProvider) || progressStore.isGuideCompleted(.firstProvider)
            )

            Section("完成这 4 件事") {
                checklistRow("进入一次提供商管理", completed: snapshot.hasVisitedProviderManagement)
                checklistRow("至少保存一个提供商", completed: snapshot.hasProvider)
                checklistRow("至少启用一个模型", completed: snapshot.hasActivatedModel)
                checklistRow("记住模型顺序入口", completed: snapshot.hasVisitedProviderManagement)
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
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
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
        WatchOnboardingStatusRow(title: title, completed: completed)
    }
}

private struct WatchFirstChatGuideView: View {
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot
    let openChat: (() -> Void)?

    var body: some View {
        List {
            WatchGuideHeaderView(
                title: "第一次发起聊天",
                summary: "先确认当前模型，再发一条消息。发完以后，记得左滑消息看看操作页。",
                isCompleted: snapshot.isSatisfied(for: .firstChat) || progressStore.isGuideCompleted(.firstChat)
            )

            Section("完成这 4 件事") {
                checklistRow("当前已有可用模型", completed: snapshot.currentModelDisplayName != nil)
                checklistRow("已经进入过聊天页", completed: snapshot.hasVisitedChat)
                checklistRow("至少有一个真实会话", completed: snapshot.hasNonTemporarySession)
                checklistRow("至少发出过一条消息", completed: snapshot.hasSentMessage)
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
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
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
        WatchOnboardingStatusRow(title: title, completed: completed)
    }
}

private struct WatchSessionManagementGuideView: View {
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
            WatchGuideHeaderView(
                title: "会话管理",
                summary: "watch 端会话管理先左滑看“更多”，右滑通常就是删除。",
                isCompleted: progressStore.isGuideCompleted(.sessionManagement)
            )

            Section("你最常找的动作") {
                checklistRow("想改会话名：左滑 → 更多 → 编辑话题", completed: practicedRename)
                checklistRow("想移到文件夹：左滑 → 更多 → 移动到文件夹", completed: practicedMove)
                checklistRow("想创建分支：左滑 → 更多 → 创建分支", completed: practicedBranch)
                checklistRow("想撤回一步：左滑 → 更多 → 删除最后一条消息", completed: practicedDeleteLast)
                checklistRow("想彻底删除：右滑删除", completed: practicedDelete)
            }

            Section("试一试：左滑会话看更多") {
                WatchSwipeMorePracticeRow(
                    title: "样例：项目整理",
                    subtitle: leftSwipeSubtitle,
                    actionTitle: "更多",
                    destination: WatchPracticeActionsSheet(
                        title: "会话操作",
                        buttons: [
                            .init(title: "编辑话题") { practicedRename = true },
                            .init(title: "移动到文件夹") { practicedMove = true },
                            .init(title: "创建分支") { practicedBranch = true },
                            .init(title: "删除最后一条消息") { practicedDeleteLast = true }
                        ]
                    )
                )
            }

            Section("试一试：右滑删除") {
                WatchDeletePracticeRow(
                    title: "样例：删除我",
                    subtitle: practicedDelete ? "已完成右滑删除练习" : "右滑后删除",
                    onDelete: {
                        practicedDelete = true
                    }
                )
            }

            if snapshot.hasVisitedSessionManagement {
                Section {
                    Text("你已经进过真实会话管理页，接下来重点把左滑和右滑练熟。")
                        .etFont(.caption2)
                        .foregroundStyle(WatchOnboardingPalette.secondaryText)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
        .navigationTitle("会话管理")
        .onAppear {
            progressStore.markGuideSeen(.sessionManagement)
        }
        .onChange(of: isCompleted) { _, newValue in
            guard newValue else { return }
            progressStore.markGuideCompleted(.sessionManagement)
        }
    }

    private var leftSwipeSubtitle: String {
        let count = [practicedRename, practicedMove, practicedBranch, practicedDeleteLast].filter { $0 }.count
        return "已练习 \(count) / 4 项左滑动作"
    }

    @ViewBuilder
    private func checklistRow(_ title: String, completed: Bool) -> some View {
        WatchOnboardingStatusRow(title: title, completed: completed)
    }
}

private struct WatchToolCenterBasicsGuideView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var progressStore = OnboardingProgressStore.shared

    let snapshot: OnboardingChecklistSnapshot

    var body: some View {
        List {
            WatchGuideHeaderView(
                title: "工具中心入门",
                summary: "先学会看“当前会话实际可用”，不要只看总开关。",
                isCompleted: snapshot.isSatisfied(for: .toolCenterBasics) || progressStore.isGuideCompleted(.toolCenterBasics)
            )

            Section("先看这 3 点") {
                checklistRow("已经进入过工具中心", completed: snapshot.hasVisitedToolCenter)
                checklistRow("知道要先看汇总区", completed: snapshot.hasVisitedToolCenter)
                checklistRow("知道世界书隔离会屏蔽工具", completed: snapshot.hasVisitedToolCenter)
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
        .scrollContentBackground(.hidden)
        .background(WatchOnboardingPalette.background.ignoresSafeArea())
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
        WatchOnboardingStatusRow(title: title, completed: completed)
    }
}

private struct WatchSwipeMorePracticeRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let destination: Destination

    var body: some View {
        HStack(spacing: 8) {
            WatchOnboardingIconBadge(systemName: "hand.draw.fill", tint: .purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .etFont(.caption2)
                    .foregroundStyle(WatchOnboardingPalette.secondaryText)
            }
            Spacer()
        }
        .watchOnboardingCard(horizontal: 10, vertical: 10)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            NavigationLink {
                destination
            } label: {
                Label(actionTitle, systemImage: "ellipsis")
            }
            .tint(.gray)
        }
    }
}

private struct WatchDeletePracticeRow: View {
    let title: String
    let subtitle: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            WatchOnboardingIconBadge(systemName: "trash.fill", tint: .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .etFont(.caption2)
                    .foregroundStyle(WatchOnboardingPalette.secondaryText)
            }
            Spacer()
        }
        .watchOnboardingCard(horizontal: 10, vertical: 10)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct WatchPracticeActionsSheet: View {
    struct ActionButton: Identifiable {
        let id = UUID()
        let title: String
        let action: () -> Void
    }

    let title: String
    let buttons: [ActionButton]

    var body: some View {
        Form {
            Section {
                ForEach(buttons) { button in
                    Button(button.title) {
                        button.action()
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}
