// ============================================================================
// BatchModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 包含 Batch API 相关的数据结构。
// ============================================================================

import Foundation

public enum BatchJobStatus: String, Codable, Sendable {
    case validating
    case inProgress = "in_progress"
    case completed
    case failed
    case expired
    case cancelling
    case cancelled
    
    // 如果需要可以增加其他状态，如 Anthropic 的 "ended" 等
}

public struct BatchJob: Codable, Sendable, Identifiable {
    public let id: String
    public let providerID: UUID
    public let modelID: String
    public var status: BatchJobStatus
    public let createdAt: Date
    public var completedAt: Date?
    public var failedAt: Date?
    
    // OpenAI 专属：
    public var inputFileId: String?
    public var outputFileId: String?
    public var errorFileId: String?
    public var endpoint: String?
    
    public init(id: String, providerID: UUID, modelID: String, status: BatchJobStatus, createdAt: Date, completedAt: Date? = nil, failedAt: Date? = nil, inputFileId: String? = nil, outputFileId: String? = nil, errorFileId: String? = nil, endpoint: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.failedAt = failedAt
        self.inputFileId = inputFileId
        self.outputFileId = outputFileId
        self.errorFileId = errorFileId
        self.endpoint = endpoint
    }
}

public struct BatchRequestItem: Codable, Sendable {
    public let customId: String
    public let method: String
    public let url: String
    public let body: JSONValue

    public init(customId: String, method: String, url: String, body: JSONValue) {
        self.customId = customId
        self.method = method
        self.url = url
        self.body = body
    }
    
    enum CodingKeys: String, CodingKey {
        case customId = "custom_id"
        case method
        case url
        case body
    }
}

public struct BatchResponseItem: Codable, Sendable {
    public let id: String
    public let customId: String
    public let response: BatchResponsePayload?
    public let error: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case id
        case customId = "custom_id"
        case response
        case error
    }
}

public struct BatchResponsePayload: Codable, Sendable {
    public let statusCode: Int
    public let requestId: String?
    public let body: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case requestId = "request_id"
        case body
    }
}
