import Foundation
import Testing
import GRDB
@testable import ETOSCore

@Suite("批量服务生命周期")
struct BatchServiceTests {
    @Test("提交中断后返回已保存任务，恢复不会再次创建已接受的远端任务")
    func interruptedSubmissionKeepsRecoveryPath() async throws {
        let fixture = try BatchServiceFixture()
        await fixture.server.cancelAfterCreation()
        let service = fixture.service()
        let report = try await fixture.submit(using: service)
        #expect(report.submittedCount == 0 && report.attentionCount == 1)
        let original = try #require(try await service.jobs().first)
        #expect(original.submission == .creating)
        try await service.resumeSubmission(id: original.id)
        #expect(try await service.jobs().first?.remoteID == "batch_1")
        #expect(await fixture.server.creationCount == 1)
    }

    @Test("部分模型不支持批量接口时保留全部任务，并报告成功和待处理数量")
    func reportsPartialSubmission() async throws {
        let fixture = try BatchServiceFixture(modelCount: 2)
        await fixture.server.rejectNextCreation()
        let service = fixture.service()
        let ids = fixture.provider.models.map { RunnableModel(provider: fixture.provider, model: $0).id }
        let report = try await service.submit(title: "部分失败", inputs: ["多行\n正文"], modelIDs: ids, temperature: nil, topP: nil)
        let jobs = try await service.jobs()
        #expect(report.submittedCount == 1)
        #expect(report.attentionCount == 1)
        #expect(jobs.count == 2)
        #expect(jobs.filter { $0.remoteID != nil }.count == 1)
        let failed = try #require(jobs.first { $0.remoteID == nil })
        #expect(failed.submission == .failed)
        #expect(failed.errorMessage == BatchError.batchEndpointUnavailable.localizedDescription)
        #expect(jobs.allSatisfy { $0.requests[0].input == "多行\n正文" })
        #expect(await fixture.server.creationCount == 1)
    }

    @Test("创建响应丢失后重启恢复，远端只创建一次")
    func recoverLostCreationResponse() async throws {
        let fixture = try BatchServiceFixture()
        await fixture.server.loseNextCreationResponse()
        let service = fixture.service()
        let report = try await fixture.submit(using: service)
        #expect(report.submittedCount == 0)
        #expect(report.attentionCount == 1)
        let original = try #require(try await service.jobs().first)
        #expect(original.submission == .uncertain)
        let restarted = fixture.service()
        try await restarted.resumeSubmission(id: original.id)
        let recovered = try #require(try await restarted.jobs().first)
        #expect(recovered.remoteID == "batch_1")
        #expect(recovered.submission == .submitted)
        #expect(await fixture.server.creationCount == 1)
    }

    @Test("恢复查询失败不能把不确定提交变成可重发状态")
    func failedRecoveryDoesNotResubmit() async throws {
        let fixture = try BatchServiceFixture()
        await fixture.server.loseNextCreationResponse()
        let service = fixture.service()
        try await fixture.submit(using: service)
        let original = try #require(try await service.jobs().first)
        await fixture.server.rejectListing()
        await #expect(throws: (any Error).self) { try await service.resumeSubmission(id: original.id) }
        let saved = try #require(try await service.jobs().first)
        #expect(saved.submission == .uncertain)
        #expect(await fixture.server.creationCount == 1)
    }

    @Test("终态下载中断后重启会继续取回成功和失败文件")
    func resumeResultDownloads() async throws {
        let fixture = try BatchServiceFixture()
        let service = fixture.service()
        try await fixture.submit(using: service)
        let job = try #require(try await service.jobs().first)
        await fixture.server.finish(job: job, failErrorDownloadOnce: true)
        await #expect(throws: (any Error).self) { try await service.refresh(id: job.id) }
        let interrupted = try #require(try await service.jobs().first)
        #expect(interrupted.status == .completed)
        #expect(!interrupted.resultsDownloaded)
        let restarted = fixture.service()
        await restarted.refreshPending(force: true)
        let saved = try #require(try await restarted.jobs().first)
        #expect(saved.resultsDownloaded)
        #expect(saved.results[0].text == "answer")
        #expect(saved.results[1].error == "failed")
        #expect(await fixture.server.creationCount == 1)
    }

    @Test("取消保留部分结果，重试只发送未成功项并保留原正文")
    func cancellationAndRetry() async throws {
        let fixture = try BatchServiceFixture()
        let service = fixture.service()
        try await fixture.submit(using: service)
        let original = try #require(try await service.jobs().first)
        await fixture.server.finish(job: original, cancelled: true)
        try await service.refresh(id: original.id, cancel: true)
        let cancelled = try #require(try await service.jobs().first)
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.results[0].succeeded)
        #expect(!cancelled.results[1].succeeded)
        try await service.retryFailures(id: original.id)
        let jobs = try await service.jobs()
        let retry = try #require(jobs.first { $0.id != original.id })
        #expect(jobs.count == 2)
        #expect(retry.requests.count == 1)
        #expect(retry.requests[0].input == original.requests[1].input)
        #expect(retry.requests[0].body == original.requests[1].body)
        #expect(await fixture.server.creationCount == 2)
    }

    @Test("同一任务的并发刷新不会同时发出请求")
    func serializesRefreshes() async throws {
        let fixture = try BatchServiceFixture()
        let service = fixture.service()
        try await fixture.submit(using: service)
        let job = try #require(try await service.jobs().first)
        let gate = await fixture.server.holdNextStatus()
        let first = Task { try await service.refresh(id: job.id) }
        for await _ in gate.entered { break }
        await #expect(throws: BatchError.self) { try await service.refresh(id: job.id) }
        gate.release.yield(())
        gate.release.finish()
        try await first.value
        #expect(await fixture.server.statusCount == 1)
    }

    @Test("同步替换数据库后丢弃旧网络响应")
    func replacementRejectsLateResponse() async throws {
        let fixture = try BatchServiceFixture()
        let service = fixture.service()
        try await fixture.submit(using: service)
        let job = try #require(try await service.jobs().first)
        let gate = await fixture.server.holdNextStatus()
        let request = Task { try await service.refresh(id: job.id) }
        for await _ in gate.entered { break }
        try fixture.replaceDatabase(copying: job)
        gate.release.yield(())
        gate.release.finish()
        await #expect(throws: BatchError.self) { try await request.value }
        let preserved = try #require(try await service.jobs().first)
        #expect(preserved.updatedAt == job.updatedAt)
        #expect(preserved.errorMessage == job.errorMessage)
    }
}

