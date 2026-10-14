import ETOSCore
import SwiftUI

/// 弹窗拥有自己的向导入口，避免依赖被原生 sheet 挡住的父窗口工具栏。
struct MacGuideInspector: ViewModifier {
    @State private var isPresented = false
    @ObservedObject private var appLock = AppLockManager.shared

    func body(content: Content) -> some View {
        content
            .toolbar {
                Button { isPresented.toggle() } label: {
                    Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles")
                }
                .disabled(appLock.state == .locked)
            }
            .inspector(isPresented: $isPresented) {
                MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500)
            }
            .overlay { if appLock.state == .locked { AppLockOverlayView() } }
    }
}
