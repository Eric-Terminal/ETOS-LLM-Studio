import ETOSCore
import SwiftUI

struct MacCloudSyncView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var sync = CloudSyncManager.shared
    @State private var confirmation: MacCloudOverwriteRequest?

    private var isSyncing: Bool { sync.isPerformingSync || workspace.isRestoringData }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(
                    id: "cloud-sync", title: NSLocalizedString("iCloud 漫游同步", comment: ""),
                    details: NSLocalizedString("iCloud 首次同步裁决说明", comment: ""), documentID: "settings-sync"
                )
                Toggle(NSLocalizedString("启用 iCloud 漫游同步", comment: ""), isOn: $configuration.cloudSyncEnabled)
            }
            .disabled(isSyncing)
            Section {
                status
                if let date = sync.lastUpdatedAt {
                    LabeledContent(NSLocalizedString("上次同步", comment: "")) {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                Button(NSLocalizedString("立即同步", comment: "")) {
                    Task { await sync.performSync(options: .fullSync, silent: false) }
                }
                .disabled(!configuration.cloudSyncEnabled || isSyncing)
            } header: { Text(NSLocalizedString("状态", comment: "")) }
            if configuration.cloudSyncEnabled, let conflict = sync.initialConflict {
                Section {
                    Text(String(format: NSLocalizedString("此设备尚未建立可信的 iCloud 同步基线。本机有 %d 条记录，iCloud 有 %d 条记录；App 无法安全判断一端为空是首次接入还是有意删除。选择前不会修改任何数据，执行覆盖前会自动创建安全快照。", comment: ""), conflict.localRecordCount, conflict.iCloudRecordCount))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("使用 iCloud 数据覆盖此设备", comment: ""), role: .destructive) {
                        confirmation = MacCloudOverwriteRequest(conflictID: conflict.id, resolution: .useICloud)
                    }
                    Button(NSLocalizedString("使用此设备数据覆盖 iCloud", comment: ""), role: .destructive) {
                        confirmation = MacCloudOverwriteRequest(conflictID: conflict.id, resolution: .useThisDevice)
                    }
                } header: { Text(NSLocalizedString("等待选择数据来源", comment: "")) }
                .disabled(isSyncing)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("iCloud 漫游同步", comment: ""))
        .guideSettingsPageContext(
            id: "mac-cloud-sync", title: NSLocalizedString("iCloud 漫游同步", comment: ""),
            documents: [GuideDocumentReference(id: "settings-sync", title: "Sync Settings")],
            settings: guideSettings
        )
        .sheet(item: $confirmation) { request in
            MacCloudOverwriteConfirmation(request: request)
        }
    }

    @ViewBuilder private var status: some View {
        if !configuration.cloudSyncEnabled {
            Text(NSLocalizedString("iCloud 漫游同步已关闭", comment: "")).foregroundStyle(.secondary)
        } else {
            switch sync.state {
            case .idle: Text(NSLocalizedString("未进行同步", comment: "")).foregroundStyle(.secondary)
            case .syncing(let message): ProgressView(message)
            case .waitingForInitialDecision:
                Label(NSLocalizedString("等待选择数据来源", comment: ""), systemImage: "arrow.triangle.branch")
            case .success:
                Label(NSLocalizedString("同步成功", comment: ""), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let error): Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("syncing", label: NSLocalizedString("状态", comment: ""), value: { .bool(isSyncing) }),
            .readOnly("awaiting_source", label: NSLocalizedString("等待选择数据来源", comment: ""), value: { .bool(sync.initialConflict != nil) }),
            .readOnly("requires_manual_action", label: NSLocalizedString("立即同步", comment: ""), value: { .bool(true) })
        ]
        if !isSyncing {
            fields += [
                .bool("icloud_enabled", label: NSLocalizedString("启用 iCloud 漫游同步", comment: ""), get: { configuration.cloudSyncEnabled }, set: { configuration.cloudSyncEnabled = $0 })
            ]
        }
        return fields
    }
}

private struct MacCloudOverwriteRequest: Identifiable {
    let id = UUID()
    let conflictID: UUID
    let resolution: CloudSyncInitialResolution

    var title: String {
        switch resolution {
        case .useICloud: NSLocalizedString("使用 iCloud 数据覆盖此设备", comment: "")
        case .useThisDevice: NSLocalizedString("使用此设备数据覆盖 iCloud", comment: "")
        }
    }
    var explanation: String {
        let format: String
        switch resolution {
        case .useICloud:
            format = NSLocalizedString("此操作会用 iCloud 的完整同步数据替换本机同步数据。请输入“%@”以确认覆盖；执行前会自动创建安全快照。", comment: "")
        case .useThisDevice:
            format = NSLocalizedString("此操作会删除 iCloud 当前同步记录并上传本机完整数据，其他设备随后会以本机数据为准。请输入“%@”以确认覆盖；执行前会自动创建安全快照。", comment: "")
        }
        return String(format: format, NSLocalizedString("确认覆盖", comment: ""))
    }
}

private struct MacCloudOverwriteConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var sync = CloudSyncManager.shared
    @ObservedObject private var configuration = AppConfigStore.shared
    let request: MacCloudOverwriteRequest
    @State private var phrase = ""
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Text(request.explanation).font(.footnote).foregroundStyle(.secondary)
                TextField(NSLocalizedString("确认覆盖", comment: ""), text: $phrase)
                    .disabled(isApplying)
                if isApplying { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(request.title, role: .destructive) {
                    isApplying = true
                    Task {
                        do {
                            try await workspace.resolveCloudConflict(using: request.resolution, conflictID: request.conflictID)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        isApplying = false
                    }
                }
                .disabled(isApplying || !configuration.cloudSyncEnabled || sync.initialConflict?.id != request.conflictID
                          || phrase.trimmingCharacters(in: .whitespacesAndNewlines) != NSLocalizedString("确认覆盖", comment: ""))
            }
            .formStyle(.grouped)
            .navigationTitle(request.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isApplying)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-cloud-overwrite-\(request.id)"), title: request.title,
                documents: [GuideDocumentReference(id: "settings-sync", title: "Sync Settings")],
                settings: [
                    .readOnly("requires_manual_confirmation", label: NSLocalizedString("确认覆盖", comment: ""), value: { .bool(true) }),
                    .readOnly("applying", label: NSLocalizedString("状态", comment: ""), value: { .bool(isApplying) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isApplying)
        .frame(minWidth: 560, minHeight: 360)
    }
}
