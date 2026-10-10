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

    public var body: some View {
        Group {
            if available { analyticsList }
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

    private var analyticsList: some View {
        List {
            settingsIntroCard
            if let presentation = viewModel.presentation {
                if presentation.isEmpty {
                    Text(NSLocalizedString("session_usage.empty", value: "No recorded requests for this conversation yet.", comment: "会话统计空状态"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(presentation.overview) { metric($0.title, value: $0.value) }
                    if let note = presentation.missingCostNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("用量总览", comment: ""))
                } footer: {
                    Text(NSLocalizedString("session_usage.cost_note", value: "Estimates use current model prices and each request's time. Missing usage or prices are excluded. Amounts use the unit configured in model pricing and are not a provider bill.", comment: "会话费用统计口径"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(presentation.tokens) { metric($0.title, value: $0.value) }
                    if let note = presentation.missingUsageNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(NSLocalizedString("session_usage.token_note", value: "Thinking and cache details may already be included in input or output tokens and are not added to the total again.", comment: "会话 Token 明细口径"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(presentation.requests) { metric($0.title, value: $0.value) }
                }
            } else {
                ProgressView(NSLocalizedString("正在加载", comment: ""))
            }
        }
    }

    private var settingsIntroCard: some View {
        Section {
            VStack(alignment: .leading) {
                Label(sessionName, systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Text(NSLocalizedString("session_usage.intro", value: "Counts recorded requests for this conversation, including retries and related tasks such as title generation. Copied history is not charged again; deleting messages does not erase recorded usage. Requests predating usage tracking are unavailable.", comment: "会话统计介绍"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(title)
        }
    }
}
