import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacBackupRestoreView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var uploads = SnapshotUploadManager.shared
    @State private var kind: SnapshotBuilder.BackupKind = .full
    @State private var encrypted = false
    @State private var strongDerivation = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isImporting = false
    @State private var incoming: MacSnapshotFile?
    @State private var exportedURL: URL?
    @State private var error: String?

    private var isExporting: Bool { workspace.isExportingSnapshot }
    private var isBusy: Bool { isExporting || uploads.isUploading || workspace.isRestoringData }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(
                    id: "snapshots", title: NSLocalizedString("快照备份", comment: ""),
                    details: NSLocalizedString("数据库快照只包含聊天、配置与记忆数据库；完整快照还包含壁纸、附件、字体与记忆向量索引文件。", comment: ""),
                    documentID: "snapshot-backup"
                )
            }
            Section {
                Picker(NSLocalizedString("快照类型", comment: ""), selection: $kind) {
                    Text(NSLocalizedString("数据库快照", comment: "")).tag(SnapshotBuilder.BackupKind.database)
                    Text(NSLocalizedString("完整快照", comment: "")).tag(SnapshotBuilder.BackupKind.full)
                }
                Toggle(NSLocalizedString("设置密码", comment: ""), isOn: $encrypted)
                if encrypted {
                    Toggle(NSLocalizedString("高强度派生", comment: ""), isOn: $strongDerivation)
                    SecureField(NSLocalizedString("密码", comment: ""), text: $password)
                    SecureField(NSLocalizedString("确认密码", comment: ""), text: $confirmation)
                }
                Button(NSLocalizedString("保存到文件…", comment: "")) { chooseExportDestination() }
                if let exportedURL {
                    Button(NSLocalizedString("在 Finder 中显示", comment: "")) {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                    }
                }
            } header: { Text(NSLocalizedString("手动快照", comment: "")) }
            .disabled(isBusy)
            Section {
                Toggle(NSLocalizedString("启用 S3/R2 保存", comment: ""), isOn: $configuration.syncBackupS3Enabled)
                    .disabled(isBusy)
                if configuration.syncBackupS3Enabled {
                    NavigationLink(NSLocalizedString("S3/R2 保存设置", comment: "")) { MacSnapshotStorageView() }
                    Button(NSLocalizedString("上传到 S3/R2", comment: "")) { upload() }
                        .disabled(isBusy)
                }
                if let progress = uploads.progress { ProgressView(value: progress.fractionCompleted) }
                if let status = uploads.statusMessage { Text(status).font(.footnote).foregroundStyle(.secondary) }
                if let error = uploads.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: { Text(NSLocalizedString("S3 兼容对象存储", comment: "")) }
            Section {
                Button(NSLocalizedString("从快照恢复", comment: ""), role: .destructive) { isImporting = true }
                    .disabled(isBusy)
            } footer: {
                Text(NSLocalizedString("恢复前请确认快照来源可信。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if isExporting { ProgressView(NSLocalizedString("正在创建快照…", comment: "")) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("快照备份", comment: ""))
        .guideSettingsPageContext(
            id: "mac-snapshot-backup", title: NSLocalizedString("快照备份", comment: ""),
            documents: SnapshotBackupGuideSupport.documents,
            settings: isBusy ? [
                .readOnly("exporting", label: NSLocalizedString("正在创建快照…", comment: ""), value: { .bool(isExporting) }),
                .readOnly("uploading", label: NSLocalizedString("上传到 S3/R2", comment: ""), value: { .bool(uploads.isUploading) }),
                .readOnly("restoring", label: NSLocalizedString("正在恢复快照…", comment: ""), value: { .bool(workspace.isRestoringData) })
            ] : SnapshotBackupGuideSupport.draftSettings(kind: $kind, encrypted: $encrypted, strongDerivation: $strongDerivation, password: $password, confirmation: $confirmation)
        )
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): incoming = MacSnapshotFile(url: url)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(item: $incoming) { file in MacSnapshotRestoreSheet(file: file) { incoming = nil } }
    }

    private func validatePassword() -> Bool {
        guard !encrypted || (!password.isEmpty && password == confirmation) else {
            error = NSLocalizedString("请填写一致的快照密码和确认密码。", comment: "")
            return false
        }
        return true
    }

    private func chooseExportDestination() {
        guard !isBusy, validatePassword() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SnapshotBuilder.fileExtension) ?? .data]
        panel.nameFieldStringValue = "ETOS-Backup.\(SnapshotBuilder.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            export(to: destination)
        }
    }

    private func export(to destination: URL) {
        guard !isBusy, workspace.beginSnapshotExport() else { return }
        error = nil
        let kind = kind
        let password = encrypted ? password : nil
        let strong = strongDerivation
        Task {
            defer { workspace.endSnapshotExport() }
            do {
                await workspace.modelTests.cancelAndWait()
                await workspace.localModels.waitForPendingWrites()
                await workspace.shortcutTools.waitForPendingWrites()
                await workspace.builtInTools.waitForPendingWrites()
                await workspace.toolApproval.waitForPendingWrites()
                await workspace.skills.waitForPendingWrites()
                await workspace.browser.waitForPendingOperations()
                await workspace.agentPrompts.waitForPendingWrites()
                await workspace.globalProxy.waitForPendingWrites()
                try await workspace.linux.waitForPendingOperations()
                await workspace.incomingDocuments.waitForPendingOperations()
                await workspace.requestControls.waitForPendingWrites()
                await configuration.flushPendingWrites()
                await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
                try await Task.detached(priority: .userInitiated) {
                    let access = destination.startAccessingSecurityScopedResource()
                    defer { if access { destination.stopAccessingSecurityScopedResource() } }
                    MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
                    let source = try SnapshotBuilder.buildSnapshot(kind: kind)
                    defer { try? FileManager.default.removeItem(at: source) }
                    if let password {
                        let data = try Data(contentsOf: source, options: .mappedIfSafe)
                        let encrypted = try strong
                            ? SnapshotEncryptor.encryptStrongPassword(data: data, password: password)
                            : SnapshotEncryptor.encryptSimplePassword(data: data, password: password)
                        try encrypted.write(to: source, options: .atomic)
                    }
                    // 同卷临时文件完成后才替换用户目标，导出失败时保留原备份。
                    let staging = destination.deletingLastPathComponent().appendingPathComponent(".etos-export-\(UUID())")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: source, to: staging)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else { try FileManager.default.moveItem(at: staging, to: destination) }
                }.value
                exportedURL = destination
                self.password = ""
                confirmation = ""
            } catch { self.error = error.localizedDescription }
        }
    }

    private func upload() {
        guard !isBusy, validatePassword() else { return }
        do {
            let storage = try MacSnapshotStorageView.storageConfiguration(configuration)
            if uploads.start(kind: kind, password: encrypted ? password : nil, useStrongDerivation: strongDerivation, configuration: storage) {
                password = ""
                confirmation = ""
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct MacSnapshotFile: Identifiable {
    let id = UUID()
    let url: URL
    var removesOnDismiss = false
}

struct MacSnapshotRestoreSheet: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let file: MacSnapshotFile
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            SnapshotImportRestoreView(fileURL: file.url, restoreOperation: { url, password in
                try await workspace.restoreSnapshot(from: url, password: password)
            }, onDismiss: onDismiss)
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 560, minHeight: 460)
        .onDisappear {
            if file.removesOnDismiss {
                let url = file.url
                Task.detached { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
}
