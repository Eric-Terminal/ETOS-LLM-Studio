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
        guard !isRunning else { return }

        let parsed = parseDebugAddress(url)
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

        let urlString = "ws://\(host):\(port)/ws"
        guard let wsURL = URL(string: urlString) else {
            self.errorMessage = NSLocalizedString("无效的服务器地址", comment: "")
            self.connectionStatus = NSLocalizedString("连接失败", comment: "")
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
                    self.connectionStatus = NSLocalizedString("已连接", comment: "")
                    self.errorMessage = nil
                    self.wsAutoFallbackEnabled = false
                    self.logger.info("已连接到 \(host):\(port)")
                case .failed(let error):
                    if self.wsAutoFallbackEnabled {
                        self.wsAutoFallbackEnabled = false
                        self.useHTTP = true
                        self.serverURL = "\(host):\(self.wsFallbackPort)"
                        self.connectionStatus = NSLocalizedString("WebSocket 失败，回退到 HTTP 轮询...", comment: "")
                        self.errorMessage = NSLocalizedString("WebSocket 连接失败，已自动切换到 HTTP 轮询", comment: "")
                        self.logger.error("WebSocket 连接失败，准备回退 HTTP: \(error.localizedDescription)")
                        self.performHTTPConnection(host: host, port: self.wsFallbackPort)
                        return
                    }

                    self.isRunning = false
                    self.connectionStatus = NSLocalizedString("连接失败", comment: "")
                    let errorDescription = error.localizedDescription.lowercased()
                    if errorDescription.contains("connection refused") || errorDescription.contains("拒绝") {
                        self.errorMessage = NSLocalizedString("连接被拒绝，请检查服务器是否已启动", comment: "")
                    } else if errorDescription.contains("timed out") || errorDescription.contains("超时") {
                        self.errorMessage = NSLocalizedString("连接超时，请检查 IP 地址和网络", comment: "")
                    } else if errorDescription.contains("unreachable") || errorDescription.contains("不可达") {
                        self.errorMessage = NSLocalizedString("网络不可达，请检查 Wi-Fi 连接和设备是否在同一网络", comment: "")
                    } else {
                        self.errorMessage = String(format: NSLocalizedString("连接失败: %@", comment: ""), error.localizedDescription)
                    }
                    self.logger.error("连接失败: \(error.localizedDescription)")
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
        startReceiving()
    }

    /// 断开连接
    @MainActor
    public func disconnect() {
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
            case "provider_upsert":
                let response = await handleProviderUpsert(json)
                sendResponse(response, requestID: requestID)
            case "provider_model_upsert":
                let response = await handleProviderModelUpsert(json)
                sendResponse(response, requestID: requestID)
            case "app_config_list":
                let response = await handleAppConfigList(json)
                sendResponse(response, requestID: requestID)
            case "app_config_set":
                let response = await handleAppConfigSet(json)
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
            case "list_sqlite_tables":
                let response = await handleSQLiteListTables(json)
                sendResponse(response, requestID: requestID)
            case "query_sqlite":
                let response = await handleSQLiteQuery(json)
                sendResponse(response, requestID: requestID)
            case "mutate_sqlite":
                let response = await handleSQLiteMutate(json)
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
