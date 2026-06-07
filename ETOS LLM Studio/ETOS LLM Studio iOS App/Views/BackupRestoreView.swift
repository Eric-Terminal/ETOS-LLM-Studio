// ============================================================================
// BackupRestoreView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 手动离线快照导出与恢复入口。
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isCreatingSnapshot = false
    @State private var isImportingSnapshot = false
    @State private var isRestoringSnapshot = false
    @State private var isUploadingSnapshot = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var uploadProgress: SyncPackageUploadProgress?
    @State private var selectedSnapshotKind: SnapshotBuilder.BackupKind = .database
    @State private var encryptExport = false
    @State private var useStrongPasswordDerivation = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirmation = ""
    @State private var restorePassword = ""
    @State private var pendingEncryptedSnapshotURL: URL?
    @State private var pendingSnapshotInspection: SnapshotRestoreService.InspectionResult?
    @State private var isPasswordPromptPresented = false

    private let snapshotContentTypes: [UTType] = {
        var types: [UTType] = [.data]
        if let elsBackupType = UTType(filenameExtension: SnapshotBuilder.fileExtension) {
            types.insert(elsBackupType, at: 0)
        }
        return types
    }()

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("快照类型", comment: ""), selection: $selectedSnapshotKind) {
                    Text(NSLocalizedString("数据库快照", comment: ""))
                        .tag(SnapshotBuilder.BackupKind.database)
                    Text(NSLocalizedString("完整快照", comment: ""))
                        .tag(SnapshotBuilder.BackupKind.full)
                }
                .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)

                Button {
                    createManualSnapshot()
                } label: {
                    HStack {
                        Spacer()
                        if isCreatingSnapshot {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("创建 iCloud Drive 快照", comment: ""), systemImage: "icloud.and.arrow.up")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)

                Toggle(NSLocalizedString("设置密码", comment: ""), isOn: $encryptExport)
                    .buttonStyle(.plain)
                    .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)

                if encryptExport {
                    Toggle(NSLocalizedString("高强度派生", comment: ""), isOn: $useStrongPasswordDerivation)
                        .buttonStyle(.plain)
                        .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)
                    SecureField(NSLocalizedString("密码", comment: ""), text: $exportPassword)
                        .textContentType(.newPassword)
                    SecureField(NSLocalizedString("确认密码", comment: ""), text: $exportPasswordConfirmation)
                        .textContentType(.newPassword)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("手动快照", comment: ""))
            } footer: {
                Text(snapshotKindFooter + "\n" + NSLocalizedString("快照会写入 iCloud Drive 的“ETOS LLM Studio Backups”文件夹；若未开启 iCloud Documents 能力，系统会改写入本机 Documents 同名文件夹。高强度派生会使用 PBKDF2-HMAC-SHA512 迭代 256000 次。", comment: ""))
            }

            Section {
                TextField(NSLocalizedString("https://<account>.r2.cloudflarestorage.com", comment: ""), text: $appConfig.syncBackupUploadEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField(NSLocalizedString("auto 或 us-east-1", comment: ""), text: $appConfig.syncBackupS3Region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(NSLocalizedString("存储桶名称", comment: ""), text: $appConfig.syncBackupS3Bucket)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(NSLocalizedString("备份路径前缀（可选）", comment: ""), text: $appConfig.syncBackupS3KeyPrefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(NSLocalizedString("Access Key ID", comment: ""), text: $appConfig.syncBackupS3AccessKeyID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField(NSLocalizedString("Secret Access Key", comment: ""), text: $appConfig.syncBackupS3SecretAccessKey)
                    .textContentType(.password)

                SecureField(NSLocalizedString("Session Token（可选）", comment: ""), text: $appConfig.syncBackupS3SessionToken)
                    .textContentType(.password)

                Button {
                    createAndUploadSnapshot()
                } label: {
                    HStack {
                        Spacer()
                        if isUploadingSnapshot {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("上传到 S3/R2", comment: ""), systemImage: "tray.and.arrow.up")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)

                if let uploadProgress {
                    SnapshotUploadProgressView(progress: uploadProgress)
                }
            } header: {
                Text(NSLocalizedString("S3 兼容对象存储", comment: ""))
            } footer: {
                Text(snapshotKindFooter + "\n" + NSLocalizedString("会使用 AWS Signature V4 生成签名请求，将 .elsbackup 以 PUT 上传到 bucket/prefix/文件名。R2 的 Region 通常填写 auto，AWS S3 请填写实际区域。", comment: ""))
            }

            Section {
                Button(role: .destructive) {
                    isImportingSnapshot = true
                } label: {
                    HStack {
                        Spacer()
                        if isRestoringSnapshot {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("从快照恢复", comment: ""), systemImage: "arrow.counterclockwise.icloud")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)
            } header: {
                Text(NSLocalizedString("恢复", comment: ""))
            } footer: {
                Text(NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库；完整快照还会恢复壁纸、附件、字体与记忆向量索引文件。请选择可信的 .elsbackup 文件。", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("快照备份", comment: ""))
        .fileImporter(
            isPresented: $isImportingSnapshot,
            allowedContentTypes: snapshotContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleSnapshotImport(result)
        }
        .alert(NSLocalizedString("快照操作失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
        .alert(NSLocalizedString("输入快照密码", comment: ""), isPresented: $isPasswordPromptPresented) {
            SecureField(NSLocalizedString("密码", comment: ""), text: $restorePassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                pendingEncryptedSnapshotURL = nil
                pendingSnapshotInspection = nil
                restorePassword = ""
            }
            Button(NSLocalizedString("恢复", comment: "")) {
                guard let pendingEncryptedSnapshotURL else { return }
                restoreSnapshot(from: pendingEncryptedSnapshotURL, password: restorePassword)
                self.pendingEncryptedSnapshotURL = nil
                pendingSnapshotInspection = nil
                restorePassword = ""
            }
            .disabled(restorePassword.isEmpty)
        } message: {
            Text(passwordPromptMessage)
        }
    }

    private var snapshotKindFooter: String {
        switch selectedSnapshotKind {
        case .database:
            return NSLocalizedString("数据库快照只包含聊天、配置与记忆数据库，会排除壁纸、附件、字体与记忆向量索引，适合日常轻量备份。", comment: "")
        case .full:
            return NSLocalizedString("完整快照会额外包含壁纸、音频附件、图片附件、文件附件、自定义字体与记忆向量索引，体积可能明显增大。", comment: "")
        }
    }

    private func createManualSnapshot() {
        guard validateExportPasswordIfNeeded() else { return }
        isCreatingSnapshot = true
        statusMessage = nil
        errorMessage = nil
        let password = encryptExport ? exportPassword : nil
        let useStrongPasswordDerivation = useStrongPasswordDerivation
        let snapshotKind = selectedSnapshotKind

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
                let snapshotURL = try SnapshotBuilder.buildSnapshot(kind: snapshotKind)
                if let password {
                    try BackupRestoreFileWriter.encryptSnapshotInPlace(
                        snapshotURL,
                        password: password,
                        useStrongDerivation: useStrongPasswordDerivation
                    )
                }
                let destinationURL = try BackupRestoreFileWriter.exportSnapshotToDocuments(snapshotURL)
                try? FileManager.default.removeItem(at: snapshotURL)
                await MainActor.run {
                    if password != nil {
                        exportPassword = ""
                        exportPasswordConfirmation = ""
                    }
                    isCreatingSnapshot = false
                    statusMessage = String(
                        format: NSLocalizedString("快照已保存到：%@", comment: ""),
                        destinationURL.path
                    )
                }
            } catch {
                await MainActor.run {
                    isCreatingSnapshot = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func validateExportPasswordIfNeeded() -> Bool {
        guard encryptExport else { return true }
        guard !exportPassword.isEmpty else {
            errorMessage = NSLocalizedString("请输入快照密码。", comment: "")
            return false
        }
        guard exportPassword == exportPasswordConfirmation else {
            errorMessage = NSLocalizedString("两次输入的快照密码不一致。", comment: "")
            return false
        }
        return true
    }

    private func s3UploadConfiguration() -> S3CompatibleUploadConfiguration? {
        let trimmed = appConfig.syncBackupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = NSLocalizedString("请先输入对象存储 Endpoint。", comment: "")
            return nil
        }
        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = NSLocalizedString("对象存储 Endpoint 必须是完整的 http/https URL。", comment: "")
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

    private func createAndUploadSnapshot() {
        guard validateExportPasswordIfNeeded(),
              let uploadConfiguration = s3UploadConfiguration() else { return }

        isUploadingSnapshot = true
        statusMessage = nil
        errorMessage = nil
        uploadProgress = nil
        let password = encryptExport ? exportPassword : nil
        let useStrongPasswordDerivation = useStrongPasswordDerivation
        let snapshotKind = selectedSnapshotKind

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()

                let snapshotURL = try SnapshotBuilder.buildSnapshot(kind: snapshotKind)
                defer { try? FileManager.default.removeItem(at: snapshotURL) }
                if let password {
                    try BackupRestoreFileWriter.encryptSnapshotInPlace(
                        snapshotURL,
                        password: password,
                        useStrongDerivation: useStrongPasswordDerivation
                    )
                }

                let result = try await SyncPackageUploadService.uploadSnapshot(
                    fileURL: snapshotURL,
                    s3: uploadConfiguration,
                    progress: { progress in
                        Task { @MainActor in
                            uploadProgress = progress
                        }
                    }
                )
                await MainActor.run {
                    if password != nil {
                        exportPassword = ""
                        exportPasswordConfirmation = ""
                    }
                    isUploadingSnapshot = false
                    statusMessage = String(
                        format: NSLocalizedString("快照已上传（HTTP %d）。", comment: ""),
                        result.statusCode
                    )
                    if let preview = result.responseBodyPreview, !preview.isEmpty {
                        statusMessage = String(
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
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleSnapshotImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            handleSelectedSnapshot(fileURL)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handleSelectedSnapshot(_ fileURL: URL) {
        do {
            let inspection = try SnapshotRestoreService.inspectSnapshot(at: fileURL)
            if inspection.requiresPassword {
                pendingEncryptedSnapshotURL = fileURL
                pendingSnapshotInspection = inspection
                restorePassword = ""
                isPasswordPromptPresented = true
                return
            }
            restoreSnapshot(from: fileURL, password: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var passwordPromptMessage: String {
        switch pendingSnapshotInspection?.encryptionMode {
        case .simplePassword:
            return NSLocalizedString("此快照使用简单密码加密，请输入导出时设置的密码。", comment: "")
        case .pbkdf2Strong:
            return NSLocalizedString("此快照使用高强度派生加密，请输入导出时设置的密码。", comment: "")
        case .none:
            return NSLocalizedString("此快照已加密，请输入导出时设置的密码。", comment: "")
        }
    }

    private func restoreSnapshot(from fileURL: URL, password: String?) {
        isRestoringSnapshot = true
        statusMessage = nil
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            do {
                try SnapshotRestoreService.restoreSnapshot(from: fileURL, password: password)
                await MainActor.run {
                    AppConfigStore.shared.reloadFromPersistentStore()
                    isRestoringSnapshot = false
                    statusMessage = NSLocalizedString("快照已恢复。若当前界面仍显示旧数据，请返回聊天列表后重新进入。", comment: "")
                }
            } catch {
                await MainActor.run {
                    isRestoringSnapshot = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

}

private struct SnapshotUploadProgressView: View {
    let progress: SyncPackageUploadProgress

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("上传进度", comment: ""))
                Spacer()
                Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                    .monospacedDigit()
            }
            .etFont(.footnote)

            ProgressView(value: progress.fractionCompleted)

            Text(progressText)
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        String(
            format: NSLocalizedString("已上传 %@ / %@", comment: ""),
            formatBytes(progress.bytesSent),
            formatBytes(progress.totalBytes)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        StorageUtility.formatSize(bytes)
    }
}

private enum BackupRestoreFileWriter {
    nonisolated static func encryptSnapshotInPlace(
        _ snapshotURL: URL,
        password: String,
        useStrongDerivation: Bool
    ) throws {
        let plainData = try Data(contentsOf: snapshotURL)
        let encryptedData: Data
        if useStrongDerivation {
            encryptedData = try SnapshotEncryptor.encryptStrongPassword(data: plainData, password: password)
        } else {
            encryptedData = try SnapshotEncryptor.encryptSimplePassword(data: plainData, password: password)
        }
        try encryptedData.write(to: snapshotURL, options: .atomic)
    }

    nonisolated static func exportSnapshotToDocuments(_ snapshotURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let containerDirectory = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDirectory = containerDirectory.appendingPathComponent("ETOS LLM Studio Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var destinationURL = backupDirectory.appendingPathComponent(snapshotURL.lastPathComponent, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = backupDirectory
                .appendingPathComponent("ETOS-Snapshot-\(UUID().uuidString)", isDirectory: false)
                .appendingPathExtension(SnapshotBuilder.fileExtension)
        }

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destinationURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                if fileManager.fileExists(atPath: coordinatedURL.path) {
                    try fileManager.removeItem(at: coordinatedURL)
                }
                try fileManager.copyItem(at: snapshotURL, to: coordinatedURL)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
        return destinationURL
    }
}
