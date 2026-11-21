import SwiftUI

public struct SessionUsageAnalyticsView: View {
    private let sessionID: UUID
    private let sessionName: String
    private let isActive: Bool
    @StateObject private var viewModel: SessionUsageAnalyticsViewModel
    @State private var isVisible = false
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.dismiss) private var dismiss

    public init(sessionID: UUID, sessionName: String, isActive: Bool = true) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.isActive = isActive
        _viewModel = StateObject(wrappedValue: SessionUsageAnalyticsViewModel(sessionID: sessionID))
    }

    private var available: Bool { isActive && appLock.state != .locked }
    private var locale: Locale { Locale(identifier: AppLanguagePreference.resolved(rawValue: configuration.appLanguage).localeIdentifier) }

    private var isCompactWatchLayout: Bool {
        #if os(watchOS)
        return true
        #else
        return false
        #endif
    }

    public var body: some View {
        Group {
            if available { analyticsContent }
            else { Color.clear }
        }
        .navigationTitle(NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计标题"))
        .onAppear { isVisible = true; viewModel.setActive(available, locale: locale) }
        .onDisappear { isVisible = false; viewModel.setActive(false) }
        .onChange(of: available) { _, active in viewModel.setActive(isVisible && active, locale: locale) }
        .onChange(of: configuration.appLanguage) { _, _ in viewModel.refresh(locale: locale) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "session-usage-analytics.\(sessionID.uuidString).\(viewModel.revision.uuidString).\(configuration.appLanguage)"),
            title: NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计标题"),
            documents: [GuideDocumentReference(id: "usage-analytics", title: NSLocalizedString("用量统计", comment: ""))],
            isActive: isVisible && available,
            settings: [
                .readOnly("session", label: NSLocalizedString("会话信息", comment: ""), value: {
                    .dictionary(["id": .string(sessionID.uuidString), "name": .string(sessionName)])
                }),
                .readOnly("summary", label: NSLocalizedString("用量总览", comment: ""), value: {
                    viewModel.presentation?.guideSnapshot ?? .null
                }),
                .readOnly("loading", label: NSLocalizedString("正在加载", comment: ""), value: { .bool(viewModel.presentation == nil) })
            ]
        )
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("完成", comment: "")) { dismiss() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var analyticsContent: some View {
        #if os(watchOS)
        watchAnalyticsList
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introBannerCard

                if let presentation = viewModel.presentation {
                    if presentation.isEmpty {
                        emptyBannerCard
                    }

                    UsageHeroSummaryCard(
                        presentation: presentation.heroCard,
                        badgeText: presentation.heroCard.exactTotalText,
                        compactLayout: false
                    )

                    requestBreakdownCard(presentation: presentation)

                    notesAndFootnotesSection(presentation: presentation)
                } else {
                    HStack {
                        Spacer()
                        ProgressView(NSLocalizedString("正在加载", comment: ""))
                            .padding(.vertical, 32)
                        Spacer()
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(sessionPageBackground)
        #endif
    }

    #if os(watchOS)
    private var watchAnalyticsList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(sessionName, systemImage: "chart.bar.xaxis")
                        .font(.footnote.weight(.semibold))
                    Text(NSLocalizedString("session_usage.intro", value: "Counts recorded requests for this conversation, including retries and related tasks such as title generation. Copied history is not charged again; deleting messages does not erase recorded usage. Requests predating usage tracking are unavailable.", comment: "会话统计介绍"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let presentation = viewModel.presentation {
                if presentation.isEmpty {
                    Section {
                        Text(NSLocalizedString("session_usage.empty", value: "No recorded requests for this conversation yet.", comment: "会话统计空状态"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    UsageHeroSummaryCard(
                        presentation: presentation.heroCard,
                        badgeText: nil,
                        compactLayout: true
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section(NSLocalizedString("session_usage.request_count", value: "Requests", comment: "会话请求总数")) {
                    ForEach(presentation.requests) { item in
                        LabeledContent {
                            Text(item.value).monospacedDigit()
                        } label: {
                            Text(item.title)
                        }
                    }
                }

                Section {
                    if let missingCost = presentation.missingCostNote {
                        Text(missingCost)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let missingUsage = presentation.missingUsageNote {
                        Text(missingUsage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(NSLocalizedString("session_usage.token_note", value: "Thinking and cache details may already be included in input or output tokens and are not added to the total again.", comment: "会话 Token 明细口径"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("session_usage.cost_note", value: "Estimates use current model prices and each request's time. Missing usage or prices are excluded. Amounts use the unit configured in model pricing and are not a provider bill.", comment: "会话费用统计口径"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(NSLocalizedString("正在加载", comment: ""))
            }
        }
    }
    #endif

    private var introBannerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(sessionName, systemImage: "chart.bar.xaxis")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(NSLocalizedString("session_usage.intro", value: "Counts recorded requests for this conversation, including retries and related tasks such as title generation. Copied history is not charged again; deleting messages does not erase recorded usage. Requests predating usage tracking are unavailable.", comment: "会话统计介绍"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .usageCardSurface(cornerRadius: 20)
    }

    private var emptyBannerCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("session_usage.empty", value: "No recorded requests for this conversation yet.", comment: "会话统计空状态"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .usageCardSurface(cornerRadius: 18)
    }

    private func requestBreakdownCard(presentation: SessionUsageAnalyticsPresentation) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(NSLocalizedString("session_usage.request_count", value: "Requests", comment: "会话请求总数"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let costMetric = presentation.overview.last {
                    Text("\(costMetric.title) · \(costMetric.value)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(presentation.requests) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(item.value)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
        .padding(20)
        .usageCardSurface(cornerRadius: 24)
    }

    private func notesAndFootnotesSection(presentation: SessionUsageAnalyticsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = presentation.missingCostNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = presentation.missingUsageNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(NSLocalizedString("session_usage.token_note", value: "Thinking and cache details may already be included in input or output tokens and are not added to the total again.", comment: "会话 Token 明细口径"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("session_usage.cost_note", value: "Estimates use current model prices and each request's time. Missing usage or prices are excluded. Amounts use the unit configured in model pricing and are not a provider bill.", comment: "会话费用统计口径"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private var sessionPageBackground: Color {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.clear
        #endif
    }
}
