// ============================================================================
// FeedbackCenterView.swift
// ============================================================================
// FeedbackCenterView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
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
            Section {
                NavigationLink {
                    FeedbackComposeView()
                } label: {
                    Label(NSLocalizedString("新建反馈", comment: "Create feedback"), systemImage: "square.and.pencil")
                }
            } footer: {
                Text(NSLocalizedString("应用内提交问题与建议，并追踪处理进度。", comment: "Feedback center footer"))
            }

            Section(NSLocalizedString("我的反馈", comment: "My feedback list")) {
                if service.tickets.isEmpty {
                    Text(NSLocalizedString("暂无反馈记录", comment: "No feedback records"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.tickets) { ticket in
                        NavigationLink {
                            FeedbackDetailView(issueNumber: ticket.issueNumber)
                        } label: {
                            FeedbackTicketRow(ticket: ticket)
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
        }
    }
}

private struct FeedbackTicketRow: View {
    let ticket: FeedbackTicket

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), ticket.issueNumber))
                    .etFont(.subheadline.weight(.semibold))
                Text(ticket.title)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(ticket.lastKnownStatus.localizedTitle)
                .etFont(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.14), in: Capsule())
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch ticket.lastKnownStatus {
        case .triage:
            return .orange
        case .inProgress:
            return .blue
        case .blocked:
            return .red
        case .resolved:
            return .green
        case .closed:
            return .gray
        case .unknown:
            return .secondary
        @unknown default:
            return .secondary
        }
    }
}

struct FeedbackComposeView: View {
    @EnvironmentObject private var controller: GuideConversationController

    var body: some View {
        FeedbackComposeForm(pageID: "feedback-compose", service: .shared, controller: controller, prepareGuide: {
            GuideContextCoordinator.shared.pinActivePage()
        })
    }
}

struct FeedbackDetailView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var service = FeedbackService.shared

    let issueNumber: Int

    @State private var snapshot: FeedbackStatusSnapshot?
    @State private var isLoading = false
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
                    Spacer()
                    Text((snapshot?.status ?? ticket?.lastKnownStatus ?? .unknown).localizedTitle)
                        .foregroundStyle(.secondary)
                }

                if let updatedAt = snapshot?.updatedAt ?? ticket?.lastKnownUpdatedAt {
                    HStack {
                        Text(NSLocalizedString("最后更新", comment: "Last updated label"))
                        Spacer()
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task {
                        await refreshStatus()
                    }
                } label: {
                    if isLoading {
                        Label(NSLocalizedString("刷新中...", comment: "Refreshing"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label(NSLocalizedString("刷新状态", comment: "Refresh status button"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isLoading || ticket == nil)

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
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.label)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                            FeedbackMarkdownView(content: field.value)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(NSLocalizedString("处理动态", comment: "Feedback timeline section")) {
                if displayedTimelineEvents.isEmpty {
                    Text(NSLocalizedString("暂无处理动态", comment: "No feedback timeline events"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedTimelineEvents) { event in
                        switch event {
                        case .comment(let comment):
                            FeedbackCommentTimelineRow(comment: comment)
                        case .referencedCommit(_, let actor, let createdAt, let commit):
                            Button {
                                selectedReferencedCommit = makeUpdateTimelineCommit(from: commit)
                            } label: {
                                FeedbackReferencedCommitTimelineRow(
                                    actor: actor,
                                    createdAt: createdAt,
                                    commit: commit
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TextField(NSLocalizedString("补充评论（会进入同一工单）", comment: "Feedback comment input"), text: $commentDraft, axis: .vertical)
                    .lineLimit(2...6)

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
                        .etFont(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section(NSLocalizedString("标签", comment: "Labels section")) {
                let labels = snapshot?.labels ?? []
                if labels.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No labels"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .etFont(.footnote)
                    }
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
                .readOnly("refreshing", label: NSLocalizedString("刷新中...", comment: ""), value: { .bool(isLoading) }),
                .readOnly("event_count", label: NSLocalizedString("处理动态", comment: ""), value: { .int(snapshot?.timelineEvents.count ?? 0) }),
                .readOnly("comment_ready", label: NSLocalizedString("补充评论（会进入同一工单）", comment: ""), value: { .bool(!commentDraft.isEmpty) }),
                .readOnly("sending", label: NSLocalizedString("发送中...", comment: ""), value: { .bool(isSendingComment) })
            ]
        )
        .task {
            await refreshStatus()
        }
        .alert(
            NSLocalizedString("刷新失败", comment: "Refresh failed alert title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(NSLocalizedString("确定", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .navigationDestination(item: $selectedReferencedCommit) { commit in
            UpdateTimelineCommitDetailView(commit: commit)
        }
    }

    private func refreshStatus() async {
        guard let ticket else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await service.fetchStatus(ticket: ticket)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FeedbackCommentTimelineRow: View {
    let comment: FeedbackComment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(comment.author)
                    .etFont(.caption.weight(.semibold))

                Image(systemName: comment.isDeveloper ? "checkmark.seal.fill" : "person.fill")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(roleIconColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(roleBadgeBackground, in: Capsule())

                Spacer(minLength: 8)

                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            FeedbackMarkdownView(content: comment.body)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(roleStripeColor)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 4)
        }
        .padding(.vertical, 3)
    }

    private var roleStripeColor: Color {
        comment.isDeveloper ? .green : .blue
    }

    private var roleBadgeBackground: Color {
        comment.isDeveloper ? .green.opacity(0.16) : .blue.opacity(0.16)
    }

    private var roleIconColor: Color {
        comment.isDeveloper ? .green : .blue
    }
}

private struct FeedbackReferencedCommitTimelineRow: View {
    let actor: String
    let createdAt: Date
    let commit: FeedbackReferencedCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(actorDisplayName)
                    .etFont(.caption.weight(.semibold))

                Image(systemName: "arrow.triangle.branch")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.14), in: Capsule())

                Spacer(minLength: 8)

                Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(NSLocalizedString("引用了 Commit", comment: "Referenced commit timeline action"))
                .etFont(.caption)
                .foregroundStyle(.secondary)

            Text(commit.displayHeadline)
                .etFont(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(commit.displayShortSHA)
                    .etFont(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if commit.verified {
                    Label(NSLocalizedString("已验证", comment: "Verified commit badge"), systemImage: "checkmark.seal.fill")
                        .etFont(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.purple)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 4)
        }
        .padding(.vertical, 3)
    }

    private var actorDisplayName: String {
        let trimmed = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSLocalizedString("开发者", comment: "Developer fallback author") : trimmed
    }
}
