import ETOSCore
import SwiftUI

@MainActor
struct MacUsageAnalyticsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacUsageAnalyticsModel()
    @State private var visible = false
    @State private var isShowingDetailSheet = false

    private let summaryColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var available: Bool {
        visible && isActive && workspace.canManageLocalModels && appLock.state != .locked
    }

    var body: some View {
        Group {
            if available, let snapshot = model.presentation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MacSettingsIntroCard(
                            id: "usage-analytics",
                            title: NSLocalizedString("用量统计", comment: ""),
                            details: NSLocalizedString("Mac 用量统计使用说明", comment: ""),
                            documentID: "usage-analytics",
                            isActive: available && !isShowingDetailSheet
                        )

                        if snapshot.isEmpty {
                            Text(NSLocalizedString("当前还没有可展示的统计数据。用量会从升级到此版本后开始累计。", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .usageCardSurface(cornerRadius: 16)
                        }

                        globalSummaryGrid(snapshot: snapshot)

                        MacUsageCalendarView(snapshot: snapshot, model: model)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(
                                    NSLocalizedString(
                                        "usage_dashboard.preview.section_title",
                                        value: "Token Breakdown",
                                        comment: "Section header for usage dashboard preview card"
                                    )
                                )
                                .font(.headline)

                                Spacer()

                                Text(
                                    NSLocalizedString(
                                        "usage_dashboard.preview.mac_click_hint",
                                        value: "Click card to inspect charts & rankings",
                                        comment: "Desktop hint next to usage dashboard preview header"
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            UsageSummaryPreviewCard(
                                snapshot: snapshot.dashboardCard,
                                compactLayout: false
                            ) {
                                isShowingDetailSheet = true
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if available {
                ProgressView(NSLocalizedString("正在加载…", comment: ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .toolbar {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Label(NSLocalizedString("刷新", comment: ""), systemImage: "arrow.clockwise") }
                .disabled(!available || model.isLoading)
        }
        .sheet(isPresented: $isShowingDetailSheet) {
            MacUsageDetailSheet(model: model, isAvailable: available)
        }
        .onAppear { visible = true; if available { model.resume() } }
        .onDisappear {
            visible = false
            isShowingDetailSheet = false
            model.suspend()
        }
        .onChange(of: available) { _, active in
            if active {
                model.resume()
            } else {
                isShowingDetailSheet = false
                model.suspend()
            }
        }
        .onChange(of: configuration.appLanguage) { _, _ in model.suspend(); if available { model.resume() } }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-usage-analytics-\(model.revision)"),
            title: NSLocalizedString("用量统计", comment: ""),
            documents: [
                GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics"),
                GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")
            ],
            isActive: available && !isShowingDetailSheet && model.presentation != nil && !model.isLoading,
            settings: [
                .readOnly("summary", label: NSLocalizedString("用量总览", comment: ""), value: { model.presentation?.guideSummary ?? .null }),
                .readOnly("scope", label: NSLocalizedString("统计范围", comment: ""), value: { .string(model.presentation?.scope.rawValue ?? "day") }),
                .readOnly("selected_day", label: NSLocalizedString("日期", comment: ""), value: { .string(model.presentation?.selectedDay ?? "") }),
                .readOnly("displayed_month", label: NSLocalizedString("日历面板", comment: ""), value: { .string(model.presentation?.monthTitle ?? "") }),
                .readOnly("detail", label: NSLocalizedString("详情", comment: ""), value: { model.presentation?.guideDetail ?? .null })
            ]
        )
    }

    private func globalSummaryGrid(snapshot: MacUsageAnalyticsPresentation) -> some View {
        let icons = [
            "总 Token": "diamond.fill",
            "对话数": "bubble.left.and.bubble.right.fill",
            "消息数": "text.bubble.fill",
            "活跃天数": "calendar",
            "连续活跃": "flame.fill",
            "最常使用的模型": "sparkles"
        ]
        let shareValue = snapshot.summary.first { $0.id == "Token 占比" }?.value
        let visibleMetrics = snapshot.summary.filter { $0.id != "Token 占比" }

        return VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("用量总览", comment: ""))
                .font(.headline)

            LazyVGrid(columns: summaryColumns, spacing: 12) {
                ForEach(visibleMetrics) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: icons[item.id] ?? "chart.bar.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(item.value)
                            .font(item.id == "最常使用的模型" ? .subheadline.weight(.bold) : .title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        if item.id == "最常使用的模型", let shareValue, !shareValue.isEmpty {
                            Text(String(format: NSLocalizedString("占比 %@", comment: ""), shareValue))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                    .padding(14)
                    .usageCardSurface(cornerRadius: 16)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - macOS 独立弹出用量看板 Sheet

@MainActor
private struct MacUsageDetailSheet: View {
    @ObservedObject var model: MacUsageAnalyticsModel
    let isAvailable: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = model.presentation {
                    ScrollView {
                        UsageDashboardDetailContentView(
                            selectedScope: snapshot.scope,
                            snapshot: snapshot.dashboardCard,
                            compactLayout: false
                        ) { scope in
                            model.selectScope(scope)
                        }
                        .padding(22)
                        .frame(maxWidth: 660, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                } else {
                    ProgressView(NSLocalizedString("正在加载…", comment: ""))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(
                NSLocalizedString(
                    "usage_dashboard.detail.nav_title",
                    value: "Usage",
                    comment: "Navigation title for detailed usage dashboard"
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            model.refresh()
                        } label: {
                            Label(NSLocalizedString("刷新", comment: ""), systemImage: "arrow.clockwise")
                        }
                        .disabled(!isAvailable)
                    }
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-usage-analytics-detail-\(model.revision)"),
                title: NSLocalizedString(
                    "usage_dashboard.detail.guide_title",
                    value: "Usage Details",
                    comment: "Guide context title for macOS detailed usage dashboard"
                ),
                documents: [
                    GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics"),
                    GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")
                ],
                isActive: isAvailable && model.presentation != nil && !model.isLoading,
                settings: [
                    .readOnly("scope", label: NSLocalizedString("统计范围", comment: ""), value: {
                        .string(model.presentation?.scope.rawValue ?? "day")
                    }),
                    .readOnly("selected_day", label: NSLocalizedString("日期", comment: ""), value: {
                        .string(model.presentation?.selectedDay ?? "")
                    }),
                    .readOnly("detail", label: NSLocalizedString("详情", comment: ""), value: {
                        model.presentation?.guideDetail ?? .null
                    }),
                    .readOnly("leaderboard_counts", label: NSLocalizedString("usage_dashboard.detail.leaderboard_counts", value: "Leaderboard Counts", comment: "Mac 用量看板排行计数"), value: {
                        guard let card = model.presentation?.dashboardCard else { return .null }
                        return .dictionary([
                            "provider_count": .int(card.providerRows.count),
                            "model_count": .int(card.modelRows.count),
                            "source_count": .int(card.sourceRows.count)
                        ])
                    })
                ]
            )
            .modifier(MacGuideInspector())
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 580, idealHeight: 740)
    }
}

@MainActor
struct MacUsageMetrics: View {
    let metrics: [MacUsageAnalyticsPresentation.Metric]
    private let columns = [GridItem(.adaptive(minimum: 140), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading) {
                    Text(metric.title).font(.caption).foregroundStyle(.secondary)
                    Text(metric.value).monospacedDigit().textSelection(.enabled)
                }
                .padding(.vertical)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
