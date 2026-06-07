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
        connectionStatus = NSLocalizedString("连接中...", comment: "")

        let config = NetworkSessionConfiguration.makeConfiguration()
        config.httpMaximumConnectionsPerHost = 4
        httpSession = URLSession(configuration: config)

        testHTTPConnection(host: host, port: port) { [weak self] success, error in
            guard let self = self else { return }
            Task { @MainActor in
                if success {
                    self.isRunning = true
                    self.connectionStatus = NSLocalizedString("已连接 (HTTP)", comment: "")
                    self.errorMessage = nil
                    self.logger.info("HTTP 连接测试成功")
                    self.startHTTPPolling(host: host, port: port)
                } else {
                    self.isRunning = false
                    self.connectionStatus = NSLocalizedString("连接失败", comment: "")
                    self.errorMessage = self.describeHTTPConnectionFailure(error)
                    self.logger.error("HTTP 连接测试失败")
                }
            }
        }
    }

    /// 测试 HTTP 连接
    func testHTTPConnection(host: String, port: String, completion: @escaping (Bool, Error?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/ping") else {
            completion(false, nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0

        httpSession?.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logger.error("HTTP 测试失败: \(error.localizedDescription)")
                completion(false, error)
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                completion(true, nil)
            } else {
                completion(false, nil)
            }
        }.resume()
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
    func startHTTPPolling(host: String, port: String) {
        logger.info("启动 HTTP 轮询，间隔: \(self.httpPollingInterval)秒")

        httpPollingTimer = Timer.scheduledTimer(withTimeInterval: self.httpPollingInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.performHTTPPoll(host: host, port: port)
            }
        }

        performHTTPPoll(host: host, port: port)
    }

    /// 执行一次 HTTP 轮询
    func performHTTPPoll(host: String, port: String) {
        if isTransferring {
            return
        }

        guard let url = URL(string: "http://\(host):\(port)/poll") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3.0

        let deviceInfo: [String: Any] = [
            "device_id": getDeviceIdentifier(),
            "platform": "watchOS",
            "timestamp": Date().timeIntervalSince1970
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: deviceInfo) {
            request.httpBody = jsonData
        }

        httpSession?.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                Task { @MainActor in
                    self.httpFailureCount += 1
                    self.addLog("轮询失败: \(error.localizedDescription)", type: .error)
                    if self.httpFailureCount >= self.maxHTTPFailures {
                        self.addLog("连续失败 \(self.httpFailureCount) 次，断开连接", type: .error)
                        self.disconnect()
                    }
                }
                return
            }

            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                Task { @MainActor in
                    self.httpFailureCount += 1
                    if self.httpFailureCount >= self.maxHTTPFailures {
                        self.addLog("响应异常，断开连接", type: .error)
                        self.disconnect()
                    }
                }
                return
            }

            Task { @MainActor in
                self.httpFailureCount = 0
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let command = json["command"] as? String {
                Task { @MainActor in
                    if command == "none" {
                        self.addLog("心跳", type: .heartbeat)
                    } else {
                        self.addLog("收到命令: \(command)", type: .receive)
                        self.handleReceivedMessage(data)
                    }
                }
            }
        }.resume()
    }

    /// 通过 HTTP 发送响应
    func sendHTTPResponse(_ response: [String: Any], host: String, port: String) {
        guard let url = URL(string: "http://\(host):\(port)/response") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        if let jsonData = try? JSONSerialization.data(withJSONObject: response) {
            request.httpBody = jsonData

            let dataSize = jsonData.count
            let path = response["path"] as? String ?? ""
            let status = response["status"] as? String ?? ""

            Task { @MainActor in
                if dataSize > 1_000_000 {
                    self.addLog("发送大响应: \(String(format: "%.2f", Double(dataSize) / 1_000_000)) MB", type: .send)
                } else if !path.isEmpty {
                    self.addLog("发送: \(path) (\(self.formatSize(dataSize)))", type: .send)
                } else {
                    self.addLog("响应: \(status)", type: .send)
                }
            }

            httpSession?.dataTask(with: request) { [weak self] _, _, error in
                guard let self = self else { return }
                Task { @MainActor in
                    if let error = error {
                        self.addLog("发送失败: \(error.localizedDescription)", type: .error)
                    }
                }
            }.resume()
        }
    }

    /// 异步发送 HTTP 响应（等待完成）
    /// 确保每个请求完全完成后再返回，避免并发导致的乱序问题。
    func sendHTTPResponseAsync(_ response: [String: Any]) async {
        let components = serverURL.split(separator: ":").map(String.init)
        let host = components.first ?? ""
        let port = components.count > 1 ? components[1] : "7654"

        guard let url = URL(string: "http://\(host):\(port)/response") else {
            logger.error("无效的 URL: http://\(host):\(port)/response")
            return
        }

        guard let session = httpSession else {
            logger.error("httpSession 为 nil，无法发送响应")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 60.0

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: response)
        } catch {
            logger.error("JSON 序列化失败: \(error.localizedDescription), 响应键: \(response.keys.joined(separator: ", "))")
            return
        }
        request.httpBody = jsonData

        let index = response["index"] as? Int
        let isComplete = response["stream_complete"] as? Bool ?? false

        do {
            let (_, httpResponse) = try await session.data(for: request)
            if let httpRes = httpResponse as? HTTPURLResponse {
                if httpRes.statusCode != 200 {
                    logger.error("服务器返回错误状态码: \(httpRes.statusCode)")
                } else if isComplete {
                    logger.info("完成信号已确认送达服务器")
                }
            }

            if index != nil && !isComplete {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            logger.error("发送响应失败 (index=\(index ?? -1)): \(error.localizedDescription)")
        }
    }
}
