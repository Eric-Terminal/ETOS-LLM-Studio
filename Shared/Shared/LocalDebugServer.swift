// ============================================================================
// LocalDebugServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件提供局域网HTTP调试服务器,允许通过命令行工具远程操作沙盒Documents目录。
// 功能包括:文件浏览、下载、上传,并通过6位PIN码进行身份验证。
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

/// 局域网调试服务器
public class LocalDebugServer: ObservableObject {
    public struct OpenAIRequestSummary: Identifiable, Hashable {
        public let id: UUID
        public let model: String?
        public let messageCount: Int
        public let receivedAt: Date
    }

    @Published public var isRunning = false
    @Published public var localIP: String = "未知"
    @Published public var pin: String = ""
    @Published public var errorMessage: String?
    @Published public var pendingOpenAIRequest: OpenAIRequestSummary?
    @Published public var pendingOpenAIQueueCount: Int = 0
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    private var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    
    public init() {}
    
    /// 启动服务器
    @MainActor
    public func start(port: UInt16 = 8080) {
        guard !isRunning else { return }
        
        do {
            // 生成随机6位PIN
            pin = String(format: "%06d", Int.random(in: 0...999999))
            
            // 创建监听器
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        Task.detached {
                            let ipAddress = await self.getLocalIPAddress()
                            await MainActor.run {
                                self.localIP = ipAddress
                            }
                        }
                        self.errorMessage = nil
                    case .failed(let error):
                        self.isRunning = false
                        self.errorMessage = "服务器失败: \(error.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: queue)
            
        } catch {
            errorMessage = "启动失败: \(error.localizedDescription)"
        }
    }
    
