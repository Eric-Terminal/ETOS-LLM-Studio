// ============================================================================
// AppLockManagerTests.swift
// ============================================================================
// 应用级锁状态机测试。
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("应用锁状态机测试")
@MainActor
struct AppLockManagerTests {
    @Test("启用应用锁后需要正确密码才能解锁")
    func testEnableAndUnlock() throws {
        let backup = backupAppLockConfig()
        defer { restoreAppLockConfig(backup) }

        let store = InMemoryAppLockCredentialStore()
        let manager = AppLockManager(credentialStore: store)

        try manager.enable(password: "passcode", confirmation: "passcode")

        #expect(AppConfigStore.shared.appLockEnabled == true)
        #expect(manager.state == .unlocked)

        manager.lock()
        #expect(manager.state == .locked)
        #expect(throws: AppLockManager.AppLockError.invalidPassword) {
            try manager.unlock(password: "wrong")
        }

        try manager.unlock(password: "passcode")
        #expect(manager.state == .unlocked)
    }

    @Test("设置密码会拒绝空密码与确认不一致")
    func testEnableValidatesPassword() {
        let backup = backupAppLockConfig()
        defer { restoreAppLockConfig(backup) }

        let manager = AppLockManager(credentialStore: InMemoryAppLockCredentialStore())

        #expect(throws: AppLockManager.AppLockError.emptyPassword) {
            try manager.enable(password: "", confirmation: "")
        }
        #expect(throws: AppLockManager.AppLockError.passwordMismatch) {
            try manager.enable(password: "one", confirmation: "two")
        }
        #expect(AppConfigStore.shared.appLockEnabled == false)
        #expect(manager.state == .disabled)
    }

    @Test("后台超过超时时间后会重新锁定")
    func testBackgroundTimeoutLocksApp() throws {
        let backup = backupAppLockConfig()
        defer { restoreAppLockConfig(backup) }

        var currentDate = Date(timeIntervalSince1970: 1_000)
        let manager = AppLockManager(
            credentialStore: InMemoryAppLockCredentialStore(),
            now: { currentDate }
        )
        try manager.enable(password: "passcode", confirmation: "passcode")
        manager.setTimeout(seconds: 10)

        manager.handleSceneDidEnterBackground()
        currentDate = Date(timeIntervalSince1970: 1_009)
        manager.handleSceneDidBecomeActive()
        #expect(manager.state == .unlocked)

        manager.handleSceneDidEnterBackground()
        currentDate = Date(timeIntervalSince1970: 1_020)
        manager.handleSceneDidBecomeActive()
        #expect(manager.state == .locked)
    }

    @Test("禁用应用锁会删除凭据并进入 disabled")
    func testDisableDeletesCredential() throws {
        let backup = backupAppLockConfig()
        defer { restoreAppLockConfig(backup) }

        let store = InMemoryAppLockCredentialStore()
        let manager = AppLockManager(credentialStore: store)
        try manager.enable(password: "passcode", confirmation: "passcode")

        try manager.disable()

        #expect(AppConfigStore.shared.appLockEnabled == false)
        #expect(manager.state == .disabled)
        #expect(store.loadCredential() == nil)
    }

    @Test("应用锁设置不会进入 AppConfig 同步快照")
    func testAppLockSettingsAreLocalOnly() {
        let backup = backupAppLockConfig()
        defer { restoreAppLockConfig(backup) }

        AppConfigStore.shared.appLockEnabled = true
        AppConfigStore.shared.appLockTimeoutSeconds = 60

        let snapshot = AppConfigStore.shared.snapshot()

        #expect(snapshot[AppConfigKey.appLockEnabled.rawValue] == nil)
        #expect(snapshot[AppConfigKey.appLockTimeoutSeconds.rawValue] == nil)
    }

    private func backupAppLockConfig() -> (enabled: Bool, timeout: Int) {
        (
            enabled: AppConfigStore.shared.appLockEnabled,
            timeout: AppConfigStore.shared.appLockTimeoutSeconds
        )
    }

    private func restoreAppLockConfig(_ backup: (enabled: Bool, timeout: Int)) {
        AppConfigStore.shared.appLockEnabled = backup.enabled
        AppConfigStore.shared.appLockTimeoutSeconds = backup.timeout
    }
}

private final class InMemoryAppLockCredentialStore: AppLockCredentialStore {
    private var credential: AppLockCredentialRecord?

    func loadCredential() -> AppLockCredentialRecord? {
        credential
    }

    func saveCredential(_ credential: AppLockCredentialRecord) -> Bool {
        self.credential = credential
        return true
    }

    func deleteCredential() -> Bool {
        credential = nil
        return true
    }
}
