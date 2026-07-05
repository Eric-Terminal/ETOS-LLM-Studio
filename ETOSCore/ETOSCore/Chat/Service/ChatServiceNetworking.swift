// ============================================================================
// ChatServiceNetworking.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的网络错误建模、Provider 配置校验、代理请求与请求日志持久化。
// ============================================================================

import Foundation
import os.log

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
                return String(format: NSLocalizedString("找不到适用于 '%@' 格式的 API 适配器。", comment: "API adapter missing error"), format)
            case .requestBuildFailed(let provider):
                return String(format: NSLocalizedString("无法为 '%@' 构建请求。", comment: "API request build failed error"), provider)
            case .featureUnavailable(let provider):
                return String(format: NSLocalizedString("当前提供商 %@ 暂未实现语音转文字能力。", comment: "Speech to text unavailable for provider error"), provider)
            case .invalidProviderConfiguration(let message):
                return message
            case .modelListUnavailable(let provider, let apiFormat):
                return String(format: NSLocalizedString("%@ (%@) 当前适配器未实现在线获取模型列表，请手动配置模型。", comment: "Online model list unavailable error"), provider, apiFormat)
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

    func isOpenAIResponsesRequest(_ request: URLRequest) -> Bool {
        guard let lastPathComponent = request.url?.path.split(separator: "/").last else {
            return false
        }
        return lastPathComponent == "responses"
    }

    func openAIResponsesRequestUsesPreviousResponseID(_ request: URLRequest) -> Bool {
        guard isOpenAIResponsesRequest(request),
              let payload = jsonObjectBody(from: request),
              let previousResponseID = payload["previous_response_id"] as? String else {
            return false
        }
        return !previousResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func openAIResponsesRequestSignature(from request: URLRequest) -> JSONValue? {
        guard isOpenAIResponsesRequest(request),
              var payload = jsonObjectBody(from: request) else {
            return nil
        }
        payload.removeValue(forKey: "input")
        payload.removeValue(forKey: "previous_response_id")
        payload.removeValue(forKey: OpenAIAdapter.responsesForceFullInputControlKey)
        return jsonValueForRequestMetadata(from: payload)
    }

    func attachOpenAIResponsesRequestMetadata(
        to message: inout ChatMessage,
        request: URLRequest,
        messagesBeforeResponse: [ChatMessage] = []
    ) {
        guard let requestSignature = openAIResponsesRequestSignature(from: request) else { return }
        var metadata = message.providerResponseMetadata ?? [:]
        metadata[OpenAIAdapter.responsesRequestSignatureKey] = requestSignature
        if let contextSignature = openAIResponsesContextSignature(
            for: message,
            request: request,
            messagesBeforeResponse: messagesBeforeResponse
        ) {
            metadata[OpenAIAdapter.responsesContextSignatureKey] = contextSignature
        }
        message.providerResponseMetadata = metadata
    }

    func openAIResponsesContextSignature(
        for message: ChatMessage,
        request: URLRequest,
        messagesBeforeResponse: [ChatMessage]
    ) -> JSONValue? {
        guard isOpenAIResponsesRequest(request),
              let payload = jsonObjectBody(from: request),
              let inputItems = payload["input"] as? [[String: Any]] else {
            return nil
        }

        let previousSignature: String?
        if let previousResponseID = payload["previous_response_id"] as? String,
           !previousResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previousSignature = openAIResponsesStoredContextSignature(
                responseID: previousResponseID,
                messages: messagesBeforeResponse
            )
            guard previousSignature != nil else { return nil }
        } else {
            previousSignature = nil
        }

        let outputItems = openAIResponsesOutputItems(from: message)
        return OpenAIAdapter.responsesContextSignature(
            previousSignature: previousSignature,
            appending: inputItems + outputItems
        )
    }

    func openAIResponsesStoredContextSignature(responseID: String, messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            guard let metadata = message.providerResponseMetadata,
                  case let .string(storedResponseID)? = metadata[OpenAIAdapter.responsesResponseIDKey],
                  storedResponseID == responseID,
                  case let .string(contextSignature)? = metadata[OpenAIAdapter.responsesContextSignatureKey],
                  !contextSignature.isEmpty else {
                continue
            }
            return contextSignature
        }
        return nil
    }

    func openAIResponsesOutputItems(from message: ChatMessage) -> [[String: Any]] {
        guard let metadata = message.providerResponseMetadata,
              case let .array(items)? = metadata[OpenAIAdapter.responsesOutputItemsKey] else {
            return []
        }
        return items.compactMap { $0.toAny() as? [String: Any] }
    }

    func isOpenAIResponsesPreviousResponseMissing(statusCode: Int, bodyData: Data?) -> Bool {
        guard statusCode == 400 || statusCode == 404 else { return false }
        guard let bodyData,
              let text = String(data: bodyData, encoding: .utf8)?.lowercased() else {
            return false
        }

        if let object = try? JSONSerialization.jsonObject(with: bodyData),
           let payload = object as? [String: Any],
           let error = payload["error"] as? [String: Any] {
            let code = (error["code"] as? String)?.lowercased() ?? ""
            let message = (error["message"] as? String)?.lowercased() ?? ""
            if code.contains("previous_response") || code.contains("response_not_found") {
                return true
            }
            if message.contains("previous_response_id")
                && (message.contains("not found")
                    || message.contains("not exist")
                    || message.contains("could not find")
                    || message.contains("missing")) {
                return true
            }
        }

        return text.contains("previous_response_not_found")
            || (text.contains("previous_response_id")
                && (text.contains("not found")
                    || text.contains("not exist")
                    || text.contains("could not find")
                    || text.contains("missing")))
    }

    func jsonObjectBody(from request: URLRequest) -> [String: Any]? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) else {
            return nil
        }
        return object as? [String: Any]
    }

    func jsonValueForRequestMetadata(from object: Any) -> JSONValue? {
        switch object {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let number as NSNumber:
            let objCType = String(cString: number.objCType)
            if objCType == "c" || objCType == "B" {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            if doubleValue.isFinite,
               floor(doubleValue) == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dictionary {
                guard let jsonValue = jsonValueForRequestMetadata(from: value) else { return nil }
                result[key] = jsonValue
            }
            return .dictionary(result)
        case let array as [Any]:
            var result: [JSONValue] = []
            for value in array {
                guard let jsonValue = jsonValueForRequestMetadata(from: value) else { return nil }
                result.append(jsonValue)
            }
            return .array(result)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
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
        if (context.requestSource == .chat || context.requestSource == .imageGeneration),
           AppConfigStore.boolValue(for: .requestLogEnabled) {
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

    func makeResponseBodySnapshotPayload(
        context: RequestLogContext,
        request: URLRequest,
        body: String,
        byteCount: Int,
        httpStatusCode: Int? = nil,
        isPartial: Bool = false
    ) -> [String: String]? {
        guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return nil }

        var payload: [String: String] = [
            NSLocalizedString("提供商", comment: "App log payload key"): context.providerName,
            NSLocalizedString("模型", comment: "App log payload key"): context.modelID,
            NSLocalizedString("请求 ID", comment: "App log payload key"): context.requestID.uuidString,
            NSLocalizedString("方法", comment: "App log payload key"): request.httpMethod ?? "POST",
            NSLocalizedString("地址", comment: "App log payload key"): AppLogRedactor.sanitizeURLForLog(request.url),
            NSLocalizedString("流式", comment: "App log payload key"): context.isStreaming
                ? NSLocalizedString("是", comment: "App log payload value")
                : NSLocalizedString("否", comment: "App log payload value"),
            NSLocalizedString("响应体字节数", comment: "App log payload key"): "\(byteCount)"
        ]

        if let httpStatusCode {
            payload[NSLocalizedString("状态码", comment: "App log payload key")] = "\(httpStatusCode)"
        }

        let bodyKey: String
        if context.isStreaming {
            bodyKey = isPartial
                ? NSLocalizedString("流式响应体(部分)", comment: "App log payload key")
                : NSLocalizedString("流式响应体", comment: "App log payload key")
        } else {
            bodyKey = isPartial
                ? NSLocalizedString("响应体(部分)", comment: "App log payload key")
                : NSLocalizedString("响应体", comment: "App log payload key")
        }
        payload[bodyKey] = body
        return payload
    }

    func logResponseBodySnapshot(
        context: RequestLogContext,
        request: URLRequest,
        body: String,
        byteCount: Int? = nil,
        httpStatusCode: Int? = nil,
        isPartial: Bool = false
    ) {
        let resolvedByteCount = byteCount ?? body.data(using: .utf8)?.count ?? 0
        guard let payload = makeResponseBodySnapshotPayload(
            context: context,
            request: request,
            body: body,
            byteCount: resolvedByteCount,
            httpStatusCode: httpStatusCode,
            isPartial: isPartial
        ) else {
            return
        }

        AppLog.developer(
            level: .debug,
            category: NSLocalizedString("请求", comment: "App log category"),
            action: String(format: NSLocalizedString("接收%@响应", comment: "App log action"), context.providerName),
            message: String(format: NSLocalizedString("%@ 响应体已接收", comment: "App log message"), context.providerName),
            payload: payload
        )
    }

    func logResponseBodySnapshot(
        context: RequestLogContext,
        request: URLRequest,
        bodyData: Data?,
        httpStatusCode: Int? = nil,
        isPartial: Bool = false
    ) {
        let bodyText: String
        if let bodyData, let text = String(data: bodyData, encoding: .utf8) {
            bodyText = text
        } else if let bodyData, !bodyData.isEmpty {
            bodyText = String(
                format: NSLocalizedString("响应体包含 %d 字节，无法以 UTF-8 解码。", comment: "Response body not UTF-8 with byte count"),
                bodyData.count
            )
        } else {
            bodyText = NSLocalizedString("响应体为空。", comment: "Empty response body")
        }

        logResponseBodySnapshot(
            context: context,
            request: request,
            body: bodyText,
            byteCount: bodyData?.count ?? 0,
            httpStatusCode: httpStatusCode,
            isPartial: isPartial
        )
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
