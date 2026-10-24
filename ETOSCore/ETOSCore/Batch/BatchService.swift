import Foundation
import UserNotifications

/// 网络等待允许 actor 重入；同一任务的提交、刷新和取消通过 inFlight 串行化。
public actor BatchService {
    public static let shared = BatchService()
    private let database: @Sendable () -> PersistenceGRDBStore?
    private let providers: @Sendable () -> [Provider]
    private let transport: @Sendable (URLRequest, Provider) async throws -> Data
    private let didChange: @Sendable () -> Void
    private var inFlight = Set<UUID>()
    private var nextRefresh: [UUID: Date] = [:]
    private var failureCounts: [UUID: Int] = [:]

    /// 测试注入独立数据库和内存传输，覆盖提交中断而不访问真实 API 或用户数据。
    init(database: @escaping @Sendable () -> PersistenceGRDBStore? = { Persistence.activeGRDBStore() },
         providers: @escaping @Sendable () -> [Provider] = { ConfigLoader.loadProviders() },
         didChange: @escaping @Sendable () -> Void = {
             WatchDatabaseSyncService.markDatabaseChanged(.chat)
             NotificationCenter.default.post(name: .batchJobsChanged, object: nil)
         }, transport: @escaping @Sendable (URLRequest, Provider) async throws -> Data = { request, provider in
             guard await MainActor.run(body: { AppLockManager.shared.state != .locked }) else { throw CancellationError() }
             let data = try await ChatService.shared.fetchData(for: request, provider: provider)
             guard await MainActor.run(body: { AppLockManager.shared.state != .locked }) else { throw CancellationError() }
             return data
         }) {
        self.database = database
        self.providers = providers
        self.transport = transport
        self.didChange = didChange
    }

    public func jobs() throws -> [BatchJob] { try BatchJobStore.loadAll(in: database()) }

    public func models() -> [RunnableModel] {
        providers().flatMap { provider in
            provider.models.filter(\.isActivated).map { RunnableModel(provider: provider, model: $0) }
        }.filter(OpenAIBatchSupport.supports)
    }

    @discardableResult
    public func submit(title: String, inputs: [String], modelIDs: [String], temperature: Double?, topP: Double?) async throws -> BatchSubmissionReport {
        let available = models()
        let selected = modelIDs.compactMap { id in available.first { $0.id == id } }
        guard !selected.isEmpty, selected.count == modelIDs.count else { throw BatchError.invalidInput }
        // 所有模型先完成校验；任一输入无法构造时，不向服务端发送部分请求。
        let prepared = try selected.map {
            try OpenAIBatchSupport.prepare(title: title, inputs: inputs, model: $0, temperature: temperature, topP: topP)
        }
        for job in prepared { try BatchJobStore.save(job, in: database()) }
        didChange()
        var submittedCount = 0
        for job in prepared {
            do {
                try await resumeSubmission(id: job.id)
                submittedCount += 1
            }
            catch {
                if case BatchError.storeReplaced = error { throw error }
                // 草稿已全部落库；中断时也交还这些记录，避免表单重试再次发送已接受的任务。
                if error is CancellationError { break }
                // 普通网络失败随各任务保存，其他模型仍可正常提交。
            }
        }
        return BatchSubmissionReport(submittedCount: submittedCount, attentionCount: prepared.count - submittedCount)
    }

    public func resumeSubmission(id: UUID) async throws {
        guard inFlight.insert(id).inserted else { throw BatchError.busy }
        defer { inFlight.remove(id) }
        var job = try BatchJobStore.load(id, in: database())
        guard job.remoteID == nil else { return }
        var attemptedCreate = false
        do {
            let (provider, key) = try OpenAIBatchSupport.credentials(for: job, providers: providers())
            if job.submission == .creating || job.submission == .uncertain {
                // POST 被服务端接受但响应丢失时，只查询 metadata；不盲目重发创建请求。
                if let response = try await findRemote(job: job, provider: provider, key: key) {
                    job = response.applying(to: job)
                    try persist(&job)
                    return
                }
                throw BatchError.uncertainSubmission
            }
            if job.inputFileID == nil {
                job.submission = .uploading
                job.errorMessage = nil
                try persist(&job)
                let request = try OpenAIBatchSupport.upload(job, provider: provider, key: key)
                let data = try await send(request, provider: provider)
                struct FileResponse: Decodable { var id: String }
                job.inputFileID = try JSONDecoder().decode(FileResponse.self, from: data).id
                try persist(&job)
            }
            guard let fileID = job.inputFileID else { throw BatchError.invalidResponse }
            job.submission = .creating
            try persist(&job)
            let payload: [String: Any] = ["input_file_id": fileID, "endpoint": job.endpoint,
                "completion_window": "24h", "metadata": ["etos_job_id": job.id.uuidString]]
            let request = try OpenAIBatchSupport.request(provider: provider, key: key, path: "batches", method: "POST",
                body: JSONSerialization.data(withJSONObject: payload))
            attemptedCreate = true
            let data = try await send(request, provider: provider)
            job = try JSONDecoder().decode(OpenAIBatchResponse.self, from: data).applying(to: job)
            try persist(&job)
        } catch {
            if error is CancellationError { throw error }
            if case BatchError.storeReplaced = error { throw error }
            if job.remoteID == nil {
                if attemptedCreate, case ChatService.NetworkError.badStatusCode(let code, _) = error,
                   [400, 401, 403, 404, 405, 413, 415, 422, 429].contains(code) {
                    job.submission = .failed
                } else {
                    job.submission = job.submission == .creating || job.submission == .uncertain ? .uncertain : .failed
                }
            }
            let submissionError: any Error
            if case ChatService.NetworkError.badStatusCode(let code, _) = error, [404, 405].contains(code) {
                submissionError = BatchError.batchEndpointUnavailable
            } else {
                submissionError = error
            }
            job.errorMessage = submissionError.localizedDescription
            try persist(&job)
            throw submissionError
        }
    }

    public func refresh(id: UUID, cancel: Bool = false) async throws {
        guard inFlight.insert(id).inserted else { throw BatchError.busy }
        defer { inFlight.remove(id) }
        var job = try BatchJobStore.load(id, in: database())
        guard let remoteID = job.remoteID else { return }
        do {
            let (provider, key) = try OpenAIBatchSupport.credentials(for: job, providers: providers())
            let shouldCancel = cancel && job.status?.isTerminal != true && job.status != .cancelling
            let request = try OpenAIBatchSupport.request(provider: provider, key: key,
                path: "batches/\(remoteID)" + (shouldCancel ? "/cancel" : ""), method: shouldCancel ? "POST" : "GET")
            let data = try await send(request, provider: provider)
            job = try JSONDecoder().decode(OpenAIBatchResponse.self, from: data).applying(to: job)
            try persist(&job)
            if job.status?.isTerminal == true, !job.resultsDownloaded {
                var results: [String: BatchResult] = [:]
                let ids = Set(job.requests.map(\.id))
                // 取消、过期和部分失败也可能有成功结果；两个文件都落库后才算下载完成。
                for fileID in [job.outputFileID, job.errorFileID].compactMap({ $0 }) {
                    let request = try OpenAIBatchSupport.request(provider: provider, key: key, path: "files/\(fileID)/content")
                    let data = try await send(request, provider: provider)
                    for result in try OpenAIBatchSupport.parseResults(data, knownIDs: ids) {
                        guard results[result.id] == nil else { throw BatchError.invalidResponse }
                        results[result.id] = result
                    }
                }
                job.results = job.requests.map { request in
                    results[request.id] ?? BatchResult(id: request.id,
                        error: job.errorMessage ?? BatchError.missingResult.localizedDescription)
                }
                job.resultsDownloaded = true
                try persist(&job)
            }
            failureCounts[id] = nil
            nextRefresh[id] = Date().addingTimeInterval(120)
            if job.resultsDownloaded, !job.notified {
                // 同一个远端任务始终用同一通知标识；重试投递只会替换，不会堆积通知。
                if await notify(job) {
                    job.notified = true
                    try persist(&job)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            if case BatchError.storeReplaced = error { throw error }
            job.errorMessage = error.localizedDescription
            try persist(&job)
            let failures = min((failureCounts[id] ?? 0) + 1, 4)
            failureCounts[id] = failures
            nextRefresh[id] = Date().addingTimeInterval(min(120 * pow(2, Double(failures)), 1800))
            throw error
        }
    }

    public func refreshPending(force: Bool = false) async {
        guard let jobs = try? jobs() else { return }
        for job in jobs where job.needsRefresh {
            guard !Task.isCancelled else { return }
            guard !inFlight.contains(job.id), force || (nextRefresh[job.id] ?? .distantPast) <= Date() else { continue }
            try? await refresh(id: job.id)
        }
    }

    public func retryFailures(id: UUID) async throws {
        let original = try BatchJobStore.load(id, in: database())
        guard original.resultsDownloaded, original.status?.isTerminal == true else { throw BatchError.noFailedItems }
        let failed = Set(original.results.filter { !$0.succeeded }.map(\.id))
        guard !failed.isEmpty else { throw BatchError.noFailedItems }
        _ = try OpenAIBatchSupport.credentials(for: original, providers: providers())
        // 重试沿用原请求正文，不受之后的模型参数修改影响，也不重复发送成功项。
        var job = original
        job.id = UUID()
        job.remoteID = nil
        job.requests = original.requests.filter { failed.contains($0.id) }
        job.results = []
        job.submission = .prepared
        job.status = nil
        job.createdAt = Date()
        job.updatedAt = Date()
        job.remoteCreatedAt = nil
        job.finishedAt = nil
        job.inputFileID = nil
        job.outputFileID = nil
        job.errorFileID = nil
        job.resultsDownloaded = false
        job.notified = false
        job.errorMessage = nil
        try BatchJobStore.save(job, in: database())
        didChange()
        try await resumeSubmission(id: job.id)
    }

    public func remove(id: UUID) throws {
        guard !inFlight.contains(id) else { throw BatchError.busy }
        let job = try BatchJobStore.load(id, in: database())
        guard job.status?.isTerminal == true || (job.remoteID == nil && ![.creating, .uncertain].contains(job.submission)) else {
            throw BatchError.activeJob
        }
        try BatchJobStore.remove(id, in: database())
        didChange()
    }

    public func export(id: UUID) throws -> URL {
        let job = try BatchJobStore.load(id, in: database())
        var data = Data()
        for result in job.results {
            let value = result.rawResponse ?? .dictionary(["custom_id": .string(result.id),
                "error": .dictionary(["message": .string(result.error ?? "")])])
            data.append(try JSONEncoder().encode(value))
            data.append(0x0A)
        }
        let url = try SyncTemporaryFileCleaner.makeFileURL(prefix: "batch-\(id.uuidString)", fileExtension: "jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func persist(_ job: inout BatchJob) throws {
        // 同步或恢复替换了任务时，迟到的网络响应不能覆盖新数据库中的版本。
        var updated = job
        updated.updatedAt = Date()
        try BatchJobStore.save(updated, expecting: job.updatedAt, in: database())
        job = updated
        didChange()
    }

    private func send(_ request: URLRequest, provider: Provider) async throws -> Data {
        try Task.checkCancellation()
        let originalStore = database()
        let data: Data
        do { data = try await transport(request, provider) }
        catch {
            guard database() === originalStore else { throw BatchError.storeReplaced }
            throw error
        }
        try Task.checkCancellation()
        guard database() === originalStore else { throw BatchError.storeReplaced }
        return data
    }

    private func findRemote(job: BatchJob, provider: Provider, key: String) async throws -> OpenAIBatchResponse? {
        struct Page: Decodable { var data: [OpenAIBatchResponse]; var has_more: Bool }
        var after: String?
        while true {
            var request = try OpenAIBatchSupport.request(provider: provider, key: key, path: "batches")
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let after { url.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            request.url = url.url
            let data = try await send(request, provider: provider)
            let page = try JSONDecoder().decode(Page.self, from: data)
            if let match = page.data.first(where: { $0.metadata?["etos_job_id"] == job.id.uuidString }) { return match }
            guard page.has_more, let last = page.data.last, last.id != after else { return nil }
            after = last.id
        }
    }

    @MainActor
    private func notify(_ job: BatchJob) async -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return true }
        let center = AppLocalNotificationCenter.shared
        let status = await center.refreshAuthorizationStatus()
        guard status == .authorized || status == .provisional else { return true }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("batch.notification.title", value: "Batch results are ready", comment: "批量通知标题")
        content.body = NSLocalizedString("batch.notification.body", value: "Open Settings > Extensions > Batch Tasks to view the results.", comment: "批量通知内容，不含请求正文")
        content.sound = .default
        return await center.addNotificationRequest(UNNotificationRequest(identifier: "batch.\(job.id.uuidString)", content: content, trigger: nil))
    }
}
