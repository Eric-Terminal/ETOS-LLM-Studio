import Combine
import ETOSCore
import Foundation

struct MacRemoteAccessPresentation: Sendable {
    struct Log: Identifiable, Sendable {
        let id: UUID
        let time: String
        let message: String
        let isError: Bool
    }
    struct Capture: Identifiable, Sendable {
        let id: UUID
        let summary: String
        let time: String
        let messageCount: Int
    }
    let logs: [Log]
    let capture: Capture?

    init(logs: [LocalDebugServer.DebugLogEntry], capture: LocalDebugServer.OpenAIRequestSummary?) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        self.logs = logs.map {
            Log(id: $0.id, time: formatter.string(from: $0.timestamp), message: $0.message, isError: $0.type == .error)
        }
        self.capture = capture.map {
            Capture(id: $0.id, summary: String(format: NSLocalizedString("请求详情：模型 %@ · 消息数 %d", comment: ""),
                $0.model ?? NSLocalizedString("未知", comment: ""), $0.messageCount),
                time: formatter.string(from: $0.receivedAt), messageCount: $0.messageCount)
        }
    }
}

/// 连接属于工作区；页面只控制发现的可见周期，锁定和维护由宿主断开并等待实际收尾。
@MainActor
final class MacRemoteAccessModel: ObservableObject {
    let server: LocalDebugServer
    let discovery: LocalDebugServerDiscovery
    @Published var address = "" { didSet { epoch = UUID(); hasAddress = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    @Published private(set) var useHTTP = true
    @Published private(set) var connectionRequested = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStopping = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published private(set) var presentation: MacRemoteAccessPresentation?
    @Published var error: String?
    private let readAddress: @Sendable () -> String
    private let saveAddress: @Sendable (String) throws -> Void
    private let connectServer: @MainActor (LocalDebugServer, String) -> Void
    private var visible = false
    private var loaded = false
    private var loading: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var preparing: Task<Void, Never>?
    private var presentationRevision = UUID()
    private var stopRevision = UUID()
    private var hasAddress = false
    private var subscriptions: Set<AnyCancellable> = []

    init(server: LocalDebugServer = LocalDebugServer(), discovery: LocalDebugServerDiscovery = LocalDebugServerDiscovery(),
         readAddress: @escaping @Sendable () -> String = { AppConfigStore.textValue(for: .localDebugLastServerAddress) },
         saveAddress: @escaping @Sendable (String) throws -> Void = { value in
             AppConfigStore.persistSynchronously(.text(value), for: .localDebugLastServerAddress, quickSync: false)
             guard AppConfigStore.textValue(for: .localDebugLastServerAddress) == value else {
                 throw NSError(domain: "MacRemoteAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("无法保存配置。", comment: "")])
             }
         },
         connectServer: @escaping @MainActor (LocalDebugServer, String) -> Void = { $0.connect(to: $1) }) {
        self.server = server; self.discovery = discovery
        self.readAddress = readAddress; self.saveAddress = saveAddress; self.connectServer = connectServer
        server.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            objectWillChange.send()
        }.store(in: &subscriptions)
        server.$debugLogs.combineLatest(server.$pendingOpenAIRequest).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPresentation() }.store(in: &subscriptions)
        server.$useHTTP.removeDuplicates().sink { [weak self] in self?.useHTTP = $0 }.store(in: &subscriptions)
        discovery.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var canEdit: Bool { !isSuspended && !isLoading && !isStopping && !connectionRequested && !server.isDisconnecting }
    var canConnect: Bool { canEdit && hasAddress }

    func setVisible(_ value: Bool) {
        visible = value
        if value { load(); refreshPresentation() }
        updateDiscovery()
    }

    func load() {
        guard !loaded, !isLoading, !isSuspended else { return }
        isLoading = true
        let expected = epoch, readAddress = readAddress, previous = loading
        loading = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { readAddress() }
            let value = await worker.value
            guard let self, !Task.isCancelled, !isSuspended else { return }
            if epoch == expected { address = value }
            loaded = true; isLoading = false
            updateDiscovery()
        }
    }

    func setHTTP(_ value: Bool) {
        guard canEdit else { return }
        useHTTP = value; epoch = UUID()
    }

    func fill(_ candidate: LocalDebugDiscoveredServer) {
        guard canEdit else { return }
        address = candidate.connectionAddress(useHTTP: useHTTP)
    }

    func scan() { if canEdit && visible { discovery.restart() } }

    func connect() {
        guard canConnect else { return }
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionRequested = true; epoch = UUID(); error = nil; discovery.stop()
        let expected = epoch, saveAddress = saveAddress
        connecting = Task { [weak self] in
            do { try await Task.detached(priority: .userInitiated) { try saveAddress(target) }.value }
            catch {
                guard let self, epoch == expected, !isSuspended else { return }
                self.error = error.localizedDescription; connectionRequested = false; updateDiscovery()
                return
            }
            guard let self, epoch == expected, !isSuspended, connectionRequested else { return }
            server.useHTTP = useHTTP
            connectServer(server, target)
        }
    }

    func disconnect() {
        connectionRequested = false; epoch = UUID(); discovery.stop(); server.disconnect()
        let previous = stopping, connection = connecting, server = server
        stopRevision = UUID()
        let revision = stopRevision
        isStopping = true
        stopping = Task { [weak self] in
            await previous?.value; await connection?.value
            await server.disconnectAndWait()
            guard let self, stopRevision == revision else { return }
            isStopping = false; updateDiscovery()
        }
    }

    func resolveCapture(id: UUID, save: Bool, expectedEpoch: UUID) {
        guard !isSuspended, !isStopping, epoch == expectedEpoch, server.pendingOpenAIRequest?.id == id else { return }
        server.resolvePendingOpenAIRequest(id: id, save: save)
    }

    func refreshPresentation() {
        guard !isSuspended else { return }
        let logs = server.debugLogs, capture = server.pendingOpenAIRequest, previous = preparing
        previous?.cancel()
        presentationRevision = UUID()
        let revision = presentationRevision
        preparing = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let value = await Task.detached(priority: .utility) { MacRemoteAccessPresentation(logs: logs, capture: capture) }.value
            guard let self, !Task.isCancelled, !isSuspended, presentationRevision == revision else { return }
            presentation = value
        }
    }

    func suspend(disconnectConnection: Bool = true) {
        isSuspended = true; epoch = UUID(); loading?.cancel(); preparing?.cancel()
        isLoading = false; loaded = false; presentation = nil; error = nil; discovery.stop()
        // 远程全量上传正由本命令进入宿主维护时，不能断开并等待自己。
        if disconnectConnection { disconnect() }
    }

    func resume() {
        isSuspended = false
        if visible { load() }
        refreshPresentation(); updateDiscovery()
    }

    func waitForPendingOperations() async {
        await loading?.value; await connecting?.value; await stopping?.value
        await server.waitForPendingOperations()
        while true {
            let revision = presentationRevision
            await preparing?.value
            if revision == presentationRevision { break }
        }
    }

    private func updateDiscovery() {
        if visible && canEdit { discovery.start() } else { discovery.stop() }
    }
}
