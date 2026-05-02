// ============================================================================
// ChatService.swift
// ============================================================================ 
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================ 

import Foundation
import Combine
import CryptoKit
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
extension ChatService {

    func resolveGeneratedImagePayload(
        from result: GeneratedImageResult,
        provider: Provider
    ) async throws -> (data: Data, mimeType: String)? {
        if let imageData = result.data, !imageData.isEmpty {
            let mimeType = (result.mimeType?.isEmpty == false ? result.mimeType! : detectImageMimeType(from: imageData))
            logger.info("生图结果使用内联图片数据: mime=\(mimeType), bytes=\(imageData.count)")
            return (imageData, mimeType)
        }

        guard let remoteURL = result.remoteURL else { return nil }
        logger.info("生图结果改为下载远端图片: \(remoteURL.absoluteString)")

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        let (data, response) = try await requestData(for: request, provider: provider)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            logger.error("下载生图结果失败: status=\(httpResponse.statusCode), url=\(remoteURL.absoluteString)")
            throw NetworkError.badStatusCode(code: httpResponse.statusCode, responseBody: data.isEmpty ? nil : data)
        }
        guard !data.isEmpty else {
            logger.warning("下载生图结果返回空数据: \(remoteURL.absoluteString)")
            return nil
        }
        let mimeType = result.mimeType ?? response.mimeType ?? detectImageMimeType(from: data)
        logger.info("下载生图结果成功: mime=\(mimeType), bytes=\(data.count)")
        return (data, mimeType)
    }

    func detectImageMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "image/png" }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        return "image/png"
    }

    func imageFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "png"
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
    
    // MARK: - 私有网络层与响应处理 (已重构)

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
            case .adapterNotFound(let format): return "找不到适用于 '\(format)' 格式的 API 适配器。"
            case .requestBuildFailed(let provider): return "无法为 '\(provider)' 构建请求。"
            case .featureUnavailable(let provider): return "当前提供商 \(provider) 暂未实现语音转文字能力。"
            case .invalidProviderConfiguration(let message): return message
            case .modelListUnavailable(let provider, let apiFormat): return "\(provider) (\(apiFormat)) 当前适配器未实现在线获取模型列表，请手动配置模型。"
            }
        }
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

    func estimatedCompletionTokens(from outputText: String) -> Int {
        let utf8Count = outputText.utf8.count
        guard utf8Count > 0 else { return 0 }
        // 粗略估算：兼顾英文与中日韩文本，优先用于流式实时速度展示。
        let estimated = Int((Double(utf8Count) / 3.2).rounded(.toNearestOrAwayFromZero))
        return max(1, estimated)
    }

    func tokenPerSecond(tokens: Int?, elapsed: TimeInterval) -> Double? {
        guard let tokens, tokens > 0, elapsed > 0 else { return nil }
        return Double(tokens) / elapsed
    }

    /// 合并流式返回的 token 使用量分片，避免后续分片覆盖掉前面字段（例如先返回 prompt，后返回 completion）。
    func mergeTokenUsage(existing: MessageTokenUsage?, incoming: MessageTokenUsage) -> MessageTokenUsage {
        MessageTokenUsage(
            promptTokens: incoming.promptTokens ?? existing?.promptTokens,
            completionTokens: incoming.completionTokens ?? existing?.completionTokens,
            totalTokens: incoming.totalTokens ?? existing?.totalTokens,
            thinkingTokens: incoming.thinkingTokens ?? existing?.thinkingTokens,
            cacheWriteTokens: incoming.cacheWriteTokens ?? existing?.cacheWriteTokens,
            cacheReadTokens: incoming.cacheReadTokens ?? existing?.cacheReadTokens
        )
    }

    func mergeReasoningProviderSpecificFields(
        existing: [String: JSONValue]?,
        incoming: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = existing ?? [:]
        for (key, value) in incoming {
            if case let .array(incomingArray) = value,
               case let .array(existingArray) = merged[key] {
                merged[key] = .array(existingArray + incomingArray)
            } else {
                merged[key] = value
            }
        }
        return merged.isEmpty ? [:] : merged
    }

    /// 流式速度计算：按照“总时长 - 首字时间”得到生成阶段时长，再计算 token/s。
    func streamingTokenPerSecond(
        tokens: Int?,
        requestStartedAt: Date,
        firstTokenAt: Date?,
        snapshotAt: Date
    ) -> Double? {
        guard let firstTokenAt else { return nil }
        let totalDuration = max(0, snapshotAt.timeIntervalSince(requestStartedAt))
        let timeToFirstToken = max(0, firstTokenAt.timeIntervalSince(requestStartedAt))
        let generationDuration = totalDuration - timeToFirstToken
        return tokenPerSecond(tokens: tokens, elapsed: generationDuration)
    }

    func effectiveStreamResponseCompletedAt(
        lastGeneratedDeltaAt: Date?,
        lastStreamPartReceivedAt: Date?,
        fallbackCompletedAt: Date
    ) -> Date {
        lastGeneratedDeltaAt ?? lastStreamPartReceivedAt ?? fallbackCompletedAt
    }

    /// 将流式速度按“整秒”采样并追加到序列中，用于实时曲线展示。
    func appendSpeedSample(
        to samples: inout [MessageResponseMetrics.SpeedSample],
        elapsed: TimeInterval,
        speed: Double?
    ) {
        guard let speed, speed.isFinite, speed > 0 else { return }
        let second = max(0, Int(elapsed.rounded(.down)))
        let sample = MessageResponseMetrics.SpeedSample(elapsedSecond: second, tokenPerSecond: speed)

        if let lastIndex = samples.indices.last {
            let last = samples[lastIndex]
            if sample.elapsedSecond == last.elapsedSecond {
                samples[lastIndex] = sample
                return
            }
            if sample.elapsedSecond < last.elapsedSecond {
                return
            }
        }
        samples.append(sample)
    }

    func makeResponseMetrics(
        requestStartedAt: Date,
        responseCompletedAt: Date?,
        totalResponseDuration: TimeInterval?,
        timeToFirstToken: TimeInterval?,
        reasoningStartedAt: Date? = nil,
        reasoningCompletedAt: Date? = nil,
        completionTokensForSpeed: Int?,
        tokenPerSecond: Double?,
        isEstimated: Bool,
        speedSamples: [MessageResponseMetrics.SpeedSample]? = nil
    ) -> MessageResponseMetrics {
        MessageResponseMetrics(
            requestStartedAt: requestStartedAt,
            responseCompletedAt: responseCompletedAt,
            totalResponseDuration: totalResponseDuration,
            timeToFirstToken: timeToFirstToken,
            reasoningStartedAt: reasoningStartedAt,
            reasoningCompletedAt: reasoningCompletedAt,
            completionTokensForSpeed: completionTokensForSpeed,
            tokenPerSecond: tokenPerSecond,
            isTokenPerSecondEstimated: isEstimated,
            speedSamples: speedSamples
        )
    }

    func ensureReasoningTimingIfNeeded(
        for message: inout ChatMessage,
        fallbackRequestStartedAt: Date? = nil,
        fallbackCompletedAt: Date? = nil
    ) {
        let reasoning = (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return }

        var metrics = message.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt
                ?? fallbackRequestStartedAt
                ?? message.requestedAt
                ?? metrics.responseCompletedAt
                ?? fallbackCompletedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = fallbackCompletedAt
                ?? metrics.responseCompletedAt
                ?? metrics.reasoningStartedAt
        }
        message.responseMetrics = metrics
    }

    func finalizeInterruptedReasoningMessage(_ message: ChatMessage, completedAt: Date = Date()) -> ChatMessage {
        var updated = message
        let reasoning = (updated.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return updated }

        var metrics = updated.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt ?? updated.requestedAt ?? completedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = completedAt
        }
        updated.responseMetrics = metrics
        return updated
    }

    /// 仅在内存中保留“最近一条助手消息”的流式速度采样，避免历史样本长期占用内存。
    func normalizedMessagesForRuntime(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        let keepMessageID = preferredMessageID ?? messages.last(where: { $0.role == .assistant })?.id

        return messages.map { message in
            guard var metrics = message.responseMetrics, metrics.speedSamples != nil else {
                return message
            }
            if let keepMessageID, message.id == keepMessageID {
                return message
            }
            var trimmedMessage = message
            metrics.speedSamples = nil
            trimmedMessage.responseMetrics = metrics
            return trimmedMessage
        }
    }

    /// 将流式采样作为临时 UI 数据，不写入磁盘，避免会话文件膨胀。
    func normalizedMessagesForPersistence(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard var metrics = message.responseMetrics, metrics.speedSamples != nil else {
                return message
            }
            var trimmedMessage = message
            metrics.speedSamples = nil
            trimmedMessage.responseMetrics = metrics
            return trimmedMessage
        }
    }

    func publishMessages(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        let normalized = normalizedMessagesForRuntime(messages, keepingSpeedSamplesFor: preferredMessageID)
        messagesForSessionSubject.send(normalized)
    }

    func persistMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        let persisted = normalizedMessagesForPersistence(messages)
        Persistence.saveMessages(persisted, for: sessionID)
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

        logRequestResult(
            context: context,
            status: status,
            tokenUsage: normalizedUsage,
            finishedAt: finishedAt,
            httpStatusCode: httpStatusCode,
            errorKind: errorKind
        )

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

    func logRequestResult(
        context: RequestLogContext,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage?,
        finishedAt: Date,
        httpStatusCode: Int?,
        errorKind: String?
    ) {
        let duration = max(0, finishedAt.timeIntervalSince(context.requestedAt))
        var payload: [String: String] = [
            "requestID": context.requestID.uuidString,
            "来源": context.requestSource.displayName,
            "状态": requestLogStatusDisplayName(status),
            "耗时秒": String(format: "%.3f", duration),
            "提供商": context.providerName,
            "模型": context.modelID,
            "流式": context.isStreaming ? "true" : "false"
        ]
        if let sessionID = context.sessionID {
            payload["sessionID"] = sessionID.uuidString
        }
        if let providerID = context.providerID {
            payload["providerID"] = providerID.uuidString
        }
        if let httpStatusCode {
            payload["HTTP状态码"] = "\(httpStatusCode)"
        }
        if let errorKind {
            payload["错误类型"] = errorKind
        }
        if let tokenUsage {
            payload["输入Token"] = tokenUsage.promptTokens.map { "\($0)" } ?? "未知"
            payload["输出Token"] = tokenUsage.completionTokens.map { "\($0)" } ?? "未知"
            payload["思考Token"] = tokenUsage.thinkingTokens.map { "\($0)" } ?? "未知"
            payload["缓存写入Token"] = tokenUsage.cacheWriteTokens.map { "\($0)" } ?? "未知"
            payload["缓存读取Token"] = tokenUsage.cacheReadTokens.map { "\($0)" } ?? "未知"
            payload["总Token"] = tokenUsage.totalTokens.map { "\($0)" } ?? "未知"
        }

        AppLog.developer(
            level: appLogLevel(for: status),
            category: "请求",
            action: "记录请求结果",
            message: "\(context.requestSource.displayName)请求\(requestLogStatusDisplayName(status))",
            payload: payload
        )
    }

    func appLogLevel(for status: RequestLogStatus) -> AppLogLevel {
        switch status {
        case .success:
            return .info
        case .failed:
            return .error
        case .cancelled:
            return .warning
        }
    }

    func requestLogStatusDisplayName(_ status: RequestLogStatus) -> String {
        switch status {
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    func makeProxySessionIfNeeded(for provider: Provider?) -> (session: URLSession, proxy: NetworkProxyConfiguration?) {
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
        let startedAt = Date()
        let resolved = makeProxySessionIfNeeded(for: provider)
        let proxiedRequest = NetworkProxySettings.applyProxyAuthorizationHeader(
            to: request,
            configuration: resolved.proxy
        )
        logHTTPRequestStart(request: proxiedRequest, provider: provider, proxy: resolved.proxy, transport: "data")
        do {
            let result = try await resolved.session.data(for: proxiedRequest)
            logHTTPResponse(
                request: proxiedRequest,
                response: result.1,
                provider: provider,
                bodyByteCount: result.0.count,
                startedAt: startedAt,
                transport: "data"
            )
            return result
        } catch {
            logHTTPTransportFailure(
                request: proxiedRequest,
                provider: provider,
                error: error,
                startedAt: startedAt,
                transport: "data"
            )
            throw error
        }
    }

    func requestBytes(
        for request: URLRequest,
        provider: Provider?
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let startedAt = Date()
        let resolved = makeProxySessionIfNeeded(for: provider)
        let proxiedRequest = NetworkProxySettings.applyProxyAuthorizationHeader(
            to: request,
            configuration: resolved.proxy
        )
        logHTTPRequestStart(request: proxiedRequest, provider: provider, proxy: resolved.proxy, transport: "stream")
        do {
            let result = try await resolved.session.bytes(for: proxiedRequest)
            logHTTPResponse(
                request: proxiedRequest,
                response: result.1,
                provider: provider,
                bodyByteCount: nil,
                startedAt: startedAt,
                transport: "stream"
            )
            return result
        } catch {
            logHTTPTransportFailure(
                request: proxiedRequest,
                provider: provider,
                error: error,
                startedAt: startedAt,
                transport: "stream"
            )
            throw error
        }
    }

    func logHTTPRequestStart(
        request: URLRequest,
        provider: Provider?,
        proxy: NetworkProxyConfiguration?,
        transport: String
    ) {
        var payload: [String: String] = [
            "传输": transport,
            "方法": request.httpMethod ?? "GET",
            "地址": AppLogRedactor.sanitizeURLForLog(request.url),
            "提供商": provider?.name ?? "无",
            "请求体字节数": "\(request.httpBody?.count ?? 0)",
            "超时秒": String(format: "%.1f", request.timeoutInterval)
        ]
        if let proxy {
            payload["代理"] = "\(proxy.type.rawValue)://\(proxy.trimmedHost):\(proxy.port)"
            payload["代理鉴权"] = proxy.hasAuthentication ? "true" : "false"
        } else {
            payload["代理"] = "未启用"
        }

        AppLog.developer(
            level: .debug,
            category: "网络",
            action: "发送HTTP请求",
            message: "HTTP 请求已发出",
            payload: payload
        )
    }

    func logHTTPResponse(
        request: URLRequest,
        response: URLResponse,
        provider: Provider?,
        bodyByteCount: Int?,
        startedAt: Date,
        transport: String
    ) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        var payload: [String: String] = [
            "传输": transport,
            "方法": request.httpMethod ?? "GET",
            "地址": AppLogRedactor.sanitizeURLForLog(request.url),
            "提供商": provider?.name ?? "无",
            "HTTP状态码": "\(statusCode)",
            "耗时秒": String(format: "%.3f", max(0, Date().timeIntervalSince(startedAt))),
            "MIME": response.mimeType ?? "未知"
        ]
        if let bodyByteCount {
            payload["响应字节数"] = "\(bodyByteCount)"
        }
        if response.expectedContentLength >= 0 {
            payload["预期响应字节数"] = "\(response.expectedContentLength)"
        }

        let isSuccess = (200...299).contains(statusCode)
        AppLog.developer(
            level: isSuccess ? .debug : .warning,
            category: "网络",
            action: "收到HTTP响应",
            message: isSuccess ? "HTTP 响应成功" : "HTTP 响应状态异常",
            payload: payload
        )
    }

    func logHTTPTransportFailure(
        request: URLRequest,
        provider: Provider?,
        error: Error,
        startedAt: Date,
        transport: String
    ) {
        AppLog.developer(
            level: isCancellationError(error) ? .warning : .error,
            category: "网络",
            action: "HTTP传输失败",
            message: AppLogRedactor.sanitizeFreeTextForLog(error.localizedDescription, maxLength: 1_000),
            payload: [
                "传输": transport,
                "方法": request.httpMethod ?? "GET",
                "地址": AppLogRedactor.sanitizeURLForLog(request.url),
                "提供商": provider?.name ?? "无",
                "耗时秒": String(format: "%.3f", max(0, Date().timeIntervalSince(startedAt))),
                "错误类型": String(describing: type(of: error))
            ]
        )
    }

    func logHTTPErrorBody(
        request: URLRequest,
        provider: Provider?,
        statusCode: Int,
        bodyData: Data?,
        transport: String
    ) {
        AppLog.developer(
            level: .error,
            category: "网络",
            action: "HTTP错误响应体",
            message: "HTTP \(statusCode) 错误响应体已捕获",
            payload: [
                "传输": transport,
                "方法": request.httpMethod ?? "GET",
                "地址": AppLogRedactor.sanitizeURLForLog(request.url),
                "提供商": provider?.name ?? "无",
                "HTTP状态码": "\(statusCode)",
                "响应体摘要": AppLogRedactor.sanitizeFreeTextForLog(responseBodySnippet(from: bodyData), maxLength: 4_000)
            ]
        )
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
            logHTTPErrorBody(
                request: request,
                provider: provider,
                statusCode: statusCode,
                bodyData: data.isEmpty ? nil : data,
                transport: "data"
            )
            throw NetworkError.badStatusCode(code: statusCode, responseBody: data.isEmpty ? nil : data)
        }
        return data
    }
}
