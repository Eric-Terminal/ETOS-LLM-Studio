import SwiftUI

private struct BatchTaskLifecycle: ViewModifier {
    let isReady: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appLock = AppLockManager.shared

    private var active: Bool { isReady && scenePhase == .active && appLock.state != .locked }

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            // 仅在前台运行；退出、锁定或系统挂起取消等待，不申请额外后台保活。
            while !Task.isCancelled {
                await BatchService.shared.refreshPending()
                do { try await Task.sleep(for: .seconds(120)) }
                catch { return }
            }
        }
    }
}

public extension View {
    func batchTaskLifecycle(isReady: Bool) -> some View { modifier(BatchTaskLifecycle(isReady: isReady)) }
}
