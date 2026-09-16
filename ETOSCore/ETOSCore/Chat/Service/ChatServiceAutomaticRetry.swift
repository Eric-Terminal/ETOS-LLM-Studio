import Foundation

public struct ChatRequestRetryStatus: Hashable, Sendable {
    public let attempt: Int
    public let maximumAttempts: Int

    public var thinkingText: String {
        String(format: NSLocalizedString("正在思考·重试(%d/%d)", comment: ""), attempt, maximumAttempts)
    }
}

public enum ChatRequestRetryPolicy {
    public static let defaultMaximumRetries = 3
    public static let allowedMaximumRetries = 0...10

    static func delay(forRetry retry: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, min(retry - 1, 5)))))
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case ChatService.NetworkError.badStatusCode(let code, _) = error {
            return [408, 429, 500, 502, 503, 504, 529].contains(code)
        }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet].contains { $0.rawValue == error.code }
    }
}

extension ChatService {
    /// 只重放当前模型请求；已完成的工具调用和附件预处理不会再次执行。
    func withAutomaticRequestRetries(
        request: URLRequest,
        loadingMessageID: UUID,
        sessionID: UUID,
        requestLogContext: RequestLogContext,
        initialPrefill: ChatMessage?,
        rebuildRequest: (ChatMessage) -> URLRequest?,
        operation: (URLRequest, UUID, RequestLogContext, @escaping (Error) async -> Bool) async -> Void
    ) async {
        let configuredMaximum = await MainActor.run { AppConfigStore.shared.maximumRequestRetries }
        let maximumRetries = min(10, max(0, configuredMaximum))
        var retryCount = 0
        var currentRequest = request
        var currentLoadingID = loadingMessageID
        var currentLogContext = requestLogContext
        var prefix = initialPrefill?.content ?? ""

        defer { setRequestRetryStatus(nil, messageID: currentLoadingID, sessionID: sessionID) }
        while !Task.isCancelled {
            var failure: Error?
            RequestTransactionLogRegistry.bindRequest(
                currentRequest, requestID: currentLogContext.requestID,
                requestedAt: currentLogContext.requestedAt, providerName: currentLogContext.providerName,
                modelID: currentLogContext.modelID, isStreaming: currentLogContext.isStreaming
            )
            await operation(currentRequest, currentLoadingID, currentLogContext) { error in
                guard !Task.isCancelled, retryCount < maximumRetries,
                      ChatRequestRetryPolicy.isRetryable(error) else { return false }
                if let message = self.messagesSnapshot(for: sessionID).first(where: { $0.id == currentLoadingID }),
                   !(message.imageFileNames ?? []).isEmpty || message.audioFileName != nil {
                    return false
                }
                failure = error
                return true
            }
            guard let failure else { return }
            await finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: currentLoadingID, in: sessionID)
            _ = await persistAndPublishStreamingMessages(
                messagesSnapshot(for: sessionID), loadingMessageID: currentLoadingID, sessionID: sessionID
            )
            let partial = messagesSnapshot(for: sessionID).first { $0.id == currentLoadingID }
            let statusCode: Int?
            if case NetworkError.badStatusCode(let code, _) = failure { statusCode = code } else { statusCode = nil }
            persistRequestLog(
                context: currentLogContext, status: .failed, tokenUsage: partial?.tokenUsage,
                finishedAt: Date(), httpStatusCode: statusCode, errorKind: "automatic_retry"
            )

            retryCount += 1
            setRequestRetryStatus(
                ChatRequestRetryStatus(attempt: retryCount, maximumAttempts: maximumRetries),
                messageID: currentLoadingID, sessionID: sessionID
            )
            do {
                try await Task.sleep(for: .seconds(ChatRequestRetryPolicy.delay(forRetry: retryCount)))
                try Task.checkCancellation()
            } catch { return }

            if let partial, !partial.content.isEmpty, partial.content != prefix {
                // 流式工具参数可能只收到一半；保留在旧版本中，不作为已完成调用重放。
                var textPrefix = ChatMessage(id: partial.id, role: .assistant, content: partial.content)
                textPrefix.reasoningContent = partial.reasoningContent
                setRequestRetryStatus(nil, messageID: currentLoadingID, sessionID: sessionID)
                guard let retry = prepareMessageRetry(
                    targetMessage: textPrefix, in: messagesSnapshot(for: sessionID), prefill: true
                ), let rebuilt = rebuildRequest(textPrefix) else {
                    addErrorMessage(NSLocalizedString("错误: 无法构建 API 请求。", comment: ""), sessionID: sessionID)
                    emitSessionRequestStatus(.error, sessionID: sessionID)
                    return
                }
                persistAndPublishMessages(retry.storedMessages, for: sessionID)
                currentLoadingID = retry.loadingMessage.id
                updateRequestLoadingMessageID(currentLoadingID, for: sessionID)
                currentRequest = rebuilt
                prefix = textPrefix.content
            }

            resetPartialResponseForRetry(messageID: currentLoadingID, sessionID: sessionID, prefix: prefix)
            setRequestRetryStatus(
                ChatRequestRetryStatus(attempt: retryCount, maximumAttempts: maximumRetries),
                messageID: currentLoadingID, sessionID: sessionID
            )
            currentLogContext = RequestLogContext(
                requestID: UUID(), sessionID: requestLogContext.sessionID,
                providerID: requestLogContext.providerID, providerName: requestLogContext.providerName,
                modelID: requestLogContext.modelID, requestSource: requestLogContext.requestSource,
                isStreaming: requestLogContext.isStreaming, requestedAt: Date(),
                modelReference: requestLogContext.modelReference, modelPricing: requestLogContext.modelPricing
            )
        }
    }

    func setRequestRetryStatus(_ status: ChatRequestRetryStatus?, messageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].requestRetryStatus != status else { return }
        messages[index].requestRetryStatus = status
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }

    private func resetPartialResponseForRetry(messageID: UUID, sessionID: UUID, prefix: String) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].content = prefix
        if prefix.isEmpty { messages[index].reasoningContent = nil }
        messages[index].toolCalls = nil
        messages[index].toolCallsPlacement = nil
        messages[index].reasoningProviderSpecificFields = nil
        messages[index].providerResponseMetadata = nil
        messages[index].responseMetrics = nil
        messages[index].tokenUsage = nil
        messages[index].costEstimate = nil
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }
}
