// ============================================================================
// AppLockWindowPresenter.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 用独立高层级 UIWindow 承载应用锁，确保它盖过设置页、Sheet 与键盘。
// ============================================================================

import Combine
import SwiftUI
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
@MainActor
final class AppLockWindowPresenter: ObservableObject {
    private var cancellables: Set<AnyCancellable> = []
    private var lockWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    init() {
        AppLockManager.shared.$state
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncWindowVisibility()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncWindowVisibility()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncWindowVisibility()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.discardDisconnectedWindowIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    func install() {
        syncWindowVisibility()
    }

    private func syncWindowVisibility() {
        guard AppLockManager.shared.state == .locked else {
            hideWindow(restoreKeyWindow: true)
            return
        }
        guard let scene = activeWindowScene() else { return }
        showWindow(in: scene)
    }

    private func showWindow(in scene: UIWindowScene) {
        if lockWindow?.windowScene !== scene {
            hideWindow(restoreKeyWindow: false)
            lockWindow = makeLockWindow(in: scene)
        }

        guard let lockWindow else { return }
        if lockWindow.isHidden {
            previousKeyWindow = scene.windows.first { window in
                window.isKeyWindow && window !== lockWindow
            }
        }
        lockWindow.makeKeyAndVisible()
    }

    private func hideWindow(restoreKeyWindow: Bool) {
        guard let lockWindow else { return }
        lockWindow.isHidden = true

        if restoreKeyWindow,
           let previousKeyWindow,
           !previousKeyWindow.isHidden {
            previousKeyWindow.makeKey()
        }
        self.previousKeyWindow = nil
    }

    private func discardDisconnectedWindowIfNeeded() {
        guard let lockWindow,
              lockWindow.windowScene?.activationState == .unattached else {
            syncWindowVisibility()
            return
        }
        hideWindow(restoreKeyWindow: false)
        self.lockWindow = nil
    }

    private func makeLockWindow(in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        let hostingController = UIHostingController(rootView: AppLockWindowRootView())
        hostingController.view.backgroundColor = .clear
        hostingController.view.accessibilityViewIsModal = true

        window.rootViewController = hostingController
        window.backgroundColor = .clear
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        return window
    }

    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }
}

private struct AppLockWindowRootView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        AppLockOverlayView()
            .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage))
    }
}
#endif
