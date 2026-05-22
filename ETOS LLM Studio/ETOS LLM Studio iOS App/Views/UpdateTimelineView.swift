// ============================================================================
// UpdateTimelineView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 显示 Git 提交检查更新与 AI 摘要。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct UpdateTimelineView: View {
    @ObservedObject private var manager = UpdateTimelineManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @Environment(\.openURL) private var openURL
    @State private var visibleTimelineLimit = 5

    private let timelineInitialLimit = 5
    private let timelinePageSize = 20

    private var displayedCommits: [UpdateTimelineCommit] {
        manager.displayedCommits
    }

    private var visibleTimelineCommits: [UpdateTimelineCommit] {
        Array(displayedCommits.prefix(visibleTimelineLimit))
    }

    private var hasMoreTimelineCommits: Bool {
        visibleTimelineCommits.count < displayedCommits.count
    }

    var body: some View {
        List {
            timelineSection
            summarySection
            statusSection
            controlsSection
        }
        .navigationTitle(NSLocalizedString("检查更新", comment: "Update check navigation title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await manager.refresh(forceNetwork: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
                .accessibilityLabel(NSLocalizedString("刷新检查更新", comment: ""))
            }
        }
        .task {
            await manager.refreshIfNeeded()
        }
        .onChange(of: displayedCommits.count) { _, newCount in
            if newCount <= timelineInitialLimit {
                visibleTimelineLimit = timelineInitialLimit
            } else {
                visibleTimelineLimit = min(max(visibleTimelineLimit, timelineInitialLimit), newCount)
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(NSLocalizedString("通道", comment: "Update timeline channel label")) {
                Text(manager.state.channel.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(NSLocalizedString("状态", comment: "Update timeline status label")) {
                Text(manager.state.status.displayName)
                    .foregroundStyle(statusColor)
            }
            if let currentBuild = manager.state.currentBuildNumber {
                LabeledContent(NSLocalizedString("当前 Build", comment: "Update timeline current build label"), value: "\(currentBuild)")
            }
            if let remoteBuild = manager.state.latestRemoteBuildNumber {
                LabeledContent(NSLocalizedString("推算最新 Build", comment: "Update timeline latest build label"), value: "\(remoteBuild)")
            }
            if let appStoreVersion = manager.state.appStoreVersion {
                LabeledContent(NSLocalizedString("App Store 版本", comment: "Update timeline app store version label"), value: appStoreVersion)
            }
            if let checkedAt = manager.state.lastCheckedAt {
                LabeledContent(NSLocalizedString("上次检查", comment: "Update timeline last checked label")) {
                    Text(checkedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = manager.state.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.orange)
            }
            if let resetAt = manager.state.rateLimitResetAt {
                Text(String(format: NSLocalizedString("GitHub 限流可能会在 %@ 后恢复。", comment: "Update timeline rate limit footer"), resetAt.formatted(date: .omitted, time: .shortened)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("版本探针", comment: "Update timeline probe section"))
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle(NSLocalizedString("自动检查更新", comment: "Update timeline auto check toggle"), isOn: autoCheckBinding)
            Toggle(NSLocalizedString("自动检查并总结", comment: "Update timeline auto summary toggle"), isOn: autoSummaryBinding)
        } footer: {
            Text(NSLocalizedString("自动总结默认关闭；关闭后可在这里手动请求 AI 基于差值 Commit 生成摘要。", comment: "Update timeline controls footer"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        Section {
            if let summary = manager.state.summaryText, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summary)
                    .etFont(.body)
                    .textSelection(.enabled)
                if let generatedAt = manager.state.summaryGeneratedAt {
                    Text(String(format: NSLocalizedString("生成于 %@", comment: "Update timeline summary generated at"), generatedAt.formatted(date: .abbreviated, time: .shortened)))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(NSLocalizedString("还没有摘要。", comment: "Update timeline empty summary"))
                    .foregroundStyle(.secondary)
            }

            if manager.state.allowsSummary {
                Button {
                    Task { await manager.generateSummary() }
                } label: {
                    Label(
                        manager.isSummarizing
                            ? NSLocalizedString("正在请求 AI 总结", comment: "Update timeline summarizing button")
                            : NSLocalizedString("请求 AI 总结", comment: "Update timeline request summary button"),
                        systemImage: "sparkles"
                    )
                }
                .disabled(manager.isSummarizing || displayedCommits.isEmpty)
            } else if let appStoreURL = manager.state.appStoreURL {
                Button {
                    openURL(appStoreURL)
                } label: {
                    Label(NSLocalizedString("前往 App Store 更新", comment: "Update timeline open App Store button"), systemImage: "arrow.up.circle")
                }
            }
        } header: {
            Text(NSLocalizedString("AI 摘要", comment: "Update timeline summary section"))
        }
    }

    private var timelineSection: some View {
        Section {
            if displayedCommits.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("暂无时间线", comment: "Update timeline empty title"),
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    description: Text(NSLocalizedString("刷新后会优先显示 GitHub 缓存中的提交记录。", comment: "Update timeline empty description"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(visibleTimelineCommits.enumerated()), id: \.element.id) { index, commit in
                    NavigationLink {
                        UpdateTimelineCommitDetailView(commit: commit)
                    } label: {
                        UpdateTimelineRow(
                            commit: commit,
                            isFirst: index == 0,
                            isLast: index == visibleTimelineCommits.count - 1
                        )
                    }
                }

                if hasMoreTimelineCommits {
                    Button {
                        visibleTimelineLimit = min(displayedCommits.count, visibleTimelineLimit + timelinePageSize)
                    } label: {
                        Label(NSLocalizedString("展开更多", comment: "Show more update timeline commits"), systemImage: "chevron.down.circle")
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("Commit 时间线", comment: "Update timeline commits section"))
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

    private var statusColor: Color {
        switch manager.state.status {
        case .unknown:
            return .secondary
        case .current:
            return .green
        case .updateAvailable:
            return .blue
        }
    }
}

private struct UpdateTimelineRow: View {
    let commit: UpdateTimelineCommit
    let isFirst: Bool
    let isLast: Bool
    private let markerColumnWidth: CGFloat = 22
    private let markerDiameter: CGFloat = 9
    private let markerTopPadding: CGFloat = 5
    private let rowVerticalPadding: CGFloat = 6

    private var markerTopY: CGFloat {
        rowVerticalPadding + markerTopPadding
    }

    private var markerBottomY: CGFloat {
        markerTopY + markerDiameter
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: markerDiameter, height: markerDiameter)
                .padding(.top, markerTopPadding)
                .frame(width: markerColumnWidth)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(commit.shortOID)
                        .etFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let build = commit.inferredBuildNumber {
                        Text(String(format: NSLocalizedString("Build %d", comment: "Update timeline build badge"), build))
                            .etFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Text(commit.displayHeadline)
                    .etFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let date = commit.committedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            UpdateTimelineConnectorShape(
                isFirst: isFirst,
                isLast: isLast,
                markerTopY: markerTopY,
                markerBottomY: markerBottomY,
                lineTopExtension: 8,
                lineBottomExtension: 8
            )
            .stroke(Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: markerColumnWidth)
        }
    }
}

private struct UpdateTimelineConnectorShape: Shape {
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

private struct UpdateTimelineCommitDetailView: View {
    @Environment(\.openURL) private var openURL
    let commit: UpdateTimelineCommit

    var body: some View {
        List {
            Section {
                LabeledContent(NSLocalizedString("Commit", comment: "Update timeline commit detail label"), value: commit.oid)
                if let build = commit.inferredBuildNumber {
                    LabeledContent(NSLocalizedString("推算 Build", comment: "Update timeline detail build label"), value: "\(build)")
                }
                if let date = commit.committedDate {
                    LabeledContent(NSLocalizedString("提交时间", comment: "Update timeline detail date label")) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section(NSLocalizedString("Commit Message", comment: "Update timeline commit message section")) {
                Text(commit.fullMessage)
                    .textSelection(.enabled)
            }

            if let url = commit.url {
                Section {
                    Button {
                        openURL(url)
                    } label: {
                        Label(NSLocalizedString("打开 GitHub Commit", comment: "Update timeline open GitHub commit"), systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle(commit.shortOID)
        .navigationBarTitleDisplayMode(.inline)
    }
}
