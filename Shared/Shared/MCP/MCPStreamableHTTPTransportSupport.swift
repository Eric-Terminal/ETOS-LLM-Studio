// ============================================================================
// MCPStreamableHTTPTransportSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 MCP Streamable HTTP 传输的内部实现细节，包括请求封装、
// SSE 循环、事件解析、会话恢复与服务端回传处理。
// 主文件仅保留对外入口与状态定义。
// ============================================================================

import Foundation
import os.log

extension MCPStreamableHTTPTransport {
    func disconnectStream() {
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - HTTP + SSE 实现

    func postMessage(_ payload: Data, requestId: JSONRPCID?) async throws {
        let notificationMethod = requestId == nil ? extractNotificationMethod(from: payload) : nil
        var didRetryForMissingSession = false

        while true {
            let appliedSessionId = currentAppliedSessionId()
            let dynamicHeaders = try await resolveDynamicHeaders()

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            applyHeaders(to: &request, includeResumption: false, dynamicHeaders: dynamicHeaders)

            let (data, httpResponse) = try await performRequest(request)

            if let serverSession = httpResponse.value(forHTTPHeaderField: mcpSessionHeader),
               !serverSession.isEmpty {
                sessionId = serverSession
            }

            if httpResponse.statusCode == 404,
               let staleSessionId = appliedSessionId,
               !didRetryForMissingSession {
                didRetryForMissingSession = true
                resetSessionAfterNotFound(previousSessionId: staleSessionId)
                continue
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)
                throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
            }

            // 202：响应会通过 SSE 流返回。
            if httpResponse.statusCode == 202 {
                if let requestId {
                    if !isSSEEnabled {
                        _ = resumeSSEProbeIfNeeded(force: true, reason: "收到 202 响应")
                    }
                    await pendingRequestsActor.markAwaitingSSE(id: requestId)
                    if sseTask == nil {
                        connectStream()
                    }
                } else if notificationMethod == "notifications/initialized", sseTask == nil {
                    if !isSSEEnabled {
                        _ = resumeSSEProbeIfNeeded(force: true, reason: "初始化通知收到 202 响应")
                    }
                    // 初始化后异步建立 SSE，会和官方 SDK 行为保持一致。
                    connectStream()
                }
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") {
                await handleInlineSSE(data)
                return
            }

            guard let requestId else { return }
            guard !data.isEmpty else {
                let pending = await pendingRequestsActor.remove(id: requestId)
                pending?.resume(throwing: MCPClientError.invalidResponse)
                return
            }
            let pending = await pendingRequestsActor.remove(id: requestId)
            pending?.resume(returning: data)
            return
        }
    }

