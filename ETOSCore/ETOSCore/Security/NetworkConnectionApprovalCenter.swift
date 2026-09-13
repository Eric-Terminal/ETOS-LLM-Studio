import Combine
import Foundation

public enum NetworkConnectionDecision: Equatable, Sendable {
    case cancel
    case once
    case remember
}

public struct NetworkConnectionApprovalRequest: Identifiable, Sendable {
    public let id: UUID
    public let origin: NetworkConnectionOrigin
    public let kind: NetworkConnectionExceptionKind
    public let detail: String
    let certificateIdentity: String?

    public var title: String {
        switch kind {
        case .http: return NSLocalizedString("Continue without encryption?", comment: "HTTP 连接确认标题")
        case .certificate: return NSLocalizedString("Unable to verify server identity", comment: "证书例外确认标题")
        }
    }

    public var message: String {
        let explanation: String
        switch kind {
        case .http:
            explanation = NSLocalizedString(
                "Messages, files and API keys sent to this address will not be encrypted and may be read or changed by others on the network.",
                comment: "HTTP 连接确认说明")
        case .certificate:
            explanation = NSLocalizedString(
                "This HTTPS connection is encrypted, but the server's identity could not be verified. Someone could be impersonating this server.",
                comment: "证书例外确认说明")
        }
        let reminder = NSLocalizedString(
            "Remembering this choice enables this type of exception for this address across the app. Manage exceptions in Extended Features > Connection Exceptions.",
            comment: "网络例外记住选择说明")
        return [origin.displayName, explanation, detail, reminder].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// 只承载用户确认，不接收请求正文、认证头或原始证书数据。
@MainActor
public final class NetworkConnectionApprovalCenter: ObservableObject {
    public static let shared = NetworkConnectionApprovalCenter()
    @Published public private(set) var currentRequest: NetworkConnectionApprovalRequest?
    @Published public private(set) var persistenceFailure = false
    private var isActive = false
    private var isDismissing = false
    private var queue: [NetworkConnectionApprovalRequest] = []
    private var waiters: [UUID: [UUID: CheckedContinuation<NetworkConnectionDecision, Never>]] = [:]
    private var guideToken: GuideContextCoordinator.RegistrationToken?

    func request(
        origin: NetworkConnectionOrigin, kind: NetworkConnectionExceptionKind, detail: String = "",
        certificateIdentity: String? = nil
    ) async -> NetworkConnectionDecision {
        guard isActive, !Task.isCancelled else { return .cancel }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                let existing = ([currentRequest].compactMap { $0 } + queue).first {
                    $0.origin == origin && $0.kind == kind && $0.detail == detail
                        && $0.certificateIdentity == certificateIdentity
                }
                let request =
                    existing
                    ?? NetworkConnectionApprovalRequest(
                        id: UUID(), origin: origin, kind: kind, detail: detail, certificateIdentity: certificateIdentity
                    )
                waiters[request.id, default: [:]][waiterID] = continuation
                if existing == nil { queue.append(request) }
                advance()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    public func setActive(_ active: Bool) {
        isActive = active
        guard !active else {
            advance()
            return
        }
        // 应用离开前台时结束等待，避免后台重连悬挂或恢复后执行过期操作。
        let pending = waiters.values.flatMap { $0.values }
        waiters.removeAll()
        queue.removeAll()
        clearCurrent()
        pending.forEach { $0.resume(returning: .cancel) }
    }

    public func resolve(id: UUID, decision: NetworkConnectionDecision) {
        guard currentRequest?.id == id else { return }
        let pending = waiters.removeValue(forKey: id) ?? [:]
        clearCurrent()
        advanceAfterDismissal()
        pending.values.forEach { $0.resume(returning: decision) }
    }

    private func advanceAfterDismissal() {
        isDismissing = true
        // 等待原生弹窗完成退场，再显示队列中的下一个来源。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.isDismissing = false
            self?.advance()
        }
    }

    func reportPersistenceFailure() { persistenceFailure = true }
    public func clearPersistenceFailure() { persistenceFailure = false }

    private func cancelWaiter(_ id: UUID) {
        guard let requestID = waiters.first(where: { $0.value[id] != nil })?.key,
            let continuation = waiters[requestID]?.removeValue(forKey: id)
        else { return }
        continuation.resume(returning: .cancel)
        if waiters[requestID]?.isEmpty == true {
            waiters.removeValue(forKey: requestID)
            queue.removeAll { $0.id == requestID }
            if currentRequest?.id == requestID {
                clearCurrent()
                advanceAfterDismissal()
            }
        }
    }

    private func advance() {
        guard isActive, !isDismissing, currentRequest == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        currentRequest = request
        // 确认弹窗是独立只读上下文，向导不能替用户批准连接。
        guideToken = GuideContextCoordinator.shared.register(
            descriptor: GuidePageDescriptor(
                id: "network-connection-confirmation", title: request.title,
                documents: [GuideDocumentReference(
                    id: "network-connection-exceptions",
                    title: NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"))]
            ),
            isFallback: false,
            snapshot: {
                GuidePageSnapshot(fields: [
                    "address": GuideSnapshotField(
                        label: NSLocalizedString("Address", comment: "网络地址字段"),
                        value: .string(request.origin.displayName), access: .readOnly),
                    "exception_type": GuideSnapshotField(
                        label: NSLocalizedString("Exception type", comment: "网络例外类型字段"),
                        value: .string(request.kind.rawValue), access: .readOnly),
                ])
            },
            executeReadTool: { call in throw GuideError.unsupportedTool(call.toolName) },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
    }

    private func clearCurrent() {
        if let guideToken { GuideContextCoordinator.shared.unregister(guideToken) }
        guideToken = nil
        currentRequest = nil
    }
}
