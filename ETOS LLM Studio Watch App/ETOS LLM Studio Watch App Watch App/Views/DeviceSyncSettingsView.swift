import SwiftUI
import Shared

struct DeviceSyncSettingsView: View {
    @EnvironmentObject private var syncManager: WatchSyncManager
    @AppStorage("sync.options.providers") private var syncProviders = true
    @AppStorage("sync.options.sessions") private var syncSessions = true
    @AppStorage("sync.options.backgrounds") private var syncBackgrounds = true
    @AppStorage("sync.options.memories") private var syncMemories = false
    @AppStorage("sync.options.mcpServers") private var syncMCPServers = true
    
    var body: some View {
        List {
            Section("同步内容") {
                Toggle("同步提供商", isOn: $syncProviders)
                Toggle("同步会话", isOn: $syncSessions)
                Toggle("同步背景", isOn: $syncBackgrounds)
                Toggle("同步记忆（仅文本）", isOn: $syncMemories)
                Toggle("同步 MCP 服务器", isOn: $syncMCPServers)
            }
            
            Section("同步操作") {
                Button {
                    syncManager.performSync(direction: .pull, options: selectedSyncOptions)
                } label: {
                    Label("从手机同步", systemImage: "arrow.down.backward")
                }
                .disabled(selectedSyncOptions.isEmpty || isSyncing)
                
                Button {
                    syncManager.performSync(direction: .push, options: selectedSyncOptions)
                } label: {
                    Label("推送到手机", systemImage: "arrow.up.forward")
                }
                .disabled(selectedSyncOptions.isEmpty || isSyncing)
            }
            
            Section("同步状态") {
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
                Label("同步成功", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步失败", systemImage: "xmark.circle")
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
            parts.append("提供商 +\(summary.importedProviders)")
        }
        if summary.importedSessions > 0 {
            parts.append("会话 +\(summary.importedSessions)")
        }
        if summary.importedBackgrounds > 0 {
            parts.append("背景 +\(summary.importedBackgrounds)")
        }
        if summary.importedMemories > 0 {
            parts.append("记忆 +\(summary.importedMemories)")
        }
        if summary.importedMCPServers > 0 {
            parts.append("MCP +\(summary.importedMCPServers)")
        }
        return parts.isEmpty ? "两端数据一致" : parts.joined(separator: "，")
    }
}
