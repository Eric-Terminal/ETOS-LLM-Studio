import Foundation
import Network

extension LocalDebugServer {
    func executeDebugCommand(_ command: String, json: [String: Any]) async -> [String: Any]? {
        switch command {
        case "list": return await handleList(json)
        case "download": return await handleDownload(json)
        case "download_all":
            if useHTTP { await handleDownloadAllStream(); return nil }
            return await handleDownloadAll()
        case "list_all": return await handleListAll()
        case "upload": return await handleUpload(json)
        case "upload_all": return await handleUploadAll(json)
        case "clear_documents": return await handleClearDocuments()
        case "upload_list": await handleUploadList(json); return nil
        case "upload_file": return await handleUploadFile(json)
        case "upload_complete": return ["status": "ok", "message": "上传完成"]
        case "delete": return await handleDelete(json)
        case "mkdir": return await handleMkdir(json)
        case "openai_capture": return await handleOpenAICapture(json)
        case "providers_list": return await handleProvidersList()
        case "providers_save": return await handleProvidersSave(json)
        case "provider_upsert": return await handleProviderUpsert(json)
        case "provider_model_upsert": return await handleProviderModelUpsert(json)
        case "app_config_list": return await handleAppConfigList(json)
        case "app_config_set": return await handleAppConfigSet(json)
        case "sessions_list": return await handleSessionsList()
        case "session_get": return await handleSessionGet(json)
        case "session_create": return await handleSessionCreate(json)
        case "session_delete": return await handleSessionDelete(json)
        case "session_update_meta": return await handleSessionUpdateMeta(json)
        case "session_update_messages": return await handleSessionUpdateMessages(json)
        case "memories_list": return await handleMemoriesList()
        case "memory_update": return await handleMemoryUpdate(json)
        case "memory_archive": return await handleMemoryArchive(json)
        case "memory_unarchive": return await handleMemoryUnarchive(json)
        case "memories_reembed_all": return await handleMemoriesReembedAll()
        case "list_sqlite_tables": return await handleSQLiteListTables(json)
        case "query_sqlite": return await handleSQLiteQuery(json)
        case "mutate_sqlite": return await handleSQLiteMutate(json)
        case "openai_queue_list": return await handleOpenAIQueueList()
        case "openai_queue_resolve": return await handleOpenAIQueueResolve(json)
        case "ping": return ["status": "ok", "message": "pong"]
        default: return ["status": "error", "message": "未知命令"]
        }
    }

    /// TaskLocal 固定命令的来源连接；后续重连不会接收旧命令的响应或传输状态。
    var canContinueDebugCommand: Bool {
        guard !Task.isCancelled else { return false }
        guard let token = LocalDebugCommandContext.connectionToken else { return true }
        return isCurrentConnection(token)
    }

    func sendResponse(_ response: [String: Any], requestID: String? = nil, streaming: Bool = false) async {
        guard canContinueDebugCommand else { return }
        let token = connectionToken, isHTTP = useHTTP, session = httpSession, connection = wsConnection
        let address = serverURL
        var payload = response
        if let requestID, !requestID.isEmpty { payload["request_id"] = requestID }
        let envelope = LocalDebugJSONObject(value: payload)
        let worker = Task.detached(priority: .userInitiated) { try? envelope.encoded() }
        let data = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard canContinueDebugCommand, isCurrentConnection(token), let data else { return }

        if isHTTP {
            guard let session, let url = URL(string: "http://\(address)/response") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if streaming { request.setValue("close", forHTTPHeaderField: "Connection") }
            request.timeoutInterval = streaming ? 60 : 30
            request.httpBody = data
            do {
                let (_, result) = try await session.securedData(for: request)
                guard canContinueDebugCommand, isCurrentConnection(token) else { return }
                if let result = result as? HTTPURLResponse, result.statusCode != 200 {
                    addLog(String(format: NSLocalizedString("Debug server returned HTTP %d.", comment: "调试响应状态日志"), result.statusCode), type: .error)
                } else {
                    addLog(String(format: NSLocalizedString("Debug response sent (%@)", comment: "调试响应发送日志"), formatSize(data.count)), type: .send)
                }
            } catch {
                guard canContinueDebugCommand, isCurrentConnection(token) else { return }
                addLog(String(format: NSLocalizedString("Debug response failed: %@", comment: "调试响应失败日志"), error.localizedDescription), type: .error)
            }
        } else if let connection {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "response", metadata: [metadata])
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }
    }
}
