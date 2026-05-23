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
    #if !os(watchOS)
    @State private var hasAttemptedBiometricUnlock = false
    @State private var isBiometricUnlocking = false
    #endif

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

                #if !os(watchOS)
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
                #endif

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
            #if !os(watchOS)
            startBiometricUnlockIfNeeded()
            #endif
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

    #if !os(watchOS)
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
    #endif
}

public struct AppLockSettingsView: View {
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var requestedDestination: AppLockSettingsDestination?
    @State private var successMessage: String?

    public init() {}

    public var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("应用锁", comment: ""), isOn: appLockEnabledBinding)

                if lockManager.isEnabled {
                    NavigationLink {
                        AppLockUpdatePasswordView {
                            successMessage = NSLocalizedString("应用锁密码已更新。", comment: "")
                        }
                    } label: {
                        Label(NSLocalizedString("更新密码", comment: ""), systemImage: "key")
                    }

                    Button {
                        lockManager.lock()
                    } label: {
                        Label(NSLocalizedString("立即锁定", comment: ""), systemImage: "lock.fill")
                    }
                }
            } header: {
                Text(NSLocalizedString("应用锁", comment: ""))
            } footer: {
                Text(NSLocalizedString("应用锁只保护本机界面，不会随同步发送到其他设备。", comment: ""))
            }

            if lockManager.isEnabled {
                #if !os(watchOS)
                    Section {
                        Toggle(NSLocalizedString("生物识别解锁", comment: ""), isOn: biometricBinding)
                            .disabled(!lockManager.canEvaluateBiometrics())
                    } header: {
                        Text(NSLocalizedString("生物识别", comment: ""))
                    } footer: {
                        Text(biometricFooterText)
                    }
                #endif

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
            }

            Section {
                Toggle(NSLocalizedString("数据库物理加密", comment: ""), isOn: databaseEncryptionEnabledBinding)

                if isDatabaseEncryptionEnabled {
                    NavigationLink {
                        DatabaseEncryptionUpdatePassphraseView {
                            successMessage = NSLocalizedString("数据库主密码已更新。", comment: "")
                        }
                    } label: {
                        Label(NSLocalizedString("更新数据库主密码", comment: ""), systemImage: "key")
                    }
                }
            } header: {
                Text(NSLocalizedString("数据库物理加密", comment: ""))
            } footer: {
                Text(NSLocalizedString("启用后，三处分库会使用独立主密码通过 SQLCipher 加密；主密码会保存在本机 Keychain 中，用于应用启动时透明解锁。它主要防止数据库文件被离线提取；若要防范已解锁设备上的直接访问，请同时启用应用锁。快照导出仍使用单独的快照密码。", comment: ""))
            }

            if let successMessage {
                Section {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用锁", comment: ""))
        .onAppear {
            lockManager.refreshState()
        }
        .navigationDestination(item: $requestedDestination) { destination in
            switch destination {
            case .enableAppLock:
                AppLockEnableView {
                    successMessage = NSLocalizedString("应用锁已启用。", comment: "")
                }
            case .disableAppLock:
                AppLockDisableView {
                    successMessage = NSLocalizedString("应用锁已关闭。", comment: "")
                }
            case .enableDatabaseEncryption:
                DatabaseEncryptionEnableView {
                    appConfig.databaseEncryptionEnabled = true
                    successMessage = NSLocalizedString("数据库物理加密已启用。", comment: "")
                }
            case .disableDatabaseEncryption:
                DatabaseEncryptionDisableView {
                    appConfig.databaseEncryptionEnabled = false
                    successMessage = NSLocalizedString("数据库物理加密已关闭。", comment: "")
                }
            }
        }
    }

    private var appLockEnabledBinding: Binding<Bool> {
        Binding(
            get: { lockManager.isEnabled },
            set: { isEnabled in
                guard isEnabled != lockManager.isEnabled else { return }
                successMessage = nil
                requestedDestination = isEnabled ? .enableAppLock : .disableAppLock
            }
        )
    }

    private var databaseEncryptionEnabledBinding: Binding<Bool> {
        Binding(
            get: { isDatabaseEncryptionEnabled },
            set: { isEnabled in
                guard isEnabled != isDatabaseEncryptionEnabled else { return }
                successMessage = nil
                requestedDestination = isEnabled ? .enableDatabaseEncryption : .disableDatabaseEncryption
            }
        )
    }

    private var isDatabaseEncryptionEnabled: Bool {
        appConfig.databaseEncryptionEnabled || DatabaseEncryptionManager.shared.hasStoredPassphrase
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { lockManager.timeoutSeconds },
            set: { lockManager.setTimeout(seconds: $0) }
        )
    }

    #if !os(watchOS)
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
    #endif

    private var timeoutOptions: [(seconds: Int, title: String)] {
        [
            (0, NSLocalizedString("立即", comment: "")),
            (60, NSLocalizedString("1 分钟", comment: "")),
            (300, NSLocalizedString("5 分钟", comment: "")),
            (900, NSLocalizedString("15 分钟", comment: "")),
            (3_600, NSLocalizedString("1 小时", comment: ""))
        ]
    }
}

