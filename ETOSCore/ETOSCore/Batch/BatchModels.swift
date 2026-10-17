import Foundation

/// 远端状态与本地提交状态分开保存，网络中断不能被误认为远端任务失败。
public enum BatchJobStatus: String, Codable, Sendable {
    case validating, inProgress = "in_progress", finalizing, completed, failed, expired, cancelling, cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .expired, .cancelled: true
        default: false
        }
    }
}

public enum BatchSubmissionState: String, Codable, Sendable {
    case prepared, uploading, creating, uncertain, submitted, failed
}

public struct BatchRequestItem: Codable, Sendable, Identifiable {
    public var id: String
    public var input: String
    public var body: JSONValue
}

public struct BatchResult: Codable, Sendable, Identifiable {
    public var id: String
    public var text: String?
    public var reasoning: String?
    public var error: String?
    public var rawResponse: JSONValue?
    public var succeeded: Bool { error == nil }
}

public struct BatchJob: Codable, Sendable, Identifiable {
    public var id: UUID
    public var remoteID: String?
    public var title: String
    public var providerID: UUID
    public var modelID: UUID
    public var providerName: String
    public var modelName: String
    public var baseURL: String
    // 只保存凭据指纹；恢复任务仍需本机提供商配置，绝不把密钥复制进任务或导出文件。
    public var credentialDigest: String
    public var headersDigest: String
    public var endpoint: String
    public var requests: [BatchRequestItem]
    public var results: [BatchResult] = []
    public var submission: BatchSubmissionState = .prepared
    public var status: BatchJobStatus?
    public var createdAt: Date = Date()
    public var remoteCreatedAt: Date?
    public var finishedAt: Date?
    public var updatedAt: Date = Date()
    public var inputFileID: String?
    public var outputFileID: String?
    public var errorFileID: String?
    public var resultsDownloaded = false
    public var notified = false
    public var errorMessage: String?

    public var needsRefresh: Bool {
        remoteID != nil && (status?.isTerminal != true || !resultsDownloaded || !notified)
    }
}

enum BatchError: LocalizedError {
    case invalidInput, unsupportedModel, credentialsChanged, unavailableStore, busy, invalidResponse
    case uncertainSubmission, missingResult, noFailedItems, activeJob, storeReplaced

    var errorDescription: String? {
        switch self {
        case .invalidInput: NSLocalizedString("batch.error.input", value: "Enter at least one nonempty request and select a model.", comment: "批量输入错误")
        case .unsupportedModel: NSLocalizedString("batch.error.model", value: "Choose an OpenAI-compatible text chat model. The provider must support the Batch API.", comment: "批量模型不支持")
        case .credentialsChanged: NSLocalizedString("batch.error.credentials", value: "The provider address, headers or API key used for this job changed. Restore the original configuration to manage it.", comment: "批量凭据已变更")
        case .unavailableStore: NSLocalizedString("batch.error.storage", value: "The batch job could not be saved. Unlock the database and try again.", comment: "批量存储失败")
        case .busy: NSLocalizedString("batch.error.busy", value: "This job is already being updated.", comment: "批量操作进行中")
        case .invalidResponse: NSLocalizedString("batch.error.response", value: "The provider returned an invalid batch response.", comment: "批量响应错误")
        case .uncertainSubmission: NSLocalizedString("batch.error.uncertain", value: "The submission response was lost. Recover the job before submitting again to avoid duplicate charges. If it cannot be found, check the provider dashboard.", comment: "批量提交待核实")
        case .missingResult: NSLocalizedString("batch.error.missing", value: "No result was returned for this request.", comment: "批量缺失结果")
        case .noFailedItems: NSLocalizedString("batch.error.retry", value: "Download all results before retrying failed requests.", comment: "批量重试限制")
        case .activeJob: NSLocalizedString("batch.error.active", value: "Cancel the remote job and refresh its final status before removing it.", comment: "批量删除限制")
        case .storeReplaced: NSLocalizedString("batch.error.storage", value: "The batch job could not be saved. Unlock the database and try again.", comment: "批量存储失败")
        }
    }
}

struct OpenAIBatchResponse: Decodable, Sendable {
    var id: String
    var status: BatchJobStatus
    var created_at: TimeInterval
    var completed_at: TimeInterval?
    var failed_at: TimeInterval?
    var expired_at: TimeInterval?
    var cancelled_at: TimeInterval?
    var input_file_id: String?
    var output_file_id: String?
    var error_file_id: String?
    var metadata: [String: String]?
    var errors: Errors?

    struct Errors: Decodable, Sendable {
        var data: [Entry]?
        struct Entry: Decodable, Sendable { var message: String? }
    }

    func applying(to original: BatchJob) -> BatchJob {
        var job = original
        job.remoteID = id
        job.submission = .submitted
        job.status = status
        job.remoteCreatedAt = Date(timeIntervalSince1970: created_at)
        job.finishedAt = (completed_at ?? failed_at ?? expired_at ?? cancelled_at).map(Date.init(timeIntervalSince1970:))
        job.inputFileID = input_file_id
        job.outputFileID = output_file_id
        job.errorFileID = error_file_id
        job.errorMessage = errors?.data?.compactMap(\.message).joined(separator: "\n")
        return job
    }
}
