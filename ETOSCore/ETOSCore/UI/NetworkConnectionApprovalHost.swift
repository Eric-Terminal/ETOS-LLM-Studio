import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(watchOS)
    import WatchKit
#elseif os(macOS)
    import AppKit
#endif

@MainActor
private struct NetworkConnectionApprovalHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = NetworkConnectionApprovalCenter.shared
    #if os(iOS)
        @State private var presentedAlert: UIAlertController?
    #elseif os(macOS)
        @State private var presentedAlert: NSAlert?
        @State private var presentedRequestID: UUID?
        @ObservedObject private var appLock = AppLockManager.shared
    #endif

    private var isPresentationActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive && appLock.state != .locked
        #else
        scenePhase == .active
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                center.setActive(isPresentationActive)
                #if os(macOS)
                presentCurrentRequest()
                #endif
            }
            .onChange(of: scenePhase) { _, _ in
                center.setActive(isPresentationActive)
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                center.setActive(isPresentationActive)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                center.setActive(false)
            }
            .onChange(of: appLock.state) { _, _ in center.setActive(isPresentationActive) }
            #endif
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
        #elseif os(macOS)
            guard let request = center.currentRequest else {
                if let alert = presentedAlert, let parent = alert.window.sheetParent {
                    parent.endSheet(alert.window, returnCode: .cancel)
                }
                presentedAlert = nil
                presentedRequestID = nil
                return
            }
            guard presentedRequestID != request.id else { return }
            guard let window = NSApplication.shared.keyWindow else {
                center.resolve(id: request.id, decision: .cancel)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = request.title
            alert.informativeText = request.message
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "取消连接"))
            alert.addButton(withTitle: NSLocalizedString("Continue Once", comment: "仅本次允许连接"))
            alert.addButton(withTitle: NSLocalizedString("Continue and Remember", comment: "允许连接并记住"))
            presentedAlert = alert
            presentedRequestID = request.id
            // 挂在实际前台窗口上，提供商或 MCP 编辑弹窗中的请求也能完成原生确认。
            let center = center
            alert.beginSheetModal(for: window) { [weak center] response in
                Task { @MainActor [weak center] in
                    let decision: NetworkConnectionDecision
                    switch response {
                    case .alertSecondButtonReturn: decision = .once
                    case .alertThirdButtonReturn: decision = .remember
                    default: decision = .cancel
                    }
                    center?.resolve(id: request.id, decision: decision)
                }
            }
        #elseif os(watchOS)
            guard let request = center.currentRequest else { return }
            guard let controller = WKApplication.shared().visibleInterfaceController else {
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
