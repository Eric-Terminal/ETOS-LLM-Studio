// ============================================================================
// LocalDebugServerConnection.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的地址解析、本地网络权限探测、
// WebSocket 连接生命周期，以及调试命令的统一分发。
// ============================================================================

import Foundation
import Network
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

extension LocalDebugServer {
    /// 用于线程安全的权限探测状态管理
    final class PermissionProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var _hasCompleted = false
        private var _permissionGranted = false

        var hasCompleted: Bool {
            get { lock.withLock { _hasCompleted } }
            set { lock.withLock { _hasCompleted = newValue } }
        }

        var permissionGranted: Bool {
            get { lock.withLock { _permissionGranted } }
            set { lock.withLock { _permissionGranted = newValue } }
        }

        /// 原子性地检查并设置完成状态，返回是否是第一次完成
        func tryComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if _hasCompleted {
                return false
            }
            _hasCompleted = true
            return true
        }
    }

    struct ParsedDebugAddress {
        let host: String
        let wsPort: String
        let httpPort: String
    }

    /// 触发本地网络权限请求
    /// 只在真机上执行，模拟器会直接跳过（避免 "Network is down" 错误）
    func triggerLocalNetworkPermission(host: String, completion: @escaping @Sendable () -> Void) {
        #if targetEnvironment(simulator)
        logger.info("检测到模拟器环境，跳过权限检查")
        completion()
        return
        #else
        logger.info("真机环境：触发本地网络权限请求...")

        // 使用目标端口而不是端口 1；watchOS 需要实际尝试连接真实服务端口才会触发权限。
        let targetPort: UInt16
        if let portNum = UInt16(host.components(separatedBy: ":").last ?? "8765") {
            targetPort = portNum
        } else {
            targetPort = 8765
        }

        let actualHost = host.components(separatedBy: ":").first ?? host
        logger.info("尝试连接到 \(actualHost):\(targetPort) 以触发权限")

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(actualHost), port: NWEndpoint.Port(rawValue: targetPort)!)
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        params.serviceClass = .responsiveData

        #if os(watchOS)
        params.requiredInterfaceType = .wifi
        #endif

        let probeConnection = NWConnection(to: endpoint, using: params)

        Task { @MainActor [weak self] in
            self?.permissionProbeConnection = probeConnection
        }

        let probeState = PermissionProbeState()

        probeConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            let logMessage = "权限探测状态: \(String(describing: state))"
            Task { @MainActor in
                self.logger.info("\(logMessage)")
            }

            switch state {
            case .ready:
                guard probeState.tryComplete() else { return }
                probeState.permissionGranted = true
                Task { @MainActor in
                    self.logger.info("权限探测成功，连接已建立")
                }
                probeConnection.cancel()
                Task { @MainActor [weak self] in
                    self?.permissionProbeConnection = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    completion()
                }

            case .failed(let error):
                guard probeState.tryComplete() else { return }
                let errorDesc = error.localizedDescription.lowercased()

                if errorDesc.contains("connection refused") || errorDesc.contains("拒绝") {
                    probeState.permissionGranted = true
                    Task { @MainActor in
                        self.logger.info("权限已授予（连接被拒绝是正常的）")
                    }
                } else if errorDesc.contains("timed out") || errorDesc.contains("超时") {
                    probeState.permissionGranted = true
                    Task { @MainActor in
                        self.logger.info("探测超时，假设权限已授予")
                    }
                } else {
                    Task { @MainActor in
                        self.logger.warning("探测失败: \(error.localizedDescription)")
                    }
                }

                probeConnection.cancel()
                Task { @MainActor [weak self] in
                    self?.permissionProbeConnection = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    completion()
                }

            case .waiting(let error):
                Task { @MainActor in
                    self.logger.info("等待网络（可能是权限弹窗）: \(error.localizedDescription)")
                }

            case .preparing:
                Task { @MainActor in
                    self.logger.info("准备连接...")
                }

            case .setup:
                Task { @MainActor in
                    self.logger.info("设置连接...")
                }

            case .cancelled:
                guard probeState.tryComplete() else { return }
                Task { @MainActor in
                    self.logger.info("探测被取消")
                }
                completion()

            @unknown default:
                Task { @MainActor in
                    self.logger.warning("未知状态: \(String(describing: state))")
                }
            }
        }

        probeConnection.start(queue: queue)

        DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard probeState.tryComplete() else { return }

            if probeState.permissionGranted {
                Task { @MainActor in
                    self?.logger.info("权限检查完成（已授予）")
                }
            } else {
                Task { @MainActor in
                    self?.logger.warning("权限检查超时，强制继续")
                }
            }

            probeConnection.cancel()
            Task { @MainActor [weak self] in
                self?.permissionProbeConnection = nil
            }
            completion()
        }
        #endif
    }

    /// 解析调试服务器地址
    /// 支持格式：
    /// - host
    /// - host:port（useHTTP=true 时按 HTTP 端口解释；否则按 WS 端口解释）
    /// - host:wsPort:httpPort（显式声明双端口）
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
        let defaultWSPort = "8765"
        let defaultHTTPPort = "7654"

        if parts.count >= 3 {
            return ParsedDebugAddress(host: host, wsPort: parts[1], httpPort: parts[2])
        }

        if parts.count == 2 {
            let port = parts[1]
            if useHTTP {
                return ParsedDebugAddress(host: host, wsPort: defaultWSPort, httpPort: port)
            }
            let inferredHTTPPort = (port == defaultWSPort) ? defaultHTTPPort : port
            return ParsedDebugAddress(host: host, wsPort: port, httpPort: inferredHTTPPort)
        }

        return ParsedDebugAddress(host: host, wsPort: defaultWSPort, httpPort: defaultHTTPPort)
    }

    /// 连接到电脑端服务器
    /// - Parameter url: 服务器地址，格式: "192.168.1.100:8765"、"192.168.1.100:8765:7654" 或 "192.168.1.100"
    @MainActor
    public func connect(to url: String) {
        guard !isRunning else { return }

        let parsed = parseDebugAddress(url)
        wsAutoFallbackEnabled = false
        wsFallbackHTTPPort = parsed.httpPort

        if useHTTP {
            logger.info("使用 HTTP 轮询模式")
            serverURL = "\(parsed.host):\(parsed.httpPort)"
            connectionStatus = "正在请求权限..."
            triggerLocalNetworkPermission(host: "\(parsed.host):\(parsed.httpPort)") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.performHTTPConnection(host: parsed.host, port: parsed.httpPort)
                }
            }
        } else {
            wsAutoFallbackEnabled = true
            serverURL = "\(parsed.host):\(parsed.wsPort)"
            connectionStatus = "正在请求权限..."
            triggerLocalNetworkPermission(host: "\(parsed.host):\(parsed.wsPort)") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.performConnection(host: parsed.host, port: parsed.wsPort)
                }
            }
        }
    }

    /// 执行实际的 WebSocket 连接
    @MainActor
    func performConnection(host: String, port: String) {
        logger.info("开始建立WebSocket连接到 \(host):\(port)")

        let urlString = "ws://\(host):\(port)/"
        guard let wsURL = URL(string: urlString) else {
            self.errorMessage = "无效的服务器地址"
            self.connectionStatus = "连接失败"
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
                switch state {
                case .ready:
                    self.isRunning = true
                    self.connectionStatus = "已连接"
                    self.errorMessage = nil
                    self.wsAutoFallbackEnabled = false
                    self.logger.info("已连接到 \(host):\(port)")
                case .failed(let error):
                    if self.wsAutoFallbackEnabled {
                        self.wsAutoFallbackEnabled = false
                        self.useHTTP = true
                        self.serverURL = "\(host):\(self.wsFallbackHTTPPort)"
                        self.connectionStatus = "WebSocket 失败，回退到 HTTP 轮询..."
                        self.errorMessage = "WebSocket 连接失败，已自动切换到 HTTP 轮询"
                        self.logger.error("WebSocket 连接失败，准备回退 HTTP: \(error.localizedDescription)")
                        self.performHTTPConnection(host: host, port: self.wsFallbackHTTPPort)
                        return
                    }

                    self.isRunning = false
                    self.connectionStatus = "连接失败"
                    let errorDescription = error.localizedDescription.lowercased()
                    if errorDescription.contains("connection refused") || errorDescription.contains("拒绝") {
                        self.errorMessage = "连接被拒绝，请检查服务器是否已启动"
                    } else if errorDescription.contains("timed out") || errorDescription.contains("超时") {
                        self.errorMessage = "连接超时，请检查 IP 地址和网络"
                    } else if errorDescription.contains("unreachable") || errorDescription.contains("不可达") {
                        self.errorMessage = "网络不可达，请检查 Wi-Fi 连接和设备是否在同一网络"
                    } else {
                        self.errorMessage = "连接失败: \(error.localizedDescription)"
                    }
                    self.logger.error("连接失败: \(error.localizedDescription)")
                case .cancelled:
                    self.isRunning = false
                    self.connectionStatus = "未连接"
                    self.errorMessage = nil
                    self.wsAutoFallbackEnabled = false
                case .waiting(let error):
                    self.connectionStatus = "等待连接..."
                    self.logger.info("等待连接: \(error.localizedDescription)")
                case .preparing:
                    self.connectionStatus = "准备中..."
                case .setup:
                    self.connectionStatus = "设置中..."
                @unknown default:
                    self.logger.warning("未知连接状态")
                }
            }
        }

        wsConnection?.start(queue: queue)
        startReceiving()
    }

    /// 断开连接
    @MainActor
    public func disconnect() {
        permissionProbeConnection?.cancel()
        permissionProbeConnection = nil

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
        connectionStatus = "未连接"
        wsAutoFallbackEnabled = false
        pendingOpenAIRequests.removeAll()
        updatePendingOpenAIState()
    }

    /// 获取设备标识符
    func getDeviceIdentifier() -> String {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return UIDevice.current.name
        #endif
    }

    func startReceiving() {
        guard let connection = wsConnection else { return }

        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("接收错误: \(error.localizedDescription)")
                Task { @MainActor in
                    self.disconnect()
                }
                return
            }

            Task { @MainActor in
                if let data {
                    self.handleReceivedMessage(data)
                }

                if isComplete {
                    self.startReceiving()
                }
            }
        }
    }

    func handleReceivedMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            return
        }
        let requestID = json["request_id"] as? String

        if command == "none" {
            return
        }

        logger.info("收到命令: \(command)")

        Task {
            switch command {
            case "list":
                let response = await handleList(json)
                sendResponse(response, requestID: requestID)
            case "download":
                let response = await handleDownload(json)
                sendResponse(response, requestID: requestID)
            case "download_all":
                if useHTTP {
                    await handleDownloadAllStream()
                } else {
                    let response = await handleDownloadAll()
                    sendResponse(response, requestID: requestID)
                }
            case "list_all":
                let response = await handleListAll()
                sendResponse(response, requestID: requestID)
            case "upload":
                let response = await handleUpload(json)
                sendResponse(response, requestID: requestID)
            case "upload_all":
                let response = await handleUploadAll(json)
                sendResponse(response, requestID: requestID)
            case "clear_documents":
                let response = await handleClearDocuments()
                sendResponse(response, requestID: requestID)
            case "upload_list":
                await handleUploadList(json)
            case "upload_file":
                let response = await handleUploadFile(json)
                sendResponse(response, requestID: requestID)
            case "upload_complete":
                logger.info("流式上传完成")
                sendResponse(["status": "ok", "message": "上传完成"], requestID: requestID)
            case "delete":
                let response = await handleDelete(json)
                sendResponse(response, requestID: requestID)
            case "mkdir":
                let response = await handleMkdir(json)
                sendResponse(response, requestID: requestID)
            case "openai_capture":
                let response = await handleOpenAICapture(json)
                sendResponse(response, requestID: requestID)
            case "providers_list":
                let response = await handleProvidersList()
                sendResponse(response, requestID: requestID)
            case "providers_save":
                let response = await handleProvidersSave(json)
                sendResponse(response, requestID: requestID)
            case "sessions_list":
                let response = await handleSessionsList()
                sendResponse(response, requestID: requestID)
            case "session_get":
                let response = await handleSessionGet(json)
                sendResponse(response, requestID: requestID)
            case "session_create":
                let response = await handleSessionCreate(json)
                sendResponse(response, requestID: requestID)
            case "session_delete":
                let response = await handleSessionDelete(json)
                sendResponse(response, requestID: requestID)
            case "session_update_meta":
                let response = await handleSessionUpdateMeta(json)
                sendResponse(response, requestID: requestID)
            case "session_update_messages":
                let response = await handleSessionUpdateMessages(json)
                sendResponse(response, requestID: requestID)
            case "memories_list":
                let response = await handleMemoriesList()
                sendResponse(response, requestID: requestID)
            case "memory_update":
                let response = await handleMemoryUpdate(json)
                sendResponse(response, requestID: requestID)
            case "memory_archive":
                let response = await handleMemoryArchive(json)
                sendResponse(response, requestID: requestID)
            case "memory_unarchive":
                let response = await handleMemoryUnarchive(json)
                sendResponse(response, requestID: requestID)
            case "memories_reembed_all":
                let response = await handleMemoriesReembedAll()
                sendResponse(response, requestID: requestID)
            case "openai_queue_list":
                let response = await handleOpenAIQueueList()
                sendResponse(response, requestID: requestID)
            case "openai_queue_resolve":
                let response = await handleOpenAIQueueResolve(json)
                sendResponse(response, requestID: requestID)
            case "ping":
                sendResponse(["status": "ok", "message": "pong"], requestID: requestID)
            default:
                sendResponse(["status": "error", "message": "未知命令"], requestID: requestID)
            }
        }
    }

    func sendResponse(_ response: [String: Any], requestID: String? = nil) {
        var payload = response
        if let requestID, !requestID.isEmpty {
            payload["request_id"] = requestID
        }

        if useHTTP {
            let components = serverURL.split(separator: ":").map(String.init)
            let host = components.first ?? ""
            let port = components.count > 1 ? components[1] : "7654"
            sendHTTPResponse(payload, host: host, port: port)
        } else {
            guard let connection = wsConnection,
                  let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return
            }

            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])

            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
