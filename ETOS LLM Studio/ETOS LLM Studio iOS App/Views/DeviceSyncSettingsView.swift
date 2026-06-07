// ============================================================================
// DeviceSyncSettingsView.swift
// ============================================================================
// DeviceSyncSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
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
                    title: "同步与备份",
                    summary: "先区分手动快照、启动保护和设备同步，再选择要执行的操作。",
                    details: syncIntroDetails,
                    isExpanded: $isSyncIntroExpanded
                )
            }

            Section {
                NavigationLink {
                    BackupRestoreView()
                } label: {
                    Label(NSLocalizedString("数据库快照", comment: ""), systemImage: "externaldrive.badge.icloud")
                }
            } header: {
                Text(NSLocalizedString("手动快照", comment: ""))
            } footer: {
                Text(NSLocalizedString("手动导出或恢复 .elsbackup 快照。", comment: ""))
            }

            Section {
                Toggle(NSLocalizedString("启动时创建数据库备份点", comment: ""), isOn: $appConfig.syncBackupCreateOnLaunch)
            } header: {
                Text(NSLocalizedString("启动保护备份", comment: ""))
            } footer: {
                Text(NSLocalizedString("只在启动时写入本机可恢复备份点。", comment: ""))
            }

            if syncManager.isCompanionAvailable {
                Section {
                    Toggle(NSLocalizedString("启用 Apple Watch 同步", comment: ""), isOn: $appConfig.syncAutoSyncEnabled)

                    Button {
                        isWatchSyncStrategyDialogPresented = true
                    } label: {
                        HStack {
                            Spacer()
                            if isSyncing || isPreparingWatchDatabasePlan {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Label(NSLocalizedString("选择同步方式", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                                .etFont(.headline)
                            Spacer()
                        }
                    }
                    .disabled(!appConfig.syncAutoSyncEnabled || isSyncing || isPreparingWatchDatabasePlan)
                } header: {
                    Text(NSLocalizedString("Apple Watch 同步", comment: ""))
                } footer: {
                    Text(NSLocalizedString("开启后可按库覆盖或手动选择旧合并。", comment: ""))
                }

                Section(NSLocalizedString("Apple Watch 状态", comment: "")) {
                    syncStatusView
                }
            }

            Section {
                Toggle(NSLocalizedString("启用 iCloud 漫游同步", comment: ""), isOn: $appConfig.cloudSyncEnabled)

                Button {
                    Task {
                        await cloudSyncManager.performSync(options: .fullSync)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isCloudSyncing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("立即同步", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(!appConfig.cloudSyncEnabled || isCloudSyncing)
            } header: {
                Text(NSLocalizedString("iCloud 漫游同步", comment: ""))
            } footer: {
                Text(NSLocalizedString("开启后会自动在同一 Apple ID 的设备间同步支持的数据。", comment: ""))
            }

            Section(NSLocalizedString("iCloud 状态", comment: "")) {
                cloudSyncStatusView
            }
        }
        .navigationTitle(NSLocalizedString("同步与备份", comment: ""))
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
        NSLocalizedString("同步与备份说明正文", comment: "")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "同步与备份介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "同步与备份介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "同步与备份介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
    
    private var isSyncing: Bool {
        if case .syncing = syncManager.state {
            return true
        }
        return false
    }

    private var isCloudSyncing: Bool {
        if case .syncing = cloudSyncManager.state {
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
    private var syncStatusView: some View {
        switch syncManager.state {
        case .idle:
            Text(NSLocalizedString("未进行同步", comment: "")).etFont(.footnote).foregroundColor(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).etFont(.footnote)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label(NSLocalizedString("同步成功", comment: ""), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                if let lastUpdated = syncManager.lastUpdatedAt {
                    Text(String(format: NSLocalizedString("上次同步：%@", comment: ""), lastUpdated.formatted(date: .abbreviated, time: .shortened)))
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label(NSLocalizedString("同步失败", comment: ""), systemImage: "xmark.circle")
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

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        if !appConfig.cloudSyncEnabled {
            Text(NSLocalizedString("iCloud 漫游同步已关闭", comment: ""))
                .etFont(.footnote)
                .foregroundColor(.secondary)
        } else {
            switch cloudSyncManager.state {
            case .idle:
                Text(NSLocalizedString("未进行同步", comment: "")).etFont(.footnote).foregroundColor(.secondary)
            case .syncing(let message):
                HStack {
                    ProgressView()
                    Text(message).etFont(.footnote)
                }
            case .success(let summary):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("同步成功", comment: ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(summaryDescription(summary))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let lastUpdated = cloudSyncManager.lastUpdatedAt {
                        Text(String(format: NSLocalizedString("上次同步：%@", comment: ""), lastUpdated.formatted(date: .abbreviated, time: .shortened)))
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("同步失败", comment: ""), systemImage: "xmark.circle")
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
                    Text(NSLocalizedString("两端数据分叉时不能可靠直接合并。请为每个库选择要保留的平台，另一端对应库会被覆盖。", comment: ""))
                        .etFont(.footnote)
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
                    } footer: {
                        Text(overwriteFooter(for: kind))
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
            .navigationBarTitleDisplayMode(.inline)
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
        return VStack(alignment: .leading, spacing: 4) {
            Text(platformName(sourcePlatform))
                .etFont(.subheadline.weight(.medium))
            Text(metadataDescription(metadata))
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func overwriteFooter(for kind: WatchSyncDatabaseKind) -> String {
        let selected = selections[kind] ?? plan.recommendedSourcePlatform(for: kind)
        return String(
            format: NSLocalizedString("将保留%@的%@。", comment: "Watch database overwrite footer"),
            platformName(selected),
            kind.localizedTitle
        )
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
