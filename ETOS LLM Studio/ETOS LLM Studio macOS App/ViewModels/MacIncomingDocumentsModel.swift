import Combine
import ETOSCore
import Foundation
import UniformTypeIdentifiers

/// Finder、拖放和附件面板共用队列；权重文件不能先作为聊天附件读进内存。
@MainActor
final class MacIncomingDocumentsModel: ObservableObject {
    typealias AttachmentLoader = @Sendable ([URL]) throws -> [MacComposerAttachment]
    @Published private(set) var isWorking = false
    @Published private(set) var contextID = UUID()
    @Published private(set) var importedModelCount = 0
    private let library: MacLocalModelLibraryModel
    private let loadAttachments: AttachmentLoader
    private let applyAttachments: @MainActor ([MacComposerAttachment]) -> Void
    private let reportError: @MainActor (String) -> Void
    private var subscription: AnyCancellable?
    private var pending: [Batch] = []
    private var task: Task<Void, Never>?
    private var isSuspended = true
    private var acceptsNewFiles = true
    private var epoch = UUID()
    private var sessionID: UUID?
    private var sessionRevision = UUID()

    private struct Batch: Sendable {
        let urls: [URL]
        let sessionRevision: UUID?
    }

    init(
        library: MacLocalModelLibraryModel,
        loadAttachments: @escaping AttachmentLoader = { try MacIncomingDocumentSelection.loadAttachments($0) },
        applyAttachments: @escaping @MainActor ([MacComposerAttachment]) -> Void,
        reportError: @escaping @MainActor (String) -> Void
    ) {
        self.library = library; self.loadAttachments = loadAttachments
        self.applyAttachments = applyAttachments; self.reportError = reportError
        subscription = library.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.drain()
        }
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        guard acceptsNewFiles, !urls.isEmpty else { return false }
        pending.append(Batch(urls: urls, sessionRevision: isSuspended ? nil : sessionRevision))
        importedModelCount = 0; isWorking = true
        drain()
        return true
    }

    func updateSession(_ id: UUID?) {
        if sessionID != id {
            sessionID = id; invalidateAttachmentContext()
        }
        drain()
    }

    func invalidateAttachmentContext() { sessionRevision = UUID(); contextID = UUID() }

    func resume(sessionID: UUID?) {
        updateSession(sessionID)
        isSuspended = false; acceptsNewFiles = true
        drain()
    }

    func suspend(acceptNewFiles: Bool = false) {
        // 启动解锁期间尚未处理的 Finder 请求仍可保留；已运行工作区的旧请求必须失效。
        if !isSuspended || !acceptNewFiles {
            epoch = UUID(); contextID = UUID()
            pending.removeAll(); task?.cancel(); importedModelCount = 0
        }
        isSuspended = true; acceptsNewFiles = acceptNewFiles
        isWorking = task != nil || !pending.isEmpty
    }

    /// 调用方先 suspend，确保等待期间不会继续从队列启动文件任务。
    func waitForPendingOperations() async { await task?.value }

    private func drain() {
        guard !isSuspended, sessionID != nil, task == nil, !pending.isEmpty, library.canWrite else { return }
        let batch = pending.removeFirst(), token = epoch
        let sourceSession = batch.sessionRevision ?? sessionRevision
        task = Task { [weak self] in
            guard let self else { return }
            await process(batch, epoch: token, sourceSession: sourceSession)
            task = nil; isWorking = !pending.isEmpty
            drain()
        }
    }

    private func process(_ batch: Batch, epoch token: UUID, sourceSession: UUID) async {
        do {
            let selection = try await Task.detached(priority: .utility) {
                try MacIncomingDocumentSelection(urls: batch.urls)
            }.value
            guard canFinish(token) else { return }
            if !selection.weights.isEmpty {
                // 分类期间设置页可能开始写入，保留整个批次，等库的变化通知再次调度。
                guard library.canWrite else { pending.insert(batch, at: 0); return }
                let succeeded = await library.importFiles(selection.weights, expectedEpoch: library.epoch)
                guard canFinish(token) else { return }
                guard succeeded else {
                    if let error = library.error { reportError(error); library.error = nil }
                    return
                }
                importedModelCount += selection.weightCount
            }
            guard !selection.attachments.isEmpty else { return }
            guard sourceSession == sessionRevision else { throw MacIncomingDocumentError.sessionChanged }
            let loader = loadAttachments, urls = selection.attachments
            let worker = Task.detached(priority: .userInitiated) { try loader(urls) }
            let attachments = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard canFinish(token) else { return }
            guard sourceSession == sessionRevision else { throw MacIncomingDocumentError.sessionChanged }
            applyAttachments(attachments)
        } catch {
            if canFinish(token) { reportError(error.localizedDescription) }
        }
    }

    private func canFinish(_ token: UUID) -> Bool {
        !Task.isCancelled && !isSuspended && epoch == token && AppLockManager.shared.state != .locked
    }
}

struct MacIncomingDocumentSelection: Sendable {
    let weights: [URL]
    let attachments: [URL]
    let weightCount: Int

    init(urls: [URL]) throws {
        var weights: [URL] = [], attachments: [URL] = []
        for url in urls {
            guard url.isFileURL else { throw MacIncomingDocumentError.localFilesOnly }
            if url.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame { weights.append(url) }
            else { attachments.append(url) }
        }
        self.weights = weights; self.attachments = attachments
        weightCount = weights.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }.count
    }

    static func loadAttachments(_ urls: [URL]) throws -> [MacComposerAttachment] {
        try urls.map { url in
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? .data
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            return MacComposerAttachment(data: data, type: type, fileName: url.lastPathComponent)
        }
    }
}

enum MacIncomingDocumentError: LocalizedError {
    case localFilesOnly, sessionChanged
    var errorDescription: String? {
        switch self {
        case .localFilesOnly: return NSLocalizedString("请选择本机文件；模型下载请使用本地模型页。", comment: "")
        case .sessionChanged: return NSLocalizedString("导入期间会话已切换，请重新选择附件。", comment: "")
        }
    }
}
