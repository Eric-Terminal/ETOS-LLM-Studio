import SwiftUI
import Foundation
import Shared

struct DeviceSyncSettingsView: View {
    @EnvironmentObject private var syncManager: WatchSyncManager
    @AppStorage("sync.options.providers") private var syncProviders = true
    @AppStorage("sync.options.sessions") private var syncSessions = true
    @AppStorage("sync.options.backgrounds") private var syncBackgrounds = true
    @AppStorage("sync.options.memories") private var syncMemories = false
    @AppStorage("sync.options.mcpServers") private var syncMCPServers = true
    @AppStorage("sync.options.imageFiles") private var syncImageFiles = true
    @AppStorage(WatchSyncManager.autoSyncEnabledKey) private var autoSyncEnabled = false
    
    var body: some View {
        List {
            Section {
                Toggle("启动时自动同步", isOn: $autoSyncEnabled)
            }
            
            Section("同步内容") {
                Toggle("提供商", isOn: $syncProviders)
                Toggle("会话", isOn: $syncSessions)
                Toggle("背景", isOn: $syncBackgrounds)
                Toggle("记忆", isOn: $syncMemories)
                Toggle("MCP", isOn: $syncMCPServers)
                Toggle("图片", isOn: $syncImageFiles)
            }
            
            Section {
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
            
            Section("状态") {
                syncStatusView
            }
        }
        .navigationTitle("设备同步")
    }
    
    private var selectedSyncOptions: SyncOptions {
        var option: SyncOptions = []
        if syncProviders { option.insert(.providers) }
        if syncSessions { option.insert(.sessions) }
        if syncBackgrounds { option.insert(.backgrounds) }
        if syncMemories { option.insert(.memories) }
        if syncMCPServers { option.insert(.mcpServers) }
        if syncImageFiles { option.insert(.imageFiles) }
        return option
    }
    
    private var isSyncing: Bool {
        if case .syncing = syncManager.state {
            return true
        }
        return false
    }
    
    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.state {
        case .idle:
            Text("未同步").font(.caption).foregroundStyle(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).font(.caption)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label("成功", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("失败", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        @unknown default:
            Text("未知状态")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        let separator = NSLocalizedString("，", comment: "")
        return parts.isEmpty ? NSLocalizedString("两端数据一致", comment: "") : parts.joined(separator: separator)
    }
}
