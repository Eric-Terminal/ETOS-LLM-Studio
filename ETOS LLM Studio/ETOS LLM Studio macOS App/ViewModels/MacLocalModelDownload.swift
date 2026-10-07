import Combine
import ETOSCore
import Foundation

/// 下载与文件登记共用工作区的写入屏障；网络可取消，已开始的登记必须等待收尾。
@MainActor
final class MacLocalModelDownload: ObservableObject {
    typealias Transport = @Sendable (URLRequest, @escaping SyncPackageUploadService.DownloadProgressHandler) async throws -> (URL, URLResponse)

    enum Phase: String {
        case idle, downloading, saving, cancelling, completed, cancelled, failed
        var isWorking: Bool { self == .downloading || self == .saving || self == .cancelling }
    }

    @Published private(set) var id = UUID()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: MacLocalDownloadProgress?
    @Published private(set) var error: String?
    private let transport: Transport
    private let updates = PassthroughSubject<(UUID, SyncPackageDownloadProgress), Never>()
    private var subscription: AnyCancellable?
    private var task: Task<Bool, Never>?

    init(transport: @escaping Transport = { request, progress in
        try await SyncPackageUploadService.downloadTemporaryFile(request: request, progress: progress)
    }) {
        self.transport = transport
        let progressQueue = DispatchQueue(label: "ETOS.Mac.LocalModelDownloadProgress")
        subscription = updates
            .throttle(for: .milliseconds(150), scheduler: progressQueue, latest: true)
            .receive(on: progressQueue)
            .map { ($0.0, MacLocalDownloadProgress(raw: $0.1)) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token, value in
                guard let self, id == token, phase == .downloading else { return }
                progress = value
            }
    }

    func start(
        urlText: String, displayName: String, store: LocalModelStore,
        permitsCommit: @escaping @MainActor @Sendable () -> Bool
    ) -> Task<Bool, Never> {
        precondition(!phase.isWorking)
        id = UUID(); phase = .downloading; progress = nil; error = nil
        let token = id, transport = transport, updates = updates
        let task = Task { [weak self] () -> Bool in
            var temporaryURL: URL?
            var succeeded = false
            do {
                let input = try await Task.detached(priority: .utility) {
                    try MacLocalDownloadRequest(urlText: urlText, displayName: displayName)
                }.value
                try Task.checkCancellation()
                let (url, response) = try await transport(input.request) { value in updates.send((token, value)) }
                temporaryURL = url
                try Task.checkCancellation()
                try MacLocalDownloadRequest.validate(response)
                // 网络回调可能在取消后才返回；只在原工作区仍有效时越过文件提交边界。
                guard permitsCommit() else { throw CancellationError() }
                self?.phase = .saving
                try await Task.detached(priority: .userInitiated) {
                    _ = try store.registerDownloadedModel(fileAt: url, suggestedFileName: input.fileName, displayName: input.displayName)
                }.value
                await store.waitForPendingUIUpdates()
                await AppConfigStore.shared.flushPendingWrites()
                succeeded = true
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self?.phase = .cancelled
                } else {
                    self?.error = error.localizedDescription
                    self?.phase = .failed
                }
            }
            if let temporaryURL {
                await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: temporaryURL) }.value
            }
            if succeeded { self?.phase = .completed }
            self?.task = nil
            return succeeded
        }
        self.task = task
        return task
    }

    func cancel(_ expectedID: UUID) {
        guard id == expectedID, phase == .downloading else { return }
        phase = .cancelling
        task?.cancel()
    }

    func refreshProgress() {
        if let progress { updates.send((id, progress.raw)) }
    }
}

struct MacLocalDownloadRequest: Sendable {
    let request: URLRequest
    let fileName: String
    let displayName: String?

    init(urlText: String, displayName: String) throws {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw MacLocalDownloadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
        self.request = request
        let proposedName = url.lastPathComponent
        // URL 路径中的编码分隔符不能成为模型目录中的子路径。
        fileName = !proposedName.isEmpty && proposedName != "." && proposedName != ".."
            && !proposedName.contains("/") && !proposedName.contains("\\") && !proposedName.contains("\0")
            ? proposedName : "model.gguf"
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.isEmpty ? nil : name
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw MacLocalDownloadError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw MacLocalDownloadError.http(response.statusCode) }
    }
}

struct MacLocalDownloadProgress: Sendable {
    let raw: SyncPackageDownloadProgress
    let caption: String

    init(raw: SyncPackageDownloadProgress) {
        self.raw = raw
        let received = ByteCountFormatter.string(fromByteCount: raw.bytesReceived, countStyle: .file)
        if raw.totalBytes > 0 {
            caption = String(format: NSLocalizedString("已下载 %@ / %@", comment: ""), received,
                             ByteCountFormatter.string(fromByteCount: raw.totalBytes, countStyle: .file))
        } else {
            caption = String(format: NSLocalizedString("已下载 %@", comment: ""), received)
        }
    }
}

enum MacLocalDownloadError: LocalizedError {
    case invalidURL, invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return NSLocalizedString("请输入有效的 HTTP 或 HTTPS 模型链接。", comment: "")
        case .invalidResponse: return NSLocalizedString("下载权重失败：服务器响应无效。", comment: "")
        case .http(let code): return String(format: NSLocalizedString("下载权重失败（HTTP %d）。", comment: ""), code)
        }
    }
}
