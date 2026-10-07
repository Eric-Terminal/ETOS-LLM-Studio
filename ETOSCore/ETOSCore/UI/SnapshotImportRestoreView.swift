import Foundation
import SwiftUI

/// 各端的导入入口与系统文件打开入口共用同一套快照检查、确认和恢复流程。
public struct SnapshotImportRestoreView: View {
    private let fileURL: URL
    private let onDismiss: () -> Void
    private let restoreOperation: (@MainActor (URL, String?) async throws -> Void)?
    @State private var inspection: SnapshotRestoreService.InspectionResult?
    @State private var isInspecting = true
    @State private var isRestoring = false
    @State private var password = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    public init(
        fileURL: URL,
        restoreOperation: (@MainActor (URL, String?) async throws -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.onDismiss = onDismiss
        self.restoreOperation = restoreOperation
    }

    public var body: some View {
        List {
            Section {
                LabeledContent(NSLocalizedString("文件名", comment: "")) {
                    Text(fileURL.lastPathComponent)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(NSLocalizedString("恢复会替换当前聊天、配置与记忆数据库；完整快照还会恢复壁纸、附件、字体与记忆向量索引文件。请选择可信的 .elsbackup 文件。", comment: "快照恢复范围"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(NSLocalizedString("快照不包含本地 Linux 的系统或用户文件。恢复会保留 Linux 配置；缺失的系统会在首次使用时重新安装，外部文件夹可能需要重新授权。", comment: "快照中的 Linux 文件边界"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if inspection?.requiresPassword == true {
                Section {
                    SecureField(NSLocalizedString("密码", comment: ""), text: $password)
                        .textContentType(.password)
                        .disabled(isRestoring)
                } footer: {
                    Text(NSLocalizedString("此快照已加密，请输入导出时设置的密码。", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isInspecting || isRestoring {
                Section {
                    HStack {
                        ProgressView()
                        Text(isInspecting
                             ? NSLocalizedString("正在检查快照…", comment: "")
                             : NSLocalizedString("正在恢复快照…", comment: ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage {
                Section(NSLocalizedString("状态", comment: "")) {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section(NSLocalizedString("快照操作失败", comment: "")) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(NSLocalizedString("恢复", comment: ""), role: .destructive) {
                    restoreSnapshot()
                }
                .disabled(isInspecting || isRestoring || inspection == nil || statusMessage != nil
                          || (inspection?.requiresPassword == true && password.isEmpty))
            }
        }
        .navigationTitle(NSLocalizedString("从快照恢复", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(statusMessage == nil
                       ? NSLocalizedString("取消", comment: "")
                       : NSLocalizedString("关闭", comment: ""), action: onDismiss)
                    .disabled(isRestoring)
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: "snapshot-import-restore", title: NSLocalizedString("从快照恢复", comment: ""), documents: SnapshotBackupGuideSupport.documents),
            snapshot: { GuidePageSnapshot(fields: [
                "file_name": GuideSnapshotField(label: NSLocalizedString("文件名", comment: ""), value: .string(fileURL.lastPathComponent), access: .readOnly),
                "encrypted": GuideSnapshotField(label: NSLocalizedString("设置密码", comment: ""), value: .bool(inspection?.requiresPassword == true), access: .readOnly),
                "restoring": GuideSnapshotField(label: NSLocalizedString("正在恢复快照…", comment: ""), value: .bool(isRestoring), access: .readOnly),
                "requires_manual_action": GuideSnapshotField(label: NSLocalizedString("恢复", comment: ""), value: .bool(true), access: .readOnly),
                "password": GuideSnapshotField(label: NSLocalizedString("密码", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly)
            ]) }
        )
        .task {
            do {
                inspection = try await Task.detached(priority: .userInitiated) {
                    try SnapshotRestoreService.inspectSnapshot(at: fileURL)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isInspecting = false
        }
    }

    private func restoreSnapshot() {
        isRestoring = true
        errorMessage = nil
        let restorePassword = inspection?.requiresPassword == true ? password : nil
        Task {
            do {
                if let restoreOperation {
                    try await restoreOperation(fileURL, restorePassword)
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try SnapshotRestoreService.restoreSnapshot(from: fileURL, password: restorePassword)
                    }.value
                    await AppConfigStore.shared.reloadFromPersistentStoreAndWait()
                }
                password = ""
                statusMessage = NSLocalizedString("快照已恢复。若当前界面仍显示旧数据，请返回聊天列表后重新进入。", comment: "")
            } catch {
                errorMessage = error.localizedDescription
            }
            isRestoring = false
        }
    }
}
