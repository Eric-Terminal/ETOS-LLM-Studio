// ============================================================================
// AppLockSettingsView.swift
// ============================================================================
// ETOS LLM Studio (iOS)
//
// 应用锁设置页（E2 + E3）：
//   - 开启/关闭应用锁（设置密码）
//   - 自动锁定超时时间
//   - 生物识别开关
// ============================================================================

import SwiftUI
import Shared

struct AppLockSettingsView: View {
    @EnvironmentObject private var appConfig: AppConfigStore
    @StateObject private var lockManager = AppLockManager.shared

    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var oldPasswordForChange: String = ""
    @State private var currentPasswordForDisable: String = ""
    @State private var errorMessage: String?
    @State private var isSetPasswordPresented: Bool = false
    @State private var isDisablePresented: Bool = false
    @State private var isSuccessAlertPresented: Bool = false
    @State private var successMessage: String = ""
    @State private var databaseCurrentPassword: String = ""
    @State private var databaseNewPassword: String = ""
    @State private var databaseConfirmPassword: String = ""
    @State private var isDatabasePasswordPresented: Bool = false
    @State private var isDatabaseDisablePresented: Bool = false
    @State private var isDatabaseEncryptionEnabled: Bool = DatabaseEncryptionManager.shared.isEncryptionEnabled()
    @State private var usesLegacyDatabaseKey: Bool = DatabaseEncryptionManager.shared.usesLegacyAutomaticKey()
    @State private var isDatabaseOperationRunning: Bool = false

    var body: some View {
        Form {
            // MARK: - 应用锁开关
            Section {
                if appConfig.appLockEnabled {
                    // 已开启：提供禁用入口
                    Button(role: .destructive) {
                        isDisablePresented = true
                    } label: {
                        Label(
                            NSLocalizedString("关闭应用锁", comment: "AppLockSettings disable button"),
                            systemImage: "lock.open.fill"
                        )
                    }

                    Button {
                        isSetPasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("修改密码", comment: "AppLockSettings change password button"),
                            systemImage: "key.fill"
                        )
                    }
                } else {
                    // 未开启：引导设置密码
                    Button {
                        isSetPasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("设置应用锁密码", comment: "AppLockSettings set password button"),
                            systemImage: "lock.fill"
                        )
                    }
                }
            } footer: {
                Text(
                    appConfig.appLockEnabled
                    ? NSLocalizedString("应用锁已开启。进入后台超过指定时间后，再次打开需要验证。", comment: "AppLockSettings enabled footer")
                    : NSLocalizedString("设置密码后，应用在后台超过指定时间将自动锁定。", comment: "AppLockSettings disabled footer")
                )
            }

            // MARK: - 超时时间
            if appConfig.appLockEnabled {
                Section(NSLocalizedString("自动锁定", comment: "AppLockSettings auto lock section")) {
                    Picker(
                        NSLocalizedString("锁定延迟", comment: "AppLockSettings lock delay picker"),
                        selection: $appConfig.appLockTimeoutSeconds
                    ) {
                        Text(NSLocalizedString("立即", comment: "AppLock timeout immediately")).tag(0)
                        Text(NSLocalizedString("1 分钟", comment: "AppLock timeout 1 min")).tag(60)
                        Text(NSLocalizedString("5 分钟", comment: "AppLock timeout 5 min")).tag(300)
                        Text(NSLocalizedString("15 分钟", comment: "AppLock timeout 15 min")).tag(900)
                        Text(NSLocalizedString("30 分钟", comment: "AppLock timeout 30 min")).tag(1800)
                        Text(NSLocalizedString("1 小时", comment: "AppLock timeout 1 hour")).tag(3600)
                    }
                }

                // MARK: - 生物识别（E3）
                Section {
                    Toggle(
                        NSLocalizedString("使用面容 ID / 触控 ID", comment: "AppLockSettings biometric toggle"),
                        isOn: $appConfig.appLockUseBiometrics
                    )
                } header: {
                    Text(NSLocalizedString("生物识别", comment: "AppLockSettings biometric section"))
                } footer: {
                    Text(NSLocalizedString("开启后，解锁时将优先使用生物识别，失败则回退至密码。", comment: "AppLockSettings biometric footer"))
                }
            }

