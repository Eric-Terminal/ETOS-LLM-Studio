import Combine
import ETOSCore
import Foundation

struct MacConnectionSecurityPresentation: Sendable {
    struct Address: Identifiable, Sendable {
        let id: UUID
        let origin: String
        let kind: NetworkConnectionExceptionKind
        let title: String
        let createdAt: String
    }

    let allowsHTTP: Bool
    let allowsCertificates: Bool
    let addresses: [Address]
    let addressesByID: [UUID: Address]

    init(state: NetworkConnectionSecurityState) {
        allowsHTTP = state.allowsHTTPExceptions
        allowsCertificates = state.allowsCertificateExceptions
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        addresses = state.exceptions.map {
            Address(id: $0.id, origin: $0.origin.displayName, kind: $0.kind,
                title: $0.kind.title, createdAt: formatter.string(from: $0.createdAt))
        }
        addressesByID = Dictionary(addresses.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}

enum MacConnectionSecurityMutation: Sendable {
    case setEnabled(Bool, NetworkConnectionExceptionKind)
    case remove(UUID)

    func apply() async throws {
        switch self {
        case .setEnabled(let enabled, let kind):
            try await NetworkConnectionSecurity.shared.setEnabled(enabled, for: kind)
        case .remove(let id):
            try await NetworkConnectionSecurity.shared.removeException(id: id)
        }
    }
}

/// 原生控件提交后由工作区持有写入；关页和锁定只清除展示，不取消已经接受的撤销。
@MainActor
final class MacConnectionSecurityModel: ObservableObject {
    @Published private(set) var presentation: MacConnectionSecurityPresentation?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var error: String?
    private let read: @Sendable () async -> MacConnectionSecurityPresentation
    private let update: @Sendable (MacConnectionSecurityMutation) async throws -> Void
    private var loading: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(
        observeChanges: Bool = true,
        read: @escaping @Sendable () async -> MacConnectionSecurityPresentation = {
            MacConnectionSecurityPresentation(state: await NetworkConnectionSecurity.shared.snapshot())
        },
        update: @escaping @Sendable (MacConnectionSecurityMutation) async throws -> Void = { try await $0.apply() }
    ) {
        self.read = read
        self.update = update
        if observeChanges {
            subscription = NotificationCenter.default.publisher(for: .networkConnectionSecurityDidChange)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
        }
    }

    var canEdit: Bool { presentation != nil && !isLoading && !isSaving && !isSuspended }

    func reload() {
        guard !isSaving, !isSuspended else { return }
        let previous = loading
        previous?.cancel()
        epoch = UUID()
        let expected = epoch, read = read
        isLoading = true; error = nil
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { await read() }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, epoch == expected, !isSuspended else { return }
            presentation = value; isLoading = false
        }
    }

    func setEnabled(_ enabled: Bool, kind: NetworkConnectionExceptionKind) {
        save(.setEnabled(enabled, kind))
    }

    func remove(id: UUID) {
        guard presentation?.addressesByID[id] != nil else { return }
        save(.remove(id))
    }

    private func save(_ mutation: MacConnectionSecurityMutation) {
        guard canEdit else { return }
        let update = update, expected = epoch
        isSaving = true; error = nil
        writing = Task { [weak self] in
            do { try await update(mutation) }
            catch {
                if let self, epoch == expected, !isSuspended { self.error = error.localizedDescription }
            }
            guard let self else { return }
            isSaving = false
            // 外部通知和本次修改统一在写入结束后重读，避免旧目录覆盖撤销结果。
            if !isSuspended {
                let failure = error
                reload()
                error = failure
            }
        }
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); loading?.cancel()
        presentation = nil; isLoading = false; error = nil
    }

    func resume() { isSuspended = false }

    func waitForPendingOperations() async {
        await writing?.value
        await loading?.value
    }
}