    func runSSELoop() async {
        defer { sseTask = nil }
        while !Task.isCancelled {
            let appliedSessionId = currentAppliedSessionId()
            let dynamicHeaders: [String: String]
            do {
                dynamicHeaders = try await resolveDynamicHeaders()
            } catch {
                streamableLogger.error("构建认证请求头失败：\(error.localizedDescription, privacy: .public)")
                guard await scheduleSSEReconnectIfNeeded() else { return }
                continue
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = .infinity
            applyHeaders(to: &request, includeResumption: true, dynamicHeaders: dynamicHeaders)

            do {
                if let responseExecutor {
                    let (data, httpResponse) = try await responseExecutor(request)

                    if let serverSession = httpResponse.value(forHTTPHeaderField: mcpSessionHeader),
                       !serverSession.isEmpty {
                        sessionId = serverSession
                    }

                    if httpResponse.statusCode == 405 {
                        await suspendSSEMode(reason: "服务端暂不支持 Streamable HTTP GET/SSE（405）。")
                        return
                    }

                    if httpResponse.statusCode == 404,
                       let staleSessionId = appliedSessionId {
                        resetSessionAfterNotFound(previousSessionId: staleSessionId)
                        continue
                    }

                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    if contentType.contains("application/json") {
                        await suspendSSEMode(reason: "服务端本轮返回 application/json，暂时降级 SSE。")
                        return
                    }

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        streamableLogger.error("Streamable HTTP SSE failed: \(httpResponse.statusCode)")
                        guard await scheduleSSEReconnectIfNeeded() else { return }
                        continue
                    }

                    sseReconnectAttempt = 0
                    await handleInlineSSE(data)

                    if Task.isCancelled {
                        return
                    }

                    streamableLogger.info("Streamable HTTP SSE stream closed by peer, scheduling reconnect.")
                    guard await scheduleSSEReconnectIfNeeded() else { return }
                    continue
                }

                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw MCPClientError.invalidResponse
                }

                if let serverSession = httpResponse.value(forHTTPHeaderField: mcpSessionHeader),
                   !serverSession.isEmpty {
                    sessionId = serverSession
                }

                if httpResponse.statusCode == 405 {
                    await suspendSSEMode(reason: "服务端暂不支持 Streamable HTTP GET/SSE（405）。")
                    return
                }

                if httpResponse.statusCode == 404,
                   let staleSessionId = appliedSessionId {
                    resetSessionAfterNotFound(previousSessionId: staleSessionId)
                    continue
                }

                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.contains("application/json") {
                    await suspendSSEMode(reason: "服务端本轮返回 application/json，暂时降级 SSE。")
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    streamableLogger.error("Streamable HTTP SSE failed: \(httpResponse.statusCode)")
                    guard await scheduleSSEReconnectIfNeeded() else { return }
                    continue
                }

                sseReconnectAttempt = 0

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    await consumeSSELine(line)
                }

                if Task.isCancelled {
                    return
                }

                streamableLogger.info("Streamable HTTP SSE stream closed by peer, scheduling reconnect.")
                guard await scheduleSSEReconnectIfNeeded() else { return }
            } catch {
                if Task.isCancelled {
                    return
                }
                streamableLogger.error("Streamable HTTP SSE error: \(error.localizedDescription)")
                guard await scheduleSSEReconnectIfNeeded() else { return }
            }
        }
    }

    func resolveDynamicHeaders() async throws -> [String: String] {
        guard let dynamicHeadersProvider else { return [:] }
        return try await dynamicHeadersProvider()
    }

    func resumeSSEProbeIfNeeded(force: Bool, reason: String) -> Bool {
        guard !isSSEEnabled else { return true }
        let now = Date()
        if force || sseSuspendedUntil == nil || now >= (sseSuspendedUntil ?? .distantPast) {
            isSSEEnabled = true
            sseSuspendedUntil = nil
            sseReconnectAttempt = 0
            streamableLogger.info("SSE 探测已恢复：\(reason, privacy: .public)")
            return true
        }
        return false
    }

    func snapshotAndClearSession() -> String? {
        let previousSessionId = sessionId
        sessionId = nil
        lastEventId = nil
        sseSuspendedUntil = nil
        isSSEEnabled = true
        return previousSessionId
    }

    func currentAppliedSessionId() -> String? {
        guard !Self.hasHeader(mcpSessionHeader, in: headers),
              let sessionId,
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }

    func extractRequestId(from payload: Data) throws -> JSONRPCID {
        if let request = try? JSONDecoder().decode(JSONRPCRequestEnvelope.self, from: payload) {
            return request.id
        }
        throw MCPClientError.invalidResponse
    }

    func terminateSession(with previousSessionId: String) async {
        let dynamicHeaders = (try? await resolveDynamicHeaders()) ?? [:]
        await Self.terminateRemoteSession(
            session: session,
            endpoint: endpoint,
            headers: headers,
            dynamicHeaders: dynamicHeaders,
            protocolVersion: protocolVersion,
            sessionId: previousSessionId,
            responseExecutor: responseExecutor
        )
    }

    // MARK: - 内部实现细节

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let responseExecutor {
            return try await responseExecutor(request)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func consumeSSELine(_ line: String) async {
        if line.isEmpty {
            if !sseDataLines.isEmpty {
                let data = sseDataLines.joined(separator: "\n")
                await handleSSEEvent(name: sseEventName, data: data, id: sseEventId)
            }
            sseEventName = nil
            sseEventId = nil
            sseDataLines = []
            return
        }

        if line.hasPrefix(":") {
            return
        }
        if line.hasPrefix("event:") {
            sseEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("id:") {
            sseEventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if data != "[DONE]" {
                sseDataLines.append(data)
            }
        }
    }

    private func handleInlineSSE(_ data: Data) async {
        let events = parseSSEEvents(from: data)
        for event in events {
            await handleSSEEvent(name: event.name, data: event.data, id: event.id)
        }
    }

    private func handleSSEEvent(name: String?, data: String, id: String?) async {
        if let id, !id.isEmpty {
            lastEventId = id
        }
        if name == "session" || name == "sessionId" {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sessionId = trimmed
            }
            return
        }
        if name == "error" {
            streamableLogger.error("Streamable HTTP SSE error event: \(data, privacy: .public)")
            return
        }
        await processSSEPayload(data)
    }

    private func processSSEPayload(_ data: String) async {
        guard let jsonData = data.data(using: .utf8) else { return }

        guard let envelope = try? JSONDecoder().decode(JSONRPCDispatchEnvelope.self, from: jsonData) else {
            return
        }

        if let method = envelope.method {
            if let requestID = envelope.id {
                switch method {
                case "sampling/createMessage":
                    if let samplingRequest = try? JSONDecoder().decode(MCPServerSamplingRequest.self, from: jsonData) {
                        await handleSamplingRequest(samplingRequest)
                    } else {
                        await sendErrorResponse(requestId: requestID, code: -32602, message: "Sampling 请求参数无效")
                    }
                case "elicitation/create":
                    if let elicitationRequest = try? JSONDecoder().decode(MCPServerElicitationRequest.self, from: jsonData) {
                        await handleElicitationRequest(elicitationRequest)
                    } else {
                        await sendErrorResponse(requestId: requestID, code: -32602, message: "Elicitation 请求参数无效")
                    }
                default:
                    return
                }
                return
            }

            if let notification = try? JSONDecoder().decode(MCPNotification.self, from: jsonData) {
                await handleNotification(notification)
            }
            return
        }

        if let id = envelope.id,
           envelope.result != nil || envelope.error != nil {
            let continuation = await pendingRequestsActor.remove(id: id)
            continuation?.resume(returning: jsonData)
        }
    }

    private func handleNotification(_ notification: MCPNotification) async {
        if notification.method == MCPNotificationType.logMessage.rawValue,
           let params = notification.params,
           let logEntry = try? decodeLogEntry(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveLogMessage(logEntry)
            }
            return
        }

        if notification.method == MCPNotificationType.progress.rawValue,
           let params = notification.params,
           let progress = try? decodeProgress(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveProgress(progress)
            }
            return
        }

        await MainActor.run {
            notificationDelegate?.didReceiveNotification(notification)
        }
    }

    private func handleSamplingRequest(_ request: MCPServerSamplingRequest) async {
        guard let handler = samplingHandler else {
            streamableLogger.warning("收到 Sampling 请求但未设置 handler")
            await sendErrorResponse(requestId: request.id, code: -32603, message: "客户端未启用 Sampling 能力")
            return
        }

        do {
            let response = try await handler.handleSamplingRequest(request.params)
            await sendSamplingResponse(requestId: request.id, response: response)
        } catch {
            await sendErrorResponse(requestId: request.id, code: -32603, message: error.localizedDescription)
        }
    }

    private func handleElicitationRequest(_ request: MCPServerElicitationRequest) async {
        guard let handler = elicitationHandler else {
            streamableLogger.info("收到 Elicitation 请求但未设置 handler，返回 decline")
            await sendElicitationResponse(requestId: request.id, response: .declined)
            return
        }

        do {
            let response = try await handler.handleElicitationRequest(request.params)
            await sendElicitationResponse(requestId: request.id, response: response)
        } catch {
            await sendErrorResponse(requestId: request.id, code: -32603, message: error.localizedDescription)
        }
    }

    private func sendSamplingResponse(requestId: JSONRPCID, response: MCPSamplingResponse) async {
        let rpcResponse = JSONRPCSamplingResponse(id: requestId, result: response)
        guard let data = try? JSONEncoder().encode(rpcResponse) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Sampling 响应失败: \(error.localizedDescription)")
        }
    }

    private func sendElicitationResponse(requestId: JSONRPCID, response: MCPElicitationResult) async {
        let rpcResponse = JSONRPCElicitationResponse(id: requestId, result: response)
        guard let data = try? JSONEncoder().encode(rpcResponse) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Elicitation 响应失败: \(error.localizedDescription)")
        }
    }

    private func sendErrorResponse(requestId: JSONRPCID, code: Int, message: String) async {
        let error = JSONRPCErrorResponse(
            id: requestId,
            error: JSONRPCErrorBody(code: code, message: message)
        )
        guard let data = try? JSONEncoder().encode(error) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 RPC 错误响应失败: \(error.localizedDescription)")
        }
    }

    private func decodeLogEntry(from value: JSONValue) throws -> MCPLogEntry {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPLogEntry.self, from: data)
    }

    private func decodeProgress(from value: JSONValue) throws -> MCPProgressParams {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPProgressParams.self, from: data)
    }

    private func applyHeaders(to request: inout URLRequest, includeResumption: Bool, dynamicHeaders: [String: String]) {
        let resolvedHeaders = mergedHeaders(staticHeaders: headers, dynamicHeaders: dynamicHeaders)
        for (key, value) in resolvedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionId, !sessionId.isEmpty, !Self.hasHeader(mcpSessionHeader, in: resolvedHeaders) {
            request.setValue(sessionId, forHTTPHeaderField: mcpSessionHeader)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader(mcpProtocolHeader, in: resolvedHeaders) {
            request.setValue(protocolVersion, forHTTPHeaderField: mcpProtocolHeader)
        }
        if includeResumption, let lastEventId, !lastEventId.isEmpty {
            request.setValue(lastEventId, forHTTPHeaderField: mcpResumptionHeader)
        }
    }

    private func suspendSSEMode(reason: String) async {
        isSSEEnabled = false
        sseSuspendedUntil = Date().addingTimeInterval(self.sseSuspensionInterval)
        sseReconnectAttempt = 0
        streamableLogger.info("\(reason, privacy: .public) 将在 \(self.sseSuspensionInterval, privacy: .public)s 后重新探测。")
        await pendingRequestsActor.failAwaitingSSE()
    }

    private func scheduleSSEReconnectIfNeeded() async -> Bool {
        guard isSSEEnabled else { return false }

        let nextAttempt = sseReconnectAttempt + 1
        guard nextAttempt <= sseReconnectMaxAttempts else {
            streamableLogger.error("Streamable HTTP SSE reconnect exhausted at \(nextAttempt - 1) attempts.")
            await suspendSSEMode(reason: "SSE 重连次数耗尽，暂时降级。")
            return false
        }

        sseReconnectAttempt = nextAttempt
        let exponent = max(0, nextAttempt - 1)
        let delay = min(sseReconnectBaseDelay * pow(2.0, Double(exponent)), sseReconnectMaxDelay)
        streamableLogger.info("Streamable HTTP SSE reconnect attempt=\(nextAttempt), delay=\(delay, privacy: .public)s")

        let nanos = UInt64(delay * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            return false
        }
        return !Task.isCancelled && isSSEEnabled
    }

    private func mergedHeaders(staticHeaders: [String: String], dynamicHeaders: [String: String]) -> [String: String] {
        var resolved = staticHeaders
        for (key, value) in dynamicHeaders {
            if let existingKey = resolved.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                resolved[existingKey] = value
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }

    private func resetSessionAfterNotFound(previousSessionId: String) {
        if sessionId == previousSessionId {
            sessionId = nil
        }
        lastEventId = nil
        sseReconnectAttempt = 0
        sseSuspendedUntil = nil
        isSSEEnabled = true
        streamableLogger.info("Streamable HTTP session 已失效（404），将清理本地会话并重建。")
    }

    private static func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func terminateRemoteSession(
        session: URLSession,
        endpoint: URL,
        headers: [String: String],
        dynamicHeaders: [String: String],
        protocolVersion: String?,
        sessionId: String,
        responseExecutor: StreamableHTTPResponseExecutor?
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let resolvedHeaders = mergeHeaders(staticHeaders: headers, dynamicHeaders: dynamicHeaders)
        for (key, value) in resolvedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !Self.hasHeader(mcpSessionHeader, in: resolvedHeaders) {
            request.setValue(sessionId, forHTTPHeaderField: mcpSessionHeader)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader(mcpProtocolHeader, in: resolvedHeaders) {
            request.setValue(protocolVersion, forHTTPHeaderField: mcpProtocolHeader)
        }

        do {
            let httpResponse: HTTPURLResponse
            if let responseExecutor {
                (_, httpResponse) = try await responseExecutor(request)
            } else {
                let (_, response) = try await session.data(for: request)
                guard let castedResponse = response as? HTTPURLResponse else {
                    streamableLogger.error("会话终止请求返回了无效响应。")
                    return
                }
                httpResponse = castedResponse
            }
            if !(200..<300).contains(httpResponse.statusCode) && httpResponse.statusCode != 405 {
                streamableLogger.error("会话终止请求失败：status=\(httpResponse.statusCode)")
            }
        } catch {
            streamableLogger.error("会话终止请求失败：\(error.localizedDescription)")
        }
    }

    private static func mergeHeaders(staticHeaders: [String: String], dynamicHeaders: [String: String]) -> [String: String] {
        var resolved = staticHeaders
        for (key, value) in dynamicHeaders {
            if let existingKey = resolved.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                resolved[existingKey] = value
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }

    private func extractNotificationMethod(from payload: Data) -> String? {
        (try? JSONDecoder().decode(JSONRPCNotificationEnvelope.self, from: payload))?.method
    }

    private func parseSSEEvents(from data: Data) -> [SSEEvent] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var events: [SSEEvent] = []
        for block in blocks {
            var eventName: String?
            var eventId: String?
            var dataLines: [String] = []
            for lineSub in block.split(separator: "\n") {
                let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("id:") {
                    eventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if data != "[DONE]" {
                        dataLines.append(data)
                    }
                }
            }
            let payload = dataLines.joined(separator: "\n")
            if !payload.isEmpty {
                events.append(SSEEvent(id: eventId, name: eventName, data: payload))
            }
        }
        return events
    }
}
