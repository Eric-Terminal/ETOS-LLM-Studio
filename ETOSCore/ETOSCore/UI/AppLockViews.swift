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

            lockContent
        }
        .onAppear {
            password = ""
            errorMessage = nil
            #if !os(watchOS)
            startBiometricUnlockIfNeeded()
            #endif
        }
    }

    private var lockContent: some View {
        VStack(spacing: lockContentSpacing) {
            lockHeader

            if lockManager.usesNumericPassword {
                numericPasswordDisplay
                errorText
                numericKeyboard
            } else {
                passwordField
                errorText
                biometricButton
                unlockButton
            }
        }
        .padding(.horizontal)
        .padding(.vertical, lockContentVerticalPadding)
        .frame(maxWidth: lockContentMaxWidth)
    }

    private var lockHeader: some View {
        VStack(spacing: lockHeaderSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: lockIconSize, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                Text(NSLocalizedString("ETOS LLM Studio 已锁定", comment: ""))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(NSLocalizedString("输入应用锁密码继续。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var passwordField: some View {
        SecureField(NSLocalizedString("密码", comment: ""), text: $password)
            .textContentType(.password)
            .submitLabel(.go)
            .onSubmit(unlock)
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var biometricButton: some View {
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
        #else
            EmptyView()
        #endif
    }

    private var unlockButton: some View {
        Button {
            unlock()
        } label: {
            Label(NSLocalizedString("解锁", comment: ""), systemImage: "lock.open")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(password.isEmpty)
    }

    private var numericPasswordDisplay: some View {
        Text(maskedNumericPassword)
            .font(.title3.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: numericPasswordDisplayHeight)
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.secondary.opacity(0.28), lineWidth: 1)
            }
    }

    private var numericKeyboard: some View {
        VStack(spacing: numericKeyboardSpacing) {
            ForEach(AppLockNumericKey.rows, id: \.self) { row in
                HStack(spacing: numericKeyboardSpacing) {
                    ForEach(row, id: \.self) { key in
                        numericKeyButton(for: key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func numericKeyButton(for key: AppLockNumericKey) -> some View {
        if key == .unlock {
            Button {
                handleNumericKey(key)
            } label: {
                numericKeyLabel(for: key)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)
        } else {
            Button {
                handleNumericKey(key)
            } label: {
                numericKeyLabel(for: key)
            }
            .buttonStyle(.bordered)
            .disabled(key.requiresPassword && password.isEmpty)
        }
    }

    @ViewBuilder
    private func numericKeyLabel(for key: AppLockNumericKey) -> some View {
        switch key {
        case .digit(let digit):
            Text(digit)
                .font(numericKeyFont)
                .frame(maxWidth: .infinity, minHeight: numericKeyHeight)
        case .delete:
            Image(systemName: "delete.left")
                .font(numericActionFont)
                .frame(maxWidth: .infinity, minHeight: numericKeyHeight)
                .accessibilityLabel(NSLocalizedString("删除", comment: ""))
        case .unlock:
            Image(systemName: "lock.open")
                .font(numericActionFont)
                .frame(maxWidth: .infinity, minHeight: numericKeyHeight)
                .accessibilityLabel(NSLocalizedString("解锁", comment: ""))
        }
    }

    private var maskedNumericPassword: String {
        guard !password.isEmpty else { return " " }
        return String(repeating: "•", count: min(password.count, 24))
    }

    private var lockContentSpacing: CGFloat {
        #if os(watchOS)
        lockManager.usesNumericPassword ? 8 : 14
        #else
        18
        #endif
    }

    private var lockHeaderSpacing: CGFloat {
        #if os(watchOS)
        lockManager.usesNumericPassword ? 4 : 8
        #else
        12
        #endif
    }

    private var lockIconSize: CGFloat {
        #if os(watchOS)
        lockManager.usesNumericPassword ? 20 : 36
        #else
        42
        #endif
    }

    private var lockContentVerticalPadding: CGFloat {
        #if os(watchOS)
        lockManager.usesNumericPassword ? 8 : 14
        #else
        16
        #endif
    }

    private var lockContentMaxWidth: CGFloat {
        #if os(watchOS)
        240
        #else
        lockManager.usesNumericPassword ? 320 : 360
        #endif
    }

    private var numericPasswordDisplayHeight: CGFloat {
        #if os(watchOS)
        28
        #else
        42
        #endif
    }

    private var numericKeyboardSpacing: CGFloat {
        #if os(watchOS)
        5
        #else
        8
        #endif
    }

    private var numericKeyHeight: CGFloat {
        #if os(watchOS)
        26
        #else
        44
        #endif
    }

    private var numericKeyFont: Font {
        #if os(watchOS)
        .headline
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var numericActionFont: Font {
        #if os(watchOS)
        .subheadline.weight(.semibold)
        #else
        .headline.weight(.semibold)
        #endif
    }

    private func handleNumericKey(_ key: AppLockNumericKey) {
        errorMessage = nil
        switch key {
        case .digit(let digit):
            password.append(digit)
        case .delete:
            guard !password.isEmpty else { return }
            password.removeLast()
        case .unlock:
            unlock()
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

private enum AppLockNumericKey: Hashable {
    case digit(String)
    case delete
    case unlock

    static let rows: [[AppLockNumericKey]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.delete, .digit("0"), .unlock]
    ]

    var requiresPassword: Bool {
        switch self {
        case .delete, .unlock:
            return true
        case .digit:
            return false
        }
    }
}

private struct AppLockOverlayLayerModifier: ViewModifier {
    @ObservedObject private var lockManager = AppLockManager.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if lockManager.state == .locked {
                    AppLockOverlayView()
                        .zIndex(1_000)
                }
            }
    }
}

public extension View {
    func appLockOverlayLayer() -> some View {
        modifier(AppLockOverlayLayerModifier())
    }
}

public struct AppLockSettingsView: View {
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var requestedDestination: AppLockSettingsDestination?
    @State private var successMessage: String?
    @State private var isShowingIntroDetails = false
    @State private var databaseEncryptionStateVersion = 0

    public init() {}

    public var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "应用锁",
                    summary: "保护本机界面，也可选择加密本机数据库文件。",
                    details: appLockIntroDetails,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("应用锁", comment: ""), isOn: appLockEnabledBinding)
                    .disabled(isManualDatabaseUnlockMode)

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
                Text(appLockFooterText)
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
                    Text(NSLocalizedString("离开后台超过所选时间后重新验证。", comment: ""))
                }
            }

            Section {
                Toggle(NSLocalizedString("数据库物理加密", comment: ""), isOn: databaseEncryptionEnabledBinding)

                if isDatabaseEncryptionEnabled {
                    Toggle(NSLocalizedString("在 Keychain 中记住数据库主密码", comment: ""), isOn: databaseEncryptionKeychainStorageBinding)

                    NavigationLink {
                        DatabaseEncryptionUpdatePassphraseView {
                            successMessage = NSLocalizedString("数据库主密码已更新。", comment: "")
                            databaseEncryptionStateVersion += 1
                        }
                    } label: {
                        Label(NSLocalizedString("更新数据库主密码", comment: ""), systemImage: "key")
                    }
                }
            } header: {
                Text(NSLocalizedString("数据库物理加密", comment: ""))
            } footer: {
                Text(databaseEncryptionFooterText)
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
                    databaseEncryptionStateVersion += 1
                    successMessage = NSLocalizedString("数据库物理加密已启用。", comment: "")
                }
            case .disableDatabaseEncryption:
                DatabaseEncryptionDisableView {
                    appConfig.databaseEncryptionEnabled = false
                    databaseEncryptionStateVersion += 1
                    successMessage = NSLocalizedString("数据库物理加密已关闭。", comment: "")
                }
            case .enableDatabaseKeychainStorage:
                DatabaseEncryptionKeychainStorageView(storesPassphraseInKeychain: true) {
                    appConfig.reloadFromPersistentStore()
                    databaseEncryptionStateVersion += 1
                    successMessage = NSLocalizedString("数据库主密码将保存到 Keychain。", comment: "")
                }
            case .disableDatabaseKeychainStorage:
                DatabaseEncryptionKeychainStorageView(storesPassphraseInKeychain: false) {
                    appConfig.reloadFromPersistentStore()
                    databaseEncryptionStateVersion += 1
                    lockManager.refreshState()
                    successMessage = NSLocalizedString("数据库主密码已改为仅保存在内存中。", comment: "")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .databaseEncryptionLockStateDidChange)) { _ in
            databaseEncryptionStateVersion += 1
            lockManager.refreshState()
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

    private var databaseEncryptionKeychainStorageBinding: Binding<Bool> {
        Binding(
            get: {
                _ = databaseEncryptionStateVersion
                return DatabaseEncryptionManager.shared.storesPassphraseInKeychain
            },
            set: { shouldStore in
                guard shouldStore != DatabaseEncryptionManager.shared.storesPassphraseInKeychain else { return }
                successMessage = nil
                requestedDestination = shouldStore ? .enableDatabaseKeychainStorage : .disableDatabaseKeychainStorage
            }
        )
    }

    private var isDatabaseEncryptionEnabled: Bool {
        _ = databaseEncryptionStateVersion
        return appConfig.databaseEncryptionEnabled || DatabaseEncryptionManager.shared.isDatabaseEncryptionEnabled
    }

    private var isManualDatabaseUnlockMode: Bool {
        _ = databaseEncryptionStateVersion
        return DatabaseEncryptionManager.shared.isManualUnlockModeEnabled
    }

    private var appLockFooterText: String {
        if isManualDatabaseUnlockMode {
            return NSLocalizedString("数据库主密码未保存到 Keychain 时，数据库解锁会接管本机界面保护，普通应用锁会暂时停用。", comment: "")
        }
        return NSLocalizedString("只影响这台设备，不随同步发送。", comment: "")
    }

    private var databaseEncryptionFooterText: String {
        if isManualDatabaseUnlockMode {
            return NSLocalizedString("当前不会把数据库主密码保存到 Keychain；冷启动时需要先输入主密码，验证成功后只暂存在内存中。", comment: "")
        }
        return NSLocalizedString("用于保护被离线提取的数据库文件。默认会把主密码保存在本机 Keychain 中，以便启动时自动解锁。", comment: "")
    }

    private var appLockIntroDetails: String {
        [
            NSLocalizedString("应用锁用于保护已经解锁设备上的 App 界面。开启后，回到前台或手动锁定时，需要输入应用锁密码；iOS 上可额外开启 Face ID / Touch ID，失败后仍能回退到密码。", comment: ""),
            NSLocalizedString("自动锁定只在应用进入后台后计时。选择“立即”会在每次离开后重新验证；选择更长时间则适合频繁切换应用的场景。", comment: ""),
            NSLocalizedString("数据库物理加密是另一层保护：它会把聊天、配置和记忆三处分库迁移为 SQLCipher 加密文件，主密码保存在本机 Keychain 中，用于启动时透明解锁。", comment: ""),
            NSLocalizedString("如果关闭 Keychain 保存，应用会在冷启动时要求输入数据库主密码；主密码验证通过后只暂存在当前进程内存里，数据库未解锁前不会启动聊天、同步或每日脉冲等数据访问任务。", comment: ""),
            NSLocalizedString("两者保护的对象不同：应用锁防止别人直接打开界面，数据库物理加密防止数据库文件被离线提取后读取。快照导出仍使用单独的导出密码，不会复用数据库主密码。", comment: ""),
            NSLocalizedString("应用锁和数据库主密码都只保存在本机，不会随 CloudKit、WatchConnectivity 或备份同步到其他设备。换设备使用时，需要在新设备上重新设置。", comment: "")
        ].joined(separator: "\n\n")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .font(.headline)
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "设置介绍卡片详情标题"))
            }
        }
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
            return NSLocalizedString("失败后仍可输入应用锁密码。", comment: "")
        }
        return NSLocalizedString("当前设备不可用生物识别。", comment: "")
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
    case enableDatabaseKeychainStorage
    case disableDatabaseKeychainStorage

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
        case .enableDatabaseKeychainStorage:
            return "enableDatabaseKeychainStorage"
        case .disableDatabaseKeychainStorage:
            return "disableDatabaseKeychainStorage"
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
