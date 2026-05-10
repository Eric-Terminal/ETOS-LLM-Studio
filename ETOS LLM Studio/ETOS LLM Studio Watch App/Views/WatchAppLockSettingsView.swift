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
    @State private var oldPasswordForChange: String = ""
    @State private var currentPasswordForDisable: String = ""
    @State private var errorMessage: String?
    @State private var isSetPasswordPresented: Bool = false
    @State private var isDisablePresented: Bool = false
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
        // 设置/修改密码弹窗
        .alert(appLockPasswordAlertTitle, isPresented: $isSetPasswordPresented) {
            if appConfig.appLockEnabled {
                SecureField(NSLocalizedString("当前密码", comment: "WatchAppLockSettings current password field for change"), text: $oldPasswordForChange)
            }
            SecureField(NSLocalizedString("新密码", comment: "WatchAppLockSettings new password field"), text: $newPassword)
            SecureField(NSLocalizedString("确认密码", comment: "WatchAppLockSettings confirm password field"), text: $confirmPassword)
            Button(NSLocalizedString("确定", comment: ""), action: applySetPassword)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                oldPasswordForChange = ""
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
    }

    private var appLockPasswordAlertTitle: String {
        appConfig.appLockEnabled
            ? NSLocalizedString("修改密码", comment: "WatchAppLockSettings change password alert title")
            : NSLocalizedString("设置密码", comment: "WatchAppLockSettings set password alert title")
    }

    // MARK: - 操作

    private func applySetPassword() {
        guard newPassword == confirmPassword else {
            errorMessage = NSLocalizedString("两次输入的密码不一致。", comment: "WatchAppLockSettings password mismatch error")
            oldPasswordForChange = ""
            newPassword = ""
            confirmPassword = ""
            return
        }
        do {
            if appConfig.appLockEnabled {
                try lockManager.changePassword(old: oldPasswordForChange, new: newPassword)
                successMessage = NSLocalizedString("密码已更新。", comment: "WatchAppLockSettings change success")
            } else {
                try lockManager.setPassword(newPassword)
                successMessage = NSLocalizedString("密码已设置，应用锁已开启。", comment: "WatchAppLockSettings set success")
            }
            oldPasswordForChange = ""
            newPassword = ""
            confirmPassword = ""
            errorMessage = nil
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
            successMessage = NSLocalizedString("应用锁已关闭。", comment: "WatchAppLockSettings disabled success")
        } catch {
            errorMessage = error.localizedDescription
            currentPasswordForDisable = ""
        }
    }
}
