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
public class LocalDebugServer: ObservableObject {
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
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    private var wsConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    private var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    private var permissionProbeConnection: NWConnection?
    
    public init() {}
    
    // MARK: - 连接管理
    
    /// 触发本地网络权限请求
    /// 只在真机上执行，模拟器会直接跳过（避免"Network is down"错误）
    private func triggerLocalNetworkPermission(host: String, completion: @escaping () -> Void) {
        // 检测是否是模拟器
        #if targetEnvironment(simulator)
        logger.info("📱 检测到模拟器环境，跳过权限检查")
        completion()
        return
        #else
        logger.info("🔐 真机环境：触发本地网络权限请求...")
        
        // 创建一个临时的TCP连接来触发权限弹窗
        // 即使连接失败，也能让系统弹出权限请求
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 1)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = nil
        params.prohibitedInterfaceTypes = [.cellular, .loopback]
        
        let probeConnection = NWConnection(to: endpoint, using: params)
        self.permissionProbeConnection = probeConnection
        
        var hasCompleted = false
        
        probeConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !hasCompleted else { return }
            
            switch state {
            case .ready, .failed:
                // 无论成功还是失败，都说明权限检查已完成
                hasCompleted = true
                self.logger.info("✅ 本地网络权限检查完成")
                probeConnection.cancel()
                self.permissionProbeConnection = nil
                // 给系统一点时间处理权限状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    completion()
                }
            case .waiting:
                // 等待中，可能是权限弹窗正在显示
                self.logger.info("⏳ 等待权限授予...")
            default:
                break
            }
        }
        
        probeConnection.start(queue: queue)
        
        // 设置超时：如果5秒内没有响应，继续执行
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, !hasCompleted else { return }
            hasCompleted = true
            self.logger.warning("⚠️ 权限检查超时，继续尝试连接")
            probeConnection.cancel()
            self.permissionProbeConnection = nil
            completion()
        }
        #endif
    }
    
    /// 连接到电脑端服务器
    /// - Parameter url: 服务器地址，格式: "192.168.1.100:8765" 或 "192.168.1.100" (默认端口8765)
    @MainActor
    public func connect(to url: String) {
        guard !isRunning else { return }
        
        // 解析URL
        let components = url.split(separator: ":").map(String.init)
        let host = components.first ?? url
        let port = components.count > 1 ? components[1] : "8765"
        
        serverURL = "\(host):\(port)"
        connectionStatus = "正在请求权限..."
        
        // 先触发权限请求（仅watchOS）
        triggerLocalNetworkPermission(host: host) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.performConnection(host: host, port: port)
            }
        }
    }
    
    /// 执行实际的WebSocket连接
    @MainActor
    private func performConnection(host: String, port: String) {
        logger.info("🔌 开始建立WebSocket连接到 \(host):\(port)")
        
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
                    self.logger.info("✅ 已连接到 \(host):\(port)")
                case .failed(let error):
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
                    self.logger.error("❌ 连接失败: \(error.localizedDescription)")
                case .cancelled:
                    self.isRunning = false
                    self.connectionStatus = "未连接"
                    self.errorMessage = nil
                case .waiting(let error):
                    self.connectionStatus = "等待连接..."
                    self.logger.info("⏳ 等待连接: \(error.localizedDescription)")
                case .preparing:
                    self.connectionStatus = "准备中..."
                case .setup:
                    self.connectionStatus = "设置中..."
                @unknown default:
                    self.logger.warning("⚠️ 未知连接状态")
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
        wsConnection?.cancel()
        wsConnection = nil
        isRunning = false
        connectionStatus = "未连接"
        pendingOpenAIRequests.removeAll()
        updatePendingOpenAIState()
    }
    
    // MARK: - 消息收发
    
    private func startReceiving() {
        guard let connection = wsConnection else { return }
        
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("❌ 接收错误: \(error.localizedDescription)")
                Task { @MainActor in
                    self.disconnect()
                }
                return
            }
            
            if let data = data {
                self.handleReceivedMessage(data)
            }
            
            if isComplete {
                self.startReceiving()
            }
        }
    }
    
    private func handleReceivedMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            return
        }
        
        logger.info("📨 收到命令: \(command)")
        
        Task {
            let response: [String: Any]
            
            switch command {
            case "list":
                response = await handleList(json)
            case "download":
                response = await handleDownload(json)
            case "download_all":
                response = await handleDownloadAll()
            case "upload":
                response = await handleUpload(json)
            case "upload_all":
                response = await handleUploadAll(json)
            case "delete":
                response = await handleDelete(json)
            case "mkdir":
                response = await handleMkdir(json)
            case "openai_capture":
                response = await handleOpenAICapture(json)
            case "ping":
                response = ["status": "ok", "message": "pong"]
            default:
                response = ["status": "error", "message": "未知命令"]
            }
            
            sendResponse(response)
        }
    }
    
    private func sendResponse(_ response: [String: Any]) {
        guard let connection = wsConnection,
              let data = try? JSONSerialization.data(withJSONObject: response) else {
            return
        }
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
        
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
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
    
    private func handleDownloadAll() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            logger.info("📦 开始扫描 Documents 目录...")
            var fileList: [[String: Any]] = []
            
            // 递归扫描所有文件
            try scanDirectory(documentsURL, baseURL: documentsURL, fileList: &fileList)
            
            logger.info("✅ 扫描完成: \(fileList.count) 个文件")
            
            return [
                "status": "ok",
                "files": fileList,
                "message": "已扫描完成"
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
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
        guard let files = json["files"] as? [[String: Any]] else {
            return ["status": "error", "message": "缺少文件列表"]
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            // 清空 Documents 目录
            logger.info("🗑️ 清空 Documents 目录...")
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in contents {
                try fileManager.removeItem(at: item)
            }
            
            // 递归创建文件
            logger.info("📤 开始上传 \(files.count) 个文件...")
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
            
            logger.info("✅ 上传完成")
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
        
        logger.info("📥 捕获 OpenAI 请求: \(model ?? "unknown")")
        
        return [
            "status": "ok",
            "message": "已捕获请求，等待用户确认"
        ]
    }
    
    public func resolvePendingOpenAIRequest(save: Bool) {
        queue.async { [weak self] in
            guard let self = self, !self.pendingOpenAIRequests.isEmpty else { return }
            let pending = self.pendingOpenAIRequests.removeFirst()
            if save {
                self.saveCapturedOpenAIRequest(pending)
            }
            self.updatePendingOpenAIState()
        }
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
