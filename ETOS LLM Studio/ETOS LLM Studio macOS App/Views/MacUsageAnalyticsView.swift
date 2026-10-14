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
    private var available: Bool { visible && isActive && workspace.canManageLocalModels && appLock.state != .locked }

    var body: some View {
        Group {
            if available, let snapshot = model.presentation {
                ScrollView {
                    VStack(alignment: .leading) {
                        MacSettingsIntroCard(id: "usage-analytics", title: NSLocalizedString("使用说明", comment: ""),
                            details: NSLocalizedString("Mac 用量统计使用说明", comment: ""), documentID: "usage-analytics", isActive: available)
                        if snapshot.isEmpty {
                            Text(NSLocalizedString("当前还没有可展示的统计数据。用量会从升级到此版本后开始累计。", comment: ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        GroupBox(NSLocalizedString("用量总览", comment: "")) { MacUsageMetrics(metrics: snapshot.summary) }
                        ForEach(snapshot.overview) { card in
                            GroupBox {
                                MacUsageMetrics(metrics: card.metrics)
                            } label: {
                                Button(card.title) { model.selectScope(card.id) }.buttonStyle(.link)
                            }
                        }
                        MacUsageCalendarView(snapshot: snapshot, model: model)
                        Picker(NSLocalizedString("统计范围", comment: ""), selection: Binding(
                            get: { snapshot.scope }, set: { model.selectScope($0) })) {
                            ForEach(UsageAnalyticsDetailScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                        }
                        .pickerStyle(.segmented)
                        GroupBox {
                            VStack(alignment: .leading) {
                                Text(snapshot.subtitle).font(.footnote).foregroundStyle(.secondary)
                                MacUsageMetrics(metrics: snapshot.detail)
                            }
                        } label: { Text(snapshot.title) }
                        MacUsageTrendView(snapshot: snapshot)
                        ranks(snapshot.models, title: NSLocalizedString("模型榜单", comment: ""),
                              empty: NSLocalizedString("当前范围内还没有模型请求。", comment: ""))
                        ranks(snapshot.sources, title: NSLocalizedString("来源分布", comment: ""),
                              empty: NSLocalizedString("当前范围内还没有来源数据。", comment: ""))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if available {
                ProgressView(NSLocalizedString("正在加载…", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .toolbar {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Label(NSLocalizedString("刷新", comment: ""), systemImage: "arrow.clockwise") }
                .disabled(!available || model.isLoading)
        }
        .onAppear { visible = true; if available { model.resume() } }
        .onDisappear { visible = false; model.suspend() }
        .onChange(of: available) { _, active in if active { model.resume() } else { model.suspend() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.suspend(); if available { model.resume() } }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-usage-analytics-\(model.revision)"),
            title: NSLocalizedString("用量统计", comment: ""),
            documents: [GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics"),
                        GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available && model.presentation != nil && !model.isLoading,
            settings: [
                .readOnly("summary", label: NSLocalizedString("用量总览", comment: ""), value: { model.presentation?.guideSummary ?? .null }),
                .readOnly("scope", label: NSLocalizedString("统计范围", comment: ""), value: { .string(model.presentation?.scope.rawValue ?? "day") }),
                .readOnly("selected_day", label: NSLocalizedString("日期", comment: ""), value: { .string(model.presentation?.selectedDay ?? "") }),
                .readOnly("displayed_month", label: NSLocalizedString("日历面板", comment: ""), value: { .string(model.presentation?.monthTitle ?? "") }),
                .readOnly("detail", label: NSLocalizedString("详情", comment: ""), value: { model.presentation?.guideDetail ?? .null })
            ])
    }

    private func ranks(_ items: [MacUsageAnalyticsPresentation.Rank], title: String, empty: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading) {
                if items.isEmpty { Text(empty).font(.footnote).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    DisclosureGroup {
                        MacUsageMetrics(metrics: item.metrics)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.title).textSelection(.enabled)
                            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
