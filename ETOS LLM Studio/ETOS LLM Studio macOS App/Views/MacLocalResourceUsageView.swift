import ETOSCore
import SwiftUI

/// 仅在前台聊天窗口的本地模型面板可见时采样，离开窗口或关闭开关即取消。
struct MacLocalResourceUsageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var text = ""

    var body: some View {
        if scenePhase == .active && controlActiveState == .key && appLock.state != .locked {
            Text(text.isEmpty ? NSLocalizedString("正在读取本机资源", comment: "") : text)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal)
                .task(id: configuration.appLanguage) {
                    text = ""
                    let monitor = await Task.detached(priority: .utility) { LocalResourceUsageMonitor() }.value
                    while !Task.isCancelled {
                        await monitor.refresh()
                        let snapshot = monitor.snapshot
                        let label = await Task.detached(priority: .utility) { snapshot.displayText }.value
                        guard !Task.isCancelled else { return }
                        text = label
                        do { try await Task.sleep(for: .seconds(2)) }
                        catch { return }
                    }
                }
        }
    }
}
