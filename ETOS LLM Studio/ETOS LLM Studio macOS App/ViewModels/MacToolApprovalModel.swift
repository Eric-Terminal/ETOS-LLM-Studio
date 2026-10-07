import Combine
import ETOSCore
import Foundation

@MainActor
final class MacToolApprovalModel: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published private(set) var enabled = false
    @Published private(set) var countdown = 8
    @Published private(set) var disabledTools: [String] = []
    @Published var error: String?
    private var center: ToolPermissionCenter?
    private var subscription: AnyCancellable?
    private var writeTask: Task<Void, Error>?
    var canWrite: Bool { isLoaded && !isWorking && !isSuspended && AppLockManager.shared.state != .locked }

    func start() async {
        guard center == nil else { refresh(); return }
        let center = await ToolPermissionCenter.prepareSharedInBackground()
        guard self.center == nil else { return }
        self.center = center; isLoaded = true
        subscription = Publishers.CombineLatest3(center.$autoApproveEnabled, center.$autoApproveCountdownSeconds, center.$disabledAutoApproveTools)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let center else { return }
        enabled = center.autoApproveEnabled; countdown = center.autoApproveCountdownSeconds; disabledTools = center.disabledAutoApproveTools
    }

    func update(_ change: ToolApprovalPreferenceChange, expectedEpoch: UUID, requestID: UUID? = nil) async throws {
        guard canWrite, expectedEpoch == epoch, let center,
              requestID == nil || center.activeRequest?.id == requestID else { throw MacMemoryWriteError.busy }
        isWorking = true
        let task = Task { try await center.updatePreferencesInBackground(change) }
        writeTask = task
        defer { writeTask = nil; isWorking = false; refresh() }
        try await task.value
    }

    func suspend() { isSuspended = true; epoch = UUID() }
    func resume() { isSuspended = false; refresh() }
    func waitForPendingWrites() async { _ = try? await writeTask?.value }
}
