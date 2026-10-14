// ============================================================================
// LocalDebugServerHTTP.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 HTTP 轮询连接、轮询命令接收，
// 以及 HTTP 模式下的响应发送与连接失败提示。
// ============================================================================

import Foundation
import os.log

extension LocalDebugServer {
    /// 执行 HTTP 连接和轮询
    @MainActor
    func performHTTPConnection(host: String, port: String) {
        logger.info("开始 HTTP 轮询模式，目标: \(host):\(port)")
        let token = beginConnectionAttempt(host: host, port: port, useHTTPMode: true)
        connectionStatus = NSLocalizedString("连接中...", comment: "")

        let config = NetworkSessionConfiguration.makeConfiguration()
        config.httpMaximumConnectionsPerHost = 4
        httpSession = NetworkSessionConfiguration.makeSession(from: config)

        testHTTPConnection(host: host, port: port) { [weak self] success, error in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.isCurrentConnection(token) else { return }
                if success {
                    self.isRunning = true
                    self.connectionStatus = NSLocalizedString("已连接 (HTTP)", comment: "")
                    self.errorMessage = nil
                    self.reconnectAttempt = 0
                    self.logger.info("HTTP 连接测试成功")
                    self.startHTTPPolling(host: host, port: port, connectionToken: token)
                } else {
                    self.logger.error("HTTP 连接测试失败")
                    self.handleConnectionLost(errorMessage: self.describeHTTPConnectionFailure(error))
                }
            }
        }
    }

    /// 测试 HTTP 连接
    func testHTTPConnection(host: String, port: String, completion: @escaping (Bool, Error?) -> Void) {
        guard let session = httpSession, let url = URL(string: "http://\(host):\(port)/ping") else {
            completion(false, nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0

        let previous = httpConnectionTask, previousPoll = httpPollTask, token = connectionToken
        httpConnectionTask = Task { [weak self] in
            await previous?.value
            await previousPoll?.value
            guard !Task.isCancelled, self?.isCurrentConnection(token) == true else { return }
            do {
                let (_, response) = try await session.securedData(for: request)
                guard !Task.isCancelled, self?.isCurrentConnection(token) == true else { return }
                completion((response as? HTTPURLResponse)?.statusCode == 200, nil)
            } catch {
                guard !Task.isCancelled, self?.isCurrentConnection(token) == true else { return }
                completion(false, error)
            }
        }
    }

    /// 生成更易定位问题的 HTTP 连接失败提示
    func describeHTTPConnectionFailure(_ error: Error?) -> String {
        guard let error else {
            return NSLocalizedString("无法连接到服务器，请检查地址和端口", comment: "")
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return NSLocalizedString("HTTP 被系统安全策略拦截，请允许本地网络明文访问后重试", comment: "")
        }

        let description = error.localizedDescription.lowercased()
        if description.contains("connection refused") || description.contains("拒绝") {
            return NSLocalizedString("连接被拒绝，请检查服务器是否已启动", comment: "")
        }
        if description.contains("timed out") || description.contains("超时") {
            return NSLocalizedString("连接超时，请检查 IP 地址和网络", comment: "")
        }
        if description.contains("unreachable") || description.contains("不可达") {
            return NSLocalizedString("网络不可达，请检查 Wi-Fi 连接和设备是否在同一网络", comment: "")
        }

        return String(format: NSLocalizedString("连接失败: %@", comment: ""), error.localizedDescription)
    }

    /// 启动 HTTP 轮询
    @MainActor
    func startHTTPPolling(host: String, port: String, connectionToken token: UUID) {
        logger.info("启动 HTTP 轮询，间隔: \(self.httpPollingInterval)秒")

        httpPollingTimer = Timer.scheduledTimer(withTimeInterval: self.httpPollingInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.isCurrentConnection(token) else { return }
                self.performHTTPPoll(host: host, port: port, connectionToken: token)
            }
        }

        performHTTPPoll(host: host, port: port, connectionToken: token)
    }

    /// 执行一次 HTTP 轮询
    func performHTTPPoll(host: String, port: String, connectionToken token: UUID) {
        guard isCurrentConnection(token), !isTransferring, commandQueue.isEmpty, httpPollID == nil,
              let session = httpSession, let url = URL(string: "http://\(host):\(port)/poll") else { return }
        let deviceInfo = LocalDebugJSONObject(value: [
            "device_id": getDeviceIdentifier(),
            "platform": Self.debugPlatformName,
            "timestamp": Date().timeIntervalSince1970
        ])
        let id = UUID(), previous = httpPollTask
        httpPollID = id
        httpPollTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if httpPollID == id { httpPollID = nil } }
            guard !Task.isCancelled, isCurrentConnection(token) else { return }
            do {
                let worker = Task.detached(priority: .utility) { try deviceInfo.encoded() }
                let body = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, isCurrentConnection(token) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 3.0
                request.httpBody = body
                let (data, response) = try await session.securedData(for: request)
                guard !Task.isCancelled, isCurrentConnection(token) else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    recordHTTPPollFailure(nil)
                    return
                }
                httpFailureCount = 0
                handleReceivedMessage(data)
            } catch {
                guard !Task.isCancelled, isCurrentConnection(token) else { return }
                recordHTTPPollFailure(error)
            }
        }
    }

    private func recordHTTPPollFailure(_ error: Error?) {
        httpFailureCount += 1
        if let error { addLog(String(format: NSLocalizedString("Debug poll failed: %@", comment: "调试轮询失败日志"), error.localizedDescription), type: .error) }
        if httpFailureCount >= maxHTTPFailures {
            addLog(String(format: NSLocalizedString("Disconnected after %d failed polls.", comment: "调试轮询断开日志"), httpFailureCount), type: .error)
            handleConnectionLost(errorMessage: describeHTTPConnectionFailure(error))
        }
    }

    /// 异步发送 HTTP 响应（等待完成）
    /// 确保每个请求完全完成后再返回，避免并发导致的乱序问题。
    func sendHTTPResponseAsync(_ response: [String: Any]) async {
        guard canContinueDebugCommand else { return }
        await sendResponse(response, streaming: true)
        if response["index"] != nil, response["stream_complete"] as? Bool != true, canContinueDebugCommand {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
