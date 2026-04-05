// ============================================================================
// LocalDebugServer.swift (WebSocket Client Version)
// ============================================================================
// ETOS LLM Studio
//
// 反向探针调试客户端,通过WebSocket主动连接到电脑端服务器。
// 功能包括:文件浏览、下载、上传、OpenAI请求捕获转发。
// ============================================================================

import Foundation
import Combine
import Network
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

/// 反向探针调试客户端
@MainActor
public class LocalDebugServer: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则本地调试页的连接状态、请求队列与日志不会稳定刷新。

    public struct OpenAIRequestSummary: Identifiable, Hashable {
        public let id: UUID
        public let model: String?
        public let messageCount: Int
        public let receivedAt: Date
    }

    @Published public var isRunning = false
    @Published public var serverURL: String = ""
    @Published public var connectionStatus: String = "未连接"
    @Published public var errorMessage: String?
    @Published public var pendingOpenAIRequest: OpenAIRequestSummary?
    @Published public var pendingOpenAIQueueCount: Int = 0
    @Published public var useHTTP: Bool = true // HTTP 轮询模式开关（默认启用）
    @Published public var debugLogs: [DebugLogEntry] = [] // 调试日志
    @Published public var isTransferring: Bool = false // 是否正在进行批量传输（暂停轮询）
    
    /// 调试日志条目
    public struct DebugLogEntry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let type: LogType
        
        public enum LogType: CustomStringConvertible {
            case info, send, receive, error, heartbeat
            
            public var description: String {
                switch self {
                case .info: return "INFO"
                case .send: return "SEND"
                case .receive: return "RECV"
                case .error: return "ERROR"
                case .heartbeat: return "BEAT"
                }
            }
        }
    }
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    private var wsConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    private var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    private var permissionProbeConnection: NWConnection?
    
    // HTTP 轮询相关
    private var httpPollingTimer: Timer?
    private var httpSession: URLSession?
    private let httpPollingInterval: TimeInterval = 1.0 // 1秒轮询一次
    private var httpFailureCount: Int = 0 // HTTP 失败计数
    private let maxHTTPFailures: Int = 5 // 最大失败次数
    
    // 自动回退相关（WS 失败后回退 HTTP）
    private var wsAutoFallbackEnabled = false
    private var wsFallbackHTTPPort = "7654"
    
    private let maxLogEntries = 100 // 最大日志条数
    
    public init() {}
    
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
    private final class PermissionProbeState: @unchecked Sendable {
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
    
    /// 触发本地网络权限请求
    /// 只在真机上执行，模拟器会直接跳过（避免"Network is down"错误）
    private func triggerLocalNetworkPermission(host: String, completion: @escaping @Sendable () -> Void) {
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
    
    private struct ParsedDebugAddress {
        let host: String
        let wsPort: String
        let httpPort: String
    }
    
    /// 解析调试服务器地址
    /// 支持格式：
    /// - host
    /// - host:port（useHTTP=true 时按 HTTP 端口解释；否则按 WS 端口解释）
    /// - host:wsPort:httpPort（显式声明双端口）
    private func parseDebugAddress(_ raw: String) -> ParsedDebugAddress {
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
    private func performConnection(host: String, port: String) {
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
    private func performHTTPConnection(host: String, port: String) {
        logger.info("开始 HTTP 轮询模式，目标: \(host):\(port)")
        
        // 创建 URLSession，支持大文件传输
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 300.0  // 5分钟，支持大文件
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
    private func testHTTPConnection(host: String, port: String, completion: @escaping (Bool, Error?) -> Void) {
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
    private func describeHTTPConnectionFailure(_ error: Error?) -> String {
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
    private func startHTTPPolling(host: String, port: String) {
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
    private func performHTTPPoll(host: String, port: String) {
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
    private func sendHTTPResponse(_ response: [String: Any], host: String, port: String) {
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
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.2f MB", mb)
    }
    
    /// 获取设备标识符
    private func getDeviceIdentifier() -> String {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return UIDevice.current.name
        #endif
    }
    
    // MARK: - 消息收发
    
    private func startReceiving() {
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
    
    private func handleReceivedMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            return
        }
        let requestID = json["request_id"] as? String
        
        // 忽略空命令
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
                // HTTP 模式下使用流式下载
                if useHTTP {
                    await handleDownloadAllStream()
                } else {
                    let response = await handleDownloadAll()
                    sendResponse(response, requestID: requestID)
                }
            case "list_all":
                // 兼容模式：只返回文件路径列表（不含数据）
                let response = await handleListAll()
                sendResponse(response, requestID: requestID)
            case "upload":
                let response = await handleUpload(json)
                sendResponse(response, requestID: requestID)
            case "upload_all":
                // WebSocket 批量上传
                let response = await handleUploadAll(json)
                sendResponse(response, requestID: requestID)
            case "clear_documents":
                // HTTP 流式上传：第一步清空目录
                let response = await handleClearDocuments()
                sendResponse(response, requestID: requestID)
            case "upload_list":
                // HTTP 流式上传：接收文件列表，逐个请求文件
                await handleUploadList(json)
            case "upload_file":
                // HTTP 流式上传：接收单个文件
                let response = await handleUploadFile(json)
                sendResponse(response, requestID: requestID)
            case "upload_complete":
                // HTTP 流式上传完成
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
    
    private func sendResponse(_ response: [String: Any], requestID: String? = nil) {
        var payload = response
        if let requestID, !requestID.isEmpty {
            payload["request_id"] = requestID
        }

        if useHTTP {
            // HTTP 模式：发送响应到服务器
            let components = serverURL.split(separator: ":").map(String.init)
            let host = components.first ?? ""
            let port = components.count > 1 ? components[1] : "7654"
            sendHTTPResponse(payload, host: host, port: port)
        } else {
            // WebSocket 模式：直接发送
            guard let connection = wsConnection,
                  let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return
            }
            
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
            
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
    
    // MARK: - 命令处理
    
    private func handleList(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 处理特殊路径
        let normalizedPath = path.trimmingCharacters(in: .whitespaces)
        let targetURL: URL
        if normalizedPath.isEmpty || normalizedPath == "." {
            targetURL = documentsURL
        } else {
            targetURL = documentsURL.appendingPathComponent(normalizedPath)
        }
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            return ["status": "error", "message": "路径越界"]
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: targetURL.path)
            var items: [[String: Any]] = []
            
            for item in contents {
                let itemURL = targetURL.appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
                
                let attributes = try FileManager.default.attributesOfItem(atPath: itemURL.path)
                
                items.append([
                    "name": item,
                    "isDirectory": isDirectory.boolValue,
                    "size": attributes[.size] as? Int64 ?? 0,
                    "modificationDate": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                ])
            }
            
            return [
                "status": "ok",
                "path": path,
                "items": items
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    private func handleDownload(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(path)
        
        guard targetURL.path.hasPrefix(documentsURL.path),
              FileManager.default.fileExists(atPath: targetURL.path) else {
            return ["status": "error", "message": "文件不存在"]
        }
        
        do {
            let data = try Data(contentsOf: targetURL)
            return [
                "status": "ok",
                "path": path,
                "data": data.base64EncodedString(),
                "size": data.count
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    private func handleUpload(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String,
              let base64 = json["data"] as? String,
              let data = Data(base64Encoded: base64) else {
            return ["status": "error", "message": "参数错误"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(path)
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            return ["status": "error", "message": "路径越界"]
        }
        
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: targetURL)
            return [
                "status": "ok",
                "path": path,
                "size": data.count
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    private func handleDelete(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(path)
        
        guard targetURL.path.hasPrefix(documentsURL.path),
              FileManager.default.fileExists(atPath: targetURL.path) else {
            return ["status": "error", "message": "文件不存在"]
        }
        
        do {
            try FileManager.default.removeItem(at: targetURL)
            return ["status": "ok", "path": path]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    /// 兼容模式：只返回文件路径列表（不含文件数据）
    /// 用于让 Python 端逐个请求下载
    private func handleListAll() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            logger.info("开始扫描 Documents 目录（仅路径）...")
            var filePaths: [String] = []
            
            // 递归收集所有文件路径
            try collectFilePaths(documentsURL, baseURL: documentsURL, filePaths: &filePaths)
            
            logger.info("扫描完成: \(filePaths.count) 个文件")
            
            return [
                "status": "ok",
                "paths": filePaths,
                "total": filePaths.count,
                "message": "文件列表已返回"
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    private func handleDownloadAll() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            logger.info("开始扫描 Documents 目录...")
            var fileList: [[String: Any]] = []
            
            // 递归扫描所有文件
            try scanDirectory(documentsURL, baseURL: documentsURL, fileList: &fileList)
            
            logger.info("扫描完成: \(fileList.count) 个文件")
            
            return [
                "status": "ok",
                "files": fileList,
                "message": "已扫描完成"
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    /// HTTP 流式下载：连续发送所有文件到电脑（不等待响应）
    private func handleDownloadAllStream() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 先检查 httpSession 是否可用
        guard httpSession != nil else {
            logger.error("httpSession 为 nil，无法执行流式下载")
            return
        }
        
        // 标记开始批量传输，暂停轮询
        isTransferring = true
        addLog("开始流式下载（暂停轮询）", type: .info)
        
        defer {
            // 传输完成后恢复轮询
            Task { @MainActor in
                self.isTransferring = false
                self.addLog("流式下载结束（恢复轮询）", type: .info)
            }
        }
        
        do {
            logger.info("开始流式下载 Documents 目录...")
            
            // 收集所有文件路径
            var filePaths: [String] = []
            try collectFilePaths(documentsURL, baseURL: documentsURL, filePaths: &filePaths)
            
            logger.info("发现 \(filePaths.count) 个文件，开始连续传输")
            
            var successCount = 0
            var failCount = 0
            
            // 连续发送所有文件（等待每个发送完成）
            for (index, relativePath) in filePaths.enumerated() {
                let fileURL = documentsURL.appendingPathComponent(relativePath)
                
                do {
                    let data = try Data(contentsOf: fileURL)
                    let response: [String: Any] = [
                        "status": "ok",
                        "path": relativePath,
                        "data": data.base64EncodedString(),
                        "size": data.count,
                        "index": index + 1,
                        "total": filePaths.count
                    ]
                    
                    // 等待发送完成再发下一个
                    await sendHTTPResponseAsync(response)
                    successCount += 1
                    
                    // 每10个文件打印一次进度
                    if (index + 1) % 10 == 0 || index + 1 == filePaths.count {
                        logger.info("进度: \(index + 1)/\(filePaths.count) (成功: \(successCount), 失败: \(failCount))")
                    }
                    
                } catch {
                    failCount += 1
                    logger.error("读取文件失败: \(relativePath) - \(error.localizedDescription)")
                }
            }
            
            logger.info("传输统计: 成功 \(successCount), 失败 \(failCount), 总计 \(filePaths.count)")
            
            // 🔥 关键修复：在发送完成信号前等待一小段时间
            // 确保服务器有时间处理最后几个文件响应
            // 实体机网络比虚拟机更快，可能导致完成信号"超车"到达
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            
            // 发送完成消息（包含实际发送的文件数，让服务器验证）
            let completeResponse: [String: Any] = [
                "status": "ok",
                "message": "流式下载完成",
                "total": filePaths.count,
                "success_count": successCount,
                "fail_count": failCount,
                "stream_complete": true
            ]
            await sendHTTPResponseAsync(completeResponse)
            logger.info("流式下载完成，共 \(filePaths.count) 个文件")
            
        } catch {
            logger.error("流式下载出错: \(error.localizedDescription)")
            let errorResponse: [String: Any] = [
                "status": "error",
                "message": error.localizedDescription
            ]
            await sendHTTPResponseAsync(errorResponse)
        }
    }
    
    /// 收集目录下所有文件的相对路径
    private func collectFilePaths(_ dirURL: URL, baseURL: URL, filePaths: inout [String]) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey])
        
        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            
            if resourceValues.isDirectory == true {
                try collectFilePaths(item, baseURL: baseURL, filePaths: &filePaths)
            } else {
                let relativePath = item.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                filePaths.append(relativePath)
            }
        }
    }
    
    /// 异步发送 HTTP 响应（等待完成）
    /// 🔥 重要：确保每个请求完全完成后再返回，避免并发导致的乱序问题
    private func sendHTTPResponseAsync(_ response: [String: Any]) async {
        let components = serverURL.split(separator: ":").map(String.init)
        let host = components.first ?? ""
        let port = components.count > 1 ? components[1] : "7654"
        
        guard let url = URL(string: "http://\(host):\(port)/response") else {
            logger.error("无效的 URL: http://\(host):\(port)/response")
            return
        }
        
        // 安全获取 httpSession
        guard let session = httpSession else {
            logger.error("httpSession 为 nil，无法发送响应")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 🔥 添加 Connection: close 避免 HTTP keep-alive 造成的乱序
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 60.0
        
        // JSON 序列化并记录错误
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: response)
        } catch {
            logger.error("JSON 序列化失败: \(error.localizedDescription), 响应键: \(response.keys.joined(separator: ", "))")
            return
        }
        request.httpBody = jsonData
        
        // 记录发送的索引（用于调试）
        let index = response["index"] as? Int
        let isComplete = response["stream_complete"] as? Bool ?? false
        
        do {
            let (_, httpResponse) = try await session.data(for: request)
            if let httpRes = httpResponse as? HTTPURLResponse {
                if httpRes.statusCode != 200 {
                    logger.error("服务器返回错误状态码: \(httpRes.statusCode)")
                } else if isComplete {
                    logger.info("✅ 完成信号已确认送达服务器")
                }
            }
            
            // 🔥 每个请求后添加小延迟，确保服务器有时间处理
            // 这对实体机尤其重要，因为实体机网络速度可能比服务器处理速度快
            if index != nil && !isComplete {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        } catch {
            logger.error("发送响应失败 (index=\(index ?? -1)): \(error.localizedDescription)")
        }
    }
    
    private func scanDirectory(_ dirURL: URL, baseURL: URL, fileList: inout [[String: Any]]) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey])
        
        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            
            if resourceValues.isDirectory == true {
                // 递归扫描子目录
                try scanDirectory(item, baseURL: baseURL, fileList: &fileList)
            } else {
                // 读取文件内容
                let data = try Data(contentsOf: item)
                let relativePath = item.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                
                fileList.append([
                    "path": relativePath,
                    "data": data.base64EncodedString(),
                    "size": data.count
                ])
            }
        }
    }
    
    private func handleUploadAll(_ json: [String: Any]) async -> [String: Any] {
        // WebSocket模式：files数组，一次性上传所有
        if let files = json["files"] as? [[String: Any]] {
            return await handleBatchUpload(files: files)
        } else {
            return ["status": "error", "message": "无效的上传参数"]
        }
    }
    
    /// HTTP 流式上传：接收文件列表，连续请求所有文件
    private func handleUploadList(_ json: [String: Any]) async {
        guard let paths = json["paths"] as? [String],
              let total = json["total"] as? Int else {
            logger.error("无效的文件列表")
            return
        }
        
        // 标记开始批量传输，暂停轮询
        isTransferring = true
        addLog("开始流式上传（暂停轮询）", type: .info)
        
        defer {
            // 传输完成后恢复轮询
            Task { @MainActor in
                self.isTransferring = false
                self.addLog("流式上传结束（恢复轮询）", type: .info)
            }
        }
        
        logger.info("收到文件列表: \(total) 个文件")
        
        // 先清空Documents目录
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            logger.info("清空 Documents 目录...")
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in contents {
                try fileManager.removeItem(at: item)
            }
            logger.info("Documents 目录已清空")
        } catch {
            logger.error("清空目录失败: \(error.localizedDescription)")
            return
        }
        
        // 连续请求所有文件
        for (index, path) in paths.enumerated() {
            await fetchAndWriteFile(path: path, index: index + 1, total: total)
        }
        
        logger.info("所有文件上传完成！")
    }
    
    /// 请求并写入单个文件
    private func fetchAndWriteFile(path: String, index: Int, total: Int) async {
        let components = serverURL.split(separator: ":").map(String.init)
        let host = components.first ?? ""
        let port = components.count > 1 ? components[1] : "7654"
        
        guard let url = URL(string: "http://\(host):\(port)/fetch_file") else {
            logger.error("无效的URL")
            return
        }
        
        // 安全获取 httpSession
        guard let session = httpSession else {
            logger.error("httpSession 为 nil，无法请求文件")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        let requestBody: [String: Any] = ["path": path]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            logger.error("无法序列化请求")
            return
        }
        request.httpBody = jsonData
        
        do {
            let (data, _) = try await session.data(for: request)
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "ok",
                  let fileData = json["data"] as? String,
                  let decodedData = Data(base64Encoded: fileData) else {
                logger.error("无效的响应: \(path)")
                return
            }
            
            // 写入文件
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent(path)
            let dirURL = fileURL.deletingLastPathComponent()
            
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try decodedData.write(to: fileURL)
            
            let remaining = json["remaining"] as? Int ?? 0
            logger.info("[\(index)/\(total)] 写入: \(path) (\(decodedData.count) bytes) [剩余 \(remaining)]")
            
        } catch {
            logger.error("请求文件失败 \(path): \(error.localizedDescription)")
        }
    }
    
    /// HTTP 流式上传：接收单个文件（旧方法，保留兼容）
    private func handleUploadFile(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String,
              let b64Data = json["data"] as? String else {
            return ["status": "error", "message": "文件数据缺失"]
        }
        
        let remaining = json["remaining"] as? Int ?? 0
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            guard let data = Data(base64Encoded: b64Data) else {
                return ["status": "error", "message": "Base64解码失败"]
            }
            
            let fileURL = documentsURL.appendingPathComponent(path)
            let dirURL = fileURL.deletingLastPathComponent()
            
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try data.write(to: fileURL)
            
            logger.info("写入: \(path) (\(data.count) bytes) [剩余 \(remaining)]")
            
            return [
                "status": "ok",
                "message": "文件已写入",
                "path": path
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    /// 清空Documents目录
    private func handleClearDocuments() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            logger.info("清空 Documents 目录...")
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in contents {
                try fileManager.removeItem(at: item)
            }
            logger.info("Documents 目录已清空")
            return ["status": "ok", "message": "目录已清空"]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    /// 批量上传（WebSocket模式）
    private func handleBatchUpload(files: [[String: Any]]) async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            // 清空目录
            logger.info("清空 Documents 目录...")
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in contents {
                try fileManager.removeItem(at: item)
            }
            
            // 递归创建文件
            logger.info("开始上传 \(files.count) 个文件...")
            for fileInfo in files {
                guard let relativePath = fileInfo["path"] as? String,
                      let base64Data = fileInfo["data"] as? String,
                      let data = Data(base64Encoded: base64Data) else {
                    continue
                }
                
                let targetURL = documentsURL.appendingPathComponent(relativePath)
                
                // 创建父目录
                let parentURL = targetURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentURL.path) {
                    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }
                
                // 写入文件
                try data.write(to: targetURL)
            }
            
            logger.info("上传完成")
            return [
                "status": "ok",
                "message": "已覆盖 Documents 目录，共 \(files.count) 个文件"
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    private func handleMkdir(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 处理特殊路径
        let normalizedPath = path.trimmingCharacters(in: .whitespaces)
        let targetURL: URL
        if normalizedPath.isEmpty || normalizedPath == "." {
            targetURL = documentsURL
        } else {
            targetURL = documentsURL.appendingPathComponent(normalizedPath)
        }
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            return ["status": "error", "message": "路径越界"]
        }
        
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return ["status": "ok", "path": path]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    // MARK: - 业务命令（提供商 / 会话 / 记忆）

    nonisolated private static func parseWebConsoleDate(_ value: String) -> Date? {
        let preciseFormatter = ISO8601DateFormatter()
        preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = preciseFormatter.date(from: value) {
            return precise
        }
        let defaultFormatter = ISO8601DateFormatter()
        defaultFormatter.formatOptions = [.withInternetDateTime]
        return defaultFormatter.date(from: value)
    }

    nonisolated private static func formatWebConsoleDate(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private func makeWebConsoleJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeWebConsoleJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let timestamp = try? container.decode(Int.self) {
                return Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
            if let value = try? container.decode(String.self) {
                if let parsed = Self.parseWebConsoleDate(value) {
                    return parsed
                }
                if let timestamp = Double(value) {
                    return Date(timeIntervalSince1970: timestamp)
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期")
        }
        return decoder
    }

    private func encodeWebConsoleJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try makeWebConsoleJSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func decodeWebConsoleObject<T: Decodable>(_ raw: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try makeWebConsoleJSONDecoder().decode(type, from: data)
    }

    private func handleProvidersList() async -> [String: Any] {
        let providers = ConfigLoader.loadProviders()
        do {
            let payload = try encodeWebConsoleJSONObject(providers)
            return ["status": "ok", "providers": payload, "count": providers.count]
        } catch {
            return ["status": "error", "message": "提供商序列化失败：\(error.localizedDescription)"]
        }
    }

    private func handleProvidersSave(_ json: [String: Any]) async -> [String: Any] {
        guard let providersRaw = json["providers"] else {
            return ["status": "error", "message": "缺少 providers 参数"]
        }

        do {
            let providers = try decodeWebConsoleObject(providersRaw, as: [Provider].self)
            let existingProviders = ConfigLoader.loadProviders()
            let incomingIDs = Set(providers.map(\.id))

            for oldProvider in existingProviders where !incomingIDs.contains(oldProvider.id) {
                ConfigLoader.deleteProvider(oldProvider)
            }
            for provider in providers {
                ConfigLoader.saveProvider(provider)
            }
            ChatService.shared.reloadProviders()

            return ["status": "ok", "message": "提供商配置已保存", "count": providers.count]
        } catch {
            return ["status": "error", "message": "保存提供商失败：\(error.localizedDescription)"]
        }
    }

    private func handleSessionsList() async -> [String: Any] {
        let sessions = Persistence.loadChatSessions()
        do {
            let payload = try encodeWebConsoleJSONObject(sessions)
            return ["status": "ok", "sessions": payload, "count": sessions.count]
        } catch {
            return ["status": "error", "message": "会话序列化失败：\(error.localizedDescription)"]
        }
    }

    private func handleSessionGet(_ json: [String: Any]) async -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }

        let sessions = Persistence.loadChatSessions()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return ["status": "error", "message": "未找到会话"]
        }

        let messages = Persistence.loadMessages(for: sessionID)
        do {
            let sessionPayload = try encodeWebConsoleJSONObject(session)
            let messagesPayload = try encodeWebConsoleJSONObject(messages)
            return [
                "status": "ok",
                "session": sessionPayload,
                "messages": messagesPayload,
                "message_count": messages.count
            ]
        } catch {
            return ["status": "error", "message": "会话详情序列化失败：\(error.localizedDescription)"]
        }
    }

    private func handleSessionCreate(_ json: [String: Any]) async -> [String: Any] {
        let rawName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (rawName?.isEmpty == false) ? rawName! : "新的对话"
        let topicPrompt = json["topic_prompt"] as? String
        let enhancedPrompt = json["enhanced_prompt"] as? String

        let session = ChatSession(
            id: UUID(),
            name: name,
            topicPrompt: topicPrompt,
            enhancedPrompt: enhancedPrompt,
            isTemporary: false
        )

        var sessions = Persistence.loadChatSessions()
        sessions.insert(session, at: 0)
        Persistence.saveChatSessions(sessions)
        Persistence.saveMessages([], for: session.id)

        var liveSessions = ChatService.shared.chatSessionsSubject.value
        liveSessions.insert(session, at: 0)
        ChatService.shared.chatSessionsSubject.send(liveSessions)

        do {
            let payload = try encodeWebConsoleJSONObject(session)
            return ["status": "ok", "message": "会话已创建", "session": payload]
        } catch {
            return ["status": "error", "message": "会话序列化失败：\(error.localizedDescription)"]
        }
    }

    private func handleSessionDelete(_ json: [String: Any]) async -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }

        let sessions = ChatService.shared.chatSessionsSubject.value
        guard let target = sessions.first(where: { $0.id == sessionID }) else {
            return ["status": "error", "message": "未找到会话"]
        }

        ChatService.shared.deleteSessions([target])
        return ["status": "ok", "message": "会话已删除", "session_id": sessionID.uuidString]
    }

    private func handleSessionUpdateMeta(_ json: [String: Any]) async -> [String: Any] {
        guard let sessionRaw = json["session"] else {
            return ["status": "error", "message": "缺少 session 参数"]
        }

        do {
            let session = try decodeWebConsoleObject(sessionRaw, as: ChatSession.self)
            let existingSessions = Persistence.loadChatSessions()
            guard existingSessions.contains(where: { $0.id == session.id }) else {
                return ["status": "error", "message": "未找到会话"]
            }

            ChatService.shared.updateSession(session)
            let payload = try encodeWebConsoleJSONObject(session)
            return ["status": "ok", "message": "会话元数据已更新", "session": payload]
        } catch {
            return ["status": "error", "message": "更新会话元数据失败：\(error.localizedDescription)"]
        }
    }

    private func handleSessionUpdateMessages(_ json: [String: Any]) async -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }
        guard let messagesRaw = json["messages"] else {
            return ["status": "error", "message": "缺少 messages 参数"]
        }

        do {
            let messages = try decodeWebConsoleObject(messagesRaw, as: [ChatMessage].self)
            Persistence.saveMessages(messages, for: sessionID)

            if ChatService.shared.currentSessionSubject.value?.id == sessionID {
                ChatService.shared.reloadCurrentSessionMessagesFromPersistence()
            }

            return ["status": "ok", "message": "会话消息已更新", "count": messages.count]
        } catch {
            return ["status": "error", "message": "更新会话消息失败：\(error.localizedDescription)"]
        }
    }

    private func handleMemoriesList() async -> [String: Any] {
        let memories = await MemoryManager.shared.getAllMemories()
        do {
            let payload = try encodeWebConsoleJSONObject(memories)
            let activeCount = memories.filter { !$0.isArchived }.count
            return [
                "status": "ok",
                "memories": payload,
                "count": memories.count,
                "active_count": activeCount
            ]
        } catch {
            return ["status": "error", "message": "记忆序列化失败：\(error.localizedDescription)"]
        }
    }

    private func handleMemoryUpdate(_ json: [String: Any]) async -> [String: Any] {
        guard let memoryIDString = json["memory_id"] as? String,
              let memoryID = UUID(uuidString: memoryIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 memory_id"]
        }

        let memories = await MemoryManager.shared.getAllMemories()
        guard let existing = memories.first(where: { $0.id == memoryID }) else {
            return ["status": "error", "message": "未找到记忆"]
        }

        let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = content != nil
        let hasArchive = json["is_archived"] != nil
        guard hasContent || hasArchive else {
            return ["status": "error", "message": "至少提供 content 或 is_archived 中的一个"]
        }
        if let content, content.isEmpty {
            return ["status": "error", "message": "content 不能为空字符串"]
        }

        if hasContent {
            var updated = existing
            updated.content = content ?? existing.content
            if let isArchived = json["is_archived"] as? Bool {
                updated.isArchived = isArchived
            }
            await MemoryManager.shared.updateMemory(item: updated)
            return [
                "status": "ok",
                "message": "记忆已更新",
                "memory_id": updated.id.uuidString,
                "reembedded": MemoryManager.shared.isEmbeddingModelConfigured()
            ]
        }

        if let isArchived = json["is_archived"] as? Bool {
            if isArchived {
                await MemoryManager.shared.archiveMemory(existing)
            } else {
                await MemoryManager.shared.unarchiveMemory(existing)
            }
            return [
                "status": "ok",
                "message": "记忆归档状态已更新",
                "memory_id": existing.id.uuidString,
                "is_archived": isArchived,
                "reembedded": false
            ]
        }

        return ["status": "error", "message": "无效的更新参数"]
    }

    private func handleMemoryArchive(_ json: [String: Any]) async -> [String: Any] {
        var payload = json
        payload["is_archived"] = true
        return await handleMemoryUpdate(payload)
    }

    private func handleMemoryUnarchive(_ json: [String: Any]) async -> [String: Any] {
        var payload = json
        payload["is_archived"] = false
        return await handleMemoryUpdate(payload)
    }

    private func handleMemoriesReembedAll() async -> [String: Any] {
        do {
            let summary = try await MemoryManager.shared.reembedAllMemories()
            return [
                "status": "ok",
                "message": "记忆重嵌入完成",
                "processed_memories": summary.processedMemories,
                "chunk_count": summary.chunkCount
            ]
        } catch {
            return ["status": "error", "message": "重嵌入失败：\(error.localizedDescription)"]
        }
    }

    private func handleOpenAIQueueList() async -> [String: Any] {
        let queue = pendingOpenAIRequests.map { item in
            [
                "id": item.id.uuidString,
                "model": item.model ?? "",
                "message_count": item.originalMessageCount,
                "received_at": Self.formatWebConsoleDate(item.receivedAt)
            ] as [String: Any]
        }
        return [
            "status": "ok",
            "queue": queue,
            "count": queue.count
        ]
    }

    private func handleOpenAIQueueResolve(_ json: [String: Any]) async -> [String: Any] {
        let shouldSave = (json["save"] as? Bool) ?? true
        let targetID: UUID?
        if let requestID = json["id"] as? String, !requestID.isEmpty {
            targetID = UUID(uuidString: requestID)
            if targetID == nil {
                return ["status": "error", "message": "id 不是合法 UUID"]
            }
        } else {
            targetID = nil
        }

        guard let resolved = resolvePendingOpenAIRequest(targetID: targetID, save: shouldSave) else {
            return ["status": "error", "message": "队列中未找到对应请求"]
        }

        return [
            "status": "ok",
            "message": shouldSave ? "已保存捕获请求" : "已忽略捕获请求",
            "resolved_id": resolved.id.uuidString,
            "remaining": pendingOpenAIRequests.count
        ]
    }
    
    private func handleOpenAICapture(_ json: [String: Any]) async -> [String: Any] {
        guard let requestData = json["request"] as? [String: Any],
              let pending = parseOpenAIChatCompletions(requestData) else {
            return ["status": "error", "message": "无效的 OpenAI 请求"]
        }
        
        let model = pending.model
        
        await MainActor.run {
            self.pendingOpenAIRequests.append(pending)
            self.updatePendingOpenAIState()
        }
        
        logger.info("捕获 OpenAI 请求: \(model ?? "unknown")")
        
        return [
            "status": "ok",
            "message": "已捕获请求，等待用户确认"
        ]
    }
    
    public func resolvePendingOpenAIRequest(save: Bool) {
        _ = resolvePendingOpenAIRequest(targetID: nil, save: save)
    }

    @discardableResult
    private func resolvePendingOpenAIRequest(targetID: UUID?, save: Bool) -> PendingOpenAIRequest? {
        guard !pendingOpenAIRequests.isEmpty else { return nil }

        let targetIndex: Int
        if let targetID {
            guard let index = pendingOpenAIRequests.firstIndex(where: { $0.id == targetID }) else {
                return nil
            }
            targetIndex = index
        } else {
            targetIndex = 0
        }

        let pending = pendingOpenAIRequests.remove(at: targetIndex)
        if save {
            saveCapturedOpenAIRequest(pending)
        }
        updatePendingOpenAIState()
        return pending
    }
}

// MARK: - OpenAI 捕获解析

private extension LocalDebugServer {
    struct PendingOpenAIRequest: Sendable {
        let id: UUID
        let receivedAt: Date
        let model: String?
        let systemPrompt: String?
        let messages: [ChatMessage]
        let originalMessageCount: Int
    }
    
    func parseOpenAIChatCompletions(_ json: [String: Any]) -> PendingOpenAIRequest? {
        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return nil
        }
        
        let model = json["model"] as? String
        var systemParts: [String] = []
        var messages: [ChatMessage] = []
        
        for rawMessage in rawMessages {
            let roleString = (rawMessage["role"] as? String) ?? "user"
            let content = normalizeOpenAIContent(rawMessage["content"])
            
            if roleString == "system" {
                if !content.isEmpty {
                    systemParts.append(content)
                }
                continue
            }
            
            let mappedRole: MessageRole
            switch roleString {
            case "assistant": mappedRole = .assistant
            case "tool", "function": mappedRole = .tool
            default: mappedRole = .user
            }
            
            messages.append(ChatMessage(role: mappedRole, content: content))
        }
        
        return PendingOpenAIRequest(
            id: UUID(),
            receivedAt: Date(),
            model: model,
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            messages: messages,
            originalMessageCount: rawMessages.count
        )
    }
    
    func normalizeOpenAIContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
            var pieces: [String] = []
            for part in parts {
                if let text = part["text"] as? String {
                    pieces.append(text)
                }
            }
            return pieces.joined(separator: "\n")
        }
        return ""
    }
    
    func saveCapturedOpenAIRequest(_ pending: PendingOpenAIRequest) {
        let session = ChatSession(
            id: UUID(),
            name: formatSessionTitle(for: pending.receivedAt),
            topicPrompt: pending.systemPrompt,
            enhancedPrompt: nil,
            isTemporary: false
        )
        
        Persistence.saveMessages(pending.messages, for: session.id)
        var sessions = Persistence.loadChatSessions()
        sessions.insert(session, at: 0)
        Persistence.saveChatSessions(sessions)
        
        Task { @MainActor in
            let chatService = ChatService.shared
            var liveSessions = chatService.chatSessionsSubject.value
            liveSessions.insert(session, at: 0)
            chatService.chatSessionsSubject.send(liveSessions)
        }
    }
    
    func formatSessionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH点mm分ss秒"
        return formatter.string(from: date)
    }
    
    func updatePendingOpenAIState() {
        let summary: OpenAIRequestSummary?
        if let pending = pendingOpenAIRequests.first {
            summary = OpenAIRequestSummary(
                id: pending.id,
                model: pending.model,
                messageCount: pending.originalMessageCount,
                receivedAt: pending.receivedAt
            )
        } else {
            summary = nil
        }
        let count = pendingOpenAIRequests.count
        
        Task { @MainActor in
            self.pendingOpenAIRequest = summary
            self.pendingOpenAIQueueCount = count
        }
    }
}
