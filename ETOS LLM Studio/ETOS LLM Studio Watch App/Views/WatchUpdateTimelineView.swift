// ============================================================================
// WatchUpdateTimelineView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 小屏检查更新视图，使用数码表冠逐条浏览 Commit。
// ============================================================================

import SwiftUI
import Foundation
import Shared
import WatchKit
import AuthenticationServices

struct WatchUpdateTimelineView: View {
    @ObservedObject private var manager = UpdateTimelineManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var crownIndex: Double = 0
    @State private var webAuthLauncher = UpdateTimelineWatchWebAuthLauncher()

    private var commits: [UpdateTimelineCommit] {
        manager.displayedCommits
    }

    private var maxIndex: Double {
        Double(max(commits.count - 1, 0))
    }

    private var selectedIndex: Int {
        min(max(Int(crownIndex.rounded()), 0), max(commits.count - 1, 0))
    }

    private var visibleCommitIndices: [Int] {
        guard !commits.isEmpty else { return [] }
        let lowerBound = max(selectedIndex - 1, 0)
        let upperBound = min(selectedIndex + 1, commits.count - 1)
        return Array(lowerBound...upperBound)
    }

    var body: some View {
        List {
            Section {
                if commits.isEmpty {
                    Text(NSLocalizedString("暂无时间线", comment: "Update timeline empty title"))
                        .foregroundStyle(.secondary)
                } else {
                    crownTimeline
                }
            } header: {
                Text(NSLocalizedString("Commit 时间线", comment: "Update timeline commits section"))
            } footer: {
                Text(NSLocalizedString("转动数码表冠逐条浏览。", comment: "Watch update timeline crown footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let summary = manager.state.summaryText, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(summary)
                        .etFont(.caption)
                        .foregroundStyle(.primary)
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
                    .disabled(manager.isSummarizing || commits.isEmpty)
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
            }
        }
        .navigationTitle(NSLocalizedString("检查更新", comment: "Update check navigation title"))
        .task {
            await manager.refreshIfNeeded()
        }
        .onChange(of: commits.count) { _, newCount in
            crownIndex = min(crownIndex, Double(max(newCount - 1, 0)))
        }
    }

    private var crownTimeline: some View {
        VStack(spacing: 6) {
            ForEach(visibleCommitIndices, id: \.self) { index in
                let commit = commits[index]
                NavigationLink {
                    WatchUpdateTimelineCommitDetailView(commit: commit)
                } label: {
                    WatchUpdateTimelineRow(
                        commit: commit,
                        isSelected: selectedIndex == index,
                        isFirst: index == 0,
                        isLast: index == commits.count - 1
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 168)
        .focusable(true)
        .digitalCrownRotation(
            $crownIndex,
            from: 0,
            through: maxIndex,
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .animation(.snappy, value: selectedIndex)
        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
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
}

private struct WatchUpdateTimelineRow: View {
    let commit: UpdateTimelineCommit
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.25))
                    .frame(width: 2, height: 10)
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.25))
                    .frame(width: 2, height: 42)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(commit.shortOID)
                        .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let build = commit.inferredBuildNumber {
                        Text(String(format: NSLocalizedString("B%d", comment: "Watch update timeline build badge"), build))
                            .etFont(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(commit.displayHeadline)
                    .etFont(.caption2.weight(.semibold))
                    .lineLimit(3)
                if let date = commit.committedDate {
                    Text(date.formatted(date: .numeric, time: .shortened))
                        .etFont(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
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
