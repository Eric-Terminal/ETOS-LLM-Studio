// ============================================================================
// ChatServiceNetworking.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的网络错误建模、Provider 配置校验、代理请求与请求日志持久化。
// ============================================================================

import Foundation

extension ChatService {
    enum NetworkError: LocalizedError {
        case badStatusCode(code: Int, responseBody: Data?)
        case adapterNotFound(format: String)
        case requestBuildFailed(provider: String)
        case featureUnavailable(provider: String)
        case invalidProviderConfiguration(message: String)
        case modelListUnavailable(provider: String, apiFormat: String)

        var errorDescription: String? {
            switch self {
            case .badStatusCode(let code, let responseBody):
                let bodyDescription: String
                if let responseBody, let text = String(data: responseBody, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    bodyDescription = text
                } else if let responseBody, !responseBody.isEmpty {
                    bodyDescription = String(
                        format: NSLocalizedString("响应体包含 %d 字节，无法以 UTF-8 解码。", comment: "Response body not UTF-8 with byte count"),
                        responseBody.count
                    )
                } else {
                    bodyDescription = NSLocalizedString("响应体为空。", comment: "Empty response body")
                }
                return String(
                    format: NSLocalizedString("服务器响应错误，状态码: %d\n\n响应体:\n%@", comment: "Bad status code with response body"),
                    code,
                    bodyDescription
                )
            case .adapterNotFound(let format):
                return "找不到适用于 '\(format)' 格式的 API 适配器。"
            case .requestBuildFailed(let provider):
                return "无法为 '\(provider)' 构建请求。"
            case .featureUnavailable(let provider):
                return "当前提供商 \(provider) 暂未实现语音转文字能力。"
            case .invalidProviderConfiguration(let message):
                return message
            case .modelListUnavailable(let provider, let apiFormat):
                return "\(provider) (\(apiFormat)) 当前适配器未实现在线获取模型列表，请手动配置模型。"
            }
        }
    }