    /// 停止服务器
    @MainActor
    public func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        pin = ""
        pendingOpenAIRequests.removeAll()
        updatePendingOpenAIState()
    }
    
    // MARK: - 连接处理
    
    private func handleConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            connection.stateUpdateHandler = { state in
                if case .cancelled = state {
                    // 使用同步方式更新连接列表
                    self.queue.async {
                        self.connections.removeAll { $0 === connection }
                    }
                }
            }
            
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection)
        }
    }
    
    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 52428800) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            
            if let request = String(data: data, encoding: .utf8) {
                self.processHTTPRequest(request, on: connection)
            }
            
            if !isComplete {
                self.receiveRequest(on: connection)
            }
        }
    }
    
    // MARK: - HTTP 请求处理
    
    private func processHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(statusCode: 400, body: "Bad Request", on: connection)
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            sendResponse(statusCode: 400, body: "Bad Request", on: connection)
            return
        }
        
        let method = components[0]
        let rawPath = components[1]
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        
        // 提取PIN码
        var receivedPIN: String?
        var bodyData: Data?
        
        // 解析Headers和Body
        if let bodyStart = request.range(of: "\r\n\r\n") {
            let headersString = String(request[..<bodyStart.lowerBound])
            let bodyString = String(request[bodyStart.upperBound...])
            bodyData = bodyString.data(using: .utf8)
            
            // 从headers中查找PIN
            for line in headersString.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("x-debug-pin:") {
                    receivedPIN = line.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        
        let shouldRequirePIN: Bool = {
            if method == "GET" && path == "/" {
                return false
            }
            if method == "POST" && path == "/v1/chat/completions" {
                return false
            }
            return true
        }()
        
        // 验证PIN
        if shouldRequirePIN {
            guard receivedPIN == pin else {
                sendResponse(statusCode: 401, body: "Unauthorized: Invalid PIN", on: connection)
                return
            }
        }
        
        // 路由处理
        handleRoute(method: method, path: path, body: bodyData, on: connection)
    }
    
    private func handleRoute(method: String, path: String, body: Data?, on connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/"):
            handleRoot(on: connection)
        case ("GET", "/api/openai/pending"):
            handleOpenAIPending(on: connection)
        case ("GET", "/api/list"):
            handleList(body: body, on: connection)
        case ("GET", "/api/download"):
            handleDownload(body: body, on: connection)
        case ("POST", "/api/upload"):
            handleUpload(body: body, on: connection)
        case ("POST", "/api/delete"):
            handleDelete(body: body, on: connection)
        case ("POST", "/api/mkdir"):
            handleMkdir(body: body, on: connection)
        case ("POST", "/api/openai/confirm"):
            handleOpenAIConfirm(body: body, on: connection)
        case ("POST", "/v1/chat/completions"):
            handleOpenAIChatCompletions(body: body, on: connection)
        default:
            sendResponse(statusCode: 404, body: "Not Found", on: connection)
        }
    }
    
    // MARK: - API 端点实现
    
    private func handleRoot(on connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><title>ETOS LLM Studio 调试服务器</title></head>
        <body>
        <h1>ETOS LLM Studio 局域网调试</h1>
        <p>服务器运行中</p>
        <p>PIN: \(pin)</p>
        <h2>OpenAI 兼容捕获</h2>
        <div id="capture-status">暂无待处理的 OpenAI 请求。</div>
        <div id="capture-actions" style="display:none;">
          <p id="capture-summary"></p>
          <button onclick="confirmCapture(true)">保存到本地</button>
          <button onclick="confirmCapture(false)">忽略</button>
        </div>
        <h2>API 端点:</h2>
        <ul>
        <li>POST /v1/chat/completions - OpenAI 兼容请求 (免 PIN)</li>
        <li>GET /api/list - 列出目录内容</li>
        <li>GET /api/download - 下载文件</li>
        <li>POST /api/upload - 上传文件</li>
        <li>POST /api/delete - 删除文件/目录</li>
        <li>POST /api/mkdir - 创建目录</li>
        </ul>
        <p>除 OpenAI 兼容请求外，所有请求需要在 Header 中包含: <code>X-Debug-PIN: \(pin)</code></p>
        <script>
        const pin = "\(pin)";
        let pendingId = null;
        async function pollPending() {
          try {
            const res = await fetch("/api/openai/pending", { headers: { "X-Debug-PIN": pin } });
            if (!res.ok) return setTimeout(pollPending, 2000);
            const data = await res.json();
            const status = document.getElementById("capture-status");
            const actions = document.getElementById("capture-actions");
            const summary = document.getElementById("capture-summary");
            if (data.pending && data.request) {
              pendingId = data.request.id;
              const when = new Date(data.request.receivedAt * 1000).toLocaleString();
              summary.textContent = `收到请求：模型 ${data.request.model || "未知"}，消息数 ${data.request.messageCount}，时间 ${when}`;
              actions.style.display = "block";
              status.textContent = `待处理请求 ${data.queueSize} 条`;
            } else {
              pendingId = null;
              actions.style.display = "none";
              status.textContent = "暂无待处理的 OpenAI 请求。";
            }
          } catch {
            // 忽略轮询错误
          }
          setTimeout(pollPending, 2000);
        }
        async function confirmCapture(save) {
          if (!pendingId) return;
          await fetch("/api/openai/confirm", {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Debug-PIN": pin },
            body: JSON.stringify({ id: pendingId, save: save })
          });
          pendingId = null;
          pollPending();
        }
        pollPending();
        </script>
        </body>
        </html>
        """
        sendResponse(statusCode: 200, body: html, contentType: "text/html; charset=utf-8", on: connection)
    }
    
    private func handleList(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String else {
            sendJSONError("Missing or invalid 'path' parameter", on: connection)
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(relativePath)
        
        // 安全检查:确保路径在Documents目录内
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            sendJSONError("Invalid path: outside Documents directory", statusCode: 403, on: connection)
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: targetURL.path)
            var items: [[String: Any]] = []
            
            for item in contents {
                let itemURL = targetURL.appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)
                
                var attributes: [FileAttributeKey: Any] = [:]
                attributes = try FileManager.default.attributesOfItem(atPath: itemURL.path)
                
                items.append([
                    "name": item,
                    "isDirectory": isDirectory.boolValue,
                    "size": attributes[.size] as? Int64 ?? 0,
                    "modificationDate": (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                ])
            }
            
            let response: [String: Any] = [
                "success": true,
                "path": relativePath,
                "items": items
            ]
            
            sendJSONResponse(response, on: connection)
            
        } catch {
            sendJSONError("Failed to list directory: \(error.localizedDescription)", on: connection)
        }
    }
    
    private func handleDownload(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String else {
            sendJSONError("Missing or invalid 'path' parameter", on: connection)
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(relativePath)
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            sendJSONError("Invalid path: outside Documents directory", statusCode: 403, on: connection)
            return
        }
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            sendJSONError("File not found", statusCode: 404, on: connection)
            return
        }
        
        do {
            let fileData = try Data(contentsOf: targetURL)
            let base64 = fileData.base64EncodedString()
            
            let response: [String: Any] = [
                "success": true,
                "path": relativePath,
                "data": base64,
                "size": fileData.count
            ]
            
            sendJSONResponse(response, on: connection)
            
        } catch {
            sendJSONError("Failed to read file: \(error.localizedDescription)", on: connection)
        }
    }
    
    private func handleUpload(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String,
              let base64Data = json["data"] as? String,
              let fileData = Data(base64Encoded: base64Data) else {
            sendJSONError("Missing or invalid parameters (path, data)", on: connection)
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(relativePath)
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            sendJSONError("Invalid path: outside Documents directory", statusCode: 403, on: connection)
            return
        }
        
        do {
            // 创建父目录
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try fileData.write(to: targetURL)
            
            let response: [String: Any] = [
                "success": true,
                "path": relativePath,
                "size": fileData.count
            ]
            
            sendJSONResponse(response, on: connection)
            
        } catch {
            sendJSONError("Failed to write file: \(error.localizedDescription)", on: connection)
        }
    }
    
    private func handleDelete(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String else {
            sendJSONError("Missing or invalid 'path' parameter", on: connection)
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(relativePath)
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            sendJSONError("Invalid path: outside Documents directory", statusCode: 403, on: connection)
            return
        }
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            sendJSONError("File not found", statusCode: 404, on: connection)
            return
        }
        
        do {
            try FileManager.default.removeItem(at: targetURL)
            
            let response: [String: Any] = [
                "success": true,
                "path": relativePath
            ]
            
            sendJSONResponse(response, on: connection)
            
        } catch {
            sendJSONError("Failed to delete: \(error.localizedDescription)", on: connection)
        }
    }
    
    private func handleMkdir(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String else {
            sendJSONError("Missing or invalid 'path' parameter", on: connection)
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let targetURL = documentsURL.appendingPathComponent(relativePath)
        
        guard targetURL.path.hasPrefix(documentsURL.path) else {
            sendJSONError("Invalid path: outside Documents directory", statusCode: 403, on: connection)
            return
        }
        
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            
            let response: [String: Any] = [
                "success": true,
                "path": relativePath
            ]
            
            sendJSONResponse(response, on: connection)
            
        } catch {
            sendJSONError("Failed to create directory: \(error.localizedDescription)", on: connection)
        }
    }
    
    private func handleOpenAIChatCompletions(body: Data?, on connection: NWConnection) {
        guard let body = body else {
            sendJSONError("Missing request body", on: connection)
            return
        }
        guard let pending = parseOpenAIChatCompletions(body: body) else {
            sendJSONError("Invalid OpenAI request body", on: connection)
            return
        }
        pendingOpenAIRequests.append(pending)
        updatePendingOpenAIState()
        logger.info("📥 捕获 OpenAI 请求: \(pending.id.uuidString, privacy: .public)")
        sendOpenAIStubResponse(model: pending.model, on: connection)
    }
    
    private func handleOpenAIPending(on connection: NWConnection) {
        if let pending = pendingOpenAIRequests.first {
            let response: [String: Any] = [
                "pending": true,
                "queueSize": pendingOpenAIRequests.count,
                "request": [
                    "id": pending.id.uuidString,
                    "model": pending.model ?? "",
                    "messageCount": pending.originalMessageCount,
                    "receivedAt": pending.receivedAt.timeIntervalSince1970
                ]
            ]
            sendJSONResponse(response, on: connection)
        } else {
            let response: [String: Any] = [
                "pending": false,
                "queueSize": 0
            ]
            sendJSONResponse(response, on: connection)
        }
    }
    
    private func handleOpenAIConfirm(body: Data?, on connection: NWConnection) {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let idString = json["id"] as? String,
              let requestID = UUID(uuidString: idString),
              let save = json["save"] as? Bool else {
            sendJSONError("Missing or invalid parameters (id, save)", on: connection)
            return
        }
        
        guard let index = pendingOpenAIRequests.firstIndex(where: { $0.id == requestID }) else {
            sendJSONError("Pending request not found", statusCode: 404, on: connection)
            return
        }
        
        let pending = pendingOpenAIRequests.remove(at: index)
        if save {
            saveCapturedOpenAIRequest(pending)
        }
        updatePendingOpenAIState()
        let response: [String: Any] = [
            "success": true,
            "saved": save
        ]
        sendJSONResponse(response, on: connection)
    }

    public func resolvePendingOpenAIRequest(save: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.pendingOpenAIRequests.isEmpty else { return }
            let pending = self.pendingOpenAIRequests.removeFirst()
            if save {
                self.saveCapturedOpenAIRequest(pending)
            }
            self.updatePendingOpenAIState()
        }
    }
    
    // MARK: - 响应助手
    
    private func sendJSONResponse(_ object: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
              let jsonString = String(data: data, encoding: .utf8) else {
            sendJSONError("Failed to serialize response", on: connection)
            return
        }
        sendResponse(statusCode: 200, body: jsonString, contentType: "application/json", on: connection)
    }
    
    private func sendJSONError(_ message: String, statusCode: Int = 400, on connection: NWConnection) {
        let error: [String: Any] = [
            "success": false,
            "error": message
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: error),
              let jsonString = String(data: data, encoding: .utf8) else {
            sendResponse(statusCode: statusCode, body: message, on: connection)
            return
        }
        sendResponse(statusCode: statusCode, body: jsonString, contentType: "application/json", on: connection)
    }
    
    private func sendOpenAIStubResponse(model: String?, on connection: NWConnection) {
        let response: [String: Any] = [
            "id": "local-debug-capture",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model ?? "unknown",
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": ""
                    ],
                    "finish_reason": "stop"
                ]
            ],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let jsonString = String(data: data, encoding: .utf8) else {
            sendResponse(statusCode: 200, body: "{}", contentType: "application/json", on: connection)
            return
        }
        sendResponse(statusCode: 200, body: jsonString, contentType: "application/json", on: connection)
    }
    
    private func sendResponse(statusCode: Int, body: String, contentType: String = "text/plain", on connection: NWConnection) {
        let statusText: String = {
            switch statusCode {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 500: return "Internal Server Error"
            default: return "Unknown"
            }
        }()
        
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        \(body)
        """
        
        guard let responseData = response.data(using: .utf8) else { return }
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    // MARK: - 网络助手
    
    private func getLocalIPAddress() async -> String {
        var address: String = "未知"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return address
        }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" || name.hasPrefix("wlan") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                              socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname,
                              socklen_t(hostname.count),
                              nil,
                              socklen_t(0),
                              NI_NUMERICHOST)
                    address = String(cString: hostname)
                    if addrFamily == UInt8(AF_INET) {
                        break
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return address
    }
}

