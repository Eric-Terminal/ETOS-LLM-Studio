// ============================================================================
// IncomingSnapshotRestoreView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端承接系统“打开方式”传入的 .elsbackup 快照恢复。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension Notification.Name {
    static let requestIncomingSnapshotRestore = Notification.Name("ios.requestIncomingSnapshotRestore")
}

struct IncomingSnapshotRestorePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

enum IncomingSnapshotRestoreSupport {
    static func isSnapshotURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare(SnapshotBuilder.fileExtension) == .orderedSame
    }
}

struct IncomingSnapshotRestoreView: View {
    let fileURL: URL
    let onDismiss: () -> Void

    @State private var inspection: SnapshotRestoreService.InspectionResult?
    @State private var isInspecting = true
    @State private var isRestoring = false
    @State private var restorePassword = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("系统打开了一个数据库快照文件。确认来源可信后再恢复。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledContent(NSLocalizedString("文件名", comment: "")) {
                        Text(fileURL.lastPathComponent)
                            .multilineTextAlignment(.trailing)
                    }

                    if isInspecting {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("正在检查快照…", comment: ""))
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if inspection?.requiresPassword == true {
                Section {
                    SecureField(NSLocalizedString("密码", comment: ""), text: $restorePassword)
                        .textContentType(.password)
                } footer: {
                    Text(passwordPromptMessage)
                }
            }

            if let statusMessage, !statusMessage.isEmpty {
                Section(NSLocalizedString("状态", comment: "")) {
                    Text(statusMessage)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isRestoring {
                Section(NSLocalizedString("状态", comment: "")) {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在恢复快照…", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section(NSLocalizedString("快照操作失败", comment: "")) {
                    Text(errorMessage)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("从快照恢复", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(dismissButtonTitle, action: onDismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("恢复", comment: "")) {
                    restoreSnapshot()
                }
                .disabled(restoreButtonDisabled)
            }
        }
        .task {
            inspectSnapshot()
        }
    }

    private var restoreButtonDisabled: Bool {
        statusMessage != nil || isInspecting || isRestoring || inspection == nil || (inspection?.requiresPassword == true && restorePassword.isEmpty)
    }

    private var dismissButtonTitle: String {
        if statusMessage == nil {
            return NSLocalizedString("取消", comment: "")
        }
        return NSLocalizedString("关闭", comment: "")
    }

    private var passwordPromptMessage: String {
        switch inspection?.encryptionMode {
        case .simplePassword:
            return NSLocalizedString("此快照使用简单密码加密，请输入导出时设置的密码。", comment: "")
        case .pbkdf2Strong:
            return NSLocalizedString("此快照使用高强度派生加密，请输入导出时设置的密码。", comment: "")
        case .none:
            return NSLocalizedString("此快照已加密，请输入导出时设置的密码。", comment: "")
        }
    }

    private func inspectSnapshot() {
        isInspecting = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try SnapshotRestoreService.inspectSnapshot(at: fileURL)
                await MainActor.run {
                    inspection = result
                    isInspecting = false
                }
            } catch {
                await MainActor.run {
                    isInspecting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func restoreSnapshot() {
        isRestoring = true
        statusMessage = nil
        errorMessage = nil
        let password = inspection?.requiresPassword == true ? restorePassword : nil

        Task.detached(priority: .userInitiated) {
            do {
                try SnapshotRestoreService.restoreSnapshot(from: fileURL, password: password)
                await MainActor.run {
                    AppConfigStore.shared.reloadFromPersistentStore()
                    isRestoring = false
                    statusMessage = NSLocalizedString("快照已恢复。若当前界面仍显示旧数据，请返回聊天列表后重新进入。", comment: "")
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