    func responseBodySnippet(from bodyData: Data?) -> String {
        if let bodyData,
           let text = String(data: bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let bodyData, !bodyData.isEmpty {
            return String(
                format: NSLocalizedString("响应体包含 %d 字节，无法以 UTF-8 解码。", comment: "Response body not UTF-8 with byte count"),
                bodyData.count
            )
        }
        return NSLocalizedString("响应体为空。", comment: "Empty response body")
    }

    func providerConfigurationValidationErrorMessage(for provider: Provider, action: String) -> String? {
        let providerName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NSLocalizedString("未命名提供商", comment: "Unnamed provider fallback name")
            : provider.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.isEmpty {
            return String(
                format: NSLocalizedString("错误: 提供商“%@”未配置 API 地址，无法%@。请在提供商设置中补全后重试。", comment: "Provider missing base URL"),
                providerName,
                action
            )
        }

        if URL(string: trimmedBaseURL) == nil {
            return String(
                format: NSLocalizedString("错误: 提供商“%@”的 API 地址格式无效，无法%@。请检查地址是否包含多余空格或换行。", comment: "Provider base URL invalid"),
                providerName,
                action
            )
        }

        let hasValidAPIKey = provider.apiKeys.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !hasValidAPIKey {
            return String(
                format: NSLocalizedString("错误: 提供商“%@”未配置 API Key，无法%@。请重新填写 API Key 后重试（如从旧版本同步迁移过，建议保存一次提供商配置）。", comment: "Provider missing API key"),
                providerName,
                action
            )
        }

        return nil
    }

    /// 检测是否为取消错误（包括 CancellationError 和 URLError.cancelled）
    /// URLError(.cancelled) 不会被 Swift 的 `is CancellationError` 匹配，需要单独处理
    func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    func persistRequestLog(
        context: RequestLogContext,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage?,
        finishedAt: Date,
        recordUsageEvent: Bool = true,
        httpStatusCode: Int? = nil,
        errorKind: String? = nil
    ) {
        let normalizedUsage = tokenUsage?.hasAnyData == true ? tokenUsage : nil
        if context.requestSource == .chat {
            let logEntry = RequestLogEntry(
                requestID: context.requestID,
                sessionID: context.sessionID,
                providerID: context.providerID,
                providerName: context.providerName,
                modelID: context.modelID,
                requestedAt: context.requestedAt,
                finishedAt: finishedAt,
                isStreaming: context.isStreaming,
                status: status,
                tokenUsage: normalizedUsage
            )
            Persistence.appendRequestLog(logEntry)
        }

        guard recordUsageEvent else { return }

        let usageEvent = UsageAnalyticsEvent(
            eventID: context.requestID,
            requestSource: context.requestSource,
            sessionID: context.sessionID,
            providerID: context.providerID,
            providerName: context.providerName,
            modelID: context.modelID,
            requestedAt: context.requestedAt,
            finishedAt: finishedAt,
            isStreaming: context.isStreaming,
            status: status,
            httpStatusCode: httpStatusCode,
            errorKind: errorKind,
            tokenUsage: normalizedUsage
        )
        Persistence.appendUsageAnalyticsEvent(usageEvent)
    }

    private func makeProxySessionIfNeeded(for provider: Provider?) -> (session: URLSession, proxy: NetworkProxyConfiguration?) {
        guard let proxyConfiguration = NetworkProxySettings.resolvedConfiguration(for: provider),
              let proxyDictionary = NetworkProxySettings.makeConnectionProxyDictionary(from: proxyConfiguration) else {
            return (urlSession, nil)
        }
        let configuration = NetworkSessionConfiguration.makeConfiguration()
        configuration.connectionProxyDictionary = proxyDictionary
        return (URLSession(configuration: configuration), proxyConfiguration)
    }

    func requestData(
        for request: URLRequest,
        provider: Provider?
    ) async throws -> (Data, URLResponse) {
        let resolved = makeProxySessionIfNeeded(for: provider)
        let proxiedRequest = NetworkProxySettings.applyProxyAuthorizationHeader(
            to: request,
            configuration: resolved.proxy
        )
        return try await resolved.session.data(for: proxiedRequest)
    }

    private func requestBytes(
        for request: URLRequest,
        provider: Provider?
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let resolved = makeProxySessionIfNeeded(for: provider)
        let proxiedRequest = NetworkProxySettings.applyProxyAuthorizationHeader(
            to: request,
            configuration: resolved.proxy
        )
        return try await resolved.session.bytes(for: proxiedRequest)
    }

    func fetchData(for request: URLRequest, provider: Provider?) async throws -> Data {
        let (data, response) = try await requestData(for: request, provider: provider)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let prettyBody = String(data: data, encoding: .utf8) {
                logger.error("  - 网络请求失败，状态码: \(statusCode)，响应体:\n---\n\(prettyBody)\n---")
            } else if !data.isEmpty {
                logger.error("  - 网络请求失败，状态码: \(statusCode)，响应体包含 \(data.count) 字节的二进制数据。")
            } else {
                logger.error("  - 网络请求失败，状态码: \(statusCode)，响应体为空。")
            }
            throw NetworkError.badStatusCode(code: statusCode, responseBody: data.isEmpty ? nil : data)
        }
        return data
    }

    func streamData(for request: URLRequest, provider: Provider?) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await requestBytes(for: request, provider: provider)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            var capturedBody: Data?
            var buffer = Data()
            let limit = 64 * 1024
            do {
                for try await byte in bytes {
                    if buffer.count < limit {
                        buffer.append(byte)
                    }
                }
                if !buffer.isEmpty {
                    capturedBody = buffer
                }
            } catch {
                logger.error("  - 读取流式错误响应体失败: \(error.localizedDescription)")
            }
            if let capturedBody, let prettyBody = String(data: capturedBody, encoding: .utf8) {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体:\n---\n\(prettyBody)\n---")
            } else if let capturedBody, !capturedBody.isEmpty {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体包含 \(capturedBody.count) 字节的二进制数据。")
            } else {
                logger.error("  - 流式网络请求失败，状态码: \(statusCode)，响应体为空。")
            }
            throw NetworkError.badStatusCode(code: statusCode, responseBody: capturedBody)
        }
        return bytes
    }
}
