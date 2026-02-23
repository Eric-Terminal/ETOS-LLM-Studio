import SwiftUI
import Shared

struct FeedbackCenterView: View {
    @ObservedObject private var service = FeedbackService.shared

    var body: some View {
        List {
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
                        .font(.footnote)
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
                                Label(NSLocalizedString("删除本地索引", comment: "Delete local index"), systemImage: "trash")
                            }
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

private struct FeedbackTicketRow: View {
    let ticket: FeedbackTicket

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), ticket.issueNumber))
                    .font(.subheadline.weight(.semibold))
                Text(ticket.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(ticket.lastKnownStatus.localizedTitle)
                .font(.caption2.weight(.medium))
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

private struct FeedbackComposeView: View {
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
        Form {
            Section(NSLocalizedString("反馈类型", comment: "Feedback category section")) {
                Picker(NSLocalizedString("反馈类型", comment: "Feedback category picker"), selection: $category) {
                    ForEach(FeedbackCategory.allCases) { category in
                        Text(category.localizedTitle).tag(category)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                TextField(NSLocalizedString("标题", comment: "Feedback title field"), text: $title)
                TextField(NSLocalizedString("详细描述", comment: "Feedback detail field"), text: $detail, axis: .vertical)
                    .lineLimit(4...8)
            }

            if category == .bug {
                Section(NSLocalizedString("问题细节（可选）", comment: "Bug detail optional section")) {
                    TextField(NSLocalizedString("可复现步骤（可选）", comment: "Reproduction steps"), text: $reproductionSteps, axis: .vertical)
                        .lineLimit(3...6)
                    TextField(NSLocalizedString("预期行为（可选）", comment: "Expected behavior"), text: $expectedBehavior, axis: .vertical)
                        .lineLimit(2...5)
                    TextField(NSLocalizedString("实际行为（可选）", comment: "Actual behavior"), text: $actualBehavior, axis: .vertical)
                        .lineLimit(2...5)
                }
            }

            Section {
                TextField(NSLocalizedString("补充信息（可选）", comment: "Extra context"), text: $extraContext, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section {
                Button {
                    Task {
                        await submit()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isSubmitting
                             ? NSLocalizedString("提交中...", comment: "Submitting state")
                             : NSLocalizedString("提交", comment: "Submit button"))
                        Spacer()
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

private struct FeedbackDetailView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var service = FeedbackService.shared

    let issueNumber: Int

    @State private var snapshot: FeedbackStatusSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

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

            Section(NSLocalizedString("开发者公开回复", comment: "Public comments section")) {
                if (snapshot?.comments ?? []).isEmpty {
                    Text(NSLocalizedString("暂无公开回复", comment: "No public comments"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot?.comments ?? []) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.author)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(comment.body)
                                .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(NSLocalizedString("标签", comment: "Labels section")) {
                let labels = snapshot?.labels ?? []
                if labels.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No labels"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(String(format: NSLocalizedString("工单 #%d", comment: "Issue number title"), issueNumber))
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
}
