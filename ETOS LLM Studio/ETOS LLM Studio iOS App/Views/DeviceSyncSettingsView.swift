// ============================================================================
// DeviceSyncSettingsView.swift
// ============================================================================
// DeviceSyncSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct DeviceSyncSettingsView: View {
    @EnvironmentObject private var syncManager: WatchSyncManager
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @AppStorage("sync.options.providers") private var syncProviders = true
    @AppStorage("sync.options.sessions") private var syncSessions = true
    @AppStorage("sync.options.backgrounds") private var syncBackgrounds = true
    @AppStorage("sync.options.memories") private var syncMemories = false
    @AppStorage("sync.options.mcpServers") private var syncMCPServers = true
    @AppStorage("sync.options.imageFiles") private var syncImageFiles = true
    @AppStorage("sync.options.shortcutTools") private var syncShortcutTools = true
    @AppStorage("sync.options.worldbooks") private var syncWorldbooks = true
    @AppStorage("sync.options.feedbackTickets") private var syncFeedbackTickets = true
    @AppStorage("sync.options.dailyPulse") private var syncDailyPulse = true
    @AppStorage("sync.options.fontFiles") private var syncFontFiles = true
    @AppStorage("sync.options.appStorage") private var syncAppStorage = true
    @AppStorage("sync.options.globalPrompt") private var legacySyncGlobalPrompt = true
    @AppStorage(WatchSyncManager.autoSyncEnabledKey) private var autoSyncEnabled = false
    @AppStorage(CloudSyncManager.enabledKey) private var cloudSyncEnabled = false
    @AppStorage(CloudSyncManager.autoSyncEnabledKey) private var cloudAutoSyncEnabled = false
    
    var body: some View {
        List {
            Section("同步内容") {
                Toggle("提供商配置", isOn: $syncProviders)
                Toggle("会话记录", isOn: $syncSessions)
                Toggle("背景图片", isOn: $syncBackgrounds)
                Toggle("记忆（仅合并文本）", isOn: $syncMemories)
                Toggle("MCP 服务器", isOn: $syncMCPServers)
                Toggle("图片文件", isOn: $syncImageFiles)
                Toggle("快捷指令工具", isOn: $syncShortcutTools)
                Toggle("世界书", isOn: $syncWorldbooks)
                Toggle("反馈工单", isOn: $syncFeedbackTickets)
                Toggle("每日脉冲", isOn: $syncDailyPulse)
                Toggle("字体文件与字体规则", isOn: $syncFontFiles)
                Toggle("软件设置（AppStorage）", isOn: $syncAppStorage)
            }

            Section {
                Toggle("启动时自动同步", isOn: $autoSyncEnabled)

                Button {
                    syncManager.performSync(options: selectedSyncOptions)
                } label: {
                    HStack {
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(selectedSyncOptions.isEmpty || isSyncing)
            } header: {
                Text("Apple Watch 同步")
            } footer: {
                Text("点击后将与 Apple Watch 双向同步数据：比较双方差异后，把对方有而本地没有的数据传过来。")
            }
            
            Section("Apple Watch 状态") {
                syncStatusView
            }

            Section {
                Toggle("启用 iCloud 同步", isOn: $cloudSyncEnabled)

                Toggle("启动时自动同步", isOn: $cloudAutoSyncEnabled)
                    .disabled(!cloudSyncEnabled)

                Button {
                    Task {
                        await cloudSyncManager.performSync(options: selectedSyncOptions)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isCloudSyncing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label("同步到 iCloud", systemImage: "icloud")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(!cloudSyncEnabled || selectedSyncOptions.isEmpty || isCloudSyncing)
            } header: {
                Text("iCloud 同步")
            } footer: {
                Text("默认关闭。开启后，iCloud 同步会先上传当前设备快照，再拉取其他设备快照并合并。API Key 通过 iCloud 钥匙串同步，不会写入普通同步包。")
            }

            Section("iCloud 状态") {
                cloudSyncStatusView
            }
        }
        .navigationTitle("设备同步")
        .onAppear(perform: migrateLegacyAppStorageOptionIfNeeded)
    }
    
    private var selectedSyncOptions: SyncOptions {
        var option: SyncOptions = []
        if syncProviders { option.insert(.providers) }
        if syncSessions { option.insert(.sessions) }
        if syncBackgrounds { option.insert(.backgrounds) }
        if syncMemories { option.insert(.memories) }
        if syncMCPServers { option.insert(.mcpServers) }
        if syncImageFiles { option.insert(.imageFiles) }
        if syncShortcutTools { option.insert(.shortcutTools) }
        if syncWorldbooks { option.insert(.worldbooks) }
        if syncFeedbackTickets { option.insert(.feedbackTickets) }
        if syncDailyPulse { option.insert(.dailyPulse) }
        if syncFontFiles { option.insert(.fontFiles) }
        if syncAppStorage { option.insert(.appStorage) }
        return option
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
    
    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.state {
        case .idle:
            Text("未进行同步").etFont(.footnote).foregroundColor(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).etFont(.footnote)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步成功", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                if let lastUpdated = syncManager.lastUpdatedAt {
                    Text("上次同步：\(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步失败", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                Text(reason)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        @unknown default:
            Text("未知状态")
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        if !cloudSyncEnabled {
            Text("iCloud 同步已关闭")
                .etFont(.footnote)
                .foregroundColor(.secondary)
        } else {
            switch cloudSyncManager.state {
            case .idle:
                Text("未进行同步").etFont(.footnote).foregroundColor(.secondary)
            case .syncing(let message):
                HStack {
                    ProgressView()
                    Text(message).etFont(.footnote)
                }
            case .success(let summary):
                VStack(alignment: .leading, spacing: 2) {
                    Label("同步成功", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(summaryDescription(summary))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let lastUpdated = cloudSyncManager.lastUpdatedAt {
                        Text("上次同步：\(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Label("同步失败", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Text(reason)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Text("未知状态")
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
        if summary.importedImageFiles > 0 {
            parts.append(String(format: NSLocalizedString("图片 +%d", comment: ""), summary.importedImageFiles))
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

    private func migrateLegacyAppStorageOptionIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "sync.options.appStorage") == nil,
              defaults.object(forKey: "sync.options.globalPrompt") != nil else {
            return
        }
        syncAppStorage = legacySyncGlobalPrompt
    }
}
