// ============================================================================
// AppLockViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS/watchOS 复用的应用锁覆盖层与设置视图。
// ============================================================================

import SwiftUI

public struct AppLockOverlayView: View {
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var hasAttemptedBiometricUnlock = false
    @State private var isBiometricUnlocking = false

    public init() {}

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.primary)

                VStack(spacing: 6) {
                    Text(NSLocalizedString("ETOS LLM Studio 已锁定", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("输入应用锁密码继续。", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                SecureField(NSLocalizedString("密码", comment: ""), text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(unlock)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if lockManager.isBiometricEnabled {
                    Button {
                        startBiometricUnlock()
                    } label: {
                        Label(NSLocalizedString("使用生物识别", comment: ""), systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBiometricUnlocking)
                }

                Button {
                    unlock()
                } label: {
                    Label(NSLocalizedString("解锁", comment: ""), systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            }
            .padding()
            .frame(maxWidth: 360)
        }
        .onAppear {
            password = ""
            errorMessage = nil
            startBiometricUnlockIfNeeded()
        }
    }

    private func unlock() {
        do {
            try lockManager.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startBiometricUnlockIfNeeded() {
        guard lockManager.isBiometricEnabled, !hasAttemptedBiometricUnlock else { return }
        hasAttemptedBiometricUnlock = true
        startBiometricUnlock()
    }

    private func startBiometricUnlock() {
        guard !isBiometricUnlocking else { return }
        isBiometricUnlocking = true
        Task { @MainActor in
            defer { isBiometricUnlocking = false }
            do {
                try await lockManager.biometricUnlock()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

public struct AppLockSettingsView: View {
    @ObservedObject private var lockManager = AppLockManager.shared
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?

    public init() {}

    public var body: some View {
        List {
            Section {
                if lockManager.isEnabled {
                    statusRow(
                        title: NSLocalizedString("状态", comment: ""),
                        value: NSLocalizedString("已启用", comment: ""),
                        systemImage: "lock.fill"
                    )

                    Button(NSLocalizedString("立即锁定", comment: "")) {
                        lockManager.lock()
                    }

                    Button(NSLocalizedString("关闭应用锁", comment: ""), role: .destructive) {
                        disable()
                    }
                } else {
                    statusRow(
                        title: NSLocalizedString("状态", comment: ""),
                        value: NSLocalizedString("未启用", comment: ""),
                        systemImage: "lock.open"
                    )
                }
            } header: {
                Text(NSLocalizedString("应用锁", comment: ""))
            } footer: {
                Text(NSLocalizedString("应用锁只保护本机界面，不会随同步发送到其他设备。", comment: ""))
            }

            if lockManager.isEnabled {
                Section {
                    Toggle(NSLocalizedString("生物识别解锁", comment: ""), isOn: biometricBinding)
                        .disabled(!lockManager.canEvaluateBiometrics())
                } header: {
                    Text(NSLocalizedString("生物识别", comment: ""))
                } footer: {
                    Text(biometricFooterText)
                }
            }

            Section {
                if lockManager.isEnabled {
                    SecureField(NSLocalizedString("当前密码", comment: ""), text: $currentPassword)
                        .textContentType(.password)
                }
                SecureField(NSLocalizedString("新密码", comment: ""), text: $newPassword)
                    .textContentType(.newPassword)
                SecureField(NSLocalizedString("确认新密码", comment: ""), text: $confirmation)
                    .textContentType(.newPassword)

                Button(lockManager.isEnabled ? NSLocalizedString("更新密码", comment: "") : NSLocalizedString("启用应用锁", comment: "")) {
                    savePassword()
                }
                .disabled(newPassword.isEmpty || confirmation.isEmpty || (lockManager.isEnabled && currentPassword.isEmpty))
            } header: {
                Text(NSLocalizedString("密码", comment: ""))
            }

            Section {
                Picker(NSLocalizedString("后台后锁定", comment: ""), selection: timeoutBinding) {
                    ForEach(timeoutOptions, id: \.seconds) { option in
                        Text(option.title).tag(option.seconds)
                    }
                }
            } header: {
                Text(NSLocalizedString("自动锁定", comment: ""))
            } footer: {
                Text(NSLocalizedString("应用进入后台并超过所选时间后，回到前台会要求重新输入应用锁密码。", comment: ""))
            }

            if let successMessage {
                Section {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用锁", comment: ""))
        .onAppear {
            lockManager.refreshState()
        }
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { lockManager.timeoutSeconds },
            set: { lockManager.setTimeout(seconds: $0) }
        )
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { lockManager.isBiometricEnabled },
            set: { lockManager.setBiometricEnabled($0) }
        )
    }

    private var biometricFooterText: String {
        if lockManager.canEvaluateBiometrics() {
            return NSLocalizedString("开启后可使用 Face ID、Touch ID 或设备支持的生物识别解锁；失败后仍可输入应用锁密码。", comment: "")
        }
        return NSLocalizedString("当前设备未启用或不支持生物识别，请继续使用应用锁密码。", comment: "")
    }

    private var timeoutOptions: [(seconds: Int, title: String)] {
        [
            (0, NSLocalizedString("立即", comment: "")),
            (60, NSLocalizedString("1 分钟", comment: "")),
            (300, NSLocalizedString("5 分钟", comment: "")),
            (900, NSLocalizedString("15 分钟", comment: "")),
            (3_600, NSLocalizedString("1 小时", comment: ""))
        ]
    }

    private func savePassword() {
        do {
            if lockManager.isEnabled {
                try lockManager.setPassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword,
                    confirmation: confirmation
                )
                successMessage = NSLocalizedString("应用锁密码已更新。", comment: "")
            } else {
                try lockManager.enable(password: newPassword, confirmation: confirmation)
                successMessage = NSLocalizedString("应用锁已启用。", comment: "")
            }
            clearPasswords()
            errorMessage = nil
        } catch {
            successMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func disable() {
        do {
            try lockManager.disable()
            clearPasswords()
            errorMessage = nil
            successMessage = NSLocalizedString("应用锁已关闭。", comment: "")
        } catch {
            successMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func clearPasswords() {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
