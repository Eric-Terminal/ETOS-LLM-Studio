// ============================================================================
// LocalDebugServerConnection.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的地址解析、连接生命周期，以及调试命令的统一分发。
// ============================================================================

import Foundation
import Network
import os.log
#if os(watchOS)
import WatchKit
#elseif os(iOS)
import UIKit
#endif

extension LocalDebugServer {
    struct ParsedDebugAddress {
        let host: String
        let port: String
    }

    /// 解析调试服务器地址
    /// 支持格式：
    /// - host
    /// - host:port
    /// - host:legacyWsPort:port（旧双端口格式会取最后一个端口）
    func parseDebugAddress(_ raw: String) -> ParsedDebugAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme: String
        if let range = trimmed.range(of: "://") {
            withoutScheme = String(trimmed[range.upperBound...])
        } else {
            withoutScheme = trimmed
        }
        let hostPortOnly = withoutScheme.split(separator: "/").first.map(String.init) ?? withoutScheme
        let parts = hostPortOnly.split(separator: ":").map(String.init).filter { !$0.isEmpty }

        let host = parts.first ?? hostPortOnly
        let defaultPort = "7654"

        if parts.count >= 3 {
            return ParsedDebugAddress(host: host, port: parts[2])
        }

        if parts.count == 2 {
            return ParsedDebugAddress(host: host, port: parts[1])
        }

