import Combine
import SwiftUI
import ETOSCore

/// 首屏等待离线语言准备，切换语言时保留已创建的页面与导航状态。
struct WatchLocalizedContentView<Content: View>: View {
    @EnvironmentObject private var appConfig: AppConfigStore
    @StateObject private var languageController = CompressedAppLanguageController.shared
    @State private var systemLanguageRevision = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if languageController.state.isReady {
                content()
            } else {
                ProgressView()
            }
        }
        .environment(\.locale, languageController.state.locale)
        .onChange(of: languageController.state.language) { _, _ in
            // 现有页面通过配置观察者重取 NSLocalizedString；后台字典安装后再
            // 发出刷新信号，避免只在设置值改变、字典尚未就绪时重算一次。
            appConfig.objectWillChange.send()
        }
        .task(id: LanguageRequest(rawValue: appConfig.appLanguage, systemRevision: systemLanguageRevision)) {
            await languageController.prepare(rawValue: appConfig.appLanguage)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            if appConfig.appLanguage == AppLanguagePreference.system.rawValue {
                systemLanguageRevision += 1
            }
        }
    }

    private struct LanguageRequest: Equatable {
        let rawValue: String
        let systemRevision: Int
    }
}
