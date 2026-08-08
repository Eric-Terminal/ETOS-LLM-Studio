// ============================================================================
// LocalLinuxWatchJobsView.swift
// ============================================================================
// watchOS 任务页按会话与 Agent Run 分组；离开页面不影响后台输出 drain。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxWatchJobsView: View {
    private struct JobGroup: Identifiable, Sendable {
        let sessionID: UUID?
        let runID: UUID?
        let jobs: [LocalLinuxJob]

        var id: String {
            "\(sessionID?.uuidString ?? "device")/\(runID?.uuidString ?? "user")"
        }
    }

    let sessionID: UUID?
    @State private var groups: [JobGroup] = []

    var body: some View {
        List {
            if groups.isEmpty {
                Text(NSLocalizedString("还没有任务。", comment: "Watch no Linux jobs"))
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section(groupTitle(group)) {
                    ForEach(group.jobs) { job in
                        NavigationLink {
                            if job.kind == .terminal, !job.state.isTerminal {
                                LocalLinuxWatchTerminalView(
                                    sessionID: job.sessionID,
                                    initialJobID: job.id
                                )
                            } else {
                                LocalLinuxWatchJobDetailView(jobID: job.id)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(job.request.executable).font(.caption.monospaced())
                                Text(
                                    String(
                                        format: NSLocalizedString("%@ · %@", comment: "Watch Linux job kind and state"),
                                        job.kind.displayName,
                                        job.state.displayName
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        if !job.state.isTerminal {
                            Button(NSLocalizedString("取消此任务", comment: "Watch cancel Linux job"), role: .destructive) {
                                Task { await LocalLinuxJobScheduler.shared.cancel(jobID: job.id) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let runID = group.runID,
                       group.jobs.contains(where: { !$0.state.isTerminal }) {
                        Button(NSLocalizedString("停止此 Agent", comment: "Watch stop Linux Agent run"), role: .destructive) {
                            Task { await ChatService.shared.stopConversationRun(runID) }
                        }
                    }
                }
            }

            if groups.contains(where: { $0.jobs.contains(where: { !$0.state.isTerminal }) }) {
                Section(NSLocalizedString("停止范围", comment: "Watch Linux task cancellation scopes")) {
                    if let sessionID {
                        Button(NSLocalizedString("停止此会话", comment: "Watch stop session Linux jobs"), role: .destructive) {
                            Task { await LocalLinuxJobScheduler.shared.cancel(sessionID: sessionID) }
                        }
                    }
                    Button(NSLocalizedString("停止全部本地任务", comment: "Watch stop all local Agent jobs"), role: .destructive) {
                        Task { await LocalLinuxJobScheduler.shared.cancelAll() }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("本地 Agent 任务", comment: "Watch local Agent jobs title"))
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func reload() async {
        let jobs: [LocalLinuxJob]
        if let sessionID {
            jobs = await LocalLinuxJobScheduler.shared.jobs(sessionID: sessionID, limit: 100)
        } else {
            jobs = await LocalLinuxJobScheduler.shared.activeJobs()
        }
        groups = await Task.detached(priority: .utility) {
            Dictionary(grouping: jobs) {
                "\($0.sessionID?.uuidString ?? "device")/\($0.runID?.uuidString ?? "user")"
            }.values.map { values in
                JobGroup(
                    sessionID: values.first?.sessionID,
                    runID: values.first?.runID,
                    jobs: values.sorted { $0.createdAt > $1.createdAt }
                )
            }.sorted {
                ($0.jobs.first?.createdAt ?? .distantPast) > ($1.jobs.first?.createdAt ?? .distantPast)
            }
        }.value
    }

    private func groupTitle(_ group: JobGroup) -> String {
        let sessionPrefix: String
        if sessionID == nil, let id = group.sessionID {
            sessionPrefix = String(
                format: NSLocalizedString("会话 %@ · ", comment: "Watch Linux task session prefix"),
                String(id.uuidString.prefix(8))
            )
        } else {
            sessionPrefix = ""
        }
        if let runID = group.runID {
            return sessionPrefix + String(
                format: NSLocalizedString("Agent %@", comment: "Watch Linux Agent run group"),
                String(runID.uuidString.prefix(8))
            )
        }
        return sessionPrefix + NSLocalizedString("用户与长期进程", comment: "Watch user and long-running jobs")
    }
}

private struct LocalLinuxWatchJobDetailView: View {
    let jobID: UUID
    @State private var job: LocalLinuxJob?
    @State private var outputPage = LocalLinuxRawOutputPage(
        cursor: LocalLinuxRawOutputCursor(),
        text: "",
        nextCursor: nil,
        isComplete: true
    )
    @State private var outputTail = ""
    @State private var cursorHistory: [LocalLinuxRawOutputCursor] = []

    var body: some View {
        List {
            if let job {
                Section {
                    LabeledContent(NSLocalizedString("状态", comment: "Status"), value: job.state.displayName)
                    Text(outputTail.isEmpty ? NSLocalizedString("没有输出。", comment: "Watch no Linux output") : outputTail)
                        .font(.caption2.monospaced())
                    if !job.state.isTerminal {
                        Button(NSLocalizedString("取消此任务", comment: "Watch cancel Linux job"), role: .destructive) {
                            Task { await LocalLinuxJobScheduler.shared.cancel(jobID: job.id) }
                        }
                    }
                }

                Section(NSLocalizedString("任务详情", comment: "Watch Linux job metadata section")) {
                    LabeledContent(NSLocalizedString("类型", comment: "Watch Linux job kind"), value: job.kind.displayName)
                    if let completionReason = job.completionReason {
                        LabeledContent(NSLocalizedString("完成原因", comment: "Watch Linux completion reason"), value: completionReason.displayName)
                    }
                    if let exitCode = job.exitCode {
                        LabeledContent(NSLocalizedString("退出码", comment: "Watch Linux exit code"), value: "\(exitCode)")
                    }
                    if let match = job.request.commandRuleMatch {
                        LabeledContent(NSLocalizedString("规则", comment: "Watch Linux matched command rule"), value: match.ruleName)
                        Text(match.matchedText).font(.caption2.monospaced())
                        LabeledContent(NSLocalizedString("处理", comment: "Watch Linux command rule action"), value: match.action.displayName)
                    }
                    Text(job.request.workingDirectory ?? "/")
                        .font(.caption2.monospaced())
                }

                Section(NSLocalizedString("原始输出", comment: "Watch Linux full output section")) {
                    Text(outputPage.text.isEmpty ? NSLocalizedString("没有输出。", comment: "Watch no Linux output") : outputPage.text)
                        .font(.caption2.monospaced())
                    if !cursorHistory.isEmpty {
                        Button(NSLocalizedString("上一页", comment: "Watch previous Linux output page")) {
                            guard let previous = cursorHistory.popLast() else { return }
                            Task { await loadPage(cursor: previous) }
                        }
                    }
                    if let next = outputPage.nextCursor {
                        Button(NSLocalizedString("下一页", comment: "Watch next Linux output page")) {
                            cursorHistory.append(outputPage.cursor)
                            Task { await loadPage(cursor: next) }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(NSLocalizedString("任务详情", comment: "Watch Linux job detail"))
        .task {
            while !Task.isCancelled {
                job = await LocalLinuxJobScheduler.shared.job(id: jobID)
                await loadOutputTail()
                await loadPage(cursor: outputPage.cursor)
                if job?.state.isTerminal == true { break }
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func loadPage(cursor: LocalLinuxRawOutputCursor) async {
        if let page = try? await LocalLinuxJobScheduler.shared.userVisibleOutputPage(
            jobID: jobID,
            cursor: cursor,
            maximumBytes: 16_384
        ) {
            outputPage = page
        }
    }

    private func loadOutputTail() async {
        guard let output = try? await LocalLinuxJobScheduler.shared.userVisibleOutput(jobID: jobID) else {
            return
        }
        outputTail = await Task.detached(priority: .utility) {
            let suffix = String(output.suffix(4_096))
            return suffix.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(6)
                .joined(separator: "\n")
        }.value
    }
}
