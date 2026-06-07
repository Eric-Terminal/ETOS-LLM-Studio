// ============================================================================
// WatchUpdateTimelineView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 小屏检查更新视图，使用数码表冠逐条浏览 Commit。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
import WatchKit
import AuthenticationServices

struct WatchUpdateTimelineView: View {
    @ObservedObject private var manager = UpdateTimelineManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var webAuthLauncher = UpdateTimelineWatchWebAuthLauncher()
    @State private var preparedSummaryMarkdown: ETPreparedMarkdownRenderPayload?
    @State private var showClearCacheConfirmation = false

    let highlightedCommit: UpdateTimelineCommit?

    init(highlightedCommit: UpdateTimelineCommit? = nil) {
        self.highlightedCommit = highlightedCommit
    }

    private var commits: [UpdateTimelineCommit] {
        manager.displayedCommits
    }

    private var previewCommits: [UpdateTimelineCommit] {
        Array(commits.prefix(2))
    }

    var body: some View {
        List {
            if let highlightedCommit {
                Section {
                    NavigationLink {
                        WatchUpdateTimelineCommitDetailView(commit: highlightedCommit)
                    } label: {
                        WatchUpdateTimelineRow(
                            commit: highlightedCommit,
                            isSelected: true,
                            isFirst: true,
                            isLast: true
                        )
                    }
                } header: {
                    Text(NSLocalizedString("关联 Commit", comment: "Linked update timeline commit section"))
                }
            }

            Section {
                if commits.isEmpty {
                    Text(NSLocalizedString("暂无时间线", comment: "Update timeline empty title"))
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        WatchUpdateTimelineBrowserView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(previewCommits.enumerated()), id: \.element.id) { index, commit in
                                WatchUpdateTimelineRow(
                                    commit: commit,
                                    isSelected: index == 0,
                                    isFirst: index == 0,
                                    isLast: index == previewCommits.count - 1
                                )
                            }
                            Text(String(format: NSLocalizedString("共 %d 项", comment: "Total item count"), commits.count))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("Commit 时间线", comment: "Update timeline commits section"))
            }

            Section {
                if let summary = manager.state.summaryText, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    WatchUpdateSummaryMarkdownView(
                        summary: summary,
                        preparedSummary: preparedSummaryMarkdown,
                        enableMarkdown: appConfig.enableMarkdown,
                        enableAdvancedRenderer: appConfig.enableAdvancedRenderer
                    )
                } else {
                    Text(NSLocalizedString("还没有摘要。", comment: "Update timeline empty summary"))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if manager.state.allowsSummary {
                    Button {
                        Task { await manager.generateSummary() }
                    } label: {
                        Label(NSLocalizedString("请求 AI 总结", comment: "Update timeline request summary button"), systemImage: "sparkles")
                    }
                    .disabled(manager.isSummarizing || manager.state.summaryCommits.isEmpty)
                } else if let appStoreURL = manager.state.appStoreURL {
                    Button {
                        webAuthLauncher.open(url: appStoreURL)
                    } label: {
                        Label(NSLocalizedString("前往 App Store 更新", comment: "Update timeline open App Store button"), systemImage: "arrow.up.circle")
                    }
                }
            } header: {
                Text(NSLocalizedString("AI 摘要", comment: "Update timeline summary section"))
            }

            Section {
                statusRow(NSLocalizedString("通道", comment: "Update timeline channel label"), value: manager.state.channel.displayName)
                statusRow(NSLocalizedString("状态", comment: "Update timeline status label"), value: manager.state.status.displayName)
                if let build = manager.state.currentBuildNumber {
                    statusRow(NSLocalizedString("当前 Build", comment: "Update timeline current build label"), value: "\(build)")
                }
                if let appStoreVersion = manager.state.appStoreVersion {
                    statusRow(NSLocalizedString("App Store 版本", comment: "Update timeline app store version label"), value: appStoreVersion)
                }
            }

            Section {
                Toggle(NSLocalizedString("自动检查更新", comment: "Update timeline auto check toggle"), isOn: autoCheckBinding)
                Toggle(NSLocalizedString("自动检查并总结", comment: "Update timeline auto summary toggle"), isOn: autoSummaryBinding)
                Button {
                    Task { await manager.refresh(forceNetwork: true) }
                } label: {
                    Label(NSLocalizedString("刷新", comment: "Update timeline refresh button"), systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
                Button(role: .destructive) {
                    showClearCacheConfirmation = true
                } label: {
                    Label(NSLocalizedString("清空更新缓存", comment: "Clear update timeline cache"), systemImage: "trash")
                }
                .disabled(manager.isRefreshing || manager.isSummarizing)
            }
        }
        .navigationTitle(NSLocalizedString("检查更新", comment: "Update check navigation title"))
        .confirmationDialog(
            NSLocalizedString("清空更新缓存？", comment: "Clear update timeline cache confirmation title"),
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清空更新缓存", comment: "Clear update timeline cache"), role: .destructive) {
                manager.clearPersistentCache()
                preparedSummaryMarkdown = nil
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("这会删除检查更新页面保存的 GitHub 时间线、限流状态和 AI 摘要缓存，下次刷新会重新请求。", comment: "Clear update timeline cache confirmation message"))
        }
        .task {
            await manager.refreshIfNeeded()
        }
        .task(id: manager.state.summaryText) {
            await prepareSummaryMarkdown(for: manager.state.summaryText)
        }
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { appConfig.updateTimelineAutoCheckEnabled },
            set: { newValue in
                appConfig.updateTimelineAutoCheckEnabled = newValue
                manager.autoCheckEnabled = newValue
            }
        )
    }

    private var autoSummaryBinding: Binding<Bool> {
        Binding(
            get: { appConfig.updateTimelineAutoSummaryEnabled },
            set: { newValue in
                appConfig.updateTimelineAutoSummaryEnabled = newValue
                manager.autoSummaryEnabled = newValue
                if newValue {
                    Task { await manager.generateSummaryIfNeeded() }
                }
            }
        )
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .etFont(.caption)
    }

    @MainActor
    private func prepareSummaryMarkdown(for summary: String?) async {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preparedSummaryMarkdown = nil
            return
        }
        guard preparedSummaryMarkdown?.sourceText != summary else { return }

        let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: summary)
        guard !Task.isCancelled else { return }
        preparedSummaryMarkdown = prepared
    }
}

