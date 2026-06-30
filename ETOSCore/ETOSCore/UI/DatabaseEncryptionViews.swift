// ============================================================================
// DatabaseEncryptionViews.swift
// ============================================================================
// ETOS LLM Studio
//
// SQLCipher 数据库解锁与主密码存储策略界面。
// ============================================================================

import SwiftUI

public struct DatabaseUnlockOverlayView: View {
    @State private var passphrase = ""
    @State private var errorMessage: String?
    @State private var isUnlocking = false
    private let onUnlocked: () -> Void

    public init(onUnlocked: @escaping () -> Void) {
        self.onUnlocked = onUnlocked
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "externaldrive.badge.key")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.primary)

                VStack(spacing: 6) {
                    Text(NSLocalizedString("数据库已锁定", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("输入数据库主密码以解锁本机数据。", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                SecureField(NSLocalizedString("数据库主密码", comment: ""), text: $passphrase)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(unlock)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    unlock()
                } label: {
                    Label(NSLocalizedString("解锁数据库", comment: ""), systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(passphrase.isEmpty || isUnlocking)

                if isUnlocking {
                    ProgressView(NSLocalizedString("正在验证数据库主密码…", comment: ""))
                }
            }
            .padding()
            .frame(maxWidth: 360)
        }
        .onAppear {
            passphrase = ""
            errorMessage = nil
        }
    }

    private func unlock() {
        guard !passphrase.isEmpty, !isUnlocking else { return }
        let passphrase = passphrase
        isUnlocking = true
        errorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DatabaseEncryptionManager.shared.unlockWithPassphrase(passphrase)
                }.value
                await MainActor.run {
                    self.passphrase = ""
                    isUnlocking = false
                    onUnlocked()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isUnlocking = false
                }
            }
        }
    }
}

struct DatabaseEncryptionKeychainStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassphrase = ""
    @State private var isUpdating = false
    @State private var errorMessage: String?
    let storesPassphraseInKeychain: Bool
    let onCompletion: () -> Void

    var body: some View {
        List {
            Section {
                SecureField(NSLocalizedString("当前主密码", comment: ""), text: $currentPassphrase)
                    .textContentType(.password)

                Button(actionTitle) {
                    updateStoragePolicy()
                }
                .disabled(isUpdating || currentPassphrase.isEmpty)

                if isUpdating {
                    ProgressView(NSLocalizedString("正在验证数据库主密码…", comment: ""))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("数据库主密码", comment: ""))
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        storesPassphraseInKeychain
            ? NSLocalizedString("记住数据库主密码", comment: "")
            : NSLocalizedString("关闭 Keychain 保存", comment: "")
    }

    private var actionTitle: String {
        storesPassphraseInKeychain
            ? NSLocalizedString("保存到 Keychain", comment: "")
            : NSLocalizedString("仅保存在内存", comment: "")
    }

    private var footerText: String {
        storesPassphraseInKeychain
            ? NSLocalizedString("启用后，应用会从 Keychain 读取数据库主密码并自动解锁 SQLCipher 数据库。", comment: "")
            : NSLocalizedString("关闭后，数据库主密码不会继续保存在 Keychain；冷启动时需要手动输入，验证通过后只暂存在当前进程内存中。", comment: "")
    }

    private func updateStoragePolicy() {
        let currentPassphrase = currentPassphrase
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DatabaseEncryptionManager.shared.setStoresPassphraseInKeychain(
                        storesPassphraseInKeychain,
                        verificationPassphrase: currentPassphrase
                    )
                }.value
                await MainActor.run {
                    isUpdating = false
                    onCompletion()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isUpdating = false
                }
            }
        }
    }
}