// MARK: - OpenAI 捕获解析

private extension LocalDebugServer {
    struct PendingOpenAIRequest {
        let id: UUID
        let receivedAt: Date
        let model: String?
        let systemPrompt: String?
        let messages: [ChatMessage]
        let originalMessageCount: Int
    }
    
    func parseOpenAIChatCompletions(body: Data) -> PendingOpenAIRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawMessages = json["messages"] as? [[String: Any]] else {
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
            case "assistant":
                mappedRole = .assistant
            case "tool", "function":
                mappedRole = .tool
            case "user":
                mappedRole = .user
            default:
                mappedRole = .user
            }
            messages.append(ChatMessage(role: mappedRole, content: content))
        }
        
        let systemPrompt = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return PendingOpenAIRequest(
            id: UUID(),
            receivedAt: Date(),
            model: model,
            systemPrompt: systemPrompt,
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
                    continue
                }
                let type = (part["type"] as? String) ?? ""
                if type == "text" || type == "input_text", let text = part["text"] as? String {
                    pieces.append(text)
                } else if type == "image_url",
                          let image = part["image_url"] as? [String: Any],
                          let url = image["url"] as? String {
                    pieces.append("[image: \(url)]")
                } else if type == "input_image",
                          let url = part["image_url"] as? String {
                    pieces.append("[image: \(url)]")
                } else if let value = part["value"] as? String {
                    pieces.append(value)
                }
            }
            return pieces.joined(separator: "\n")
        }
        if let dict = content as? [String: Any] {
            if let text = dict["text"] as? String {
                return text
            }
            if let value = dict["value"] as? String {
                return value
            }
            if let url = dict["url"] as? String {
                return url
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
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
        
        let chatService = ChatService.shared
        Task { @MainActor in
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
