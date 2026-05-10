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
    @State private var isCreatingSnapshot = false
    @State private var isImportingSnapshot = false
    @State private var isRestoringSnapshot = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var encryptExport = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirmation = ""
    @State private var restorePassword = ""
    @State private var pendingEncryptedSnapshotURL: URL?
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
                .disabled(isCreatingSnapshot || isRestoringSnapshot)

                Toggle(NSLocalizedString("设置密码", comment: ""), isOn: $encryptExport)
                    .buttonStyle(.plain)
                    .disabled(isCreatingSnapshot || isRestoringSnapshot)

                if encryptExport {
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
                Text(NSLocalizedString("快照会写入 iCloud Drive 的“ETOS LLM Studio Backups”文件夹；若未开启 iCloud Documents 能力，系统会改写入本机 Documents 同名文件夹。设置密码时将使用简单 AES-GCM 加密。", comment: ""))
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
                .disabled(isCreatingSnapshot || isRestoringSnapshot)
            } header: {
                Text(NSLocalizedString("恢复", comment: ""))
            } footer: {
                Text(NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库。请选择可信的 .elsbackup 文件；加密快照将在后续安全恢复流中处理。", comment: ""))
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
                restorePassword = ""
            }
            Button(NSLocalizedString("恢复", comment: "")) {
                guard let pendingEncryptedSnapshotURL else { return }
                restoreSnapshot(from: pendingEncryptedSnapshotURL, password: restorePassword)
                self.pendingEncryptedSnapshotURL = nil
                restorePassword = ""
            }
            .disabled(restorePassword.isEmpty)
        } message: {
            Text(NSLocalizedString("此快照已加密，请输入导出时设置的密码。", comment: ""))
        }
    }

    private func createManualSnapshot() {
        guard validateExportPasswordIfNeeded() else { return }
        isCreatingSnapshot = true
        statusMessage = nil
        errorMessage = nil
        let password = encryptExport ? exportPassword : nil

        Task.detached(priority: .userInitiated) {
            do {
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                let snapshotURL = try SnapshotBuilder.buildSnapshot()
                if let password {
                    try Self.encryptSnapshotInPlace(snapshotURL, password: password)
                }
                let destinationURL = try Self.exportSnapshotToDocuments(snapshotURL)
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
            if try Self.snapshotIsEncrypted(fileURL) {
                pendingEncryptedSnapshotURL = fileURL
                restorePassword = ""
                isPasswordPromptPresented = true
                return
            }
            restoreSnapshot(from: fileURL, password: nil)
        } catch {
            errorMessage = error.localizedDescription
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

    private static func encryptSnapshotInPlace(_ snapshotURL: URL, password: String) throws {
        let plainData = try Data(contentsOf: snapshotURL)
        let encryptedData = try SnapshotEncryptor.encryptSimplePassword(data: plainData, password: password)
        try encryptedData.write(to: snapshotURL, options: .atomic)
    }

    private static func snapshotIsEncrypted(_ snapshotURL: URL) throws -> Bool {
        let shouldStopAccess = snapshotURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccess {
                snapshotURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: snapshotURL, options: .mappedIfSafe)
        return try SnapshotEncryptor.encryptedMode(for: data) != nil
    }

    private static func exportSnapshotToDocuments(_ snapshotURL: URL) throws -> URL {
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
