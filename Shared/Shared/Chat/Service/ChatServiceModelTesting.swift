// ============================================================================
// ChatServiceModelTesting.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供不写入聊天历史的模型连通性批量测试。
// ============================================================================

import Foundation

public struct ModelConnectivityTestResult: Identifiable, Sendable {
    public enum Status: Sendable, Equatable {
        case pending
        case testing
        case succeeded
        case failed
    }

    public let id: String
    public let providerID: UUID
    public let providerName: String
    public let modelID: UUID
    public let modelName: String
    public let displayName: String
    public var status: Status
    public var latencyMilliseconds: Int?
    public var responsePreview: String?
    public var errorMessage: String?

    public init(
        runnableModel: RunnableModel,
        status: Status = .pending,
        latencyMilliseconds: Int? = nil,
        responsePreview: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = runnableModel.id
        self.providerID = runnableModel.provider.id
        self.providerName = runnableModel.provider.name
        self.modelID = runnableModel.model.id
        self.modelName = runnableModel.model.modelName
        self.displayName = runnableModel.model.displayName
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.responsePreview = responsePreview
        self.errorMessage = errorMessage
    }
}

public extension ModelConnectivityTestResult.Status {
    var localizedName: String {
        switch self {
        case .pending:
            return NSLocalizedString("等待测试", comment: "Model connectivity test status")
        case .testing:
            return NSLocalizedString("测试中", comment: "Model connectivity test status")
        case .succeeded:
            return NSLocalizedString("可用", comment: "Model connectivity test status")
        case .failed:
            return NSLocalizedString("不可用", comment: "Model connectivity test status")
        }
    }
}

extension ChatService {
    public func connectivityTestCandidates(for provider: Provider) -> [RunnableModel] {
        provider.models
            .filter { $0.isActivated && $0.isChatModel }
            .map { RunnableModel(provider: provider, model: $0) }
    }

    public func testModelConnectivity(
        for runnableModel: RunnableModel
    ) async -> ModelConnectivityTestResult {
        var result = ModelConnectivityTestResult(runnableModel: runnableModel, status: .testing)
        let startedAt = Date()
        let requestContext = RequestLogContext(
            requestID: UUID(),
            sessionID: nil,
            providerID: runnableModel.provider.id,
            providerName: runnableModel.provider.name,
            modelID: runnableModel.model.modelName,
            requestSource: .modelTest,
            isStreaming: false,
            requestedAt: startedAt
        )

        do {
            guard let adapter = adapters[runnableModel.provider.apiFormat] else {
                throw NetworkError.adapterNotFound(format: runnableModel.provider.apiFormat)
            }

            if let configurationError = providerConfigurationValidationErrorMessage(
                for: runnableModel.provider,
                action: NSLocalizedString("测试模型连通性", comment: "Model connectivity test action")
            ) {
                throw NetworkError.invalidProviderConfiguration(message: configurationError)
            }

            let messages = [
                ChatMessage(
                    role: .user,
                    content: NSLocalizedString("请只回复 OK。", comment: "Model connectivity test prompt")
                )
            ]
            let payload: [String: Any] = [
                "temperature": 0,
                "stream": false
            ]
            guard let request = adapter.buildChatRequest(
                for: runnableModel,
                commonPayload: payload,
                messages: messages,
                tools: nil,
                audioAttachments: [:],
                imageAttachments: [:],
                fileAttachments: [:]
            ) else {
                throw DetachedCompletionError.buildRequestFailed
            }

            let data = try await fetchData(for: request, provider: runnableModel.provider)
            let responseMessage = try adapter.parseResponse(data: data)
            result.status = .succeeded
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.responsePreview = Self.trimmedConnectivityPreview(responseMessage.content)
            persistRequestLog(
                context: requestContext,
                status: .success,
                tokenUsage: responseMessage.tokenUsage,
                finishedAt: Date()
            )
        } catch is CancellationError {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = NSLocalizedString("测试已取消。", comment: "Model connectivity test cancelled")
            persistRequestLog(
                context: requestContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = NetworkError.badStatusCode(code: code, responseBody: bodyData).localizedDescription
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
        } catch {
            result.status = .failed
            result.latencyMilliseconds = Self.elapsedMilliseconds(since: startedAt)
            result.errorMessage = error.localizedDescription
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "model_test_failed"
            )
        }

        return result
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private static func trimmedConnectivityPreview(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 160 {
            return trimmed
        }
        return String(trimmed.prefix(160))
    }
}
