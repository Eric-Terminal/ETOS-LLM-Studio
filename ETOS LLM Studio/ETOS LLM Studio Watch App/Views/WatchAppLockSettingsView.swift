// ============================================================================
// WatchAppLockSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App (watchOS)
//
// 应用锁设置页（E2 + E3）：
//   - 开启/关闭应用锁（设置密码）
//   - 自动锁定超时时间
//   - 生物识别开关
// ============================================================================

import SwiftUI
import Shared

struct WatchAppLockSettingsView: View {
    @EnvironmentObject private var appConfig: AppConfigStore
    @StateObject private var lockManager = AppLockManager.shared

    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var currentPasswordForDisable: String = ""
    @State private var errorMessage: String?
    @State private var isSetPasswordPresented: Bool = false
    @State private var isDisablePresented: Bool = false
    @State private var databaseCurrentPassword: String = ""
    @State private var databaseNewPassword: String = ""
    @State private var databaseConfirmPassword: String = ""
    @State private var isDatabasePasswordPresented: Bool = false
    @State private var isDatabaseDisablePresented: Bool = false
    @State private var isDatabaseEncryptionEnabled: Bool = DatabaseEncryptionManager.shared.isEncryptionEnabled()
    @State private var usesLegacyDatabaseKey: Bool = DatabaseEncryptionManager.shared.usesLegacyAutomaticKey()
    @State private var isDatabaseOperationRunning: Bool = false
    @State private var successMessage: String?