/// GRDB 自带并发保护；锁仅用于模拟整库替换，不访问应用的共享数据库。
private final class BatchServiceFixture: @unchecked Sendable {
    let directory: URL
    let provider: Provider
    let server = BatchServerFixture()
    private let lock = NSLock()
    private var store: PersistenceGRDBStore

    init(modelCount: Int = 1) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceGRDBStore(chatsDirectory: directory, configuration: Configuration(), schedulesMaintenance: false)
        provider = Provider(name: "Fixture", baseURL: "https://example.invalid/v1", apiKeys: ["fixture-key"],
            apiFormat: "openai-compatible", models: (0..<modelCount).map { Model(modelName: "fixture-model-\($0)", isActivated: true) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func service() -> BatchService {
        BatchService(database: { self.lock.withLock { self.store } }, providers: { [self.provider] }, didChange: {},
                     transport: { request, _ in try await self.server.send(request) })
    }

    @discardableResult
    func submit(using service: BatchService) async throws -> BatchSubmissionReport {
        let id = RunnableModel(provider: provider, model: provider.models[0]).id
        return try await service.submit(title: "测试任务", inputs: ["第一条", "第二条"], modelIDs: [id], temperature: nil, topP: nil)
    }

    func replaceDatabase(copying job: BatchJob) throws {
        let replacement = directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let newStore = try PersistenceGRDBStore(chatsDirectory: replacement, configuration: Configuration(), schedulesMaintenance: false)
        try BatchJobStore.save(job, in: newStore)
        lock.withLock { store = newStore }
    }
}

private actor BatchServerFixture {
    private(set) var creationCount = 0
    private(set) var statusCount = 0
    private var lostCreation = false
    private var creationRejected = false
    private var creationCancelled = false
    private var listingRejected = false
    private var errorDownloadFails = false
    private var remote: [String: JSONValue] = [:]
    private var output = Data()
    private var errors = Data()
    private var statusGate: (entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    func loseNextCreationResponse() { lostCreation = true }
    func rejectNextCreation() { creationRejected = true }
    func cancelAfterCreation() { creationCancelled = true }
    func rejectListing() { listingRejected = true }

    func holdNextStatus() -> (entered: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        statusGate = (entered.continuation, release.stream)
        return (entered.stream, release.continuation)
    }

    func finish(job: BatchJob, cancelled: Bool = false, failErrorDownloadOnce: Bool = false) {
        remote["status"] = .string(cancelled ? "cancelled" : "completed")
        remote["output_file_id"] = .string("output")
        output = Data("""
        {"custom_id":"\(job.requests[0].id)","response":{"status_code":200,"body":{"choices":[{"message":{"role":"assistant","content":"answer"}}]}},"error":null}
        """.utf8)
        if !cancelled {
            remote["error_file_id"] = .string("errors")
            errors = Data("""
            {"custom_id":"\(job.requests[1].id)","response":null,"error":{"message":"failed"}}
            """.utf8)
        }
        errorDownloadFails = failErrorDownloadOnce
    }

    func send(_ request: URLRequest) async throws -> Data {
        let path = request.url?.path ?? ""
        if path == "/v1/files", request.httpMethod == "POST" {
            return Data(#"{"id":"input"}"#.utf8)
        }
        if path == "/v1/batches", request.httpMethod == "POST" {
            if creationRejected {
                creationRejected = false
                throw ChatService.NetworkError.badStatusCode(code: 404, responseBody: nil)
            }
            creationCount += 1
            let payload = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            guard case .dictionary(let fields) = payload else { throw BatchError.invalidInput }
            remote = ["id": .string("batch_\(creationCount)"), "status": .string("in_progress"),
                      "created_at": .int(1000), "metadata": fields["metadata"]!, "input_file_id": .string("input")]
            if creationCancelled { creationCancelled = false; throw CancellationError() }
            if lostCreation { lostCreation = false; throw URLError(.networkConnectionLost) }
            return try JSONEncoder().encode(JSONValue.dictionary(remote))
        }
        if path == "/v1/batches" {
            if listingRejected { throw ChatService.NetworkError.badStatusCode(code: 401, responseBody: nil) }
            return try JSONEncoder().encode(JSONValue.dictionary(["data": .array([.dictionary(remote)]), "has_more": .bool(false)]))
        }
        if path.hasPrefix("/v1/batches/") {
            statusCount += 1
            if let gate = statusGate {
                statusGate = nil
                gate.entered.yield(())
                gate.entered.finish()
                for await _ in gate.release { break }
            }
            return try JSONEncoder().encode(JSONValue.dictionary(remote))
        }
        if path == "/v1/files/output/content" { return output }
        if path == "/v1/files/errors/content" {
            if errorDownloadFails { errorDownloadFails = false; throw URLError(.networkConnectionLost) }
            return errors
        }
        throw BatchError.invalidResponse
    }
}