private struct WatchUpdateTimelineBrowserView: View {
    @ObservedObject private var manager = UpdateTimelineManager.shared
    @State private var loadedCommits: [UpdateTimelineCommit] = []
    @State private var isLoadingMoreCommits = false
    @State private var pendingLoadMoreCommitsTask: Task<Void, Never>?
    private let maxCommitsPerPage = 20
    private let loadMoreTriggerRemainingCount = 8

    private var commits: [UpdateTimelineCommit] {
        manager.displayedCommits
    }

    private var hasMoreCommits: Bool {
        loadedCommits.count < commits.count
    }

    private var shouldShowLoadingMoreFooter: Bool {
        isLoadingMoreCommits || hasMoreCommits
    }

    var body: some View {
        List {
            if commits.isEmpty {
                Text(NSLocalizedString("暂无时间线", comment: "Update timeline empty title"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(loadedCommits.enumerated()), id: \.element.id) { index, commit in
                    NavigationLink {
                        WatchUpdateTimelineCommitDetailView(commit: commit)
                    } label: {
                        WatchUpdateTimelineRow(
                            commit: commit,
                            isSelected: index == 0,
                            isFirst: index == 0,
                            isLast: index == loadedCommits.count - 1 && !hasMoreCommits
                        )
                    }
                    .onAppear {
                        loadMoreCommitsIfNeeded(currentID: commit.id)
                    }
                }

                if shouldShowLoadingMoreFooter {
                    loadingMoreFooter
                }
            }
        }
        .navigationTitle(NSLocalizedString("Commit 时间线", comment: "Update timeline commits section"))
        .onAppear {
            syncLoadedCommitsWithSource()
        }
        .onChange(of: commits) { _, _ in
            syncLoadedCommitsWithSource()
        }
        .onDisappear {
            pendingLoadMoreCommitsTask?.cancel()
            pendingLoadMoreCommitsTask = nil
            isLoadingMoreCommits = false
        }
    }

    private func scheduleNextCommitsPage() {
        guard !isLoadingMoreCommits, hasMoreCommits, pendingLoadMoreCommitsTask == nil else { return }
        isLoadingMoreCommits = true
        pendingLoadMoreCommitsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                isLoadingMoreCommits = false
                pendingLoadMoreCommitsTask = nil
                return
            }

            let start = loadedCommits.count
            let end = min(start + maxCommitsPerPage, commits.count)
            if start < end {
                loadedCommits.append(contentsOf: commits[start..<end])
            }
            isLoadingMoreCommits = false
            pendingLoadMoreCommitsTask = nil
        }
    }

    private func syncLoadedCommitsWithSource() {
        pendingLoadMoreCommitsTask?.cancel()
        pendingLoadMoreCommitsTask = nil
        isLoadingMoreCommits = false
        guard !commits.isEmpty else {
            loadedCommits = []
            return
        }
        let loadedCount = min(max(loadedCommits.count, maxCommitsPerPage), commits.count)
        loadedCommits = Array(commits.prefix(loadedCount))
    }

    private func loadMoreCommitsIfNeeded(currentID: String) {
        guard loadedCommits.suffix(loadMoreTriggerRemainingCount).contains(where: { $0.id == currentID }) else { return }
        scheduleNextCommitsPage()
    }

    private var loadingMoreFooter: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(NSLocalizedString("正在加载", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WatchUpdateSummaryMarkdownView: View {
    let summary: String
    let preparedSummary: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool

    var body: some View {
        if enableMarkdown,
           let preparedSummary,
           preparedSummary.sourceText == summary {
            ETAdvancedMarkdownRenderer(
                content: summary,
                preparedContent: preparedSummary,
                enableMarkdown: true,
                isOutgoing: false,
                enableAdvancedRenderer: enableAdvancedRenderer,
                enableMathRendering: enableAdvancedRenderer,
                customTextColor: .primary
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .etFont(.caption, sampleText: summary)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WatchUpdateTimelineRow: View {
    let commit: UpdateTimelineCommit
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    private let markerColumnWidth: CGFloat = 10
    private let markerDiameter: CGFloat = 8
    private let markerTopPadding: CGFloat = 6
    private let rowVerticalPadding: CGFloat = 4

    private var markerTopY: CGFloat {
        rowVerticalPadding + markerTopPadding
    }

    private var markerBottomY: CGFloat {
        markerTopY + markerDiameter
    }

    private var isBuildCommit: Bool {
        commit.inferredBuildNumber != nil
    }

    private var markerColor: Color {
        if isBuildCommit {
            return .green
        }
        return isSelected ? .accentColor : .secondary.opacity(0.55)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(markerColor)
                .frame(width: markerDiameter, height: markerDiameter)
                .padding(.top, markerTopPadding)
                .frame(width: markerColumnWidth)

            VStack(alignment: .leading, spacing: 4) {
                Text(commit.shortOID)
                    .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isBuildCommit ? markerColor : Color.secondary)
                Text(commit.displayHeadline)
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(isBuildCommit ? markerColor : Color.primary)
                    .lineLimit(2)
                if let date = commit.committedDate {
                    Text(date.formatted(date: .numeric, time: .shortened))
                        .etFont(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let build = commit.inferredBuildNumber {
                Text(String(format: NSLocalizedString("B%d", comment: "Watch update timeline build badge"), build))
                    .etFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(markerColor)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(markerColor.opacity(0.16), in: Capsule())
                    .accessibilityLabel(String(format: NSLocalizedString("Build %d", comment: "Update timeline build badge"), build))
            }
        }
        .padding(.vertical, rowVerticalPadding)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            WatchUpdateTimelineConnectorShape(
                isFirst: isFirst,
                isLast: isLast,
                markerTopY: markerTopY,
                markerBottomY: markerBottomY,
                lineTopExtension: 3,
                lineBottomExtension: 3
            )
            .stroke(markerColor.opacity(isBuildCommit ? 0.42 : 0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: markerColumnWidth + 4)
        }
    }
}

private struct WatchUpdateTimelineConnectorShape: Shape {
    let isFirst: Bool
    let isLast: Bool
    let markerTopY: CGFloat
    let markerBottomY: CGFloat
    let lineTopExtension: CGFloat
    let lineBottomExtension: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        if !isFirst {
            path.move(to: CGPoint(x: x, y: rect.minY - lineTopExtension))
            path.addLine(to: CGPoint(x: x, y: rect.minY + markerTopY))
        }
        if !isLast {
            path.move(to: CGPoint(x: x, y: rect.minY + markerBottomY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + lineBottomExtension))
        }
        return path
    }
}

private struct WatchUpdateTimelineCommitDetailView: View {
    let commit: UpdateTimelineCommit
    @State private var webAuthLauncher = UpdateTimelineWatchWebAuthLauncher()

    var body: some View {
        List {
            Section {
                Text(commit.shortOID)
                    .etFont(.caption.monospaced())
                if let build = commit.inferredBuildNumber {
                    Text(String(format: NSLocalizedString("Build %d", comment: "Update timeline build badge"), build))
                        .etFont(.caption)
                }
                if let date = commit.committedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(NSLocalizedString("Commit Message", comment: "Update timeline commit message section")) {
                Text(commit.fullMessage)
                    .etFont(.caption)
            }

            if let url = commit.url {
                Section {
                    Button {
                        webAuthLauncher.open(url: url)
                    } label: {
                        Label(NSLocalizedString("打开 GitHub Commit", comment: "Update timeline open GitHub commit"), systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle(commit.shortOID)
    }
}

@MainActor
private final class UpdateTimelineWatchWebAuthLauncher: NSObject {
    private var session: ASWebAuthenticationSession?

    func open(url: URL) {
        session?.cancel()
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                self?.session = nil
            }
        }
        session?.prefersEphemeralWebBrowserSession = true
        _ = session?.start()
    }
}