private enum AppLockSettingsDestination: Hashable, Identifiable {
    case enableAppLock
    case disableAppLock
    case enableDatabaseEncryption
    case disableDatabaseEncryption

    var id: String {
        switch self {
        case .enableAppLock:
            return "enableAppLock"
        case .disableAppLock:
            return "disableAppLock"
        case .enableDatabaseEncryption:
            return "enableDatabaseEncryption"
        case .disableDatabaseEncryption:
            return "disableDatabaseEncryption"
        }
    }
}

private struct AppLockEnableView: View {
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

private struct AppLockDisableView: View {
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

private struct AppLockUpdatePasswordView: View {
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

private struct DatabaseEncryptionEnableView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isMigrating = false
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("数据库主密码", comment: ""), text: $passphrase)
                    .textContentType(.newPassword)
                SecureField(NSLocalizedString("确认数据库主密码", comment: ""), text: $confirmation)
                    .textContentType(.newPassword)

                Button(NSLocalizedString("启用数据库物理加密", comment: "")) {
                    enableEncryption()
                }
                .disabled(isMigrating || !canConfirm)

                if isMigrating {
                    ProgressView(NSLocalizedString("正在迁移数据库…", comment: ""))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("数据库主密码", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("启用数据库物理加密", comment: ""))
    }

    private var canConfirm: Bool {
        !passphrase.isEmpty && passphrase == confirmation
    }

    private func enableEncryption() {
        let passphrase = passphrase
        let confirmation = confirmation
        runMigration {
            try Persistence.enableDatabaseEncryption(
                passphrase: passphrase,
                confirmation: confirmation
            )
        }
    }

    private func runMigration(operation: @escaping @Sendable () throws -> Void) {
        guard !isMigrating else { return }
        isMigrating = true
        errorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                await MainActor.run {
                    errorMessage = nil
                    appConfig.reloadFromPersistentStore()
                    isMigrating = false
                    onCompletion()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isMigrating = false
                }
            }
        }
    }
}

private struct DatabaseEncryptionDisableView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var currentPassphrase = ""
    @State private var isMigrating = false
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("当前主密码", comment: ""), text: $currentPassphrase)
                    .textContentType(.password)

                Button(NSLocalizedString("关闭数据库物理加密", comment: ""), role: .destructive) {
                    disableEncryption()
                }
                .disabled(isMigrating || currentPassphrase.isEmpty)

                if isMigrating {
                    ProgressView(NSLocalizedString("正在迁移数据库…", comment: ""))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("数据库主密码", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("关闭数据库物理加密", comment: ""))
    }

    private func disableEncryption() {
        let currentPassphrase = currentPassphrase
        runMigration {
            try Persistence.removeDatabaseEncryption(passphrase: currentPassphrase)
        }
    }

    private func runMigration(operation: @escaping @Sendable () throws -> Void) {
        guard !isMigrating else { return }
        isMigrating = true
        errorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                await MainActor.run {
                    errorMessage = nil
                    appConfig.reloadFromPersistentStore()
                    isMigrating = false
                    onCompletion()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isMigrating = false
                }
            }
        }
    }
}

private struct DatabaseEncryptionUpdatePassphraseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var currentPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmation = ""
    @State private var isMigrating = false
    @State private var errorMessage: String?
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("当前主密码", comment: ""), text: $currentPassphrase)
                    .textContentType(.password)
                SecureField(NSLocalizedString("新主密码", comment: ""), text: $newPassphrase)
                    .textContentType(.newPassword)
                SecureField(NSLocalizedString("确认新主密码", comment: ""), text: $confirmation)
                    .textContentType(.newPassword)

                Button(NSLocalizedString("更新数据库主密码", comment: "")) {
                    updatePassphrase()
                }
                .disabled(isMigrating || !canConfirm)

                if isMigrating {
                    ProgressView(NSLocalizedString("正在迁移数据库…", comment: ""))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("数据库主密码", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更新数据库主密码", comment: ""))
    }

    private var canConfirm: Bool {
        !currentPassphrase.isEmpty && !newPassphrase.isEmpty && newPassphrase == confirmation
    }

    private func updatePassphrase() {
        let currentPassphrase = currentPassphrase
        let newPassphrase = newPassphrase
        let confirmation = confirmation
        runMigration {
            try Persistence.updateDatabaseEncryptionPassphrase(
                currentPassphrase: currentPassphrase,
                newPassphrase: newPassphrase,
                confirmation: confirmation
            )
        }
    }

    private func runMigration(operation: @escaping @Sendable () throws -> Void) {
        guard !isMigrating else { return }
        isMigrating = true
        errorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                await MainActor.run {
                    errorMessage = nil
                    appConfig.reloadFromPersistentStore()
                    isMigrating = false
                    onCompletion()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isMigrating = false
                }
            }
        }
    }
}
