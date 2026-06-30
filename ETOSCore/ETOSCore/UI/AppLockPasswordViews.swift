// ============================================================================
// AppLockPasswordViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用锁密码启用、关闭与更新表单。
// ============================================================================

import SwiftUI

struct AppLockEnableView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("密码", comment: ""), text: $password)
                    .textContentType(.newPassword)
                SecureField(NSLocalizedString("确认密码", comment: ""), text: $confirmation)
                    .textContentType(.newPassword)

                Button(NSLocalizedString("启用应用锁", comment: "")) {
                    enable()
                }
                .disabled(!canConfirm)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("密码", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("启用应用锁", comment: ""))
    }

    private var canConfirm: Bool {
        !password.isEmpty && password == confirmation
    }

    private func enable() {
        do {
            try lockManager.enable(password: password, confirmation: confirmation)
            onCompletion()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AppLockDisableView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var password = ""
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("当前密码", comment: ""), text: $password)
                    .textContentType(.password)

                Button(NSLocalizedString("关闭应用锁", comment: ""), role: .destructive) {
                    disable()
                }
                .disabled(password.isEmpty)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("密码", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("关闭应用锁", comment: ""))
    }

    private func disable() {
        do {
            try lockManager.disable(password: password)
            onCompletion()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AppLockUpdatePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("当前密码", comment: ""), text: $currentPassword)
                    .textContentType(.password)
                SecureField(NSLocalizedString("新密码", comment: ""), text: $newPassword)
                    .textContentType(.newPassword)
                SecureField(NSLocalizedString("确认新密码", comment: ""), text: $confirmation)
                    .textContentType(.newPassword)

                Button(NSLocalizedString("更新密码", comment: "")) {
                    updatePassword()
                }
                .disabled(!canConfirm)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("密码", comment: ""))
            } footer: {
                Text(NSLocalizedString("更新或关闭应用锁前需要输入当前密码。", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更新密码", comment: ""))
    }

    private var canConfirm: Bool {
        !currentPassword.isEmpty && !newPassword.isEmpty && newPassword == confirmation
    }

    private func updatePassword() {
        do {
            try lockManager.setPassword(
                currentPassword: currentPassword,
                newPassword: newPassword,
                confirmation: confirmation
            )
            onCompletion()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
