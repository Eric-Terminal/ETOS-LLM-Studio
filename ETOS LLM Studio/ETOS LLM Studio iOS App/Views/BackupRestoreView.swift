// ============================================================================
// BackupRestoreView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// iCloud Drive 手动快照导出/导入 UI（Plan D2）：
//   - 导出：通过 NSFileCoordinator 写入 iCloud Drive 或系统分享表单
//   - 导入：.fileImporter 选取 .elsbackup，自动检测加密并弹出密码输入
//
// ⚠️ 导出到 iCloud Drive 需在 Xcode Signing & Capabilities → iCloud → Documents
//     中添加对应容器（iCloud.com.ericterminal.els）。
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

// MARK: - UTType 扩展

extension UTType {
    static let elsbackup = UTType(exportedAs: "com.ericterminal.els.elsbackup")
}

// MARK: - 分享表单

private struct BackupShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 密码解密弹窗

private struct BackupDecryptPrompt: View {
    let fileName: String
    @Binding var password: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(NSLocalizedString("backup.password.placeholder", comment: ""), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit { if !password.isEmpty { onConfirm() } }
                } header: {
                    Text(String(format: NSLocalizedString("backup.decrypt.header", comment: ""), fileName))
                } footer: {
                    Text(NSLocalizedString("backup.decrypt.footer", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(NSLocalizedString("backup.decrypt.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("backup.decrypt.confirm", comment: "")) {
                        onConfirm()
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}

// MARK: - BackupRestoreView

struct BackupRestoreView: View {

    // 导出状态
    @State private var isBuilding = false
    @State private var builtFileURL: URL?
    @State private var exportError: String?
    @State private var showShareSheet = false
    @State private var iCloudExportSuccess = false
    @State private var iCloudExportError: String?
    @State private var isUploadingToiCloud = false

    // 加密选项
    @State private var enableEncryption = false
    @State private var useStrongKDF = true
    @State private var exportPassword = ""
    @State private var confirmPassword = ""

    // 导入状态
    @State private var showImportPicker = false
    @State private var isRestoring = false
    @State private var restoreSuccess = false
    @State private var restoreError: String?

    // 加密文件解密弹窗
    @State private var pendingRestoreURL: URL?
    @State private var showDecryptPrompt = false
    @State private var decryptPassword = ""
    @State private var decryptError: String?

    // 恢复确认弹窗
    @State private var showRestoreConfirm = false
    @State private var pendingPlainRestoreURL: URL?

    private var passwordMismatch: Bool {
        enableEncryption && !confirmPassword.isEmpty && exportPassword != confirmPassword
    }

    private var exportReady: Bool {
        if enableEncryption {
            return !exportPassword.isEmpty && exportPassword == confirmPassword
        }
        return true
    }

    var body: some View {
        List {
            // MARK: - 导出 Section
            Section {
                Toggle(NSLocalizedString("backup.export.encrypt", comment: ""), isOn: $enableEncryption.animation())

                if enableEncryption {
                    Toggle(NSLocalizedString("backup.export.strongKDF", comment: ""), isOn: $useStrongKDF)

                    SecureField(NSLocalizedString("backup.password.placeholder", comment: ""), text: $exportPassword)
                        .textContentType(.newPassword)

                    SecureField(NSLocalizedString("backup.confirmPassword.placeholder", comment: ""), text: $confirmPassword)
                        .textContentType(.newPassword)

                    if passwordMismatch {
                        Text(NSLocalizedString("两次输入的密码不一致。", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // 导出到 iCloud Drive
                Button {
                    exportToiCloudDrive()
                } label: {
                    HStack {
                        Spacer()
                        if isBuilding || isUploadingToiCloud {
                            ProgressView().padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("backup.export.icloud", comment: ""), systemImage: "icloud.and.arrow.up")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(!exportReady || isBuilding || isUploadingToiCloud || isRestoring)

                // 分享备份文件
                Button {
                    buildAndShare()
                } label: {
                    HStack {
                        Spacer()
                        if isBuilding {
                            ProgressView().padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("backup.export.share", comment: ""), systemImage: "square.and.arrow.up")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(!exportReady || isBuilding || isRestoring)

            } header: {
                Text(NSLocalizedString("backup.section.export", comment: ""))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("backup.export.footer", comment: ""))
                    if let exportError {
                        Text(exportError)
                            .foregroundStyle(.red)
                    }
                    if iCloudExportSuccess {
                        Text(NSLocalizedString("backup.export.icloud.success", comment: ""))
                            .foregroundStyle(.green)
                    }
                    if let iCloudExportError {
                        Text(iCloudExportError)
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }

            // MARK: - 恢复 Section
            Section {
                Button {
                    showImportPicker = true
                } label: {
                    HStack {
                        Spacer()
                        if isRestoring {
                            ProgressView().padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("backup.restore.pick", comment: ""), systemImage: "folder.badge.plus")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(isBuilding || isRestoring)

                if let restoreError {
                    Text(restoreError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if restoreSuccess {
                    Text(NSLocalizedString("backup.restore.success", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.green)
                }

            } header: {
                Text(NSLocalizedString("backup.section.restore", comment: ""))
            } footer: {
                Text(NSLocalizedString("backup.restore.footer", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("backup.nav.title", comment: ""))
        .navigationBarTitleDisplayMode(.large)
        // 文件导入器
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.elsbackup, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        // 分享 Sheet
        .sheet(isPresented: $showShareSheet, onDismiss: {
            if let url = builtFileURL {
                try? FileManager.default.removeItem(at: url)
                builtFileURL = nil
            }
        }) {
            if let url = builtFileURL {
                BackupShareSheet(fileURL: url)
                    .ignoresSafeArea()
            }
        }
        // 解密密码 Sheet
        .sheet(isPresented: $showDecryptPrompt) {
            BackupDecryptPrompt(
                fileName: pendingRestoreURL?.lastPathComponent ?? "",
                password: $decryptPassword,
                onConfirm: {
                    showDecryptPrompt = false
                    performEncryptedRestore()
                },
                onCancel: {
                    showDecryptPrompt = false
                    pendingRestoreURL = nil
                    decryptPassword = ""
                }
            )
        }
        // 恢复确认弹窗
        .alert(
            NSLocalizedString("backup.restore.confirm.title", comment: ""),
            isPresented: $showRestoreConfirm
        ) {
            Button(NSLocalizedString("backup.restore.confirm.action", comment: ""), role: .destructive) {
                if let url = pendingPlainRestoreURL {
                    performPlainRestore(from: url)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                pendingPlainRestoreURL = nil
            }
        } message: {
            Text(NSLocalizedString("backup.restore.confirm.message", comment: ""))
        }
    }

    // MARK: - 导出逻辑

    /// 构建备份文件后通过系统分享表单分享
    private func buildAndShare() {
        exportError = nil
        isBuilding = true
        Task.detached(priority: .userInitiated) {
            do {
                let rawURL = try SnapshotBuilder.buildSnapshot()
                let finalURL: URL
                if await enableEncryption {
                    let pwd = await exportPassword
                    let mode: SnapshotEncryptor.EncryptionMode = await useStrongKDF ? .strong : .simple
                    let encrypted = try SnapshotEncryptor.encrypt(fileURL: rawURL, password: pwd, mode: mode)
                    try? FileManager.default.removeItem(at: rawURL)
                    let encURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(rawURL.lastPathComponent)
                    try encrypted.write(to: encURL, options: .atomic)
                    finalURL = encURL
                } else {
                    finalURL = rawURL
                }
                await MainActor.run {
                    builtFileURL = finalURL
                    isBuilding = false
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    exportError = String(format: NSLocalizedString("backup.export.error", comment: ""), error.localizedDescription)
                    isBuilding = false
                }
            }
        }
    }

    /// 构建备份文件后写入 iCloud Drive
    private func exportToiCloudDrive() {
        exportError = nil
        iCloudExportSuccess = false
        iCloudExportError = nil
        isBuilding = true

        Task.detached(priority: .userInitiated) {
            do {
                let rawURL = try SnapshotBuilder.buildSnapshot()
                let finalURL: URL
                if await enableEncryption {
                    let pwd = await exportPassword
                    let mode: SnapshotEncryptor.EncryptionMode = await useStrongKDF ? .strong : .simple
                    let encrypted = try SnapshotEncryptor.encrypt(fileURL: rawURL, password: pwd, mode: mode)
                    try? FileManager.default.removeItem(at: rawURL)
                    let encURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(rawURL.lastPathComponent)
                    try encrypted.write(to: encURL, options: .atomic)
                    finalURL = encURL
                } else {
                    finalURL = rawURL
                }

                await MainActor.run { isBuilding = false; isUploadingToiCloud = true }

                // 获取 iCloud Drive 容器路径
                guard let iCloudRoot = FileManager.default.url(
                    forUbiquityContainerIdentifier: "iCloud.com.ericterminal.els"
                ) else {
                    try? FileManager.default.removeItem(at: finalURL)
                    await MainActor.run {
                        isUploadingToiCloud = false
                        iCloudExportError = NSLocalizedString("backup.export.icloud.unavailable", comment: "")
                    }
                    return
                }

                let backupDir = iCloudRoot
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("ETOS LLM Studio Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let destURL = backupDir.appendingPathComponent(finalURL.lastPathComponent)

                // 使用 NSFileCoordinator 安全写入 iCloud Drive
                var coordinatorError: NSError?
                NSFileCoordinator().coordinate(
                    writingItemAt: destURL,
                    options: .forReplacing,
                    error: &coordinatorError
                ) { writingURL in
                    do {
                        if FileManager.default.fileExists(atPath: writingURL.path) {
                            try FileManager.default.removeItem(at: writingURL)
                        }
                        try FileManager.default.copyItem(at: finalURL, to: writingURL)
                    } catch {
                        coordinatorError = error as NSError
                    }
                }
                try? FileManager.default.removeItem(at: finalURL)

                if let coordinatorError {
                    throw coordinatorError
                }

                await MainActor.run {
                    isUploadingToiCloud = false
                    iCloudExportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    isUploadingToiCloud = false
                    iCloudExportError = String(format: NSLocalizedString("backup.export.error", comment: ""), error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 导入逻辑

    private func handleImportResult(_ result: Result<[URL], Error>) {
        restoreError = nil
        restoreSuccess = false
        decryptError = nil
        switch result {
        case .failure(let error):
            restoreError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // 需要获取沙箱安全访问权限
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let encMode = try SnapshotRestoreService.detectEncryption(at: url)
                if encMode != nil {
                    // 加密文件，复制到临时目录后弹出密码输入
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    pendingRestoreURL = tempURL
                    decryptPassword = ""
                    showDecryptPrompt = true
                } else {
                    // 明文 ZIP，弹确认对话框
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    pendingPlainRestoreURL = tempURL
                    showRestoreConfirm = true
                }
            } catch {
                restoreError = error.localizedDescription
            }
        }
    }

    private func performPlainRestore(from url: URL) {
        isRestoring = true
        Task {
            do {
                try await SnapshotRestoreService.restorePlaintext(from: url)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    isRestoring = false
                    restoreSuccess = true
                    pendingPlainRestoreURL = nil
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    isRestoring = false
                    restoreError = String(format: NSLocalizedString("backup.restore.error", comment: ""), error.localizedDescription)
                    pendingPlainRestoreURL = nil
                }
            }
        }
    }

    private func performEncryptedRestore() {
        guard let url = pendingRestoreURL else { return }
        let pwd = decryptPassword
        isRestoring = true
        decryptPassword = ""
        pendingRestoreURL = nil

        Task {
            do {
                try await SnapshotRestoreService.restoreEncrypted(from: url, password: pwd)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    isRestoring = false
                    restoreSuccess = true
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                let isWrongPassword = (error as? SnapshotEncryptorError) != nil
                await MainActor.run {
                    isRestoring = false
                    if isWrongPassword {
                        restoreError = NSLocalizedString("backup.restore.wrongPassword", comment: "")
                    } else {
                        restoreError = String(format: NSLocalizedString("backup.restore.error", comment: ""), error.localizedDescription)
                    }
                }
            }
        }
    }
}
