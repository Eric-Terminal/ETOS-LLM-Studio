import ETOSCore
import SwiftUI

struct MacUpdateTimelineView: View {
    let isActive: Bool
    @ObservedObject private var model = MacAppInformationModel.shared

    var body: some View {
        Group {
            if let manager = model.updates {
                MacUpdateTimelineContent(isActive: isActive, manager: manager, model: model)
            } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
        }
        .navigationTitle(NSLocalizedString("检查更新", comment: ""))
    }
}

private struct MacUpdateTimelineContent: View {
    let isActive: Bool
    @ObservedObject var manager: UpdateTimelineManager
    @ObservedObject var model: MacAppInformationModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var clearConfirmation = false
    private var working: Bool { model.working || manager.isRefreshing || manager.isSummarizing }

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("自动检查更新", comment: ""), isOn: $configuration.updateTimelineAutoCheckEnabled)
                Toggle(NSLocalizedString("自动检查并总结", comment: ""), isOn: $configuration.updateTimelineAutoSummaryEnabled)
                Button(NSLocalizedString("刷新检查更新", comment: "")) { model.refresh() }.disabled(working)
                Button(NSLocalizedString("清空更新缓存", comment: ""), role: .destructive) { clearConfirmation = true }.disabled(working)
            }
            Section(NSLocalizedString("状态", comment: "")) {
                LabeledContent(NSLocalizedString("通道", comment: ""), value: manager.state.channel.displayName)
                LabeledContent(NSLocalizedString("状态", comment: ""), value: manager.state.status.displayName)
                if let date = manager.state.lastCheckedAt { Text(date, style: .date) }
                if let error = manager.state.lastErrorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                if working { ProgressView() }
            }
            Section(NSLocalizedString("AI 摘要", comment: "")) {
                if let summary = model.timeline?.summary { MacMessageTextView(text: summary) }
                else { Text(NSLocalizedString("还没有摘要。", comment: "")).foregroundStyle(.secondary) }
                Button(NSLocalizedString("请求 AI 总结", comment: "")) { model.summarize() }
                    .disabled(working || model.timeline?.allowsSummary != true)
            }
            Section(NSLocalizedString("Commit 时间线", comment: "")) {
                ForEach(model.timeline?.commits ?? []) { commit in
                    NavigationLink {
                        Form {
                            Text(commit.value.oid).font(.caption.monospaced()).textSelection(.enabled)
                            MacMessageTextView(text: commit.text)
                            if let url = commit.value.url { Link(NSLocalizedString("打开 GitHub Commit", comment: ""), destination: url) }
                        }
                        .formStyle(.grouped)
                        .navigationTitle(commit.shortOID)
                        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-update-\(commit.id)"),
                            title: NSLocalizedString("关联 Commit", comment: ""),
                            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("检查更新", comment: ""))],
                            isActive: isActive, settings: [.readOnly("commit", label: NSLocalizedString("Commit", comment: ""), value: { .string(commit.id) })])
                    } label: {
                        VStack(alignment: .leading) {
                            Text(commit.headline)
                            Text(commit.shortOID).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped).disabled(!isActive)
        .confirmationDialog(NSLocalizedString("清空更新缓存？", comment: ""), isPresented: $clearConfirmation) {
            Button(NSLocalizedString("清空更新缓存", comment: ""), role: .destructive) { if isActive { model.clearUpdates() } }
        }
        .guideSettingsPageContext(id: "mac-update-timeline", title: NSLocalizedString("检查更新", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("检查更新", comment: ""))],
            isActive: isActive, settings: [
                .bool("auto_check", label: NSLocalizedString("自动检查更新", comment: ""), get: { configuration.updateTimelineAutoCheckEnabled }, set: { configuration.updateTimelineAutoCheckEnabled = $0 }),
                .bool("auto_summary", label: NSLocalizedString("自动检查并总结", comment: ""), get: { configuration.updateTimelineAutoSummaryEnabled }, set: { configuration.updateTimelineAutoSummaryEnabled = $0 }),
                .readOnly("status", label: NSLocalizedString("状态", comment: ""), value: { .string(manager.state.status.rawValue) })
            ])
    }
}
