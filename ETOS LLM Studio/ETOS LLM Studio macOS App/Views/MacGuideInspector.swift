import ETOSCore
import SwiftUI

extension EnvironmentValues {
    @Entry var isGuideSettingsWindow = false
}

/// 弹窗拥有自己的向导入口，避免依赖被原生 sheet 挡住的父窗口工具栏。
struct MacGuideInspector: ViewModifier {
    private let presentation: Binding<Bool>?
    @State private var localPresentation = false
    @Environment(\.isGuideSettingsWindow) private var isSettingsWindow
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared

    init(presentation: Binding<Bool>? = nil) {
        self.presentation = presentation
    }

    func body(content: Content) -> some View {
        let isPresented = presentation ?? $localPresentation
        content
            .environment(\.feedbackGuidePresentation, isPresented)
            .toolbar {
                if !isSettingsWindow || configuration.guideOverlayEnabled || isPresented.wrappedValue {
                    Button { isPresented.wrappedValue.toggle() } label: {
                        Label(NSLocalizedString("使用助手", value: "App Guide", comment: "打开使用助手检查器"), systemImage: "sparkles")
                    }
                    .disabled(appLock.state == .locked)
                }
            }
            .inspector(isPresented: isPresented) {
                MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500)
            }
            .onChange(of: configuration.guideOverlayEnabled) { _, enabled in
                if isSettingsWindow && !enabled { isPresented.wrappedValue = false }
            }
            .overlay { if appLock.state == .locked { AppLockOverlayView() } }
    }
}
