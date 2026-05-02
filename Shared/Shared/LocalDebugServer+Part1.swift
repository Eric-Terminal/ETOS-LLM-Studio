import Foundation
import Combine
import Network
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

extension LocalDebugServer {
    // MARK: - 调试日志
    
    /// 添加调试日志
    public func addLog(_ message: String, type: DebugLogEntry.LogType = .info) {
        // 心跳日志只记录到系统日志，不显示在UI中（避免占用空间）
        if type == .heartbeat {
            logger.debug("[\(type)] \(message)")
            return
        }
        
        let entry = DebugLogEntry(timestamp: Date(), message: message, type: type)
        debugLogs.insert(entry, at: 0)
        if debugLogs.count > maxLogEntries {
            debugLogs.removeLast()
        }
        logger.info("[\(type)] \(message)")
    }
    
    /// 清空日志
    public func clearLogs() {
        debugLogs.removeAll()
    }
    
    // MARK: - 连接管理
    
    /// 用于线程安全的权限探测状态管理
    final class PermissionProbeState: @unchecked Sendable {
        let lock = NSLock()
        var _hasCompleted = false
        var _permissionGranted = false
        
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
    
    /// 触发本地网络权限请求
    /// 只在真机上执行，模拟器会直接跳过（避免"Network is down"错误）
    func triggerLocalNetworkPermission(host: String, completion: @escaping @Sendable () -> Void) {
        // 检测是否是模拟器
        #if targetEnvironment(simulator)
        logger.info("检测到模拟器环境，跳过权限检查")
        completion()
        return
        #else
        logger.info("真机环境：触发本地网络权限请求...")
        
        // 🔥 关键修复：使用目标端口而不是端口1！
        // watchOS需要实际尝试连接到真实的服务端口才会触发权限
        // 使用解析后的实际端口号
        let targetPort: UInt16
        if let portNum = UInt16(host.components(separatedBy: ":").last ?? "8765") {
            targetPort = portNum
        } else {
            targetPort = 8765
        }
        
        // 使用实际的host（不带端口）
        let actualHost = host.components(separatedBy: ":").first ?? host
        
        logger.info("尝试连接到 \(actualHost):\(targetPort) 以触发权限")
        
        // 创建临时的TCP连接
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(actualHost), port: NWEndpoint.Port(rawValue: targetPort)!)
        let params = NWParameters.tcp
        
        // 🔥 关键：不要禁用任何接口，让系统自己选择
        // 禁用蜂窝是对的，但不要禁用loopback（如果服务器在本机）
        params.prohibitedInterfaceTypes = [.cellular]
        
        // 🔥 设置超时时间
        params.serviceClass = .responsiveData
        
        #if os(watchOS)
        // watchOS必须指定使用WiFi
        params.requiredInterfaceType = .wifi
        #endif
        
        let probeConnection = NWConnection(to: endpoint, using: params)
        
        // 在主线程上设置 permissionProbeConnection
        Task { @MainActor [weak self] in
            self?.permissionProbeConnection = probeConnection
        }
        
        // 使用线程安全的状态对象
        let probeState = PermissionProbeState()
        
        probeConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            // 使用 nonisolated 方式记录日志
            let logMessage = "权限探测状态: \(String(describing: state))"
            Task { @MainActor in
                self.logger.info("\(logMessage)")
            }
            
            switch state {
            case .ready:
                // 连接成功！这意味着权限已授予
                guard probeState.tryComplete() else { return }
                probeState.permissionGranted = true
                Task { @MainActor in
                    self.logger.info("权限探测成功，连接已建立")
                }
                probeConnection.cancel()
                Task { @MainActor [weak self] in
                    self?.permissionProbeConnection = nil
                }
                // 等待一下让权限状态完全生效
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    completion()
                }
                
            case .failed(let error):
                // 连接失败但不代表权限失败
                // 如果是"connection refused"，说明至少网络栈尝试连接了（权限OK）
                guard probeState.tryComplete() else { return }
                let errorDesc = error.localizedDescription.lowercased()
                
                if errorDesc.contains("connection refused") || errorDesc.contains("拒绝") {
                    // 连接被拒绝 = 权限OK，但服务器未启动
                    probeState.permissionGranted = true
                    Task { @MainActor in
                        self.logger.info("权限已授予（连接被拒绝是正常的）")
                    }
                } else if errorDesc.contains("timed out") || errorDesc.contains("超时") {
                    // 超时也可能是权限OK的
                    probeState.permissionGranted = true
                    Task { @MainActor in
                        self.logger.info("探测超时，假设权限已授予")
                    }
                } else {
                    // 其他错误，可能是权限问题
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
                // 等待中 - 可能是权限弹窗正在显示！
                Task { @MainActor in
                    self.logger.info("⏳ 等待网络（可能是权限弹窗）: \(error.localizedDescription)")
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
    
    struct ParsedDebugAddress {
        let host: String
        let wsPort: String
        let httpPort: String
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
            // HTTP 轮询模式，直接启动
            logger.info("使用 HTTP 轮询模式")
            serverURL = "\(parsed.host):\(parsed.httpPort)"
            connectionStatus = "正在请求权限..."
            triggerLocalNetworkPermission(host: "\(parsed.host):\(parsed.httpPort)") { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.performHTTPConnection(host: parsed.host, port: parsed.httpPort)
                }
            }
        } else {
            // WebSocket 优先，并在失败时自动回退 HTTP 轮询
            wsAutoFallbackEnabled = true
            serverURL = "\(parsed.host):\(parsed.wsPort)"
            connectionStatus = "正在请求权限..."
            triggerLocalNetworkPermission(host: "\(parsed.host):\(parsed.wsPort)") { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.performConnection(host: parsed.host, port: parsed.wsPort)
                }
            }
        }
    }
    
