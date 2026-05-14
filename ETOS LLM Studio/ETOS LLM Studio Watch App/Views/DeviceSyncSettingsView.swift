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
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var snapshotFileURL: URL?
    @State private var snapshotStatusMessage: String?
    @State private var snapshotErrorMessage: String?
    @State private var isCreatingSnapshot: Bool = false
    @State private var isUploadingSnapshot: Bool = false
    @State private var encryptSnapshot: Bool = false
    @State private var useStrongSnapshotPasswordDerivation: Bool = false
    @State private var snapshotPassword: String = ""
    @State private var snapshotPasswordConfirmation: String = ""
    @State private var snapshotRestoreDownloadURL: String = ""
    @State private var isRestoringSnapshot: Bool = false
    @State private var restorePassword: String = ""
    @State private var pendingEncryptedSnapshotURL: URL?
    @State private var pendingSnapshotInspection: SnapshotRestoreService.InspectionResult?
    
    var body: some View {
        List {
            Section(NSLocalizedString("数据库快照", comment: "")) {
                Toggle(NSLocalizedString("设置密码", comment: ""), isOn: $encryptSnapshot)
                    .buttonStyle(.plain)
                    .disabled(isSnapshotBusy)

                if encryptSnapshot {
                    Toggle(NSLocalizedString("高强度派生", comment: ""), isOn: $useStrongSnapshotPasswordDerivation)
                        .buttonStyle(.plain)
                        .disabled(isSnapshotBusy)
                    SecureField(NSLocalizedString("密码", comment: ""), text: $snapshotPassword.watchKeyboardNewlineBinding())
                        .textContentType(.newPassword)
                    SecureField(NSLocalizedString("确认密码", comment: ""), text: $snapshotPasswordConfirmation.watchKeyboardNewlineBinding())
                        .textContentType(.newPassword)
                }

                Button {
                    createSnapshotFile()
                } label: {
                    HStack {
                        Spacer()
                        if isCreatingSnapshot {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("生成快照文件", comment: ""), systemImage: "externaldrive.badge.icloud")
                        Spacer()
                    }
                }
                .disabled(isSnapshotBusy)

                if let snapshotFileURL {
                    if #available(watchOS 9.0, *) {
                        ShareLink(item: snapshotFileURL) {
                            HStack {
                                Spacer()
                                Label(NSLocalizedString("分享快照文件", comment: ""), systemImage: "square.and.arrow.up")
                                Spacer()
                            }
                        }
                    } else {
                        Text(NSLocalizedString("当前系统暂不支持直接分享导出文件。", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    uploadSnapshotFile()
                } label: {
                    HStack {
                        Spacer()
                        if isUploadingSnapshot {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("上传到自定义地址", comment: ""), systemImage: "tray.and.arrow.up")
                        Spacer()
                    }
                }
                .disabled(isSnapshotBusy)

                Text(NSLocalizedString("会先生成 .elsbackup，再以 HTTP POST 上传到已配置的自定义地址；这不是 iCloud 同步。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                TextField(
                    NSLocalizedString("https://example.com/backup.elsbackup", comment: ""),
                    text: $snapshotRestoreDownloadURL.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button(role: .destructive) {
                    downloadSnapshotForRestore()
                } label: {
                    HStack {
                        Spacer()
                        if isRestoringSnapshot {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("从 URL 下载并恢复", comment: ""), systemImage: "arrow.down.doc")
                        Spacer()
                    }
                }
                .disabled(isSnapshotBusy || snapshotRestoreDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if pendingEncryptedSnapshotURL != nil {
                    Text(snapshotPasswordPromptMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    SecureField(NSLocalizedString("密码", comment: ""), text: $restorePassword.watchKeyboardNewlineBinding())
                        .textContentType(.password)

                    Button(role: .destructive) {
                        restorePendingEncryptedSnapshot()
                    } label: {
                        HStack {
                            Spacer()
                            Label(NSLocalizedString("恢复", comment: ""), systemImage: "arrow.counterclockwise")
                            Spacer()
                        }
                    }
                    .disabled(restorePassword.isEmpty || isSnapshotBusy)

                    Button(NSLocalizedString("取消", comment: "")) {
                        clearPendingEncryptedSnapshot()
                    }
                    .disabled(isSnapshotBusy)
                }

                if let snapshotStatusMessage, !snapshotStatusMessage.isEmpty {
                    Text(snapshotStatusMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(NSLocalizedString("快照会包含聊天、配置与记忆数据库，不包含 memory_vectors.sqlite；加密快照需要在恢复时输入这里设置的密码。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库。请选择可信的 .elsbackup 文件；加密快照会先要求输入密码，解密与校验成功后才会替换本机数据。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("Apple Watch 同步", comment: "")) {
                Toggle(NSLocalizedString("启用 Apple Watch 同步", comment: ""), isOn: $appConfig.syncAutoSyncEnabled)

                Button {
                    syncManager.performSync(options: .fullSync)
                } label: {
                    HStack {
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Label(NSLocalizedString("同步", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                }
                .disabled(!appConfig.syncAutoSyncEnabled || isSyncing)
            }
            
            Section(NSLocalizedString("Apple Watch 状态", comment: "")) {
                syncStatusView
            }

            Section(NSLocalizedString("iCloud 同步", comment: "")) {
                Toggle(NSLocalizedString("启用 iCloud 同步", comment: ""), isOn: $appConfig.cloudSyncEnabled)

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
                        Label(NSLocalizedString("同步到 iCloud", comment: ""), systemImage: "icloud")
                        Spacer()
                    }
                }
                .disabled(!appConfig.cloudSyncEnabled || isCloudSyncing)

                Text(NSLocalizedString("用于同一 Apple ID 下多台设备间漫游数据。只有一台设备使用本应用时可以保持关闭；开启后会上传本机快照并合并其他设备快照，提供商 API Key 也会在您的设备间同步。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("iCloud 状态", comment: "")) {
                cloudSyncStatusView
            }

            Section(NSLocalizedString("启动保护备份", comment: "")) {
                Toggle(NSLocalizedString("启动时创建数据库备份点", comment: ""), isOn: $appConfig.syncBackupCreateOnLaunch)

                Text(NSLocalizedString("用于防止 SQLite 数据库损坏。开启后每次启动会额外 dump 一份可恢复备份并落盘，可能占用更多空间；若检测到数据库损坏，会按这份备份自动重建并恢复检索索引。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let snapshotErrorMessage, !snapshotErrorMessage.isEmpty {
                Section(NSLocalizedString("快照操作失败", comment: "")) {
                    Text(snapshotErrorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("同步与备份", comment: ""))
        .onAppear {
            WatchSnapshotFileWriter.cleanupTemporaryImportFiles()
        }
        .onDisappear {
            cleanupSnapshotFile()
            clearPendingEncryptedSnapshot()
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

    private var isSnapshotBusy: Bool {
        isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot
    }
    
    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.state {
        case .idle:
            Text(NSLocalizedString("未同步", comment: "")).etFont(.caption).foregroundStyle(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).etFont(.caption)
            }
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

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        if !appConfig.cloudSyncEnabled {
            Text(NSLocalizedString("iCloud 同步已关闭", comment: ""))
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

    private func createSnapshotFile() {
        guard validateSnapshotPasswordIfNeeded() else { return }

        isCreatingSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil
        let password = encryptSnapshot ? snapshotPassword : nil
        let useStrongDerivation = useStrongSnapshotPasswordDerivation

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                let fileURL = try SnapshotBuilder.buildSnapshot()
                if let password {
                    try WatchSnapshotFileWriter.encryptSnapshotInPlace(
                        fileURL,
                        password: password,
                        useStrongDerivation: useStrongDerivation
                    )
                }

                await MainActor.run {
                    if let existing = snapshotFileURL {
                        try? FileManager.default.removeItem(at: existing)
                    }
                    snapshotFileURL = fileURL
                    if password != nil {
                        snapshotPassword = ""
                        snapshotPasswordConfirmation = ""
                    }
                    isCreatingSnapshot = false
                    snapshotStatusMessage = NSLocalizedString("快照已生成，可通过分享发送到其他设备。", comment: "")
                }
            } catch {
                await MainActor.run {
                    isCreatingSnapshot = false
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func uploadSnapshotFile() {
        guard validateSnapshotPasswordIfNeeded() else { return }
        let trimmed = appConfig.syncBackupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            snapshotErrorMessage = NSLocalizedString("请先输入自定义上传地址。", comment: "")
            return
        }
        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            snapshotErrorMessage = NSLocalizedString("自定义上传地址格式无效，请输入完整的 http/https URL。", comment: "")
            return
        }

        isUploadingSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil
        let password = encryptSnapshot ? snapshotPassword : nil
        let useStrongDerivation = useStrongSnapshotPasswordDerivation
        let endpointString = endpoint.absoluteString

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                guard let endpoint = URL(string: endpointString) else {
                    await MainActor.run {
                        isUploadingSnapshot = false
                        snapshotErrorMessage = NSLocalizedString("自定义上传地址格式无效，请输入完整的 http/https URL。", comment: "")
                    }
                    return
                }

                let fileURL = try SnapshotBuilder.buildSnapshot()
                defer { try? FileManager.default.removeItem(at: fileURL) }
                if let password {
                    try WatchSnapshotFileWriter.encryptSnapshotInPlace(
                        fileURL,
                        password: password,
                        useStrongDerivation: useStrongDerivation
                    )
                }

                let result = try await SyncPackageUploadService.uploadSnapshot(fileURL: fileURL, to: endpoint)
                await MainActor.run {
                    if password != nil {
                        snapshotPassword = ""
                        snapshotPasswordConfirmation = ""
                    }
                    isUploadingSnapshot = false
                    snapshotStatusMessage = String(format: NSLocalizedString("快照已上传（HTTP %d）。", comment: ""), result.statusCode)
                    if let preview = result.responseBodyPreview, !preview.isEmpty {
                        snapshotStatusMessage = String(
                            format: NSLocalizedString("快照已上传（HTTP %d）：%@", comment: ""),
                            result.statusCode,
                            preview
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isUploadingSnapshot = false
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func downloadSnapshotForRestore() {
        let trimmed = snapshotRestoreDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            snapshotErrorMessage = NSLocalizedString("快照下载 URL 无效，请输入完整的 http/https URL。", comment: "")
            return
        }

        isRestoringSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = NSLocalizedString("正在下载快照…", comment: "")
        clearPendingEncryptedSnapshot()

        Task.detached(priority: .userInitiated) {
            var stagedSnapshotURL: URL?
            do {
                let stagedURL = try await WatchSnapshotFileWriter.downloadSnapshotForRestore(from: url)
                stagedSnapshotURL = stagedURL
                let inspection = try SnapshotRestoreService.inspectSnapshot(at: stagedURL)

                await MainActor.run {
                    isRestoringSnapshot = false
                    if inspection.requiresPassword {
                        pendingEncryptedSnapshotURL = stagedURL
                        pendingSnapshotInspection = inspection
                        restorePassword = ""
                        snapshotStatusMessage = NSLocalizedString("请输入快照密码后恢复。", comment: "")
                    } else {
                        restoreSnapshot(from: stagedURL, password: nil, removeWhenFinished: true)
                    }
                }
            } catch {
                if let stagedSnapshotURL {
                    try? FileManager.default.removeItem(at: stagedSnapshotURL)
                }
                await MainActor.run {
                    isRestoringSnapshot = false
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepareSnapshotRestore(from fileURL: URL) {
        isRestoringSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil
        clearPendingEncryptedSnapshot()

        Task.detached(priority: .userInitiated) {
            var stagedSnapshotURL: URL?
            do {
                let stagedURL = try WatchSnapshotFileWriter.stageSnapshotForRestore(fileURL)
                stagedSnapshotURL = stagedURL
                let inspection = try SnapshotRestoreService.inspectSnapshot(at: stagedURL)

                await MainActor.run {
                    isRestoringSnapshot = false
                    if inspection.requiresPassword {
                        pendingEncryptedSnapshotURL = stagedURL
                        pendingSnapshotInspection = inspection
                        restorePassword = ""
                        snapshotStatusMessage = NSLocalizedString("请输入快照密码后恢复。", comment: "")
                    } else {
                        restoreSnapshot(from: stagedURL, password: nil, removeWhenFinished: true)
                    }
                }
            } catch {
                if let stagedSnapshotURL {
                    try? FileManager.default.removeItem(at: stagedSnapshotURL)
                }
                await MainActor.run {
                    isRestoringSnapshot = false
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func restorePendingEncryptedSnapshot() {
        guard let pendingEncryptedSnapshotURL else { return }
        let password = restorePassword
        self.pendingEncryptedSnapshotURL = nil
        pendingSnapshotInspection = nil
        restorePassword = ""
        restoreSnapshot(from: pendingEncryptedSnapshotURL, password: password, removeWhenFinished: true)
    }

    private func restoreSnapshot(
        from fileURL: URL,
        password: String?,
        removeWhenFinished: Bool
    ) {
        isRestoringSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil

        Task.detached(priority: .userInitiated) {
            defer {
                if removeWhenFinished {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }

            do {
                try SnapshotRestoreService.restoreSnapshot(from: fileURL, password: password)
                await MainActor.run {
                    AppConfigStore.shared.reloadFromPersistentStore()
                    isRestoringSnapshot = false
                    snapshotStatusMessage = NSLocalizedString("快照已恢复。若当前界面仍显示旧数据，请返回聊天列表后重新进入。", comment: "")
                }
            } catch {
                await MainActor.run {
                    isRestoringSnapshot = false
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private var snapshotPasswordPromptMessage: String {
        switch pendingSnapshotInspection?.encryptionMode {
        case .simplePassword:
            return NSLocalizedString("此快照使用简单密码加密，请输入导出时设置的密码。", comment: "")
        case .pbkdf2Strong:
            return NSLocalizedString("此快照使用高强度派生加密，请输入导出时设置的密码。", comment: "")
        case .none:
            return NSLocalizedString("此快照已加密，请输入导出时设置的密码。", comment: "")
        }
    }

    private func validateSnapshotPasswordIfNeeded() -> Bool {
        guard encryptSnapshot else { return true }
        guard !snapshotPassword.isEmpty else {
            snapshotErrorMessage = NSLocalizedString("请输入快照密码。", comment: "")
            return false
        }
        guard snapshotPassword == snapshotPasswordConfirmation else {
            snapshotErrorMessage = NSLocalizedString("两次输入的快照密码不一致。", comment: "")
            return false
        }
        return true
    }

    private func cleanupSnapshotFile() {
        guard let fileURL = snapshotFileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        snapshotFileURL = nil
    }

    private func clearPendingEncryptedSnapshot() {
        if let pendingEncryptedSnapshotURL {
            try? FileManager.default.removeItem(at: pendingEncryptedSnapshotURL)
        }
        pendingEncryptedSnapshotURL = nil
        pendingSnapshotInspection = nil
        restorePassword = ""
    }
}

private enum WatchSnapshotFileWriter {
    nonisolated static func encryptSnapshotInPlace(
        _ snapshotURL: URL,
        password: String,
        useStrongDerivation: Bool
    ) throws {
        let plainData = try Data(contentsOf: snapshotURL)
        let encryptedData = useStrongDerivation
            ? try SnapshotEncryptor.encryptStrongPassword(data: plainData, password: password)
            : try SnapshotEncryptor.encryptSimplePassword(data: plainData, password: password)
        try encryptedData.write(to: snapshotURL, options: .atomic)
    }

    nonisolated static func stageSnapshotForRestore(_ sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let importDirectory = temporaryImportDirectory
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let destinationURL = importDirectory
            .appendingPathComponent("ETOS-Snapshot-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(SnapshotBuilder.fileExtension)

        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    nonisolated static func downloadSnapshotForRestore(from sourceURL: URL) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: sourceURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw NSError(domain: "ETOSWatchSnapshotRestore", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: NSLocalizedString("下载快照失败（HTTP %d）。", comment: ""),
                    httpResponse.statusCode
                )
            ])
        }
        return try stageSnapshotForRestore(downloadedURL)
    }

    nonisolated static func cleanupTemporaryImportFiles() {
        try? FileManager.default.removeItem(at: temporaryImportDirectory)
    }

    private nonisolated static var temporaryImportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ETOSWatchSnapshotImports", isDirectory: true)
    }
}
