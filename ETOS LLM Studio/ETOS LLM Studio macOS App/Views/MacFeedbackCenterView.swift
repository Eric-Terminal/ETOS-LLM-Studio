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
                        Button(NSLocalizedString("从列表移除", value: "Remove from List", comment: "移除本机反馈记录"), role: .destructive) { pendingDeletion = ticket }
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
            Button(NSLocalizedString("从列表移除", value: "Remove from List", comment: "移除本机反馈记录"), role: .destructive) {
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
struct MacFeedbackComposeView: View {
    let isActive: Bool
    @ObservedObject var service: FeedbackService

    var body: some View {
        FeedbackComposeForm(pageID: "mac-feedback-compose", isActive: isActive, service: service,
                            controller: MacGuideSession.shared.controller)
    }
}
