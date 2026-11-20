// ============================================================================
// FeedbackCenterView.swift
// ============================================================================
// FeedbackCenterView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import ETOSCore

struct FeedbackCenterView: View {
    @ObservedObject private var service = FeedbackService.shared

    var body: some View {
        List {
            Section {
                settingsIntroCard
            }
            NavigationLink {
                WatchFeedbackComposeView()
            } label: {
                Label(NSLocalizedString("新建反馈", comment: "Create feedback"), systemImage: "square.and.pencil")
            }

            if service.tickets.isEmpty {
                Text(NSLocalizedString("暂无反馈记录", comment: "No feedback records"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.tickets) { ticket in
                    NavigationLink {
                        WatchFeedbackDetailView(issueNumber: ticket.issueNumber)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), ticket.issueNumber))
                                .etFont(.caption.weight(.semibold))
                            Text(ticket.title)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(ticket.lastKnownStatus.localizedTitle)
                                .etFont(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            service.deleteTicket(issueNumber: ticket.issueNumber)
                        } label: {
                            Label(NSLocalizedString("从列表移除", value: "Remove from List", comment: "移除本机反馈记录"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("反馈助手", comment: "Feedback center title"))
        .guideSettingsPageContext(
            id: "feedback-center",
            title: NSLocalizedString("反馈助手", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            settings: [
                .readOnly("ticket_count", label: NSLocalizedString("我的反馈", comment: ""), value: { .int(service.tickets.count) })
            ]
        )
        .watchGuideEntry()
        .task {
            service.reloadTickets()
        }
        .refreshable {
            await service.refreshAllTickets()
        }
    }

    private var settingsIntroCard: some View {
        SettingsHelpCard(
            title: NSLocalizedString("反馈与处理进度", value: "Feedback and progress", comment: "反馈介绍卡标题"),
            summary: NSLocalizedString("应用内提交问题与建议，并追踪处理进度。", value: "Submit issues or suggestions in-app and track progress.", comment: "反馈介绍卡摘要")
        ) {
            SettingsHelpText(NSLocalizedString("反馈助手使用说明", comment: "反馈介绍卡教程"))
                .guideSettingsPageContext(
                    id: "feedback-introduction",
                    title: NSLocalizedString("反馈与处理进度", value: "Feedback and progress", comment: "反馈介绍页标题"),
                    documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
                    settings: [.readOnly("read_only", label: NSLocalizedString("反馈与处理进度", comment: ""), value: { .bool(true) })]
                )
                .watchGuideEntry()
        }
    }
}

struct WatchFeedbackComposeView: View {
    @EnvironmentObject private var controller: GuideConversationController
    @State private var showsGuide = false

    var body: some View {
        FeedbackComposeForm(pageID: "feedback-compose", service: .shared, controller: controller,
                            adaptKeyboard: { $0.watchKeyboardNewlineBinding() }) {
            GuideContextCoordinator.shared.pinActivePage()
            WatchGuideSheetNavigation.shared.close = { showsGuide = false }
        }
        .environment(\.feedbackGuidePresentation, $showsGuide)
        .watchGuideEntry()
        .sheet(isPresented: $showsGuide, onDismiss: {
            GuideContextCoordinator.shared.unpinActivePage()
            WatchGuideSheetNavigation.shared.didDismiss()
        }) {
            NavigationStack {
                WatchGuideConversationView(controller: controller) { showsGuide = false }
            }
        }
    }
}

struct WatchFeedbackDetailView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var service = FeedbackService.shared

    let issueNumber: Int

    @State private var snapshot: FeedbackStatusSnapshot?
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var commentDraft: String = ""
    @State private var isSendingComment = false
    @State private var selectedReferencedCommit: UpdateTimelineCommit?

    private var ticket: FeedbackTicket? {
        service.tickets.first { $0.issueNumber == issueNumber }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(NSLocalizedString("状态", comment: "Status label"))
                        .etFont(.caption2)
                    Spacer()
                    Text((snapshot?.status ?? ticket?.lastKnownStatus ?? .unknown).localizedTitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await refreshStatus()
                    }
                } label: {
                    Label(NSLocalizedString("刷新状态", comment: "Refresh status button"), systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || ticket == nil)

                if let url = snapshot?.publicURL ?? ticket?.publicURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(NSLocalizedString("打开 GitHub 页面", comment: "Open GitHub page"), systemImage: "safari")
                    }
                }
            }

            if !submittedFields.isEmpty {
                Section(NSLocalizedString("我的反馈", comment: "My feedback list")) {
                    ForEach(Array(submittedFields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.label)
                                .etFont(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            FeedbackMarkdownView(content: field.value)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(NSLocalizedString("处理动态", comment: "Feedback timeline section")) {
                if displayedTimelineEvents.isEmpty {
                    Text(NSLocalizedString("暂无处理动态", comment: "No feedback timeline events"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedTimelineEvents) { event in
                        switch event {
                        case .comment(let comment):
                            WatchFeedbackCommentTimelineRow(comment: comment)
                        case .referencedCommit(_, let actor, let createdAt, let commit):
                            Button {
                                selectedReferencedCommit = makeUpdateTimelineCommit(from: commit)
                            } label: {
                                WatchFeedbackReferencedCommitTimelineRow(
                                    actor: actor,
                                    createdAt: createdAt,
                                    commit: commit
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TextField(
                    NSLocalizedString("补充评论（会进入同一工单）", comment: "Feedback comment input"),
                    text: $commentDraft.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(2...5)

                Button {
                    Task {
                        await sendComment()
                    }
                } label: {
                    if isSendingComment {
                        Label(NSLocalizedString("发送中...", comment: "Sending comment"), systemImage: "paperplane")
                    } else {
                        Label(NSLocalizedString("发送评论", comment: "Send comment"), systemImage: "paperplane")
                    }
                }
                .disabled(isSendingComment || ticket == nil || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let moderationMessage = ticket?.moderationMessage,
               !moderationMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text(moderationMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Section(NSLocalizedString("标签", comment: "Labels section")) {
                let labels = snapshot?.labels ?? []
                if labels.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No labels"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .etFont(.caption2)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), issueNumber))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "feedback-detail-\(issueNumber)"),
            title: NSLocalizedString("反馈助手", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            settings: [
                .readOnly("issue_number", label: NSLocalizedString("我的反馈", comment: ""), value: { .int(issueNumber) }),
                .readOnly("status", label: NSLocalizedString("状态", comment: ""), value: { .string((snapshot?.status ?? ticket?.lastKnownStatus ?? .unknown).rawValue) }),
                .readOnly("refreshing", label: NSLocalizedString("刷新中...", comment: ""), value: { .bool(isRefreshing) }),
                .readOnly("event_count", label: NSLocalizedString("处理动态", comment: ""), value: { .int(snapshot?.timelineEvents.count ?? 0) }),
                .readOnly("comment_ready", label: NSLocalizedString("补充评论（会进入同一工单）", comment: ""), value: { .bool(!commentDraft.isEmpty) }),
                .readOnly("sending", label: NSLocalizedString("发送中...", comment: ""), value: { .bool(isSendingComment) })
            ]
        )
        .watchGuideEntry()
        .navigationDestination(item: $selectedReferencedCommit) { commit in
            WatchUpdateTimelineCommitDetailView(commit: commit)
        }
        .task {
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        guard let ticket else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await service.fetchStatus(ticket: ticket)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var displayedComments: [FeedbackComment] {
        (snapshot?.comments ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private var displayedTimelineEvents: [FeedbackTimelineEvent] {
        let events = snapshot?.timelineEvents ?? []
        if events.isEmpty {
            return displayedComments.map(FeedbackTimelineEvent.comment)
        }
        return events.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private func makeUpdateTimelineCommit(from commit: FeedbackReferencedCommit) -> UpdateTimelineCommit {
        if let cached = UpdateTimelineManager.shared.timelineCommit(matching: commit.sha) {
            return cached
        }
        return UpdateTimelineCommit(
            oid: commit.sha,
            messageHeadline: commit.displayHeadline,
            message: commit.message,
            committedDate: commit.committedAt,
            url: commit.htmlURL,
            ciContexts: []
        )
    }

    private var submittedFields: [(label: String, value: String)] {
        guard let ticket else { return [] }

        func appendIfPresent(_ label: String, value: String?, to result: inout [(label: String, value: String)]) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return
            }
            result.append((label: label, value: value))
        }

        var fields: [(label: String, value: String)] = []
        appendIfPresent(
            NSLocalizedString("标题", comment: "Feedback title field"),
            value: ticket.submittedTitle ?? ticket.title,
            to: &fields
        )
        appendIfPresent(
            NSLocalizedString("详细描述", comment: "Feedback detail field"),
            value: ticket.submittedDetail,
            to: &fields
        )
        appendIfPresent(
            NSLocalizedString("可复现步骤（可选）", comment: "Reproduction steps"),
            value: ticket.submittedReproductionSteps,
            to: &fields
        )
        appendIfPresent(
            NSLocalizedString("预期行为（可选）", comment: "Expected behavior"),
            value: ticket.submittedExpectedBehavior,
            to: &fields
        )
        appendIfPresent(
            NSLocalizedString("实际行为（可选）", comment: "Actual behavior"),
            value: ticket.submittedActualBehavior,
            to: &fields
        )
        appendIfPresent(
            NSLocalizedString("补充信息（可选）", comment: "Extra context"),
            value: ticket.submittedExtraContext,
            to: &fields
        )
        return fields
    }

    private func sendComment() async {
        guard let ticket else { return }
        let pending = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty else { return }

        isSendingComment = true
        defer { isSendingComment = false }

        do {
            _ = try await service.submitComment(ticket: ticket, body: pending)
            commentDraft = ""
            snapshot = try await service.fetchStatus(ticket: ticket)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WatchFeedbackCommentTimelineRow: View {
    let comment: FeedbackComment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(comment.author)
                    .etFont(.system(size: 9, weight: .semibold))

                Image(systemName: comment.isDeveloper ? "checkmark.seal.fill" : "person.fill")
                    .etFont(.system(size: 8, weight: .medium))
                    .foregroundStyle(roleIconColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(roleBadgeBackground, in: Capsule())

                Spacer(minLength: 6)

                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .etFont(.system(size: 8))
                    .foregroundStyle(.secondary)
            }

            FeedbackMarkdownView(content: comment.body)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(roleStripeColor)
                .frame(width: 3)
                .padding(.vertical, 5)
                .padding(.leading, 3)
        }
        .padding(.vertical, 1)
    }

    private var roleStripeColor: Color {
        comment.isDeveloper ? .green : .blue
    }

    private var roleBadgeBackground: Color {
        comment.isDeveloper ? .green.opacity(0.20) : .blue.opacity(0.20)
    }

    private var roleIconColor: Color {
        comment.isDeveloper ? .green : .blue
    }
}

private struct WatchFeedbackReferencedCommitTimelineRow: View {
    let actor: String
    let createdAt: Date
    let commit: FeedbackReferencedCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(actorDisplayName)
                    .etFont(.system(size: 9, weight: .semibold))

                Image(systemName: "arrow.triangle.branch")
                    .etFont(.system(size: 8, weight: .medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.20), in: Capsule())

                Spacer(minLength: 6)

                Text(createdAt.formatted(date: .numeric, time: .shortened))
                    .etFont(.system(size: 8))
                    .foregroundStyle(.secondary)
            }

            Text(NSLocalizedString("引用了 Commit", comment: "Referenced commit timeline action"))
                .etFont(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(commit.displayHeadline)
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)

            HStack(spacing: 5) {
                Text(commit.displayShortSHA)
                    .etFont(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if commit.verified {
                    Image(systemName: "checkmark.seal.fill")
                        .etFont(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                        .accessibilityLabel(NSLocalizedString("已验证", comment: "Verified commit badge"))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.purple)
                .frame(width: 3)
                .padding(.vertical, 5)
                .padding(.leading, 3)
        }
        .padding(.vertical, 1)
    }

    private var actorDisplayName: String {
        let trimmed = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSLocalizedString("开发者", comment: "Developer fallback author") : trimmed
    }
}
