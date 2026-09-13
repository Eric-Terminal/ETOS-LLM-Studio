import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(watchOS)
    import WatchKit
#endif

@MainActor
private struct NetworkConnectionApprovalHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = NetworkConnectionApprovalCenter.shared
    #if os(iOS)
        @State private var presentedAlert: UIAlertController?
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear { center.setActive(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                center.setActive(phase == .active)
            }
            .onChange(of: center.currentRequest?.id) { _, _ in presentCurrentRequest() }
            .alert(
                NSLocalizedString("Unable to save exception", comment: "网络例外保存失败标题"),
                isPresented: Binding(
                    get: { center.persistenceFailure },
                    set: { if !$0 { center.clearPersistenceFailure() } }
                )
            ) {
                Button(NSLocalizedString("OK", comment: "确认按钮"), role: .cancel) { center.clearPersistenceFailure() }
            } message: {
                Text(NetworkConnectionSecurityError.persistenceFailed.localizedDescription)
            }
    }

    private func presentCurrentRequest() {
        #if os(iOS)
            guard let request = center.currentRequest else {
                presentedAlert?.dismiss(animated: true)
                presentedAlert = nil
                return
            }
            let alert = UIAlertController(title: request.title, message: request.message, preferredStyle: .alert)
            let choices: [(String, NetworkConnectionDecision)] = [
                (NSLocalizedString("Cancel", comment: "取消连接"), .cancel),
                (NSLocalizedString("Continue Once", comment: "仅本次允许连接"), .once),
                (NSLocalizedString("Continue and Remember", comment: "允许连接并记住"), .remember),
            ]
            for (title, decision) in choices {
                alert.addAction(
                    UIAlertAction(title: title, style: decision == .cancel ? .cancel : .default) { _ in
                        center.resolve(id: request.id, decision: decision)
                    })
            }
            // 从当前可见控制器展示，提供商编辑器等 sheet 内发起请求时也能看到确认。
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows).first { $0.isKeyWindow }
            var controller = window?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            guard let controller else {
                center.resolve(id: request.id, decision: .cancel)
                return
            }
            if controller is UIAlertController {
                // 不抢占其他正在等待用户决定的原生提示。
                center.resolve(id: request.id, decision: .cancel)
                return
            }
            presentedAlert = alert
            controller.present(alert, animated: true)
        #elseif os(watchOS)
            guard let request = center.currentRequest else { return }
            guard let controller = WKExtension.shared().visibleInterfaceController else {
                center.resolve(id: request.id, decision: .cancel)
                return
            }
            controller.presentAlert(
                withTitle: request.title, message: request.message, preferredStyle: .alert,
                actions: [
                    WKAlertAction(title: NSLocalizedString("Cancel", comment: "取消连接"), style: .cancel) {
                        Task { @MainActor in center.resolve(id: request.id, decision: .cancel) }
                    },
                    WKAlertAction(title: NSLocalizedString("Continue Once", comment: "仅本次允许连接"), style: .default) {
                        Task { @MainActor in center.resolve(id: request.id, decision: .once) }
                    },
                    WKAlertAction(
                        title: NSLocalizedString("Continue and Remember", comment: "允许连接并记住"), style: .default
                    ) {
                        Task { @MainActor in center.resolve(id: request.id, decision: .remember) }
                    },
                ])
        #endif
    }
}

@MainActor
extension View {
    public func networkConnectionApprovalHost() -> some View {
        modifier(NetworkConnectionApprovalHost())
    }
}
