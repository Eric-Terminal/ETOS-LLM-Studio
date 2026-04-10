// ============================================================================
// DeviceSyncSettingsView.swift
// ============================================================================
// DeviceSyncSettingsView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
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
    @AppStorage("sync.options.skills") private var syncSkills = true
    @AppStorage("sync.options.shortcutTools") private var syncShortcutTools = true
    @AppStorage("sync.options.worldbooks") private var syncWorldbooks = true
    @AppStorage("sync.options.feedbackTickets") private var syncFeedbackTickets = true
    @AppStorage("sync.options.dailyPulse") private var syncDailyPulse = true
    @AppStorage("sync.options.fontFiles") private var syncFontFiles = true
    @AppStorage("sync.options.appStorage") private var syncAppStorage = true
    @AppStorage("sync.options.globalPrompt") private var legacySyncGlobalPrompt = true
    @AppStorage("sync.backup.uploadEndpoint") private var backupUploadEndpoint = ""
    @AppStorage(Persistence.launchBackupEnabledKey) private var launchBackupEnabled = false
    @AppStorage(WatchSyncManager.autoSyncEnabledKey) private var autoSyncEnabled = false
    @AppStorage(CloudSyncManager.enabledKey) private var cloudSyncEnabled = false
    @AppStorage(CloudSyncManager.autoSyncEnabledKey) private var cloudAutoSyncEnabled = false
    @State private var exportFileURL: URL?
    @State private var exportErrorMessage: String?
    @State private var isExporting: Bool = false
    @State private var isUploading: Bool = false
    @State private var uploadErrorMessage: String?
    @State private var uploadSuccessMessage: String?
    @State private var uploadResponsePreview: String?
    
    var body: some View {
        List {
            Section("同步内容") {
                Toggle("提供商", isOn: $syncProviders)
                Toggle("会话", isOn: $syncSessions)
                Toggle("背景", isOn: $syncBackgrounds)
                Toggle("记忆", isOn: $syncMemories)
                Toggle("MCP", isOn: $syncMCPServers)
                Toggle("图片", isOn: $syncImageFiles)
                Toggle("Skills", isOn: $syncSkills)
                Toggle("快捷指令", isOn: $syncShortcutTools)
                Toggle("世界书", isOn: $syncWorldbooks)
                Toggle("反馈工单", isOn: $syncFeedbackTickets)
                Toggle("每日脉冲", isOn: $syncDailyPulse)
                Toggle("字体文件与规则", isOn: $syncFontFiles)
                Toggle("软件设置", isOn: $syncAppStorage)
            }

            Section("导出备份") {
                Button {
                    exportDataPackage()
                } label: {
                    HStack {
                        Spacer()
                        if isExporting {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label("生成导出文件", systemImage: "square.and.arrow.up")
                        Spacer()
                    }
                }
                .disabled(selectedSyncOptions.isEmpty || isExporting)

                if let exportFileURL {
                    if #available(watchOS 9.0, *) {
                        ShareLink(item: exportFileURL) {
                            HStack {
                                Spacer()
                                Label("分享导出文件", systemImage: "square.and.arrow.up")
                                Spacer()
                            }
                        }
                    } else {
                        Text("当前系统暂不支持直接分享导出文件。")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("导出包可能包含 API Key 等敏感配置，请仅分享给可信对象。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("上传备份（POST）") {
                TextField("https://example.com/backup", text: $backupUploadEndpoint.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    uploadDataPackage()
                } label: {
                    HStack {
                        Spacer()
                        if isUploading {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label("上传到地址", systemImage: "icloud.and.arrow.up")
                        Spacer()
                    }
                }
                .disabled(selectedSyncOptions.isEmpty || isUploading)

                if let uploadSuccessMessage, !uploadSuccessMessage.isEmpty {
                    Text(uploadSuccessMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.green)
                }

                if let uploadResponsePreview, !uploadResponsePreview.isEmpty {
                    Text("响应：\(uploadResponsePreview)")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text("会向输入地址发送 POST(JSON)，请确认地址可信。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Watch 同步") {
                Toggle("启动时自动同步", isOn: $autoSyncEnabled)

                Button {
                    syncManager.performSync(options: selectedSyncOptions)
                } label: {
                    HStack {
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                }
                .disabled(selectedSyncOptions.isEmpty || isSyncing)
            }
            
            Section("Apple Watch 状态") {
                syncStatusView
            }

            Section("iCloud 同步") {
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
                                .padding(.trailing, 4)
                        }
                        Label("同步到 iCloud", systemImage: "icloud")
                        Spacer()
                    }
                }
                .disabled(!cloudSyncEnabled || selectedSyncOptions.isEmpty || isCloudSyncing)
            }

            Section("iCloud 状态") {
                cloudSyncStatusView
            }

            Section("启动保护备份") {
                Toggle("启动时创建数据库备份点", isOn: $launchBackupEnabled)

                Text("用于防止 SQLite 数据库损坏。开启后每次启动会额外 dump 一份可恢复备份并落盘，可能占用更多空间；若检测到数据库损坏，会按这份备份自动重建并恢复检索索引。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let exportErrorMessage, !exportErrorMessage.isEmpty {
                Section("导出错误") {
                    Text(exportErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            if let uploadErrorMessage, !uploadErrorMessage.isEmpty {
                Section("上传错误") {
                    Text(uploadErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("同步与备份")
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
        if syncSkills { option.insert(.skills) }
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
            Text("未同步").etFont(.caption).foregroundStyle(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).etFont(.caption)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label("成功", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("失败", systemImage: "xmark.circle")
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
                .etFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch cloudSyncManager.state {
            case .idle:
                Text("未同步")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            case .syncing(let message):
                HStack {
                    ProgressView()
                    Text(message)
                        .etFont(.caption)
                }
            case .success(let summary):
                VStack(alignment: .leading, spacing: 2) {
                    Label("成功", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(summaryDescription(summary))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Label("失败", systemImage: "xmark.circle")
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

    private func exportDataPackage() {
        isExporting = true
        defer { isExporting = false }

        do {
            let package = SyncEngine.buildPackage(options: selectedSyncOptions)
            let output = try SyncPackageTransferService.exportPackage(package)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
            try output.data.write(to: fileURL, options: .atomic)

            if let existing = exportFileURL {
                try? FileManager.default.removeItem(at: existing)
            }

            exportFileURL = fileURL
            exportErrorMessage = nil
        } catch {
            exportErrorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func uploadDataPackage() {
        let trimmed = backupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            uploadErrorMessage = "请先输入上传地址。"
            return
        }
        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            uploadErrorMessage = "上传地址格式无效，请输入完整的 http/https URL。"
            return
        }

        isUploading = true
        uploadErrorMessage = nil
        uploadSuccessMessage = nil
        uploadResponsePreview = nil

        Task {
            do {
                let package = SyncEngine.buildPackage(options: selectedSyncOptions)
                let result = try await SyncPackageUploadService.upload(package: package, to: endpoint)
                await MainActor.run {
                    isUploading = false
                    uploadSuccessMessage = "上传成功（HTTP \(result.statusCode)）"
                    uploadResponsePreview = result.responseBodyPreview
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    uploadErrorMessage = error.localizedDescription
                }
            }
        }
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