        return ParsedDebugAddress(host: host, port: defaultPort)
    }

    /// 连接到电脑端服务器
    /// - Parameter url: 服务器地址，格式: "192.168.1.100:7654" 或 "192.168.1.100"
    @MainActor
    public func connect(to url: String) {
        guard !isRunning, !isDisconnecting else { return }

        let parsed = parseDebugAddress(url)
        cancelScheduledReconnect(resetAttempt: true)
        beginAutoReconnect(host: parsed.host, port: parsed.port, useHTTPMode: useHTTP)
        wsAutoFallbackEnabled = false
        wsFallbackPort = parsed.port

        if useHTTP {
            logger.info("使用 HTTP 轮询模式")
            serverURL = "\(parsed.host):\(parsed.port)"
            performHTTPConnection(host: parsed.host, port: parsed.port)
        } else {
            wsAutoFallbackEnabled = true
            serverURL = "\(parsed.host):\(parsed.port)"
            performConnection(host: parsed.host, port: parsed.port)
        }
    }

    /// 执行实际的 WebSocket 连接
    @MainActor
    func performConnection(host: String, port: String) {
        logger.info("开始建立WebSocket连接到 \(host):\(port)")
        let token = beginConnectionAttempt(host: host, port: port, useHTTPMode: false)

        let urlString = "ws://\(host):\(port)/ws"
        guard let wsURL = URL(string: urlString) else {
            self.errorMessage = NSLocalizedString("无效的服务器地址", comment: "")
            self.connectionStatus = NSLocalizedString("连接失败", comment: "")
            self.scheduleReconnectIfNeeded()
            return
        }

        let endpoint = NWEndpoint.url(wsURL)
        let parameters = NWParameters.tcp

        #if !targetEnvironment(simulator)
        parameters.prohibitedInterfaceTypes = [.cellular]
        #if os(watchOS)
        parameters.requiredInterfaceType = .wifi
        #endif
        #endif

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        wsConnection = NWConnection(to: endpoint, using: parameters)

        wsConnection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentConnection(token) else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.connectionStatus = NSLocalizedString("已连接", comment: "")
                    self.errorMessage = nil
                    self.wsAutoFallbackEnabled = false
                    self.reconnectAttempt = 0
                    self.logger.info("已连接到 \(host):\(port)")
                case .failed(let error):
                    if self.wsAutoFallbackEnabled {
                        self.wsAutoFallbackEnabled = false
                        self.useHTTP = true
                        self.serverURL = "\(host):\(self.wsFallbackPort)"
                        self.beginAutoReconnect(host: host, port: self.wsFallbackPort, useHTTPMode: true)
                        self.connectionStatus = NSLocalizedString("WebSocket 失败，回退到 HTTP 轮询...", comment: "")
                        self.errorMessage = NSLocalizedString("WebSocket 连接失败，已自动切换到 HTTP 轮询", comment: "")
                        self.logger.error("WebSocket 连接失败，准备回退 HTTP: \(error.localizedDescription)")
                        self.performHTTPConnection(host: host, port: self.wsFallbackPort)
                        return
                    }

                    self.logger.error("连接失败: \(error.localizedDescription)")
                    self.handleConnectionLost(errorMessage: self.describeDebugConnectionFailure(error))
                case .cancelled:
                    self.isRunning = false
                    self.connectionStatus = NSLocalizedString("未连接", comment: "")
                    self.errorMessage = nil
                    self.wsAutoFallbackEnabled = false
                case .waiting(let error):
                    self.connectionStatus = NSLocalizedString("等待连接...", comment: "")
                    self.logger.info("等待连接: \(error.localizedDescription)")
                case .preparing:
                    self.connectionStatus = NSLocalizedString("准备中...", comment: "")
                case .setup:
                    self.connectionStatus = NSLocalizedString("设置中...", comment: "")
                @unknown default:
                    self.logger.warning("未知连接状态")
                }
            }
        }

        wsConnection?.start(queue: queue)
        startReceiving(connectionToken: token)
    }

    /// 断开连接
    @MainActor
    public func disconnect() {
        stopAutoReconnect()
        invalidateConnectionToken()
        httpPollingTimer?.invalidate()
        httpPollingTimer = nil
        httpFailureCount = 0

        wsConnection?.cancel()
        wsConnection = nil

        httpPollingTimer?.invalidate()
        httpPollingTimer = nil
        httpSession?.invalidateAndCancel()
        httpSession = nil

        isRunning = false
        connectionStatus = NSLocalizedString("未连接", comment: "")
        wsAutoFallbackEnabled = false
        pendingOpenAIRequests.removeAll()
        updatePendingOpenAIState()
    }

    /// 生命周期调用方必须在命令队列之外等待，返回时已开始的命令与网络授权等待都已收尾。
    public func disconnectAndWait() async {
        disconnectWaiterCount += 1
        isDisconnecting = true
        defer { disconnectWaiterCount -= 1; isDisconnecting = disconnectWaiterCount > 0 }
        disconnect()
        await waitForPendingOperations()
    }

    public func waitForPendingOperations() async {
        await httpConnectionTask?.value
        await httpPollTask?.value
        await commandQueue.waitForCompletion()
    }

    @MainActor
    func beginAutoReconnect(host: String, port: String, useHTTPMode: Bool) {
        autoReconnectEnabled = true
        reconnectTarget = DebugConnectionTarget(host: host, port: port, useHTTP: useHTTPMode)
        reconnectAttempt = 0
    }

    @MainActor
    func stopAutoReconnect() {
        autoReconnectEnabled = false
        reconnectTarget = nil
        cancelScheduledReconnect(resetAttempt: true)
    }

    @MainActor
    func cancelScheduledReconnect(resetAttempt: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        if resetAttempt {
            reconnectAttempt = 0
        }
    }

    @MainActor
    func beginConnectionAttempt(host: String, port: String, useHTTPMode: Bool) -> UUID {
        cancelScheduledReconnect(resetAttempt: false)
        invalidateConnectionToken()
        httpPollingTimer?.invalidate()
        httpPollingTimer = nil
        wsConnection?.cancel()
        wsConnection = nil
        httpSession?.invalidateAndCancel()
        httpSession = nil
        isRunning = false
        serverURL = "\(host):\(port)"
        useHTTP = useHTTPMode
        return connectionToken
    }

    @MainActor
    func invalidateConnectionToken() {
        connectionToken = UUID()
        commandQueue.cancel()
        httpConnectionTask?.cancel()
        httpPollTask?.cancel()
        httpPollID = nil
        isProcessingCommand = false
        isTransferring = false
    }

    @MainActor
    func isCurrentConnection(_ token: UUID) -> Bool {
        connectionToken == token
    }

    @MainActor
    func handleConnectionLost(errorMessage: String?) {
        invalidateConnectionToken()
        httpPollingTimer?.invalidate()
        httpPollingTimer = nil
        httpFailureCount = 0
        wsConnection?.cancel()
        wsConnection = nil
        httpSession?.invalidateAndCancel()
        httpSession = nil

        isRunning = false
        connectionStatus = NSLocalizedString("连接失败", comment: "")
        self.errorMessage = errorMessage
        wsAutoFallbackEnabled = false
        pendingOpenAIRequests.removeAll()
        updatePendingOpenAIState()
        scheduleReconnectIfNeeded()
    }

    @MainActor
    func scheduleReconnectIfNeeded() {
        guard autoReconnectEnabled, reconnectTask == nil, let target = reconnectTarget else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let interval = reconnectInterval
        let delaySeconds = Int(interval)
        connectionStatus = String(
            format: NSLocalizedString("重连中（第%d次，约 %ds）", comment: "Local debug reconnect status"),
            attempt,
            delaySeconds
        )

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reconnectTask = nil
                guard self.autoReconnectEnabled, !self.isRunning else { return }
                if target.useHTTP {
                    self.performHTTPConnection(host: target.host, port: target.port)
                } else {
                    self.performConnection(host: target.host, port: target.port)
                }
            }
        }
    }

    func describeDebugConnectionFailure(_ error: Error) -> String {
        let errorDescription = error.localizedDescription.lowercased()
        if errorDescription.contains("connection refused") || errorDescription.contains("拒绝") {
            return NSLocalizedString("连接被拒绝，请检查服务器是否已启动", comment: "")
        }
        if errorDescription.contains("timed out") || errorDescription.contains("超时") {
            return NSLocalizedString("连接超时，请检查 IP 地址和网络", comment: "")
        }
        if errorDescription.contains("unreachable") || errorDescription.contains("不可达") {
            return NSLocalizedString("网络不可达，请检查 Wi-Fi 连接和设备是否在同一网络", comment: "")
        }
        return String(format: NSLocalizedString("连接失败: %@", comment: ""), error.localizedDescription)
    }

    /// 获取设备标识符
    func getDeviceIdentifier() -> String {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    nonisolated static var debugPlatformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "watchOS"
        #endif
    }

    func startReceiving(connectionToken token: UUID) {
        guard let connection = wsConnection else { return }

        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("接收错误: \(error.localizedDescription)")
                Task { @MainActor in
                    guard self.isCurrentConnection(token) else { return }
                    self.handleConnectionLost(errorMessage: self.describeDebugConnectionFailure(error))
                }
                return
            }

            Task { @MainActor in
                guard self.isCurrentConnection(token) else { return }
                if let data {
                    self.handleReceivedMessage(data)
                    // 让套接字承担背压，不能把大批文件命令无界堆到应用内存中。
                    await self.commandQueue.waitForCompletion()
                }

                if isComplete, self.isCurrentConnection(token) {
                    self.startReceiving(connectionToken: token)
                }
            }
        }
    }

    func handleReceivedMessage(_ data: Data) {
        let token = connectionToken
        commandQueue.enqueue { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try? LocalDebugJSONObject.decode(data) }
            let decoded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, isCurrentConnection(token), let decoded,
                  let command = decoded.value["command"] as? String else { return }
            guard command != "none" else { addLog("心跳", type: .heartbeat); return }
            isProcessingCommand = true
            defer { if isCurrentConnection(token) { isProcessingCommand = false } }
            await LocalDebugCommandContext.$connectionToken.withValue(token) {
                self.addLog(String(format: NSLocalizedString("Debug command received: %@", comment: "调试命令接收日志"), command), type: .receive)
                let response = await self.executeDebugCommand(command, json: decoded.value)
                if let response { await self.sendResponse(response, requestID: decoded.value["request_id"] as? String) }
            }
        }
    }
}
