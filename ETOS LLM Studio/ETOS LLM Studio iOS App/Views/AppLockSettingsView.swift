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
                Section(NSLocalizedString("生物识别", comment: "AppLockSettings biometric section")) {
                    Toggle(
                        NSLocalizedString("使用面容 ID / 触控 ID", comment: "AppLockSettings biometric toggle"),
                        isOn: $appConfig.appLockUseBiometrics
                    )
                } footer: {
                    Text(NSLocalizedString("开启后，解锁时将优先使用生物识别，失败则回退至密码。", comment: "AppLockSettings biometric footer"))
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
        }
        .navigationTitle(NSLocalizedString("应用锁", comment: "AppLockSettings navigation title"))
        // 设置/修改密码弹窗
        .alert(
            appConfig.appLockEnabled
                ? NSLocalizedString("修改密码", comment: "AppLockSettings change password alert title")
                : NSLocalizedString("设置密码", comment: "AppLockSettings set password alert title"),
            isPresented: $isSetPasswordPresented
        ) {
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
        // 成功提示
        .alert(successMessage, isPresented: $isSuccessAlertPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        }
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
}