            Section {
                if isDatabaseEncryptionEnabled {
                    Button {
                        isDatabasePasswordPresented = true
                    } label: {
                        Label(
                            usesLegacyDatabaseKey
                                ? NSLocalizedString("设置数据库主密码", comment: "AppLockSettings set database password button")
                                : NSLocalizedString("修改数据库主密码", comment: "AppLockSettings change database password button"),
                            systemImage: "internaldrive.fill.badge.key"
                        )
                    }
                    .disabled(isDatabaseOperationRunning)

                    if !usesLegacyDatabaseKey {
                        Button(role: .destructive) {
                            isDatabaseDisablePresented = true
                        } label: {
                            Label(
                                NSLocalizedString("关闭数据库加密", comment: "AppLockSettings disable database encryption button"),
                                systemImage: "internaldrive.fill.badge.xmark"
                            )
                        }
                        .disabled(isDatabaseOperationRunning)
                    }
                } else {
                    Button {
                        isDatabasePasswordPresented = true
                    } label: {
                        Label(
                            NSLocalizedString("启用数据库加密", comment: "AppLockSettings enable database encryption button"),
                            systemImage: "internaldrive.fill.badge.lock"
                        )
                    }
                    .disabled(isDatabaseOperationRunning)
                }

                if isDatabaseOperationRunning {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在处理数据库加密…", comment: "AppLockSettings database encryption progress"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(NSLocalizedString("数据库加密", comment: "AppLockSettings database encryption section"))
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
        }
        .navigationTitle(NSLocalizedString("应用锁", comment: "AppLockSettings navigation title"))
        .onAppear(perform: refreshDatabaseEncryptionState)
        // 设置/修改密码弹窗
        .alert(appLockPasswordAlertTitle, isPresented: $isSetPasswordPresented) {
            // 修改密码场景需要验证旧密码，防止旁路认证攻击
            if appConfig.appLockEnabled {
                SecureField(NSLocalizedString("当前密码", comment: "AppLockSettings current password field for change"), text: $oldPasswordForChange)
            }
            SecureField(NSLocalizedString("新密码", comment: "AppLockSettings new password field"), text: $newPassword)
            SecureField(NSLocalizedString("确认密码", comment: "AppLockSettings confirm password field"), text: $confirmPassword)
            Button(NSLocalizedString("确定", comment: ""), action: applySetPassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                oldPasswordForChange = ""
                newPassword = ""
                confirmPassword = ""
            }
        }
        // 关闭应用锁弹窗
        .alert(
            NSLocalizedString("关闭应用锁", comment: "AppLockSettings disable alert title"),
            isPresented: $isDisablePresented
        ) {
            SecureField(NSLocalizedString("输入当前密码", comment: "AppLockSettings current password field"), text: $currentPasswordForDisable)
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
                SecureField(NSLocalizedString("当前数据库主密码", comment: "AppLockSettings current database password field"), text: $databaseCurrentPassword)
            }
            SecureField(databasePasswordFieldTitle, text: $databaseNewPassword)
            SecureField(NSLocalizedString("确认数据库主密码", comment: "AppLockSettings confirm database password field"), text: $databaseConfirmPassword)
            Button(NSLocalizedString("确定", comment: ""), action: applyDatabasePassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel, action: resetDatabasePasswordFields)
        }
        .alert(
            NSLocalizedString("关闭数据库加密", comment: "AppLockSettings disable database encryption alert title"),
            isPresented: $isDatabaseDisablePresented
        ) {
            SecureField(NSLocalizedString("当前数据库主密码", comment: "AppLockSettings disable database password field"), text: $databaseCurrentPassword)
            Button(NSLocalizedString("关闭", comment: ""), role: .destructive, action: applyDisableDatabaseEncryption)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel, action: resetDatabasePasswordFields)
        }
        // 成功提示
        .alert(successMessage, isPresented: $isSuccessAlertPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        }
    }

    private var databasePasswordAlertTitle: String {
        if !isDatabaseEncryptionEnabled {
            return NSLocalizedString("启用数据库加密", comment: "AppLockSettings enable database encryption alert title")
        }
        if usesLegacyDatabaseKey {
            return NSLocalizedString("设置数据库主密码", comment: "AppLockSettings adopt legacy database password alert title")
        }
        return NSLocalizedString("修改数据库主密码", comment: "AppLockSettings change database password alert title")
    }

    private var appLockPasswordAlertTitle: String {
        appConfig.appLockEnabled
            ? NSLocalizedString("修改密码", comment: "AppLockSettings change password alert title")
            : NSLocalizedString("设置密码", comment: "AppLockSettings set password alert title")
    }

    private var databasePasswordFieldTitle: String {
        isDatabaseEncryptionEnabled
            ? NSLocalizedString("新数据库主密码", comment: "AppLockSettings new database password field")
            : NSLocalizedString("数据库主密码", comment: "AppLockSettings database password field")
    }

    private var databaseEncryptionFooterText: String {
        if isDatabaseEncryptionEnabled {
            if usesLegacyDatabaseKey {
                return NSLocalizedString("检测到旧版自动密钥。请先设置自定义数据库主密码，随后才能关闭数据库加密。", comment: "AppLockSettings legacy database encryption footer")
            }
            return NSLocalizedString("已启用 SQLCipher。聊天、配置、记忆与向量数据库会使用独立主密码加密，密码仅保存在当前设备。", comment: "AppLockSettings database encryption enabled footer")
        }
        return NSLocalizedString("启用后将使用 SQLCipher 加密聊天、配置、记忆与向量数据库。请设置一个不同于系统锁屏密码的独立主密码。", comment: "AppLockSettings database encryption disabled footer")
    }

    // MARK: - 操作

    private func applySetPassword() {
        guard newPassword == confirmPassword else {
            errorMessage = NSLocalizedString("两次输入的密码不一致。", comment: "AppLockSettings password mismatch error")
            oldPasswordForChange = ""
            newPassword = ""
            confirmPassword = ""
            return
        }
        do {
            if appConfig.appLockEnabled {
                // 修改密码：必须验证旧密码，防止旁路认证攻击
                try lockManager.changePassword(old: oldPasswordForChange, new: newPassword)
                successMessage = NSLocalizedString("密码已更新。", comment: "AppLockSettings change success")
            } else {
                try lockManager.setPassword(newPassword)
                successMessage = NSLocalizedString("密码已设置，应用锁已开启。", comment: "AppLockSettings set success")
            }
            oldPasswordForChange = ""
            newPassword = ""
            confirmPassword = ""
            errorMessage = nil
            isSuccessAlertPresented = true
        } catch {
            errorMessage = error.localizedDescription
            oldPasswordForChange = ""
            newPassword = ""
            confirmPassword = ""
        }
    }

    private func applyDisable() {
        do {
            try lockManager.removePassword(currentPassword: currentPasswordForDisable)
            currentPasswordForDisable = ""
            errorMessage = nil
            successMessage = NSLocalizedString("应用锁已关闭。", comment: "AppLockSettings disabled success")
            isSuccessAlertPresented = true
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
            errorMessage = NSLocalizedString("两次输入的数据库主密码不一致。", comment: "AppLockSettings database password mismatch error")
            resetDatabasePasswordFields()
            return
        }

        let currentPassword = databaseCurrentPassword
        let newPassword = databaseNewPassword
        resetDatabasePasswordFields()
        isDatabaseOperationRunning = true

        Task {
            do {
                if !isDatabaseEncryptionEnabled {
                    try await DatabaseEncryptionManager.shared.enableEncryption(with: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库加密已开启。", comment: "AppLockSettings enable database encryption success")
                    }
                } else if usesLegacyDatabaseKey {
                    try await DatabaseEncryptionManager.shared.adoptLegacyAutomaticKey(with: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库主密码已设置。", comment: "AppLockSettings adopt database password success")
                    }
                } else {
                    try await DatabaseEncryptionManager.shared.changePassphrase(currentPassphrase: currentPassword, newPassphrase: newPassword)
                    await MainActor.run {
                        successMessage = NSLocalizedString("数据库主密码已更新。", comment: "AppLockSettings change database password success")
                    }
                }

                await MainActor.run {
                    refreshDatabaseEncryptionState()
                    errorMessage = nil
                    isDatabaseOperationRunning = false
                    isSuccessAlertPresented = true
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

        Task {
            do {
                try await DatabaseEncryptionManager.shared.disableEncryption(currentPassphrase: currentPassword)
                await MainActor.run {
                    refreshDatabaseEncryptionState()
                    errorMessage = nil
                    successMessage = NSLocalizedString("数据库加密已关闭。", comment: "AppLockSettings disable database encryption success")
                    isDatabaseOperationRunning = false
                    isSuccessAlertPresented = true
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
