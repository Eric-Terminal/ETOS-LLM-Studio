// ============================================================================
// AppLockOverlayView.swift
// ============================================================================
// ETOS LLM Studio (iOS)
//
// 应用锁覆盖视图（Phase E2 + E3）：
//   - 模糊背景 + 密码输入（SecureField）
//   - 若开启生物识别，自动触发 Face ID / Touch ID
//   - 生物识别失败后回退到密码输入
// ============================================================================

import SwiftUI
import Shared

struct AppLockOverlayView: View {
    @StateObject private var lockManager = AppLockManager.shared
    @EnvironmentObject private var appConfig: AppConfigStore

    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isBiometricTrying: Bool = false

    var body: some View {
        if lockManager.lockState == .locked {
            ZStack {
                // 模糊背景
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    // 图标
                    Image(systemName: "lock.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(NSLocalizedString("ETOS LLM Studio 已锁定", comment: "AppLock overlay title"))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        // 密码输入框
                        SecureField(
                            NSLocalizedString("输入密码", comment: "AppLock password placeholder"),
                            text: $password
                        )
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit(unlockWithPassword)

                        // 错误提示
                        if let msg = errorMessage {
                            Text(msg)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        // 解锁按钮
                        Button(action: unlockWithPassword) {
                            Text(NSLocalizedString("解锁", comment: "AppLock unlock button"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                    }
                    .padding(.horizontal)

                    // 生物识别按钮（E3）
                    if appConfig.appLockUseBiometrics {
                        Button(action: tryBiometric) {
                            Label(
                                NSLocalizedString("使用面容 ID / 触控 ID", comment: "AppLock biometric button"),
                                systemImage: "faceid"
                            )
                            .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBiometricTrying)
                    }
                }
                .padding(32)
                .frame(maxWidth: 360)
            }
            .task {
                // 视图出现时自动尝试生物识别（E3）
                if appConfig.appLockUseBiometrics {
                    await biometricUnlockIfPossible()
                }
            }
        }
    }

    // MARK: - 解锁操作

    private func unlockWithPassword() {
        guard !password.isEmpty else { return }
        do {
            try lockManager.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            password = ""
        }
    }

    private func tryBiometric() {
        Task { await biometricUnlockIfPossible() }
    }

    private func biometricUnlockIfPossible() async {
        isBiometricTrying = true
        defer { isBiometricTrying = false }
        do {
            try await lockManager.biometricUnlock()
            errorMessage = nil
        } catch {
            // 生物识别失败时不显示错误，回退到密码输入即可
        }
    }
}
