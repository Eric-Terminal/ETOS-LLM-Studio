#if os(macOS)
import AppKit

/// 聊天窗口和设置窗口共用一个承载者，避免同一审批被多个 SwiftUI 根视图重复展示。
@MainActor
final class NetworkConnectionApprovalMacPresenter {
    static let shared = NetworkConnectionApprovalMacPresenter()
    private var presentedAlert: NSAlert?
    private var presentedRequestID: UUID?

    func presentCurrentRequest(from center: NetworkConnectionApprovalCenter) {
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
        // 使用实际前台窗口；原 SwiftUI 根视图消失后，另一个根视图仍能关闭取消的审批。
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
    }
}
#endif
