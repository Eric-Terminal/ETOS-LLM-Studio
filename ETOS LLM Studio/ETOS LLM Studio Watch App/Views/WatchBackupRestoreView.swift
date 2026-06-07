// ============================================================================
// WatchBackupRestoreView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 端手动数据库快照导出、上传与安全恢复入口。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct WatchBackupRestoreView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var snapshotFileURL: URL?
    @State private var snapshotStatusMessage: String?
    @State private var snapshotErrorMessage: String?
    @State private var isCreatingSnapshot = false
    @State private var isUploadingSnapshot = false
    @State private var uploadProgress: SyncPackageUploadProgress?
    @State private var selectedSnapshotKind: SnapshotBuilder.BackupKind = .database
    @State private var encryptSnapshot = false
    @State private var useStrongSnapshotPasswordDerivation = false
    @State private var snapshotPassword = ""
    @State private var snapshotPasswordConfirmation = ""
    @State private var snapshotRestoreDownloadURL = ""
    @State private var isRestoringSnapshot = false
    @State private var restoreDownloadProgress: SyncPackageDownloadProgress?
    @State private var restorePassword = ""
    @State private var pendingEncryptedSnapshotURL: URL?
    @State private var pendingSnapshotInspection: SnapshotRestoreService.InspectionResult?
    @State private var isSnapshotIntroPresented = false
    @State private var isSnapshotDestinationDialogPresented = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "快照备份",
                    summary: "先了解快照类型、保存位置、上传方式和恢复风险，再执行下面的操作。",
                    details: snapshotIntroDetails,
                    isExpanded: $isSnapshotIntroPresented
                )
            }

            manualSnapshotSection
            snapshotSaveSection
            s3UploadSection
            restoreSection
            statusSection
            errorSection
        }
        .navigationTitle(NSLocalizedString("快照备份", comment: ""))
        .confirmationDialog(
            NSLocalizedString("选择快照保存位置", comment: ""),
            isPresented: $isSnapshotDestinationDialogPresented,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("生成快照文件", comment: "")) {
                createSnapshotFile()
            }
            if appConfig.syncBackupS3Enabled {
                Button(NSLocalizedString("上传到 S3/R2", comment: "")) {
                    uploadSnapshotFile()
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("选择保存位置后再创建快照。", comment: ""))
        }
        .onAppear {
            WatchSnapshotFileWriter.cleanupTemporaryImportFiles()
        }
        .onDisappear {
            cleanupSnapshotFile()
            clearPendingEncryptedSnapshot()
        }
    }

    private var manualSnapshotSection: some View {
        Section {
            Picker(NSLocalizedString("快照类型", comment: ""), selection: $selectedSnapshotKind) {
                Text(NSLocalizedString("数据库快照", comment: ""))
                    .tag(SnapshotBuilder.BackupKind.database)
                Text(NSLocalizedString("完整快照", comment: ""))
                    .tag(SnapshotBuilder.BackupKind.full)
            }
            .disabled(isSnapshotBusy)

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
        } header: {
            Text(NSLocalizedString("手动快照", comment: ""))
        } footer: {
            Text(String(format: NSLocalizedString("当前选择：%@", comment: ""), snapshotKindTitle))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var snapshotSaveSection: some View {
        Section {
            Button {
                isSnapshotDestinationDialogPresented = true
            } label: {
                HStack {
                    Spacer()
                    if isCreatingSnapshot || isUploadingSnapshot {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Label(NSLocalizedString("保存快照", comment: ""), systemImage: "square.and.arrow.up")
                    Spacer()
                }
            }
            .disabled(isSnapshotBusy)

            if let uploadProgress {
                WatchSnapshotUploadProgressView(progress: uploadProgress)
            }

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
        } header: {
            Text(NSLocalizedString("保存", comment: ""))
        } footer: {
            Text(NSLocalizedString("选择保存位置后再创建快照。", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var s3UploadSection: some View {
        Section {
            Toggle(NSLocalizedString("启用 S3/R2 保存", comment: ""), isOn: $appConfig.syncBackupS3Enabled)
                .buttonStyle(.plain)
                .disabled(isSnapshotBusy)

            if appConfig.syncBackupS3Enabled {
                NavigationLink {
                    WatchS3CompatibleSnapshotStorageSettingsView()
                } label: {
                    Label(NSLocalizedString("S3/R2 保存设置", comment: ""), systemImage: "shippingbox")
                }
                .disabled(isSnapshotBusy)
            }
        } header: {
            Text(NSLocalizedString("S3 兼容对象存储", comment: ""))
        } footer: {
            Text(appConfig.syncBackupS3Enabled
                 ? NSLocalizedString("打开后可配置对象存储，并将快照上传到自己的 S3/R2 存储桶。", comment: "")
                 : NSLocalizedString("关闭后不会显示 S3/R2 配置与上传入口。", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var restoreSection: some View {
        Section {
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

            if let restoreDownloadProgress {
                WatchSnapshotDownloadProgressView(progress: restoreDownloadProgress)
            }

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
        } header: {
            Text(NSLocalizedString("恢复", comment: ""))
        } footer: {
            Text(NSLocalizedString("恢复前请确认快照来源可信。", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let snapshotStatusMessage, !snapshotStatusMessage.isEmpty {
            Section(NSLocalizedString("状态", comment: "")) {
                Text(snapshotStatusMessage)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let snapshotErrorMessage, !snapshotErrorMessage.isEmpty {
            Section(NSLocalizedString("快照操作失败", comment: "")) {
                Text(snapshotErrorMessage)
                    .etFont(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isSnapshotBusy: Bool {
        isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot
    }

    private var snapshotKindFooter: String {
        switch selectedSnapshotKind {
        case .database:
            return NSLocalizedString("数据库快照只包含聊天、配置与记忆数据库，会排除壁纸、附件、字体与记忆向量索引，适合日常轻量备份。", comment: "")
        case .full:
            return NSLocalizedString("完整快照会额外包含壁纸、音频附件、图片附件、文件附件、自定义字体与记忆向量索引，体积可能明显增大。", comment: "")
        }
    }

    private var snapshotKindTitle: String {
        switch selectedSnapshotKind {
        case .database:
            return NSLocalizedString("数据库快照", comment: "")
        case .full:
            return NSLocalizedString("完整快照", comment: "")
        }
    }

    private var snapshotIntroDetails: String {
        [
            snapshotKindFooter,
            NSLocalizedString("快照已生成，可通过分享发送到其他设备。", comment: ""),
            NSLocalizedString("会先生成 .elsbackup，再使用 AWS Signature V4 上传到 S3/R2；R2 的 Region 通常填写 auto。", comment: ""),
            NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库；完整快照还会恢复壁纸、附件、字体与记忆向量索引文件。请选择可信的 .elsbackup 文件。", comment: "")
        ].joined(separator: "\n\n")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "快照备份介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "快照备份介绍卡片摘要"))
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

    private func createSnapshotFile() {
        guard validateSnapshotPasswordIfNeeded() else { return }

        isCreatingSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil
        let password = encryptSnapshot ? snapshotPassword : nil
        let useStrongDerivation = useStrongSnapshotPasswordDerivation
        let snapshotKind = selectedSnapshotKind

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
                let fileURL = try SnapshotBuilder.buildSnapshot(kind: snapshotKind)
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
        guard let uploadConfiguration = s3UploadConfiguration() else { return }

        isUploadingSnapshot = true
        snapshotErrorMessage = nil
        snapshotStatusMessage = nil
        uploadProgress = nil
        let password = encryptSnapshot ? snapshotPassword : nil
        let useStrongDerivation = useStrongSnapshotPasswordDerivation
        let snapshotKind = selectedSnapshotKind

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()

                let fileURL = try SnapshotBuilder.buildSnapshot(kind: snapshotKind)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                if let password {
                    try WatchSnapshotFileWriter.encryptSnapshotInPlace(
                        fileURL,
                        password: password,
                        useStrongDerivation: useStrongDerivation
                    )
                }

                let result = try await SyncPackageUploadService.uploadSnapshot(
                    fileURL: fileURL,
                    s3: uploadConfiguration,
                    progress: { progress in
                        Task { @MainActor in
                            uploadProgress = progress
                        }
                    }
                )
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
                    uploadProgress = nil
                    snapshotErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func s3UploadConfiguration() -> S3CompatibleUploadConfiguration? {
        let trimmed = appConfig.syncBackupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            snapshotErrorMessage = NSLocalizedString("请先输入对象存储 Endpoint。", comment: "")
            return nil
        }
        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            snapshotErrorMessage = NSLocalizedString("对象存储 Endpoint 必须是完整的 http/https URL。", comment: "")
            return nil
        }
        return S3CompatibleUploadConfiguration(
            endpoint: endpoint,
            region: appConfig.syncBackupS3Region,
            bucket: appConfig.syncBackupS3Bucket,
            keyPrefix: appConfig.syncBackupS3KeyPrefix,
            accessKeyID: appConfig.syncBackupS3AccessKeyID,
            secretAccessKey: appConfig.syncBackupS3SecretAccessKey,
            sessionToken: appConfig.syncBackupS3SessionToken
        )
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
        restoreDownloadProgress = nil
        snapshotErrorMessage = nil
        snapshotStatusMessage = NSLocalizedString("正在下载快照…", comment: "")
        clearPendingEncryptedSnapshot()

        Task.detached(priority: .userInitiated) {
            var stagedSnapshotURL: URL?
            do {
                let stagedURL = try await WatchSnapshotFileWriter.downloadSnapshotForRestore(
                    from: url,
                    progress: { progress in
                        Task { @MainActor in
                            restoreDownloadProgress = progress
                        }
                    }
                )
                stagedSnapshotURL = stagedURL
                let inspection = try SnapshotRestoreService.inspectSnapshot(at: stagedURL)

                await MainActor.run {
                    isRestoringSnapshot = false
                    restoreDownloadProgress = nil
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
                    restoreDownloadProgress = nil
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
        restoreDownloadProgress = nil
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

private struct WatchSnapshotDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("下载进度", comment: ""))
                Spacer()
                if progress.totalBytes > 0 {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .monospacedDigit()
                }
            }
            .etFont(.caption2)

            if progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                Text(progressText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(NSLocalizedString("正在下载快照…", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        String(
            format: NSLocalizedString("已下载 %@ / %@", comment: ""),
            StorageUtility.formatSize(progress.bytesReceived),
            StorageUtility.formatSize(progress.totalBytes)
        )
    }
}

private struct WatchS3CompatibleSnapshotStorageSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section {
                TextField(
                    NSLocalizedString("https://<account>.r2.cloudflarestorage.com", comment: ""),
                    text: $appConfig.syncBackupUploadEndpoint.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    NSLocalizedString("auto 或 us-east-1", comment: ""),
                    text: $appConfig.syncBackupS3Region.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    NSLocalizedString("存储桶名称", comment: ""),
                    text: $appConfig.syncBackupS3Bucket.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    NSLocalizedString("备份路径前缀（可选）", comment: ""),
                    text: $appConfig.syncBackupS3KeyPrefix.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    NSLocalizedString("Access Key ID", comment: ""),
                    text: $appConfig.syncBackupS3AccessKeyID.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                SecureField(
                    NSLocalizedString("Secret Access Key", comment: ""),
                    text: $appConfig.syncBackupS3SecretAccessKey.watchKeyboardNewlineBinding()
                )
                .textContentType(.password)

                SecureField(
                    NSLocalizedString("Session Token（可选）", comment: ""),
                    text: $appConfig.syncBackupS3SessionToken.watchKeyboardNewlineBinding()
                )
                .textContentType(.password)
            } header: {
                Text(NSLocalizedString("对象存储配置", comment: ""))
            } footer: {
                Text(NSLocalizedString("配置用于上传和读取远端快照。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("S3 兼容对象存储", comment: ""))
    }
}

private struct WatchSnapshotUploadProgressView: View {
    let progress: SyncPackageUploadProgress

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("上传进度", comment: ""))
                Spacer()
                Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                    .monospacedDigit()
            }
            .etFont(.caption2)

            ProgressView(value: progress.fractionCompleted)

            Text(progressText)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var progressText: String {
        String(
            format: NSLocalizedString("已上传 %@ / %@", comment: ""),
            StorageUtility.formatSize(progress.bytesSent),
            StorageUtility.formatSize(progress.totalBytes)
        )
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

    nonisolated static func downloadSnapshotForRestore(
        from sourceURL: URL,
        progress: SyncPackageUploadService.DownloadProgressHandler? = nil
    ) async throws -> URL {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
        let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
            request: request,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
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