    var body: some View {
        List {
            // MARK: - 应用锁状态与开关
            Section {
                if appConfig.appLockEnabled {
                    Button {
                        isSetPasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("修改密码", comment: "WatchAppLockSettings change password button"),
                            systemImage: "key.fill"
                        )
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        isDisablePresented = true
                    } label: {
                        Label(
                            NSLocalizedString("关闭应用锁", comment: "WatchAppLockSettings disable button"),
                            systemImage: "lock.open.fill"
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        isSetPasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("设置密码", comment: "WatchAppLockSettings set password button"),
                            systemImage: "lock.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(
                    appConfig.appLockEnabled
                    ? NSLocalizedString("应用锁已开启", comment: "WatchAppLockSettings enabled footer")
                    : NSLocalizedString("设置密码后启用锁定", comment: "WatchAppLockSettings disabled footer")
                )
            }

            // MARK: - 超时时间
            if appConfig.appLockEnabled {
                Section {
                    Picker(
                        NSLocalizedString("延迟", comment: "WatchAppLockSettings lock delay picker"),
                        selection: $appConfig.appLockTimeoutSeconds
                    ) {
                        Text(NSLocalizedString("立即", comment: "AppLock timeout immediately")).tag(0)
                        Text(NSLocalizedString("1 分钟", comment: "AppLock timeout 1 min")).tag(60)
                        Text(NSLocalizedString("5 分钟", comment: "AppLock timeout 5 min")).tag(300)
                        Text(NSLocalizedString("15 分钟", comment: "AppLock timeout 15 min")).tag(900)
                        Text(NSLocalizedString("30 分钟", comment: "AppLock timeout 30 min")).tag(1800)
                    }
                } header: {
                    Text(NSLocalizedString("锁定延迟", comment: "WatchAppLockSettings lock delay section"))
                }

                // MARK: - 生物识别（E3）
                Section {
                    Toggle(
                        NSLocalizedString("生物识别解锁", comment: "WatchAppLockSettings biometric toggle"),
                        isOn: $appConfig.appLockUseBiometrics
                    )
                } footer: {
                    Text(NSLocalizedString("开启后优先使用腕部检测/密码双重验证", comment: "WatchAppLockSettings biometric footer"))
                }
            }

            Section {
                if isDatabaseEncryptionEnabled {
                    Button {
                        isDatabasePasswordPresented = true
                    } label: {
                        Label(
                            usesLegacyDatabaseKey
                                ? NSLocalizedString("设置数据库主密码", comment: "WatchAppLockSettings set database password button")
                                : NSLocalizedString("修改数据库主密码", comment: "WatchAppLockSettings change database password button"),
                            systemImage: "internaldrive.fill.badge.key"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDatabaseOperationRunning)

                    if !usesLegacyDatabaseKey {
                        Button(role: .destructive) {
                            isDatabaseDisablePresented = true
                        } label: {
                            Label(
                                NSLocalizedString("关闭数据库加密", comment: "WatchAppLockSettings disable database encryption button"),
                                systemImage: "internaldrive.fill.badge.xmark"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDatabaseOperationRunning)
                    }
                } else {
                    Button {
                        isDatabasePasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("启用数据库加密", comment: "WatchAppLockSettings enable database encryption button"),
                            systemImage: "internaldrive.fill.badge.lock"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDatabaseOperationRunning)
                }

                if isDatabaseOperationRunning {
                    ProgressView(NSLocalizedString("正在处理数据库加密…", comment: "WatchAppLockSettings database encryption progress"))
                }
            } header: {
                Text(NSLocalizedString("数据库加密", comment: "WatchAppLockSettings database encryption section"))
            } footer: {
                Text(databaseEncryptionFooterText)
            }

            // MARK: - 错误提示
            if let msg = errorMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if let successMessage {
                Section {
                    Text(successMessage)
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用锁", comment: "WatchAppLockSettings navigation title"))
        .onAppear(perform: refreshDatabaseEncryptionState)
        // 设置/修改密码弹窗
        .alert(appLockPasswordAlertTitle, isPresented: $isSetPasswordPresented) {
            SecureField(NSLocalizedString("新密码", comment: "WatchAppLockSettings new password field"), text: $newPassword)
            SecureField(NSLocalizedString("确认密码", comment: "WatchAppLockSettings confirm password field"), text: $confirmPassword)
            Button(NSLocalizedString("确定", comment: ""), action: applySetPassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                newPassword = ""
                confirmPassword = ""
            }
        }
        // 关闭应用锁弹窗
        .alert(
            NSLocalizedString("关闭应用锁", comment: "WatchAppLockSettings disable alert title"),
            isPresented: $isDisablePresented
        ) {
            SecureField(NSLocalizedString("当前密码", comment: "WatchAppLockSettings current password field"), text: $currentPasswordForDisable)
            Button(NSLocalizedString("关闭", comment: ""), role: .destructive, action: applyDisable)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                currentPasswordForDisable = ""
            }
        }
        .alert(
            databasePasswordAlertTitle,
            isPresented: $isDatabasePasswordPresented
        ) {
            if isDatabaseEncryptionEnabled && !usesLegacyDatabaseKey {
                SecureField(NSLocalizedString("当前数据库主密码", comment: "WatchAppLockSettings current database password field"), text: $databaseCurrentPassword)
            }
            SecureField(databasePasswordFieldTitle, text: $databaseNewPassword)
            SecureField(NSLocalizedString("确认数据库主密码", comment: "WatchAppLockSettings confirm database password field"), text: $databaseConfirmPassword)
            Button(NSLocalizedString("确定", comment: ""), action: applyDatabasePassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel, action: resetDatabasePasswordFields)
        }
        .alert(
            NSLocalizedString("关闭数据库加密", comment: "WatchAppLockSettings disable database encryption alert title"),
            isPresented: $isDatabaseDisablePresented
        ) {
            SecureField(NSLocalizedString("当前数据库主密码", comment: "WatchAppLockSettings disable database password field"), text: $databaseCurrentPassword)
            Button(NSLocalizedString("关闭", comment: ""), role: .destructive, action: applyDisableDatabaseEncryption)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel, action: resetDatabasePasswordFields)
        }
    }

    private var databasePasswordAlertTitle: String {
        if !isDatabaseEncryptionEnabled {
            return NSLocalizedString("启用数据库加密", comment: "WatchAppLockSettings enable database encryption alert title")
        }
        if usesLegacyDatabaseKey {
            return NSLocalizedString("设置数据库主密码", comment: "WatchAppLockSettings adopt legacy database password alert title")
        }
        return NSLocalizedString("修改数据库主密码", comment: "WatchAppLockSettings change database password alert title")
    }

    private var appLockPasswordAlertTitle: String {
        appConfig.appLockEnabled
            ? NSLocalizedString("修改密码", comment: "WatchAppLockSettings change password alert title")
            : NSLocalizedString("设置密码", comment: "WatchAppLockSettings set password alert title")
    }

    private var databasePasswordFieldTitle: String {
        isDatabaseEncryptionEnabled
            ? NSLocalizedString("新数据库主密码", comment: "WatchAppLockSettings new database password field")
            : NSLocalizedString("数据库主密码", comment: "WatchAppLockSettings database password field")
    }

    private var databaseEncryptionFooterText: String {
        if isDatabaseEncryptionEnabled {
            if usesLegacyDatabaseKey {
                return NSLocalizedString("检测到旧版自动密钥。请先设置自定义数据库主密码，再决定是否关闭数据库加密。", comment: "WatchAppLockSettings legacy database encryption footer")
            }
            return NSLocalizedString("已启用 SQLCipher，聊天、配置、记忆与向量数据库都会使用独立主密码加密。", comment: "WatchAppLockSettings database encryption enabled footer")
        }
        return NSLocalizedString("启用后将使用 SQLCipher 加密聊天、配置、记忆与向量数据库。请设置一个独立主密码。", comment: "WatchAppLockSettings database encryption disabled footer")
    }

    // MARK: - 操作

    private func applySetPassword() {
        guard newPassword == confirmPassword else {
            errorMessage = NSLocalizedString("两次输入的密码不一致。", comment: "WatchAppLockSettings password mismatch error")
            newPassword = ""
            confirmPassword = ""
            return
        }
        do {
            try lockManager.setPassword(newPassword)
            newPassword = ""
            confirmPassword = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            newPassword = ""
            confirmPassword = ""
        }
    }

    private func applyDisable() {
        do {
            try lockManager.removePassword(currentPassword: currentPasswordForDisable)
            currentPasswordForDisable = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            currentPasswordForDisable = ""
        }
    }

    private func refreshDatabaseEncryptionState() {
        isDatabaseEncryptionEnabled = DatabaseEncryptionManager.shared.isEncryptionEnabled()
        usesLegacyDatabaseKey = DatabaseEncryptionManager.shared.usesLegacyAutomaticKey()
    }

    private func resetDatabasePasswordFields() {
        databaseCurrentPassword = ""
        databaseNewPassword = ""
        databaseConfirmPassword = ""
    }

    private func applyDatabasePassword() {
        guard databaseNewPassword == databaseConfirmPassword else {
            errorMessage = NSLocalizedString("两次输入的数据库主密码不一致。", comment: "WatchAppLockSettings database password mismatch error")
            resetDatabasePasswordFields()
            return
        }

        let currentPassword = databaseCurrentPassword
        let newPassword = databaseNewPassword
        resetDatabasePasswordFields()
        isDatabaseOperationRunning = true
        successMessage = nil

        Task {
            do {
                if !isDatabaseEncryptionEnabled {
                    try await DatabaseEncryptionManager.shared.enableEncryption(with: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库加密已开启。", comment: "WatchAppLockSettings enable database encryption success")
                    }
                } else if usesLegacyDatabaseKey {
                    try await DatabaseEncryptionManager.shared.adoptLegacyAutomaticKey(with: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库主密码已设置。", comment: "WatchAppLockSettings adopt database password success")
                    }
                } else {
                    try await DatabaseEncryptionManager.shared.changePassphrase(currentPassphrase: currentPassword, newPassphrase: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库主密码已更新。", comment: "WatchAppLockSettings change database password success")
                    }
                }

                await MainActor.run {
                    refreshDatabaseEncryptionState()
                    errorMessage = nil
                    isDatabaseOperationRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDatabaseOperationRunning = false
                    refreshDatabaseEncryptionState()
                }
            }
        }
    }

    private func applyDisableDatabaseEncryption() {
        let currentPassword = databaseCurrentPassword
        resetDatabasePasswordFields()
        isDatabaseOperationRunning = true
        successMessage = nil

        Task {
            do {
                try await DatabaseEncryptionManager.shared.disableEncryption(currentPassphrase: currentPassword)
                await MainActor.run {
                    refreshDatabaseEncryptionState()
                    errorMessage = nil
                    successMessage = NSLocalizedString("数据库加密已关闭。", comment: "WatchAppLockSettings disable database encryption success")
                    isDatabaseOperationRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDatabaseOperationRunning = false
                    refreshDatabaseEncryptionState()
                }
            }
        }
    }
}
