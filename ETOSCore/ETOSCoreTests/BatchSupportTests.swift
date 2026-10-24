import Foundation
import Testing
import GRDB
@testable import ETOSCore

@Suite("批量请求、状态与结果回归")
struct BatchSupportTests {
    private func model(format: String = "openai-compatible", overrides: [String: JSONValue] = [:]) -> RunnableModel {
        let model = Model(modelName: "batch-test", isActivated: true, overrideParameters: overrides)
        return RunnableModel(provider: Provider(name: "Batch Test", baseURL: "https://example.invalid/v1",
            apiKeys: ["batch-test-key"], apiFormat: format, models: [model]), model: model,
            requestBodyControlState: model.defaultRequestBodyControlState)
    }

    private func job(_ model: RunnableModel? = nil) throws -> BatchJob {
        try OpenAIBatchSupport.prepare(title: "测试", inputs: ["第一条", "第二条"], model: model ?? self.model(), temperature: 0.3, topP: 0.8)
    }

    @Test("JSONL 每行独立且自定义 ID 短于 64 字符")
    func independentRequests() throws {
        let job = try job()
        let lines = String(decoding: try OpenAIBatchSupport.jsonl(job), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(Set(job.requests.map(\.id)).count == 2)
        for (index, line) in lines.enumerated() {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect((payload["custom_id"] as? String)?.count == 36)
            #expect(payload["url"] as? String == "/v1/chat/completions")
            let body = try #require(payload["body"] as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages[0]["content"] as? String == job.requests[index].input)
            #expect(body["temperature"] as? Double == 0.3)
            #expect(body["top_p"] as? Double == 0.8)
            #expect(body["stream"] as? Bool == false)
            #expect(body[providerAPIKeyControlKey] == nil)
        }
    }

    @Test("模型覆盖不能重新启用流式或跨请求会话")
    func disablesStreamingAndContinuation() throws {
        let job = try job(model(overrides: ["stream": .bool(true), "stream_options": .dictionary(["include_usage": .bool(true)]),
                                          "previous_response_id": .string("old"), "background": .bool(true)]))
        let body = try #require(job.requests[0].body.toAny() as? [String: Any])
        #expect(body["stream"] as? Bool == false)
        for key in ["stream_options", "previous_response_id", "background", "conversation"] { #expect(body[key] == nil) }
    }

    @Test("Responses 独立协议使用匹配的 Batch 端点")
    func responsesEndpoint() throws {
        let job = try job(model(format: "openai-responses"))
        #expect(job.endpoint == "/v1/responses")
        let body = try #require(job.requests[0].body.toAny() as? [String: Any])
        #expect(body["input"] != nil)
        #expect(body["messages"] == nil)
    }

    @Test("采用模型级协议覆盖并拒绝不支持的模型")
    func modelOverride() throws {
        let original = model(format: "anthropic")
        var definition = original.model
        definition.apiFormatOverride = "openai-compatible"
        #expect(OpenAIBatchSupport.supports(RunnableModel(provider: original.provider, model: definition)))
        #expect(throws: BatchError.self) { try job(original) }
    }

    @Test("不允许静默丢弃空请求")
    func emptyInputRejected() {
        #expect(throws: BatchError.self) {
            try OpenAIBatchSupport.prepare(title: "", inputs: ["有效", "  "], model: model(), temperature: nil, topP: nil)
        }
    }

    @Test("密钥排序变化仍匹配原凭据，换项目请求头则拒绝")
    func stableCredentials() throws {
        var provider = model().provider
        provider.apiKeys = [" first ", "second"]
        provider.headerOverrides = ["OpenAI-Project": "project-one"]
        let selected = RunnableModel(provider: provider, model: provider.models[0])
        let job = try job(selected)
        provider.apiKeys.reverse()
        let (_, key) = try OpenAIBatchSupport.credentials(for: job, providers: [provider])
        #expect(OpenAIBatchSupport.digest(key) == job.credentialDigest)
        provider.headerOverrides["OpenAI-Project"] = "project-two"
        #expect(throws: BatchError.self) { try OpenAIBatchSupport.credentials(for: job, providers: [provider]) }
        let encoded = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        #expect(!encoded.contains("\"apiKeys\""))
        #expect(!encoded.contains("\"first\""))
        #expect(!encoded.contains("\"second\""))
    }

    @Test("上传使用 multipart 并保持同一认证信息")
    func multipartUpload() throws {
        let model = model()
        let job = try job(model)
        let request = try OpenAIBatchSupport.upload(job, provider: model.provider, key: "batch-test-key")
        #expect(request.url?.absoluteString == "https://example.invalid/v1/files")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer batch-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"purpose\""))
        #expect(body.contains("filename=\"batch.jsonl\""))
        #expect(body.contains(job.requests[0].id))
    }

    @Test("准备结果状态不会被误判失败，时间沿用服务端")
    func remoteStatusAndDates() throws {
        let response = try JSONDecoder().decode(OpenAIBatchResponse.self, from: Data("""
        {"id":"batch_one","status":"finalizing","created_at":1000,"completed_at":null}
        """.utf8))
        let updated = response.applying(to: try job())
        #expect(updated.status == .finalizing)
        #expect(updated.needsRefresh)
        #expect(updated.remoteCreatedAt == Date(timeIntervalSince1970: 1000))
        #expect(updated.finishedAt == nil)
    }

    @Test("终态任务在结果未保存时仍需刷新", arguments: [BatchJobStatus.completed, .expired, .cancelled, .failed])
    func resumesIncompleteDownloads(status: BatchJobStatus) throws {
        var job = try job()
        job.remoteID = "batch"
        job.status = status
        #expect(job.needsRefresh)
        job.resultsDownloaded = true
        #expect(job.needsRefresh)
        job.notified = true
        #expect(!job.needsRefresh)
    }

    @Test("乱序结果按 ID 对回原输入并保留错误")
    func unorderedResults() throws {
        var job = try job()
        let data = Data("""
        {"custom_id":"\(job.requests[1].id)","response":null,"error":{"code":"batch_expired","message":"expired"}}
        {"custom_id":"\(job.requests[0].id)","response":{"status_code":200,"body":{"choices":[{"message":{"role":"assistant","content":"answer"}}]}},"error":null}
        """.utf8)
        job.results = try OpenAIBatchSupport.parseResults(data, knownIDs: Set(job.requests.map(\.id)))
        let presentation = BatchJobRow(job: job)
        #expect(presentation.results[0].input == "第一条")
        #expect(presentation.results[0].text == "answer")
        #expect(presentation.results[1].error == "expired")
    }

    @Test("非成功 HTTP 响应和未知 custom_id 不会伪装成成功")
    func invalidResults() throws {
        let data = Data(#"{"custom_id":"one","response":{"status_code":429,"body":{"error":{"message":"limited"}}},"error":null}"#.utf8)
        let result = try OpenAIBatchSupport.parseResults(data, knownIDs: ["one"])
        #expect(result[0].error != nil)
        #expect(throws: BatchError.self) { try OpenAIBatchSupport.parseResults(data, knownIDs: ["other"]) }
        #expect(throws: (any Error).self) { try OpenAIBatchSupport.parseResults(Data("invalid".utf8), knownIDs: ["one"]) }
    }

    @Test("完成下载前不可重试或导出，未确认提交不可删除")
    func presentationGuards() throws {
        var job = try job()
        job.submission = .uncertain
        var row = BatchJobRow(job: job)
        #expect(!row.canRemove && !row.canRetry && !row.canExport)
        job.status = .completed
        job.resultsDownloaded = true
        job.results = [BatchResult(id: job.requests[0].id, error: "failed")]
        row = BatchJobRow(job: job)
        #expect(row.canRemove && row.canRetry && row.canExport)
    }

    @Test("数据库往返保存完整请求和结果且拒绝迟到覆盖")
    func persistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory, configuration: Configuration(), schedulesMaintenance: false)
        var original = try job()
        original.results = [BatchResult(id: original.requests[0].id, text: "saved")]
        try BatchJobStore.save(original, in: store)
        let restored = try BatchJobStore.load(original.id, in: store)
        #expect(restored.requests.map(\.input) == original.requests.map(\.input))
        #expect(restored.results[0].text == "saved")
        #expect(try BatchJobStore.loadAll(in: store).count == 1)
        var newer = original
        newer.updatedAt = original.updatedAt.addingTimeInterval(10)
        newer.status = .completed
        try BatchJobStore.save(newer, expecting: original.updatedAt, in: store)
        #expect(throws: BatchError.self) { try BatchJobStore.save(original, expecting: original.updatedAt, in: store) }
        #expect(try BatchJobStore.load(original.id, in: store).status == .completed)
        try BatchJobStore.remove(original.id, in: store)
        #expect(try BatchJobStore.loadAll(in: store).isEmpty)
    }

    @Test("向导文档说明拓展功能入口、草稿边界、同步、恢复与前台通知限制")
    func guideKnowledge() {
        let document = BatchGuideSupport.document()
        #expect(document.id == "batch-tasks")
        for word in ["设置→拓展功能→批量任务", "草稿", "原生确认", "metadata", "前台", "聊天数据库", "API Key"] {
            #expect(document.content.contains(word))
        }
        #expect(GuideDocumentCatalog.documents.contains { $0.id == document.id })
        let extended = GuideDocumentCatalog.documents.first { $0.id == "settings-extended" }
        #expect(extended?.keywords.contains("Batch") == true)
        #expect(extended?.content.contains("设置→拓展功能→批量任务") == true)
        #expect(extended?.content.contains(document.id) == true)
    }
}
