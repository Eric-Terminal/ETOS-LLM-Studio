import ETOSCore
import SwiftUI

@MainActor
struct MacFeedbackCenterView: View {
    let isActive: Bool
    var initialIssueNumber: Int? = nil
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var service = MacAppInformationModel.shared.feedback
    @ObservedObject private var information = MacAppInformationModel.shared
    @State private var visible = false
    @State private var pendingDeletion: FeedbackTicket?
    @State private var selectedTicket: FeedbackTicket?
    @State private var operation: Task<Void, Never>?
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "feedback", title: NSLocalizedString("反馈与处理进度", comment: ""),
                    details: NSLocalizedString("反馈助手使用说明", comment: ""), documentID: "feedback-assistant", isActive: available)
                NavigationLink {
                    MacFeedbackComposeView(isActive: available, service: service)
                } label: { Label(NSLocalizedString("新建反馈", comment: ""), systemImage: "square.and.pencil") }
            }
            Section(NSLocalizedString("我的反馈", comment: "")) {
                if service.tickets.isEmpty {
                    Text(NSLocalizedString("暂无反馈记录", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(service.tickets) { ticket in
                    NavigationLink {
                        MacFeedbackDetailView(isActive: available, service: service, ticket: ticket)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(ticket.title).lineLimit(2)
                            Text(String(format: NSLocalizedString("工单 #%d", comment: ""), ticket.issueNumber))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ticket.lastKnownStatus.localizedTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) { pendingDeletion = ticket }
                            .disabled(service.isRefreshing || service.isSubmitting || information.refreshingFeedbackOnLaunch)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("反馈助手", comment: ""))
        .toolbar {
            Button {
                operation?.cancel()
                operation = Task { await service.refreshAllTickets() }
            } label: { Label(NSLocalizedString("刷新状态", comment: ""), systemImage: "arrow.clockwise") }
                .disabled(service.isRefreshing || service.isSubmitting || information.refreshingFeedbackOnLaunch)
        }
        .disabled(!available)
        .task(id: initialIssueNumber) {
            await service.reloadTicketsInBackground()
            if let initialIssueNumber {
                selectedTicket = service.tickets.first { $0.issueNumber == initialIssueNumber }
            }
        }
        .navigationDestination(item: $selectedTicket) { ticket in
            MacFeedbackDetailView(isActive: available, service: service, ticket: ticket)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; operation?.cancel() }
        .onChange(of: available) { _, value in if !value { operation?.cancel(); pendingDeletion = nil } }
        .confirmationDialog(NSLocalizedString("删除本地反馈记录？", value: "Delete local feedback record?", comment: ""),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard available, !service.isRefreshing, !service.isSubmitting, !information.refreshingFeedbackOnLaunch, let ticket = pendingDeletion else { return }
                pendingDeletion = nil
                operation = Task {
                    await Task.detached(priority: .utility) { FeedbackStore.deleteTicket(issueNumber: ticket.issueNumber) }.value
                    await service.reloadTicketsInBackground()
                }
            }
        } message: {
            Text(NSLocalizedString("此操作仅移除本机记录，不会关闭远端工单。", value: "This removes the local record without closing the remote ticket.", comment: ""))
        }
        .guideSettingsPageContext(id: "mac-feedback", title: NSLocalizedString("反馈助手", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            isActive: available && visible, settings: [
                .readOnly("ticket_count", label: NSLocalizedString("我的反馈", comment: ""), value: { .int(service.tickets.count) }),
                .readOnly("refreshing", label: NSLocalizedString("刷新中...", comment: ""), value: { .bool(service.isRefreshing) })
            ])
    }
}

@MainActor
private struct MacFeedbackComposeView: View {
    let isActive: Bool
    @ObservedObject var service: FeedbackService
    @Environment(\.dismiss) private var dismiss
    @State private var category: FeedbackCategory = .bug
    @State private var title = ""
    @State private var detail = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var actual = ""
    @State private var context = ""
    @State private var environmentSummary = ""
    @State private var error: String?
    @State private var submitting = false
    @State private var operation: Task<Void, Never>?
    @State private var visible = false

    var body: some View {
        Form {
            Section {
                Picker(NSLocalizedString("反馈类型", comment: ""), selection: $category) {
                    ForEach(FeedbackCategory.allCases) { Text($0.localizedTitle).tag($0) }
                }
                TextField(NSLocalizedString("标题", comment: ""), text: $title)
                TextField(NSLocalizedString("详细描述", comment: ""), text: $detail, axis: .vertical).lineLimit(4...12)
            }
            if category == .bug {
                Section(NSLocalizedString("问题细节（可选）", comment: "")) {
                    TextField(NSLocalizedString("可复现步骤（可选）", comment: ""), text: $steps, axis: .vertical)
                    TextField(NSLocalizedString("预期行为（可选）", comment: ""), text: $expected, axis: .vertical)
                    TextField(NSLocalizedString("实际行为（可选）", comment: ""), text: $actual, axis: .vertical)
                }
            }
            Section {
                TextField(NSLocalizedString("补充信息（可选）", comment: ""), text: $context, axis: .vertical)
            } footer: { Text(environmentSummary).font(.footnote).foregroundStyle(.secondary) }
            Section {
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(NSLocalizedString("提交", comment: "")) { submit() }
                    .disabled(submitting || title.isEmpty || detail.isEmpty)
                if submitting { ProgressView(NSLocalizedString("提交中...", comment: "")) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("新建反馈", comment: ""))
        .disabled(!isActive || submitting)
        .onAppear { visible = true }
        .onDisappear { visible = false; operation?.cancel() }
        .onChange(of: isActive) { _, active in if !active { operation?.cancel() } }
        .task {
            environmentSummary = await Task.detached(priority: .utility) {
                let environment = FeedbackEnvironmentCollector.collectSnapshot()
                return String(format: NSLocalizedString("将自动附带环境信息：%@ %@ (Build %@) · %@ · %@", comment: ""),
                    environment.platform, environment.appVersion, environment.appBuild,
                    environment.osVersion, environment.localizedDistributionChannel)
            }.value
        }
        .guideSettingsPageContext(id: "mac-feedback-compose", title: NSLocalizedString("新建反馈", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            isActive: isActive && visible, settings: [
                .readOnly("category", label: NSLocalizedString("反馈类型", comment: ""), value: { .string(category.rawValue) }),
                .readOnly("title_ready", label: NSLocalizedString("标题", comment: ""), value: { .bool(!title.isEmpty) }),
                .readOnly("detail_ready", label: NSLocalizedString("详细描述", comment: ""), value: { .bool(!detail.isEmpty) }),
                .readOnly("steps_ready", label: NSLocalizedString("可复现步骤（可选）", comment: ""), value: { .bool(category == .bug && !steps.isEmpty) }),
                .readOnly("expected_ready", label: NSLocalizedString("预期行为（可选）", comment: ""), value: { .bool(category == .bug && !expected.isEmpty) }),
                .readOnly("actual_ready", label: NSLocalizedString("实际行为（可选）", comment: ""), value: { .bool(category == .bug && !actual.isEmpty) }),
                .readOnly("context_ready", label: NSLocalizedString("补充信息（可选）", comment: ""), value: { .bool(!context.isEmpty) }),
                .readOnly("submitting", label: NSLocalizedString("提交中...", comment: ""), value: { .bool(submitting) })
            ])
    }

    private func submit() {
        guard isActive, !submitting else { return }
        let draft = FeedbackDraft(category: category, title: title, detail: detail,
            reproductionSteps: category == .bug ? steps : nil, expectedBehavior: category == .bug ? expected : nil,
            actualBehavior: category == .bug ? actual : nil, extraContext: context)
        submitting = true; error = nil
        operation = Task {
            defer { submitting = false }
            do {
                _ = try await service.submit(draft: draft)
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
