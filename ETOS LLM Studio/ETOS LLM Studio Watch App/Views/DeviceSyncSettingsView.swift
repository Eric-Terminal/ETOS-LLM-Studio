// ============================================================================
// DeviceSyncSettingsView.swift
// ============================================================================
// DeviceSyncSettingsView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct DeviceSyncSettingsView: View {
    @EnvironmentObject private var syncManager: WatchSyncManager
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isSyncIntroExpanded = false
    @State private var isPreparingWatchDatabasePlan = false
    @State private var watchDatabasePlan: WatchSyncDatabasePlan?
    @State private var watchDatabaseSelections: [WatchSyncDatabaseKind: String] = [:]
    @State private var isWatchSyncStrategyDialogPresented = false
    @State private var isLegacyMergeWarningPresented = false
    @State private var watchSyncErrorMessage: String?

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("同步与备份", comment: "Sync and backup intro title"),
                    summary: NSLocalizedString("先区分手动快照、启动保护和设备同步，再选择要执行的操作。", comment: "Sync and backup intro summary"),
                    details: syncIntroDetails,
                    isExpanded: $isSyncIntroExpanded
                )
            }

            Section {
                NavigationLink {
                    WatchBackupRestoreView()
                } label: {
                    Label(NSLocalizedString("数据库快照", comment: ""), systemImage: "externaldrive.badge.icloud")
                }
            } header: {
                Text(NSLocalizedString("手动快照", comment: ""))
            } footer: {
                Text(NSLocalizedString("手动导出或恢复 .elsbackup 快照。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("启动时创建数据库备份点", comment: ""), isOn: $appConfig.syncBackupCreateOnLaunch)
                    .buttonStyle(.plain)
            } header: {
                Text(NSLocalizedString("启动保护备份", comment: ""))
            } footer: {
                Text(NSLocalizedString("只保留一个本机启动还原点；新还原点确认可用后会删除上一份。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("启用 Apple Watch 同步", comment: ""), isOn: $appConfig.syncAutoSyncEnabled)
                    .buttonStyle(.plain)

                Button {
                    isWatchSyncStrategyDialogPresented = true
                } label: {
                    HStack {
                        Spacer()
                        if isSyncing || isPreparingWatchDatabasePlan {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("选择同步方式", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                }
                .disabled(!appConfig.syncAutoSyncEnabled || isSyncing || isPreparingWatchDatabasePlan)
            } header: {
                Text(NSLocalizedString("Apple Watch 同步", comment: ""))
            } footer: {
                Text(NSLocalizedString("开启后可按库覆盖或手动选择旧合并。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("启用 iCloud 漫游同步", comment: ""), isOn: $appConfig.cloudSyncEnabled)
                    .buttonStyle(.plain)

                Button {
                    Task {
                        await cloudSyncManager.performSync(options: .fullSync)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isCloudSyncing {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("立即检查并同步", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                }
                .disabled(!appConfig.cloudSyncEnabled || isCloudSyncing)
            } header: {
                Text(NSLocalizedString("iCloud 漫游同步", comment: ""))
            } footer: {
                Text(NSLocalizedString("开启后会自动增量同步。此按钮只会立即检查远端变化并上传本机变化，不会强制覆盖任一端。首次发现两套不同数据时，会先让你选择保留哪一套。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("iCloud 状态", comment: "")) {
                cloudSyncStatusView
            }
        }
        .navigationTitle(NSLocalizedString("同步与备份", comment: ""))
        .confirmationDialog(
            NSLocalizedString("发现两套不同的数据", comment: ""),
            isPresented: Binding(
                get: { cloudSyncManager.initialConflict != nil },
                set: { if !$0 { cloudSyncManager.dismissInitialConflictPrompt() } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("使用 iCloud 数据", comment: "")) {
                Task {
                    await cloudSyncManager.resolveInitialConflict(using: .useICloud)
                }
            }
            Button(NSLocalizedString("使用此设备数据覆盖 iCloud", comment: ""), role: .destructive) {
                Task {
                    await cloudSyncManager.resolveInitialConflict(using: .useThisDevice)
                }
            }
            Button(NSLocalizedString("暂不同步", comment: ""), role: .cancel) {
                cloudSyncManager.dismissInitialConflictPrompt()
            }
        } message: {
            if let conflict = cloudSyncManager.initialConflict {
                Text(String(
                    format: NSLocalizedString("此设备尚未建立可信的 iCloud 同步基线。本机有 %d 条记录，iCloud 有 %d 条记录；选择前不会修改任何数据。执行覆盖前会自动创建安全快照。", comment: ""),
                    conflict.localRecordCount,
                    conflict.iCloudRecordCount
                ))
            }
        }
        .confirmationDialog(
            NSLocalizedString("选择 Apple Watch 同步方式", comment: ""),
            isPresented: $isWatchSyncStrategyDialogPresented,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("按库选择覆盖", comment: "")) {
                prepareWatchDatabasePlan()
            }
            Button(NSLocalizedString("使用旧合并引擎", comment: ""), role: .destructive) {
                isLegacyMergeWarningPresented = true
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("如果 iPhone 与 Apple Watch 已经分叉，直接合并并不可靠。可以选择每个库保留哪一端；旧合并可能恢复已删除内容。", comment: ""))
        }
        .alert(NSLocalizedString("旧合并存在风险", comment: ""), isPresented: $isLegacyMergeWarningPresented) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("继续合并", comment: ""), role: .destructive) {
                syncManager.performSync(options: .fullSync)
            }
        } message: {
            Text(NSLocalizedString("旧合并引擎会尝试把两端数据拼在一起，但单端删除的提供商、设置或会话可能被另一端旧数据同步回来。", comment: ""))
        }
        .alert(NSLocalizedString("同步准备失败", comment: ""), isPresented: Binding(
            get: { watchSyncErrorMessage != nil },
            set: { if !$0 { watchSyncErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) {}
        } message: {
            Text(watchSyncErrorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { watchDatabasePlan != nil },
            set: { if !$0 { watchDatabasePlan = nil } }
        )) {
            if let plan = watchDatabasePlan {
                WatchDatabaseOverwriteSelectionView(
                    plan: plan,
                    selections: $watchDatabaseSelections,
                    onCancel: {
                        watchDatabasePlan = nil
                    },
                    onConfirm: { resolutions in
                        watchDatabasePlan = nil
                        syncManager.performDatabaseOverwriteSync(resolutions: resolutions)
                    }
                )
            }
        }
    }

    private var syncIntroDetails: String {
        [
            NSLocalizedString("同步与备份说明正文", comment: ""),
            NSLocalizedString("iCloud 首次同步裁决说明", comment: "")
        ].joined(separator: "\n\n")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "同步与备份介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "同步与备份介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var isCloudSyncing: Bool {
        if case .syncing = cloudSyncManager.state {
            return true
        }
        return false
    }

    private var isSyncing: Bool {
        if case .syncing = syncManager.state {
            return true
        }
        return false
    }

    private func prepareWatchDatabasePlan() {
        isPreparingWatchDatabasePlan = true
        Task {
            do {
                let plan = try await syncManager.fetchDatabaseSyncPlan()
                watchDatabaseSelections = Dictionary(
                    uniqueKeysWithValues: WatchSyncDatabaseKind.allCases.map { kind in
                        (kind, plan.recommendedSourcePlatform(for: kind))
                    }
                )
                watchDatabasePlan = plan
            } catch {
                watchSyncErrorMessage = error.localizedDescription
            }
            isPreparingWatchDatabasePlan = false
        }
    }

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        if !appConfig.cloudSyncEnabled {
            Text(NSLocalizedString("iCloud 漫游同步已关闭", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch cloudSyncManager.state {
            case .idle:
                Text(NSLocalizedString("未同步", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            case .syncing(let message):
                HStack {
                    ProgressView()
                    Text(message)
                        .etFont(.caption)
                }
            case .waitingForInitialDecision:
                Label(NSLocalizedString("等待选择数据来源", comment: ""), systemImage: "arrow.triangle.branch")
                    .etFont(.caption)
                    .foregroundStyle(.orange)
            case .success(let summary):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("成功", comment: ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(summaryDescription(summary))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("失败", comment: ""), systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Text(reason)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Text(NSLocalizedString("未知状态", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryDescription(_ summary: SyncMergeSummary) -> String {
        var parts: [String] = []
        if summary.importedProviders > 0 {
            parts.append(String(format: NSLocalizedString("提供商 +%d", comment: ""), summary.importedProviders))
        }
        if summary.importedSessions > 0 {
            parts.append(String(format: NSLocalizedString("会话 +%d", comment: ""), summary.importedSessions))
        }
        if summary.importedBackgrounds > 0 {
            parts.append(String(format: NSLocalizedString("背景 +%d", comment: ""), summary.importedBackgrounds))
        }
        if summary.importedMemories > 0 {
            parts.append(String(format: NSLocalizedString("记忆 +%d", comment: ""), summary.importedMemories))
        }
        if summary.importedMCPServers > 0 {
            parts.append(String(format: NSLocalizedString("MCP +%d", comment: ""), summary.importedMCPServers))
        }
        if summary.importedAudioFiles > 0 {
            parts.append(String(format: NSLocalizedString("音频 +%d", comment: ""), summary.importedAudioFiles))
        }
        if summary.importedImageFiles > 0 {
            parts.append(String(format: NSLocalizedString("图片 +%d", comment: ""), summary.importedImageFiles))
        }
        if summary.importedSkills > 0 {
            parts.append(String(format: NSLocalizedString("Skills +%d", comment: ""), summary.importedSkills))
        }
        if summary.importedShortcutTools > 0 {
            parts.append(String(format: NSLocalizedString("快捷指令工具 +%d", comment: ""), summary.importedShortcutTools))
        }
        if summary.importedWorldbooks > 0 {
            parts.append(String(format: NSLocalizedString("世界书 +%d", comment: ""), summary.importedWorldbooks))
        }
        if summary.importedFeedbackTickets > 0 {
            parts.append(String(format: NSLocalizedString("工单 +%d", comment: ""), summary.importedFeedbackTickets))
        }
        if summary.importedDailyPulseRuns > 0 {
            parts.append(String(format: NSLocalizedString("每日脉冲 +%d", comment: ""), summary.importedDailyPulseRuns))
        }
        if summary.importedUsageEvents > 0 {
            parts.append(String(format: NSLocalizedString("用量事件 +%d", comment: ""), summary.importedUsageEvents))
        }
        if summary.importedFontFiles > 0 {
            parts.append(String(format: NSLocalizedString("字体文件 +%d", comment: ""), summary.importedFontFiles))
        }
        if summary.importedFontRouteConfigurations > 0 {
            parts.append(String(format: NSLocalizedString("字体规则 +%d", comment: ""), summary.importedFontRouteConfigurations))
        }
        if summary.importedAppStorageValues > 0 {
            parts.append(String(format: NSLocalizedString("软件设置 +%d", comment: ""), summary.importedAppStorageValues))
        }
        let separator = NSLocalizedString("，", comment: "")
        return parts.isEmpty ? NSLocalizedString("两端数据一致", comment: "") : parts.joined(separator: separator)
    }
}

private struct WatchDatabaseOverwriteSelectionView: View {
    let plan: WatchSyncDatabasePlan
    @Binding var selections: [WatchSyncDatabaseKind: String]
    let onCancel: () -> Void
    let onConfirm: ([WatchSyncDatabaseResolution]) -> Void
    @State private var isConfirmingOverwrite = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(NSLocalizedString("选择每个库要保留哪一端；另一端会被覆盖。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(WatchSyncDatabaseKind.allCases) { kind in
                    Section {
                        Picker(NSLocalizedString("保留平台", comment: ""), selection: selectionBinding(for: kind)) {
                            Text(platformName(plan.local.sourcePlatform)).tag(plan.local.sourcePlatform)
                            Text(platformName(plan.remote.sourcePlatform)).tag(plan.remote.sourcePlatform)
                        }

                        databaseMetadataRow(kind: kind, sourcePlatform: plan.local.sourcePlatform)
                        databaseMetadataRow(kind: kind, sourcePlatform: plan.remote.sourcePlatform)
                    } header: {
                        Text(kind.localizedTitle)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingOverwrite = true
                    } label: {
                        Label(NSLocalizedString("开始覆盖", comment: ""), systemImage: "externaldrive.badge.arrow.down")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("按库选择覆盖", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: ""), action: onCancel)
                }
            }
            .alert(NSLocalizedString("确认覆盖数据库", comment: ""), isPresented: $isConfirmingOverwrite) {
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
                Button(NSLocalizedString("开始覆盖", comment: ""), role: .destructive) {
                    onConfirm(resolutions)
                }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    private var resolutions: [WatchSyncDatabaseResolution] {
        WatchSyncDatabaseKind.allCases.map { kind in
            WatchSyncDatabaseResolution(
                kind: kind,
                sourcePlatform: selections[kind] ?? plan.recommendedSourcePlatform(for: kind)
            )
        }
    }

    private var confirmationMessage: String {
        let detail = resolutions.map { resolution in
            String(
                format: NSLocalizedString("%@：保留%@", comment: "Watch database overwrite confirmation item"),
                resolution.kind.localizedTitle,
                platformName(resolution.sourcePlatform)
            )
        }.joined(separator: "\n")
        return String(
            format: NSLocalizedString("即将按下面的选择覆盖数据库：\n%@\n覆盖前如果有重要对话，请先到会话列表把单个会话发送到另一端。", comment: "Watch database overwrite confirmation message"),
            detail
        )
    }

    private func selectionBinding(for kind: WatchSyncDatabaseKind) -> Binding<String> {
        Binding(
            get: { selections[kind] ?? plan.recommendedSourcePlatform(for: kind) },
            set: { selections[kind] = $0 }
        )
    }

    private func databaseMetadataRow(kind: WatchSyncDatabaseKind, sourcePlatform: String) -> some View {
        let metadata = plan.metadata(kind: kind, sourcePlatform: sourcePlatform)
        return VStack(alignment: .leading, spacing: 2) {
            Text(platformName(sourcePlatform))
                .etFont(.caption.weight(.medium))
            Text(metadataDescription(metadata))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func metadataDescription(_ metadata: WatchSyncDatabaseMetadata?) -> String {
        guard let metadata else {
            return NSLocalizedString("没有可用信息", comment: "")
        }
        return String(
            format: NSLocalizedString("更新时间：%@；大小：%@", comment: "Watch database metadata description"),
            formattedDate(metadata.updatedAt),
            formattedBytes(metadata.byteSize)
        )
    }

    private func formattedDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened)
            ?? NSLocalizedString("未知", comment: "")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "iOS":
            return NSLocalizedString("iPhone", comment: "Watch sync iOS platform name")
        case "watchOS":
            return NSLocalizedString("Apple Watch", comment: "Watch sync watchOS platform name")
        default:
            return platform
        }
    }
}
