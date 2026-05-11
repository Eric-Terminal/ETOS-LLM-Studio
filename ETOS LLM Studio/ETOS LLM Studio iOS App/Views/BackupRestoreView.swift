// ============================================================================
// BackupRestoreView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 手动离线快照导出与恢复入口。
// ============================================================================

import Foundation
import Shared
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
                Text(NSLocalizedString("快照会写入 iCloud Drive 的“ETOS LLM Studio Backups”文件夹；若未开启 iCloud Documents 能力，系统会改写入本机 Documents 同名文件夹。高强度派生会使用 PBKDF2-HMAC-SHA512 迭代 256000 次。", comment: ""))
            }

            Section {
                TextField(NSLocalizedString("https://example.com/backup", comment: ""), text: $appConfig.syncBackupUploadEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button {
                    createAndUploadSnapshot()
                } label: {
                    HStack {
                        Spacer()
                        if isUploadingSnapshot {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("创建并上传快照", comment: ""), systemImage: "externaldrive.badge.icloud")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(isCreatingSnapshot || isUploadingSnapshot || isRestoringSnapshot)
            } header: {
                Text(NSLocalizedString("上传快照", comment: ""))
            } footer: {
                Text(NSLocalizedString("会使用上方密码设置生成 .elsbackup，并以二进制 POST 上传到自定义端点。请仅使用可信的 R2 或自有服务器地址。", comment: ""))
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
                Text(NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库。请选择可信的 .elsbackup 文件；加密快照会先要求输入密码，解密与校验成功后才会替换本机数据。", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("数据库快照", comment: ""))
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

    private func createManualSnapshot() {
        guard validateExportPasswordIfNeeded() else { return }
        isCreatingSnapshot = true
        statusMessage = nil
        errorMessage = nil
        let password = encryptExport ? exportPassword : nil
        let useStrongPasswordDerivation = useStrongPasswordDerivation

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                let snapshotURL = try SnapshotBuilder.buildSnapshot()
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

    private func validatedUploadEndpoint() -> URL? {
        let trimmed = appConfig.syncBackupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = NSLocalizedString("请先输入上传地址。", comment: "")
            return nil
        }
        guard let endpoint = URL(string: trimmed),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = NSLocalizedString("上传地址格式无效，请输入完整的 http/https URL。", comment: "")
            return nil
        }
        return endpoint
    }

    private func createAndUploadSnapshot() {
        guard validateExportPasswordIfNeeded(),
              let endpoint = validatedUploadEndpoint() else { return }

        isUploadingSnapshot = true
        statusMessage = nil
        errorMessage = nil
        let password = encryptExport ? exportPassword : nil
        let useStrongPasswordDerivation = useStrongPasswordDerivation
        let endpointString = endpoint.absoluteString

        Task.detached(priority: .userInitiated) {
            do {
                await AppConfigStore.shared.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                guard let endpoint = URL(string: endpointString) else {
                    throw SnapshotUploadError.invalidEndpoint
                }

                let snapshotURL = try SnapshotBuilder.buildSnapshot()
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
                    to: endpoint
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

private enum SnapshotUploadError: LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return NSLocalizedString("上传地址格式无效，请输入完整的 http/https URL。", comment: "")
        }
    }
}
