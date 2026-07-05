// ============================================================================
// OpenAIAdapterBatchSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 OpenAIAdapter 的 Batch 请求构建与响应解析入口。
// ============================================================================

import Foundation
import os.log

extension OpenAIAdapter {
    
    // MARK: - Batch API (File Upload)
    
    public func buildBatchFileUploadRequest(for model: RunnableModel, jsonlData: Data, purpose: String) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Batch 文件上传请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let filesURL = baseURL.appendingPathComponent("files")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Batch 文件上传请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: filesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var body = Data()
        body.appendMultipartField(name: "purpose", value: purpose, boundary: boundary)
        body.appendMultipartFile(name: "file", fileName: "batch.jsonl", mimeType: "application/jsonl", data: jsonlData, boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        
        request.httpBody = body
        return request
    }
    
    public func parseBatchFileUploadResponse(data: Data) throws -> String {
        let response = try JSONDecoder().decode(OpenAIFileUploadResponse.self, from: data)
        return response.id
    }
    
    // MARK: - Batch API (Batch Management)
    
    public func buildBatchCreateRequest(for model: RunnableModel, fileId: String, endpoint: String, metadata: [String: String]?) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Batch 创建请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let batchesURL = baseURL.appendingPathComponent("batches")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Batch 创建请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: batchesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var payload: [String: Any] = [
            "input_file_id": fileId,
            "endpoint": endpoint,
            "completion_window": "24h"
        ]
        if let metadata = metadata, !metadata.isEmpty {
            payload["metadata"] = metadata
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建 Batch 创建请求失败: 无法编码 JSON - \(error.localizedDescription)")
            return nil
        }
    }
    
    public func parseBatchCreateResponse(data: Data) throws -> BatchJob {
        return try parseBatchStatus(from: data)
    }
    
    public func buildBatchStatusRequest(for model: RunnableModel, batchId: String) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Batch 状态查询请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let batchesURL = baseURL.appendingPathComponent("batches/\(batchId)")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Batch 状态查询请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: batchesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        return request
    }
    
    public func parseBatchStatusResponse(data: Data) throws -> BatchJob {
        return try parseBatchStatus(from: data)
    }
    
    private func parseBatchStatus(from data: Data) throws -> BatchJob {
        let response = try JSONDecoder().decode(OpenAIBatchJobResponse.self, from: data)
        let status: BatchJobStatus
        switch response.status {
        case "validating": status = .validating
        case "in_progress": status = .inProgress
        case "completed": status = .completed
        case "failed": status = .failed
        case "expired": status = .expired
        case "cancelling": status = .cancelling
        case "cancelled": status = .cancelled
        default: status = .failed
        }
        
        return BatchJob(
            id: response.id,
            providerID: UUID(), // Caller should correct this
            modelID: "",        // Caller should correct this
            status: status,
            createdAt: Date(),
            completedAt: status == .completed ? Date() : nil,
            failedAt: status == .failed ? Date() : nil,
            inputFileId: response.input_file_id,
            outputFileId: response.output_file_id,
            errorFileId: response.error_file_id,
            endpoint: response.endpoint
        )
    }
    
    // MARK: - Batch API (Download Results)
    
    public func buildBatchResultDownloadRequest(for model: RunnableModel, fileId: String) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Batch 结果下载请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let filesURL = baseURL.appendingPathComponent("files/\(fileId)/content")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Batch 结果下载请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: filesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        return request
    }
    
    public func parseBatchResultDownloadResponse(data: Data) throws -> Data {
        // OpenAI directly returns the content
        return data
    }
}
