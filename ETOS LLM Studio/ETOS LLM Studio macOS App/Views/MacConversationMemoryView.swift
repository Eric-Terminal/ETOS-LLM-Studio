import ETOSCore
import SwiftUI

struct MacConversationMemoryView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacConversationMemoryModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var editor: MacProfileEditorDraft?
    @State private var deletion: Deletion?

    private enum Deletion { case summary(UUID), summaries, profile }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(
                    id: "conversation-memory", title: NSLocalizedString("跨对话记忆与画像", comment: ""),
                    details: NSLocalizedString("跨对话记忆会在后台整理会话摘要，并向后续对话提供最近摘要和用户画像。启用记忆及异步跨对话记忆后，摘要按轮次和最小间隔触发；画像可每天自动更新，也可手动编辑。编辑只改变草稿，保存时保留结构化事实；清空操作需单独确认。", comment: ""),
                    documentID: "settings-memory"
                )
                Toggle(NSLocalizedString("启用记忆", comment: ""), isOn: $configuration.enableMemory)
                Toggle(NSLocalizedString("启用异步跨对话记忆", comment: ""), isOn: $configuration.enableConversationMemoryAsync)
                Stepper(value: $configuration.conversationMemoryRecentLimit, in: 1...Int.max) {
                    LabeledContent(NSLocalizedString("注入最近摘要数", comment: ""), value: String(configuration.conversationMemoryRecentLimit))
                }
                Stepper(value: $configuration.conversationMemoryRoundThreshold, in: 1...Int.max) {
                    LabeledContent(NSLocalizedString("摘要触发轮次阈值", comment: ""), value: String(configuration.conversationMemoryRoundThreshold))
                }
                Stepper(value: $configuration.conversationMemorySummaryMinIntervalMinutes, in: 0...Int.max) {
                    LabeledContent(NSLocalizedString("摘要最小间隔（分钟）", comment: ""), value: String(configuration.conversationMemorySummaryMinIntervalMinutes))
                }
                Toggle(NSLocalizedString("用户画像每天自动更新一次", comment: ""), isOn: $configuration.enableConversationProfileDailyUpdate)
                Picker(NSLocalizedString("摘要专用模型", comment: ""), selection: $configuration.conversationSummaryModelIdentifier) {
                    Text(NSLocalizedString("未选择（跟随当前对话模型）", comment: "")).tag("")
                    if !model.modelIDSet.contains(configuration.conversationSummaryModelIdentifier) {
                        Text(NSLocalizedString("已选模型不可用", comment: "")).tag(configuration.conversationSummaryModelIdentifier)
                    }
                    ForEach(model.models) { item in Text(item.model.displayName).tag(item.id) }
                }
            }
            Section {
                if !model.isLoaded { ProgressView() }
                else if model.presentation.summaries.isEmpty {
                    Text(NSLocalizedString("暂无会话摘要。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.presentation.summaries) { row in
                    NavigationLink {
                        MacConversationSummaryView(model: model, id: row.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(row.source.sessionName)
                            Text(row.source.summary).lineLimit(3).font(.footnote).foregroundStyle(.secondary)
                            Text(row.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletion = .summary(row.id) } }
                }
                Button(NSLocalizedString("清空全部会话摘要", comment: ""), role: .destructive) { deletion = .summaries }
                    .disabled(model.presentation.summaries.isEmpty)
            } header: { Text(NSLocalizedString("会话摘要管理", comment: "")) }
            Section {
                if let profile = model.presentation.profile {
                    Text(profile.content).lineLimit(6).textSelection(.enabled)
                    Text(model.presentation.profileDate).font(.caption).foregroundStyle(.secondary)
                    if !model.presentation.factGroups.isEmpty {
                        NavigationLink(NSLocalizedString("画像事实", comment: "")) { MacProfileFactsView(model: model) }
                    }
                    Button(NSLocalizedString("编辑用户画像", comment: "")) { editor = MacProfileEditorDraft(profile: profile) }
                    Button(NSLocalizedString("清空用户画像", comment: ""), role: .destructive) { deletion = .profile }
                } else {
                    Text(NSLocalizedString("暂无用户画像。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("新建用户画像", comment: "")) { editor = MacProfileEditorDraft(profile: nil) }
                        .disabled(!model.isLoaded)
                }
            } header: { Text(NSLocalizedString("用户画像", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .disabled(model.isWorking)
        .navigationTitle(NSLocalizedString("跨对话记忆与画像", comment: ""))
        .task { model.start(service: workspace.service) }
        .sheet(item: $editor) { draft in MacProfileEditor(model: model, original: draft.profile) }
        .confirmationDialog(NSLocalizedString("确认删除", comment: ""), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { action in
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                deletion = nil
                Task {
                    guard !workspace.isRestoringData else { return }
                    switch action {
                    case .summary(let id): await model.deleteSummary(id: id)
                    case .summaries: await model.clearSummaries()
                    case .profile: await model.clearProfile()
                    }
                }
            }
        } message: { action in
            switch action {
            case .summary: Text(NSLocalizedString("删除", comment: ""))
            case .summaries: Text(NSLocalizedString("清空全部会话摘要", comment: ""))
            case .profile: Text(NSLocalizedString("清空用户画像", comment: ""))
            }
        }
        .guideSettingsPageContext(
            id: "mac-conversation-memory", title: NSLocalizedString("跨对话记忆与画像", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: model.isWorking ? [.readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })] : [
                .bool("enabled", label: NSLocalizedString("启用记忆", comment: ""), get: { configuration.enableMemory }, set: { configuration.enableMemory = $0 }),
                .bool("async_memory", label: NSLocalizedString("启用异步跨对话记忆", comment: ""), get: { configuration.enableConversationMemoryAsync }, set: { configuration.enableConversationMemoryAsync = $0 }),
                .integer("recent_limit", label: NSLocalizedString("注入最近摘要数", comment: ""), range: 1...Int.max, get: { configuration.conversationMemoryRecentLimit }, set: { configuration.conversationMemoryRecentLimit = $0 }),
                .integer("round_threshold", label: NSLocalizedString("摘要触发轮次阈值", comment: ""), range: 1...Int.max, get: { configuration.conversationMemoryRoundThreshold }, set: { configuration.conversationMemoryRoundThreshold = $0 }),
                .integer("minimum_interval", label: NSLocalizedString("摘要最小间隔（分钟）", comment: ""), range: 0...Int.max, get: { configuration.conversationMemorySummaryMinIntervalMinutes }, set: { configuration.conversationMemorySummaryMinIntervalMinutes = $0 }),
                .bool("daily_profile", label: NSLocalizedString("用户画像每天自动更新一次", comment: ""), get: { configuration.enableConversationProfileDailyUpdate }, set: { configuration.enableConversationProfileDailyUpdate = $0 }),
                .string("summary_model", label: NSLocalizedString("摘要专用模型", comment: ""), allowedValues: model.modelIDs, get: { configuration.conversationSummaryModelIdentifier }, set: { configuration.conversationSummaryModelIdentifier = $0 }),
                .readOnly("summary_count", label: NSLocalizedString("会话摘要数量", comment: ""), value: { .int(model.presentation.summaries.count) }),
                .readOnly("profile", label: NSLocalizedString("用户画像", comment: ""), value: { .string(model.presentation.profile?.content ?? "") }),
                .readOnly("fact_count", label: NSLocalizedString("结构化事实数量", comment: ""), value: { .int(model.presentation.profile?.facts.count ?? 0) })
            ]
        )
    }
}

private struct MacProfileEditorDraft: Identifiable {
    let id = UUID()
    let profile: ConversationUserProfile?
}

private struct MacConversationSummaryView: View {
    @ObservedObject var model: MacConversationMemoryModel
    let id: UUID
    private var row: MacConversationSummaryRow? { model.presentation.summariesByID[id] }

    var body: some View {
        Form {
            if let row {
                Text(row.source.sessionName).font(.headline)
                Text(row.date).font(.caption).foregroundStyle(.secondary)
                Text(row.source.summary).textSelection(.enabled)
            } else { Text(NSLocalizedString("暂无会话摘要。", comment: "")).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("会话摘要管理", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-conversation-summary-\(id.uuidString)"), title: NSLocalizedString("会话摘要管理", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: [
                .readOnly("session", label: NSLocalizedString("会话名称", comment: ""), value: { .string(row?.source.sessionName ?? "") }),
                .readOnly("summary", label: NSLocalizedString("会话摘要管理", comment: ""), value: { .string(row?.source.summary ?? "") }),
                .readOnly("updated_at", label: NSLocalizedString("更新时间", comment: ""), value: { .string(row?.date ?? "") })
            ]
        )
    }
}

private struct MacProfileFactsView: View {
    @ObservedObject var model: MacConversationMemoryModel

    var body: some View {
        Form {
            ForEach(model.presentation.factGroups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        VStack(alignment: .leading) {
                            Text(row.statement).textSelection(.enabled)
                            Text(row.evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("画像事实", comment: ""))
        .guideSettingsPageContext(
            id: "mac-profile-facts", title: NSLocalizedString("画像事实", comment: ""),
            documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
            settings: [.readOnly("facts", label: NSLocalizedString("画像事实", comment: ""), value: { model.presentation.guideFacts })]
        )
    }
}
