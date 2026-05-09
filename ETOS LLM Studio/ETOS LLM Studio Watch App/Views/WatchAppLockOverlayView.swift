// ============================================================================
// WatchAppLockOverlayView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 应用锁覆盖视图（Phase E2 + E3）：
//   - 屏幕极小，仅展示锁定图标 + 简单提示 + 密码输入
//   - 若开启生物识别，自动触发认证
// ============================================================================

import SwiftUI
import Shared

struct WatchAppLockOverlayView: View {
    @StateObject private var lockManager = AppLockManager.shared
    @EnvironmentObject private var appConfig: AppConfigStore

    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        if lockManager.lockState == .locked {
            ZStack {
                Rectangle()
                    .fill(.black)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)

                        Text(NSLocalizedString("已锁定", comment: "WatchAppLock overlay title"))
                            .font(.headline)

                        // 密码输入
                        SecureField(
                            NSLocalizedString("密码", comment: "WatchAppLock password placeholder"),
                            text: $password
                        )
                        .textInputAutocapitalization(.never)
                        .onSubmit(unlockWithPassword)

                        if let msg = errorMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: unlockWithPassword) {
                            Text(NSLocalizedString("解锁", comment: "WatchAppLock unlock button"))
                        }
                        .disabled(password.isEmpty)

                        // 生物识别（E3）
                        if appConfig.appLockUseBiometrics {
                            Button(action: tryBiometric) {
                                Label(
                                    NSLocalizedString("生物识别", comment: "WatchAppLock biometric button"),
                                    systemImage: "faceid"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding()
                }
            }
            .task {
                if appConfig.appLockUseBiometrics {
                    await biometricUnlockIfPossible()
                }
            }
        }
    }

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
        do {
            try await lockManager.biometricUnlock()
            errorMessage = nil
        } catch {
            // 回退到密码输入，不显示生物识别错误
        }
    }
}
