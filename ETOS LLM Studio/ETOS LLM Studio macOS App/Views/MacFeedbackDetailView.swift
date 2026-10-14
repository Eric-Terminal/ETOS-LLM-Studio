import ETOSCore
import SwiftUI

@MainActor
struct MacFeedbackDetailView: View {
    let isActive: Bool
    @ObservedObject var service: FeedbackService
    let ticket: FeedbackTicket
    @State private var snapshot: FeedbackStatusSnapshot?
    @State private var latestTicket: FeedbackTicket?
    @State private var presentation: MacFeedbackPresentation?
    @State private var comment = ""
    @State private var working = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var visible = false

    var body: some View {
        Form {
            Section {
                Text(snapshot?.title ?? ticket.title).font(.headline)
                LabeledContent(NSLocalizedString("状态", comment: ""), value: (snapshot?.status ?? ticket.lastKnownStatus).localizedTitle)
                if let updatedAt = snapshot?.updatedAt ?? ticket.lastKnownUpdatedAt {
                    LabeledContent(NSLocalizedString("最后更新", comment: "")) { Text(updatedAt, style: .date) }
                }
                Button(NSLocalizedString("刷新状态", comment: "")) {
                    operation = Task { await refresh() }
                }.disabled(working)
                if let url = snapshot?.publicURL ?? ticket.publicURL {
                    Link(NSLocalizedString("打开 GitHub 页面", comment: ""), destination: url)
                }
                if let message = (latestTicket ?? ticket).moderationMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if working { ProgressView() }
            }
            if let presentation {
                Section(NSLocalizedString("我的反馈", comment: "")) {
                    ForEach(presentation.fields) { field in
                        VStack(alignment: .leading) {
                            Text(NSLocalizedString(field.id, comment: "")).font(.caption).foregroundStyle(.secondary)
                            MacMessageTextView(text: field.text)
                        }
                    }
                }
                Section(NSLocalizedString("处理动态", comment: "")) {
                    ForEach(presentation.events) { event in
                        VStack(alignment: .leading) {
                            Text(event.author).font(.headline)
                            Text(event.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let commit = event.commit {
                                NavigationLink {
                                    MacFeedbackCommitView(isActive: isActive, commit: commit, text: event.text)
                                } label: {
                                    Text(commit.displayShortSHA + " · " + commit.displayHeadline)
                                        .lineLimit(2)
                                }
                            } else { MacMessageTextView(text: event.text) }
                        }
                    }
                }
            }
            Section(NSLocalizedString("标签", comment: "")) {
                ForEach(snapshot?.labels ?? [], id: \.self) { Text($0).font(.footnote) }
            }
            Section {
                TextField(NSLocalizedString("补充评论（会进入同一工单）", comment: ""), text: $comment, axis: .vertical)
                    .lineLimit(2...8)
                Button(NSLocalizedString("发送评论", comment: "")) { sendComment() }
                    .disabled(working || comment.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(format: NSLocalizedString("工单 #%d", comment: ""), ticket.issueNumber))
        .disabled(!isActive)
        .task { await refresh() }
        .onAppear { visible = true }
        .onDisappear { visible = false; operation?.cancel() }
        .onChange(of: isActive) { _, active in if !active { operation?.cancel() } }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-feedback-\(ticket.issueNumber)"),
            title: NSLocalizedString("反馈助手", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            isActive: isActive && visible, settings: [
                .readOnly("issue_number", label: NSLocalizedString("我的反馈", comment: ""), value: { .int(ticket.issueNumber) }),
                .readOnly("status", label: NSLocalizedString("状态", comment: ""), value: { .string((snapshot?.status ?? ticket.lastKnownStatus).rawValue) }),
                .readOnly("event_count", label: NSLocalizedString("处理动态", comment: ""), value: { .int(presentation?.events.count ?? 0) }),
                .readOnly("comment_ready", label: NSLocalizedString("补充评论（会进入同一工单）", comment: ""), value: { .bool(!comment.isEmpty) }),
                .readOnly("working", label: NSLocalizedString("刷新中...", comment: ""), value: { .bool(working) })
            ])
    }

    private func refresh() async {
        guard isActive, !working else { return }
        working = true; error = nil
        defer { working = false }
        if presentation == nil { await prepare(nil) }
        do {
            let result = try await service.fetchStatus(ticket: ticket)
            guard !Task.isCancelled else { return }
            snapshot = result
            await prepare(result)
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func prepare(_ snapshot: FeedbackStatusSnapshot?) async {
        let tickets = service.tickets, original = ticket
        let prepared = await Task.detached(priority: .userInitiated) {
            let current = tickets.first { $0.issueNumber == original.issueNumber } ?? original
            return (current, MacFeedbackPresentation(ticket: current, snapshot: snapshot))
        }.value
        if !Task.isCancelled { latestTicket = prepared.0; presentation = prepared.1 }
    }

    private func sendComment() {
        guard isActive, !working else { return }
        let draft = comment
        working = true; error = nil
        operation = Task {
            do {
                _ = try await service.submitComment(ticket: ticket, body: draft)
                if comment == draft { comment = "" }
                working = false
                if !Task.isCancelled { await refresh() }
            } catch is CancellationError { working = false
            } catch { working = false; self.error = error.localizedDescription }
        }
    }
}

private struct MacFeedbackCommitView: View {
    let isActive: Bool
    let commit: FeedbackReferencedCommit
    let text: MacPreparedMessageText
    var body: some View {
        Form {
            Section {
                Text(commit.sha).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let date = commit.committedAt { Text(date, style: .date).foregroundStyle(.secondary) }
                MacMessageTextView(text: text)
                if let url = commit.htmlURL { Link(NSLocalizedString("打开 GitHub 页面", comment: ""), destination: url) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(commit.displayShortSHA)
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-feedback-commit-\(commit.sha)"),
            title: NSLocalizedString("处理动态", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            isActive: isActive, settings: [
                .readOnly("commit", label: NSLocalizedString("处理动态", comment: ""), value: { .string(commit.sha) })
            ])
    }
}