    /// 执行实际的WebSocket连接
    @MainActor
    func performConnection(host: String, port: String) {
        logger.info("开始建立WebSocket连接到 \(host):\(port)")
        
        // 创建 WebSocket URL
        let urlString = "ws://\(host):\(port)/"
        guard let wsURL = URL(string: urlString) else {
            self.errorMessage = "无效的服务器地址"
            self.connectionStatus = "连接失败"
            return
        }
        
        let endpoint = NWEndpoint.url(wsURL)
        let parameters = NWParameters.tcp
        
        // 真机环境：禁用蜂窝网络，优先使用WiFi
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
            guard let self = self else { return }
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
                    // 提供更友好的错误信息
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
                    self.logger.info("⏳ 等待连接: \(error.localizedDescription)")
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
        // 停止权限探测
        permissionProbeConnection?.cancel()
        permissionProbeConnection = nil
        
        // 停止 HTTP 轮询
        httpPollingTimer?.invalidate()
        httpPollingTimer = nil
        httpFailureCount = 0
        
        // 停止 WebSocket
        wsConnection?.cancel()
        wsConnection = nil
        
        // 停止 HTTP 轮询
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
    
    // MARK: - HTTP 轮询模式
    
    /// 执行 HTTP 连接和轮询
    @MainActor
    func performHTTPConnection(host: String, port: String) {
        logger.info("开始 HTTP 轮询模式，目标: \(host):\(port)")
        
        // 创建 URLSession，支持大文件传输
        let config = NetworkSessionConfiguration.makeConfiguration()
        config.httpMaximumConnectionsPerHost = 4  // 增加并发连接数
        httpSession = URLSession(configuration: config)
        
        // 先测试连接
        testHTTPConnection(host: host, port: port) { [weak self] success, error in
            guard let self = self else { return }
            Task { @MainActor in
                if success {
                    self.isRunning = true
                    self.connectionStatus = "已连接 (HTTP)"
                    self.errorMessage = nil
                    self.logger.info("HTTP 连接测试成功")
                    // 启动轮询定时器
                    self.startHTTPPolling(host: host, port: port)
                } else {
                    self.isRunning = false
                    self.connectionStatus = "连接失败"
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
            return "无法连接到服务器，请检查地址和端口"
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "HTTP 被系统安全策略拦截，请允许本地网络明文访问后重试"
        }

        let description = error.localizedDescription.lowercased()
        if description.contains("connection refused") || description.contains("拒绝") {
            return "连接被拒绝，请检查服务器是否已启动"
        }
        if description.contains("timed out") || description.contains("超时") {
            return "连接超时，请检查 IP 地址和网络"
        }
        if description.contains("unreachable") || description.contains("不可达") {
            return "网络不可达，请检查 Wi-Fi 连接和设备是否在同一网络"
        }

        return "连接失败: \(error.localizedDescription)"
    }
    
    /// 启动 HTTP 轮询
    @MainActor
    func startHTTPPolling(host: String, port: String) {
        logger.info("启动 HTTP 轮询，间隔: \(self.httpPollingInterval)秒")
        
        // 使用主线程的 Timer
        httpPollingTimer = Timer.scheduledTimer(withTimeInterval: self.httpPollingInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 在主线程上执行轮询
            Task { @MainActor in
                self.performHTTPPoll(host: host, port: port)
            }
        }
        
        // 立即执行第一次轮询
        performHTTPPoll(host: host, port: port)
    }
    
    /// 执行一次 HTTP 轮询
    func performHTTPPoll(host: String, port: String) {
        // 如果正在批量传输，跳过此次轮询
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
        
        // 发送设备信息
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
                // 轮询失败计数
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
            
            // 重置失败计数
            Task { @MainActor in
                self.httpFailureCount = 0
            }
            
            // 解析命令
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let command = json["command"] as? String {
                Task { @MainActor in
                    if command == "none" {
                        // 心跳包，无命令
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
        request.timeoutInterval = 30.0  // 增加到30秒，支持大文件
        
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
    
    /// 格式化文件大小
    func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.2f MB", mb)
    }
    
    /// 获取设备标识符
    func getDeviceIdentifier() -> String {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return UIDevice.current.name
        #endif
    }
    
    // MARK: - 消息收发
    
    func startReceiving() {
        guard let connection = wsConnection else { return }
        
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("接收错误: \(error.localizedDescription)")
                Task { @MainActor in
                    self.disconnect()
                }
                return
            }
            
            Task { @MainActor in
                if let data = data {
                    self.handleReceivedMessage(data)
                }
                
                if isComplete {
                    self.startReceiving()
                }
            }
        }
    }
    
}
