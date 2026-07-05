// ============================================================================
// BatchService.swift
// ============================================================================
// ETOS LLM Studio
//
// 核心业务服务，负责 Batch 任务的全生命周期管理（提交、轮询、下载与解析）。
// ============================================================================

import Foundation
import Combine
import os.log

public class BatchService {
    public static let shared = BatchService()
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "BatchService")
    
    // 用于通知 UI 任务状态更新
    public let activeJobsSubject = CurrentValueSubject<[BatchJob], Never>([])
    private var cancellables = Set<AnyCancellable>()
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private let pollingLock = NSLock()
    
    private init() {
        // 初始化时加载已有任务，继续轮询未完成的
        let existing = BatchJobStore.shared.getAllJobs()
        activeJobsSubject.send(existing)
        
        for job in existing {
            if job.status == .validating || job.status == .inProgress || job.status == .cancelling {
                startPolling(for: job)
            }
        }
    }
    
    /// 将消息打包为 Batch 请求并提交
    public func submitBatch(messages: [ChatMessage], model: RunnableModel, sessionID: UUID) async throws -> BatchJob {
        guard let adapter = ChatService.shared.adapters[model.provider.apiFormat] else {
            throw NSError(domain: "BatchService", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持此提供商的 Batch 操作。"])
        }
        
        // 1. 构建 BatchRequestItems
        var batchItems: [BatchRequestItem] = []
        for (index, msg) in messages.enumerated() {
            let customId = "req-\(sessionID.uuidString)-\(msg.id.uuidString)-\(index)"
            
            // 构造请求体：由于 APIAdapter 没有暴露暴露纯 JSON 构造，
            // 我们可以利用 buildChatRequest 并截获其 httpBody
            let request = adapter.buildChatRequest(
                for: model,
                commonPayload: [:],
                messages: [msg],
                tools: nil,
                audioAttachments: [:],
                imageAttachments: [:],
                fileAttachments: [:]
            )
            
            guard let httpBody = request?.httpBody,
                  let jsonObj = try? JSONSerialization.jsonObject(with: httpBody, options: []),
                  let dict = jsonObj as? [String: Any],
                  let jsonValue = try? JSONValue(from: dict) else {
                continue
            }
            
            let item = BatchRequestItem(
                customId: customId,
                method: "POST",
                url: "/v1/chat/completions",
                body: jsonValue
            )
            batchItems.append(item)
        }
        
        guard !batchItems.isEmpty else {
            throw NSError(domain: "BatchService", code: -2, userInfo: [NSLocalizedDescriptionKey: "构建 Batch 请求项失败。"])
        }
        
        // 2. 序列化为 JSONL
        var jsonlData = Data()
        for item in batchItems {
            let data = try JSONEncoder().encode(item)
            jsonlData.append(data)
            jsonlData.appendString("\n")
        }
        
        // 3. 上传文件
        guard let uploadReq = adapter.buildBatchFileUploadRequest(for: model, jsonlData: jsonlData, purpose: "batch") else {
            throw NSError(domain: "BatchService", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法构建文件上传请求。"])
        }
        let uploadData = try await ChatService.shared.fetchData(for: uploadReq, provider: model.provider)
        let fileId = try adapter.parseBatchFileUploadResponse(data: uploadData)
        
        // 4. 创建 Batch 任务
        let metadata = ["session_id": sessionID.uuidString]
        guard let createReq = adapter.buildBatchCreateRequest(for: model, fileId: fileId, endpoint: "/v1/chat/completions", metadata: metadata) else {
            throw NSError(domain: "BatchService", code: -4, userInfo: [NSLocalizedDescriptionKey: "无法构建 Batch 创建请求。"])
        }
        let createData = try await ChatService.shared.fetchData(for: createReq, provider: model.provider)
        var newJob = try adapter.parseBatchCreateResponse(data: createData)
        
        // 修正本地附加信息
        newJob = BatchJob(
            id: newJob.id,
            providerID: model.provider.id,
            modelID: model.model.id.uuidString,
            status: newJob.status,
            createdAt: newJob.createdAt,
            completedAt: newJob.completedAt,
            failedAt: newJob.failedAt,
            inputFileId: newJob.inputFileId,
            outputFileId: newJob.outputFileId,
            errorFileId: newJob.errorFileId,
            endpoint: newJob.endpoint
        )
        
        // 5. 保存并开始轮询
        BatchJobStore.shared.saveJob(newJob)
        updateActiveJobs()
        startPolling(for: newJob)
        
        return newJob
    }
    
    private func updateActiveJobs() {
        activeJobsSubject.send(BatchJobStore.shared.getAllJobs())
    }
    
    private func startPolling(for job: BatchJob) {
        pollingLock.lock()
        defer { pollingLock.unlock() }
        
        if pollingTasks[job.id] != nil { return }
        
        let task = Task {
            while !Task.isCancelled {
                do {
                    // 查询状态，每分钟查一次
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    try await checkStatus(jobId: job.id)
                    
                    let currentJob = BatchJobStore.shared.getJob(id: job.id)
                    if let status = currentJob?.status, status == .completed || status == .failed || status == .expired || status == .cancelled {
                        break
                    }
                } catch {
                    logger.error("轮询 Batch 任务失败: \(error.localizedDescription)")
                }
            }
            pollingLock.lock()
            pollingTasks.removeValue(forKey: job.id)
            pollingLock.unlock()
        }
        pollingTasks[job.id] = task
    }
    
    public func checkStatus(jobId: String) async throws {
        guard var job = BatchJobStore.shared.getJob(id: jobId) else { return }
        
        // 我们需要 model 和 provider 来构建请求
        // 简便起见，根据 id 重新找出 model
        let providers = ChatService.shared.providers
        guard let provider = providers.first(where: { $0.id == job.providerID }),
              let modelDef = provider.models.first(where: { $0.id.uuidString == job.modelID }) else {
            return
        }
        let runnableModel = RunnableModel(provider: provider, model: modelDef)
        
        guard let adapter = ChatService.shared.adapters[provider.apiFormat],
              let req = adapter.buildBatchStatusRequest(for: runnableModel, batchId: job.id) else {
            return
        }
        
        let data = try await ChatService.shared.fetchData(for: req, provider: provider)
        let updatedJob = try adapter.parseBatchStatusResponse(data: data)
        
        job.status = updatedJob.status
        job.outputFileId = updatedJob.outputFileId
        job.errorFileId = updatedJob.errorFileId
        job.completedAt = updatedJob.completedAt
        job.failedAt = updatedJob.failedAt
        
        BatchJobStore.shared.saveJob(job)
        updateActiveJobs()
        
        if job.status == .completed, let outFileId = job.outputFileId {
            // 自动下载结果
            try await downloadAndProcessResults(for: job, model: runnableModel, fileId: outFileId)
        }
    }
    
    private func downloadAndProcessResults(for job: BatchJob, model: RunnableModel, fileId: String) async throws {
        guard let adapter = ChatService.shared.adapters[model.provider.apiFormat] else { return }
        guard let req = adapter.buildBatchResultDownloadRequest(for: model, fileId: fileId) else { return }
        
        let data = try await ChatService.shared.fetchData(for: req, provider: model.provider)
        let jsonlString = String(data: data, encoding: .utf8) ?? ""
        let lines = jsonlString.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        var generatedMessages: [ChatMessage] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            do {
                let responseItem = try JSONDecoder().decode(BatchResponseItem.self, from: lineData)
                if let payloadBody = responseItem.response?.body {
                    // 转回 Data 再丢给原先的 adapter 解析
                    if let rawData = try? JSONEncoder().encode(payloadBody) {
                        let msg = try adapter.parseResponse(data: rawData)
                        generatedMessages.append(msg)
                    }
                }
            } catch {
                logger.error("解析 Batch 结果单行失败: \(error.localizedDescription)")
            }
        }
        
        // TODO: 将生成的 messages 插入回当前的 ChatService 或通过 Notification 广播
        // 目前为了演示体验，我们可以打印出来或发送特定的 Event
        logger.info("Batch 任务 \(job.id) 处理完成，解析出 \(generatedMessages.count) 条结果。")
    }
}
