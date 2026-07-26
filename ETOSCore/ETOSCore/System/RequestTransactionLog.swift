// ============================================================================
// RequestTransactionLog.swift
// ============================================================================
// ETOS LLM Studio
//
// 将请求构建、响应快照和最终状态收敛为一条 HTTP 事务，避免流水式噪声日志。
// ============================================================================

import Foundation
import CryptoKit

struct RequestTransactionLogSnapshot: Sendable {
    let level: AppLogLevel
    let action: String
    let message: String
    let payload: [String: String]
}

private struct RequestLogAttemptDraft: Sendable {
    let signature: String
    let adapter: String
    let method: String
    let safeURL: String
    let sanitizedHeaders: String?
    let sanitizedBody: String
    let bodyBytes: Int
    let stagedAt: Date
}

private struct RequestLogResponseDraft: Sendable {
    let sanitizedBody: String
    let bodyBytes: Int
    let statusCode: Int?
    let isPartial: Bool
    let receivedAt: Date
}

private struct RequestLogTransactionDraft: Sendable {
    let requestID: UUID
    let requestedAt: Date
    let providerName: String
    let modelID: String
    let isStreaming: Bool
    var attempts: [RequestLogAttemptDraft]
    var responses: [RequestLogResponseDraft]
}

enum RequestLogCapturePolicy {
    static func shouldCaptureStreamingBody(
        requestLogEnabled: Bool,
        plainMessageEnabled: Bool
    ) -> Bool {
        requestLogEnabled && plainMessageEnabled
    }
}

