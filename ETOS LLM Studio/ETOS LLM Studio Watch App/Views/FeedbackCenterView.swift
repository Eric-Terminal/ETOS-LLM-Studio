import SwiftUI
import Shared

struct FeedbackCenterView: View {
    @ObservedObject private var service = FeedbackService.shared

    var body: some View {
        List {
            NavigationLink {
                WatchFeedbackComposeView()
            } label: {
                Label(NSLocalizedString("新建反馈", comment: "Create feedback"), systemImage: "square.and.pencil")
            }

            if service.tickets.isEmpty {
                Text(NSLocalizedString("暂无反馈记录", comment: "No feedback records"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.tickets) { ticket in
                    NavigationLink {
                        WatchFeedbackDetailView(issueNumber: ticket.issueNumber)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), ticket.issueNumber))
                                .font(.caption.weight(.semibold))
                            Text(ticket.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(ticket.lastKnownStatus.localizedTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            service.deleteTicket(issueNumber: ticket.issueNumber)
                        } label: {
                            Label(NSLocalizedString("删除本地索引", comment: "Delete local index"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("反馈助手", comment: "Feedback center title"))
        .task {
            service.reloadTickets()
        }
        .refreshable {
            await service.refreshAllTickets()
        }
    }
}

private struct WatchFeedbackComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = FeedbackService.shared

    @State private var category: FeedbackCategory = .bug
    @State private var title: String = ""
    @State private var detail: String = ""
    @State private var reproductionSteps: String = ""
    @State private var expectedBehavior: String = ""
    @State private var actualBehavior: String = ""
    @State private var extraContext: String = ""
    @State private var isSubmitting = false
    @State private var submitErrorMessage: String?

    var body: some View {
        List {
            Section(NSLocalizedString("反馈类型", comment: "Feedback category section")) {
                Picker(NSLocalizedString("反馈类型", comment: "Feedback category picker"), selection: $category) {
                    ForEach(FeedbackCategory.allCases) { category in
                        Text(category.localizedTitle).tag(category)
                    }
                }
            }

            Section {
                TextField(NSLocalizedString("标题", comment: "Feedback title field"), text: $title.watchKeyboardNewlineBinding())
                TextField(
                    NSLocalizedString("详细描述", comment: "Feedback detail field"),
                    text: $detail.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...8)
            }

            if category == .bug {
                Section(NSLocalizedString("问题细节（可选）", comment: "Bug detail optional section")) {
                    TextField(
                        NSLocalizedString("可复现步骤（可选）", comment: "Reproduction steps"),
                        text: $reproductionSteps.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                    .lineLimit(3...6)

                    TextField(
                        NSLocalizedString("预期行为（可选）", comment: "Expected behavior"),
                        text: $expectedBehavior.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                    .lineLimit(2...5)

                    TextField(
                        NSLocalizedString("实际行为（可选）", comment: "Actual behavior"),
                        text: $actualBehavior.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }
            }

            Section {
                TextField(
                    NSLocalizedString("补充信息（可选）", comment: "Extra context"),
                    text: $extraContext.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(2...5)
            }

            Section {
                Button {
                    Task {
                        await submit()
                    }
                } label: {
                    if isSubmitting {
                        Label(NSLocalizedString("提交中...", comment: "Submitting state"), systemImage: "hourglass")
                    } else {
                        Label(NSLocalizedString("提交", comment: "Submit button"), systemImage: "paperplane")
                    }
                }
                .disabled(isSubmitting || !isDraftValid)
            } footer: {
                Text(environmentSummary)
            }
        }
        .navigationTitle(NSLocalizedString("新建反馈", comment: "Create feedback title"))
        .alert(
            NSLocalizedString("提交失败", comment: "Submit failed title"),
            isPresented: Binding(
                get: { submitErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        submitErrorMessage = nil
                    }
                }
            )
        ) {
            Button(NSLocalizedString("确定", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(submitErrorMessage ?? "")
        }
    }

    private var isDraftValid: Bool {
        let draft = FeedbackDraft(category: category, title: title, detail: detail)
        return draft.isValid
    }

    private var environmentSummary: String {
        let snapshot = FeedbackEnvironmentCollector.collectSnapshot()
        return String(
            format: NSLocalizedString("将自动附带环境信息：%@ %@ (Build %@) · %@", comment: "Environment summary"),
            snapshot.platform,
            snapshot.appVersion,
            snapshot.appBuild,
            snapshot.deviceModel
        )
    }

    private func submit() async {
        let draft = FeedbackDraft(
            category: category,
            title: title,
            detail: detail,
            reproductionSteps: reproductionSteps,
            expectedBehavior: expectedBehavior,
            actualBehavior: actualBehavior,
            extraContext: extraContext
        )
        guard draft.isValid else {
            submitErrorMessage = NSLocalizedString("请至少填写标题和详细描述。", comment: "Feedback invalid input")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await service.submit(draft: draft)
            dismiss()
        } catch {
            submitErrorMessage = error.localizedDescription
        }
    }
}

private struct WatchFeedbackDetailView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var service = FeedbackService.shared

    let issueNumber: Int

    @State private var snapshot: FeedbackStatusSnapshot?
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private var ticket: FeedbackTicket? {
        service.tickets.first { $0.issueNumber == issueNumber }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(NSLocalizedString("状态", comment: "Status label"))
                        .font(.caption2)
                    Spacer()
                    Text((snapshot?.status ?? ticket?.lastKnownStatus ?? .unknown).localizedTitle)
                        .font(.caption2)
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

            Section(NSLocalizedString("开发者公开回复", comment: "Public comments section")) {
                if (snapshot?.comments ?? []).isEmpty {
                    Text(NSLocalizedString("暂无公开回复", comment: "No public comments"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot?.comments ?? []) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.author)
                                .font(.caption2.weight(.semibold))
                            Text(comment.body)
                                .font(.caption2)
                                .lineLimit(6)
                            Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(NSLocalizedString("标签", comment: "Labels section")) {
                let labels = snapshot?.labels ?? []
                if labels.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No labels"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), issueNumber))
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
}