enum RequestTransactionLogRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stagedBySignature: [String: [RequestLogAttemptDraft]] = [:]
    private nonisolated(unsafe) static var transactions: [UUID: RequestLogTransactionDraft] = [:]
    private static let stagingLifetime: TimeInterval = 10 * 60

    static func stageRequest(
        adapter: String,
        request: URLRequest,
        sanitizedBody: String,
        sanitizedHeaders: String?
    ) {
        guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return }
        let signature = requestSignature(request)
        let draft = RequestLogAttemptDraft(
            signature: signature,
            adapter: adapter,
            method: request.httpMethod ?? "POST",
            safeURL: AppLogRedactor.sanitizeURLForLog(request.url),
            sanitizedHeaders: sanitizedHeaders,
            sanitizedBody: sanitizedBody,
            bodyBytes: request.httpBody?.count ?? 0,
            stagedAt: Date()
        )

        lock.lock()
        purgeExpiredStagingLocked(now: draft.stagedAt)
        stagedBySignature[signature, default: []].append(draft)
        lock.unlock()
    }

    static func bindRequest(
        _ request: URLRequest,
        requestID: UUID,
        requestedAt: Date,
        providerName: String,
        modelID: String,
        isStreaming: Bool
    ) {
        RequestPerformanceSignpostRegistry.begin(
            requestID: requestID,
            streaming: isStreaming
        )
        guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return }
        let signature = requestSignature(request)

        lock.lock()
        var transaction = transactions[requestID] ?? RequestLogTransactionDraft(
            requestID: requestID,
            requestedAt: requestedAt,
            providerName: providerName,
            modelID: modelID,
            isStreaming: isStreaming,
            attempts: [],
            responses: []
        )

        if !transaction.attempts.contains(where: { $0.signature == signature }) {
            let staged = popStagedRequestLocked(signature: signature) ?? fallbackDraft(
                request: request,
                signature: signature
            )
            transaction.attempts.append(staged)
        }
        transactions[requestID] = transaction
        lock.unlock()

    }

    static func stageResponse(
        requestID: UUID,
        request: URLRequest,
        requestedAt: Date,
        providerName: String,
        modelID: String,
        isStreaming: Bool,
        sanitizedBody: String,
        bodyBytes: Int,
        statusCode: Int?,
        isPartial: Bool
    ) {
        guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return }
        bindRequest(
            request,
            requestID: requestID,
            requestedAt: requestedAt,
            providerName: providerName,
            modelID: modelID,
            isStreaming: isStreaming
        )

        lock.lock()
        guard var transaction = transactions[requestID] else {
            lock.unlock()
            return
        }
        transaction.responses.append(
            RequestLogResponseDraft(
                sanitizedBody: sanitizedBody,
                bodyBytes: bodyBytes,
                statusCode: statusCode,
                isPartial: isPartial,
                receivedAt: Date()
            )
        )
        transactions[requestID] = transaction
        lock.unlock()
    }

    @discardableResult
    static func finalize(
        requestID: UUID,
        status: RequestLogStatus,
        finishedAt: Date,
        httpStatusCode: Int?,
        errorKind: String?,
        tokenUsage: MessageTokenUsage?
    ) -> Task<Void, Never>? {
        lock.lock()
        let transaction = transactions.removeValue(forKey: requestID)
        lock.unlock()

        RequestPerformanceSignpostRegistry.end(requestID: requestID)
        guard let transaction, !transaction.attempts.isEmpty else { return nil }
        guard AppConfigStore.boolValue(for: .requestLogEnabled) else { return nil }
        return AppLog.requestTransaction(
            makeSnapshot(
                transaction: transaction,
                status: status,
                finishedAt: finishedAt,
                httpStatusCode: httpStatusCode,
                errorKind: errorKind,
                tokenUsage: tokenUsage
            )
        )
    }

    private static func makeSnapshot(
        transaction: RequestLogTransactionDraft,
        status: RequestLogStatus,
        finishedAt: Date,
        httpStatusCode: Int?,
        errorKind: String?,
        tokenUsage: MessageTokenUsage?
    ) -> RequestTransactionLogSnapshot {
        let durationMilliseconds = max(
            0,
            Int(finishedAt.timeIntervalSince(transaction.requestedAt) * 1_000)
        )
        let finalResponse = transaction.responses.last
        let resolvedStatusCode = finalResponse?.statusCode ?? httpStatusCode ??
            (status == .success ? 200 : nil)
        let firstAttempt = transaction.attempts[0]

        var payload: [String: String] = [
            "method": firstAttempt.method,
            "url": firstAttempt.safeURL,
            "request_body": firstAttempt.sanitizedBody,
            "request_body_bytes": "\(firstAttempt.bodyBytes)",
            "response_body": finalResponse?.sanitizedBody ?? "",
            "response_body_bytes": "\(finalResponse?.bodyBytes ?? 0)",
            "duration_ms": "\(durationMilliseconds)",
            "status": status.rawValue,
            "streaming": transaction.isStreaming ? "true" : "false"
        ]
        if let resolvedStatusCode {
            payload["http_status"] = "\(resolvedStatusCode)"
        }
        if let errorKind, !errorKind.isEmpty {
            payload["error_kind"] = errorKind
        }

        payload["request_id"] = transaction.requestID.uuidString
        payload["provider"] = transaction.providerName
        payload["model"] = transaction.modelID
        payload["requested_at"] = ISO8601DateFormatter().string(from: transaction.requestedAt)
        payload["finished_at"] = ISO8601DateFormatter().string(from: finishedAt)
        payload["attempt_count"] = "\(transaction.attempts.count)"
        payload["response_snapshot_count"] = "\(transaction.responses.count)"
        payload["attempts"] = encodeAttempts(transaction.attempts)
        payload["responses"] = encodeResponses(transaction.responses)
        if let tokenUsage {
            payload["token_usage"] = encodeTokenUsage(tokenUsage)
        }

        let statusText = resolvedStatusCode.map(String.init) ?? status.rawValue
        let message = "\(firstAttempt.method) \(firstAttempt.safeURL) → \(statusText) · \(durationMilliseconds) ms"
        return RequestTransactionLogSnapshot(
            level: status == .failed ? .error : (status == .cancelled ? .warning : .info),
            action: status.rawValue,
            message: message,
            payload: payload
        )
    }

    private static func encodeAttempts(_ attempts: [RequestLogAttemptDraft]) -> String {
        let values: [[String: Any]] = attempts.enumerated().map { index, attempt in
            var value: [String: Any] = [
                "index": index + 1,
                "adapter": attempt.adapter,
                "method": attempt.method,
                "url": attempt.safeURL,
                "body_bytes": attempt.bodyBytes
            ]
            if let headers = attempt.sanitizedHeaders {
                value["headers"] = headers
            }
            return value
        }
        return encodeJSONObject(values)
    }

    private static func encodeResponses(_ responses: [RequestLogResponseDraft]) -> String {
        let formatter = ISO8601DateFormatter()
        let values: [[String: Any]] = responses.enumerated().map { index, response in
            var value: [String: Any] = [
                "index": index + 1,
                "body_bytes": response.bodyBytes,
                "partial": response.isPartial,
                "received_at": formatter.string(from: response.receivedAt)
            ]
            if let statusCode = response.statusCode {
                value["http_status"] = statusCode
            }
            return value
        }
        return encodeJSONObject(values)
    }

    private static func encodeTokenUsage(_ usage: MessageTokenUsage) -> String {
        guard let data = try? JSONEncoder().encode(usage) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeJSONObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fallbackDraft(
        request: URLRequest,
        signature: String
    ) -> RequestLogAttemptDraft {
        let body: String
        if let data = request.httpBody,
           let rawObject = try? JSONSerialization.jsonObject(with: data),
           let object = rawObject as? [String: Any],
           let sanitized = AppLogRedactor.sanitizeRequestBodyForLog(object) {
            body = sanitized
        } else {
            body = NSLocalizedString("[请求体快照不可用]", comment: "Request body snapshot unavailable")
        }
        return RequestLogAttemptDraft(
            signature: signature,
            adapter: "unknown",
            method: request.httpMethod ?? "POST",
            safeURL: AppLogRedactor.sanitizeURLForLog(request.url),
            sanitizedHeaders: AppLogRedactor.sanitizeHeadersForLog(request.allHTTPHeaderFields),
            sanitizedBody: body,
            bodyBytes: request.httpBody?.count ?? 0,
            stagedAt: Date()
        )
    }

    private static func requestSignature(_ request: URLRequest) -> String {
        var data = Data()
        data.append(Data((request.httpMethod ?? "POST").utf8))
        data.append(0)
        data.append(Data((request.url?.absoluteString ?? "").utf8))
        data.append(0)
        data.append(request.httpBody ?? Data())
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func popStagedRequestLocked(signature: String) -> RequestLogAttemptDraft? {
        guard var staged = stagedBySignature[signature], !staged.isEmpty else { return nil }
        let first = staged.removeFirst()
        if staged.isEmpty {
            stagedBySignature[signature] = nil
        } else {
            stagedBySignature[signature] = staged
        }
        return first
    }

    private static func purgeExpiredStagingLocked(now: Date) {
        for key in Array(stagedBySignature.keys) {
            let retained = stagedBySignature[key, default: []].filter {
                now.timeIntervalSince($0.stagedAt) < stagingLifetime
            }
            stagedBySignature[key] = retained.isEmpty ? nil : retained
        }
    }
}

private enum RequestPerformanceSignpostRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var tokens: [UUID: TelemetrySignpostToken] = [:]

    static func begin(requestID: UUID, streaming: Bool) {
        lock.lock()
        guard tokens[requestID] == nil else {
            lock.unlock()
            return
        }
        let token = TelemetrySignpost.begin(
            TelemetrySignpost.requestInterval(streaming: streaming),
            correlatingWith: requestID
        )
        tokens[requestID] = token
        lock.unlock()
    }

    static func end(requestID: UUID) {
        lock.lock()
        let token = tokens.removeValue(forKey: requestID)
        lock.unlock()
        if let token {
            TelemetrySignpost.end(token)
        }
    }
}

extension AppLog {
    @discardableResult
    static func requestTransaction(
        _ snapshot: RequestTransactionLogSnapshot
    ) -> Task<Void, Never> {
        Task { @MainActor in
            AppLogCenter.shared.logRequestTransaction(snapshot)
        }
    }
}
