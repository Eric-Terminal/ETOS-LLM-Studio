// ============================================================================
// LocalDebugServerFileCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 Documents 文件浏览、下载、上传、
// 批量同步和目录管理命令。
// ============================================================================

import Foundation
import os.log

extension LocalDebugServer {
    func runDebugFileOperation(_ operation: @escaping @Sendable (LocalDebugFileAccess) throws -> [String: Any]) async -> [String: Any] {
        let fileRoot = fileRoot
        return await runDebugDataOperation {
            do { return try operation(LocalDebugFileAccess(root: fileRoot())) }
            catch { return ["status": "error", "message": error.localizedDescription] }
        }
    }

    func handleList(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        return await runDebugFileOperation { access in
            ["status": "ok", "path": path, "items": try access.list(path: path)]
        }
    }

    func handleDownload(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        return await runDebugFileOperation { access in
            var payload = try access.download(path: path)
            payload["status"] = "ok"
            return payload
        }
    }

    func handleUpload(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String,
              let base64 = json["data"] as? String else {
            return ["status": "error", "message": "参数错误"]
        }

        return await runDebugFileOperation { access in
            ["status": "ok", "path": path, "size": try access.upload(path: path, base64: base64)]
        }
    }

    func handleDelete(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        return await runDebugFileOperation { access in
            try access.delete(path: path)
            return ["status": "ok", "path": path]
        }
    }

    /// 兼容模式：只返回文件路径列表（不含文件数据）
    /// 用于让 Python 端逐个请求下载。
    func handleListAll() async -> [String: Any] {
        await runDebugFileOperation { access in
            let scan = try access.scan()
            return [
                "status": "ok",
                "paths": scan.paths,
                "total": scan.paths.count,
                "skipped_paths": scan.skippedPaths,
                "message": "文件列表已返回"
            ]
        }
    }

    func handleDownloadAll() async -> [String: Any] {
        await runDebugFileOperation { access in
            let scan = try access.scan()
            let files = try scan.paths.map { try access.download(path: $0) }
            return [
                "status": "ok",
                "files": files,
                "skipped_paths": scan.skippedPaths,
                "message": "已扫描完成"
            ]
        }
    }

    /// HTTP 流式下载逐项等待发送；连接失效后不再读取下一项。
    func handleDownloadAllStream() async {
        guard canContinueDebugCommand else { return }
        let token = connectionToken

        guard httpSession != nil else {
            logger.error("httpSession 为 nil，无法执行流式下载")
            return
        }

        isTransferring = true
        addLog(NSLocalizedString("Streaming download started; polling paused.", comment: "调试流式下载日志"), type: .info)

        defer {
            if isCurrentConnection(token) {
                isTransferring = false
                addLog(NSLocalizedString("Streaming download ended; polling resumed.", comment: "调试流式下载日志"), type: .info)
            }
        }

        let scan = await handleListAll()
        guard canContinueDebugCommand else { return }
        guard scan["status"] as? String == "ok", let paths = scan["paths"] as? [String] else {
            await sendHTTPResponseAsync(scan)
            return
        }
        var successCount = 0, failCount = 0
        for (index, path) in paths.enumerated() {
            guard canContinueDebugCommand else { return }
            var response = await handleDownload(["path": path])
            guard canContinueDebugCommand else { return }
            guard response["status"] as? String == "ok" else {
                failCount += 1
                logger.error("读取文件失败: \(path)")
                continue
            }
            response["index"] = index + 1
            response["total"] = paths.count
            await sendHTTPResponseAsync(response)
            guard canContinueDebugCommand else { return }
            successCount += 1
        }
        await sendHTTPResponseAsync([
            "status": "ok", "message": "流式下载完成", "total": paths.count,
            "success_count": successCount, "fail_count": failCount, "stream_complete": true,
            "skipped_paths": scan["skipped_paths"] as? [String] ?? []
        ])
    }

    func handleUploadAll(_ json: [String: Any]) async -> [String: Any] {
        if let files = json["files"] as? [[String: Any]] {
            return await handleBatchUpload(files: files)
        } else {
            return ["status": "error", "message": "无效的上传参数"]
        }
    }

    /// HTTP 流式上传：接收文件列表，连续请求所有文件
    func handleUploadList(_ json: [String: Any]) async {
        guard canContinueDebugCommand else { return }
        let token = connectionToken
        guard let paths = json["paths"] as? [String],
              let total = json["total"] as? Int else {
            logger.error("无效的文件列表")
            return
        }

        isTransferring = true
        addLog(NSLocalizedString("Streaming upload started; polling paused.", comment: "调试流式上传日志"), type: .info)

        defer {
            if isCurrentConnection(token) {
                isTransferring = false
                addLog(NSLocalizedString("Streaming upload ended; polling resumed.", comment: "调试流式上传日志"), type: .info)
            }
        }

        logger.info("收到文件列表: \(total) 个文件")

        var replacement: LocalDebugDocumentReplacement?
        do {
            guard total == paths.count else { throw LocalDebugDocumentReplacementError.incompleteUpload }
            let staged = try await prepareDebugUpload(paths: paths)
            replacement = staged
            for (index, path) in paths.enumerated() {
                try await fetchAndStageFile(path: path, into: staged, index: index + 1, total: total)
            }
            try await commitDebugUpload(staged)
            if canContinueDebugCommand { logger.info("所有文件上传完成！") }
        } catch {
            await sendHTTPResponseAsync(["status": "error", "message": error.localizedDescription])
        }
        if let replacement { await discardDebugUpload(replacement) }
    }

    /// 请求返回后只写入暂存区；所有文件齐全之前不触碰原 Documents。
    func fetchAndStageFile(path: String, into replacement: LocalDebugDocumentReplacement, index: Int, total: Int) async throws {
        guard canContinueDebugCommand else { throw CancellationError() }
        let token = connectionToken
        let data = try await fetchDebugFilePayload(path: path)
        guard canContinueDebugCommand, isCurrentConnection(token) else { throw CancellationError() }
        let worker = Task.detached(priority: .userInitiated) {
            guard let json = try LocalDebugJSONObject.decode(data)?.value,
                  json["status"] as? String == "ok", let base64 = json["data"] as? String else {
                throw URLError(.badServerResponse)
            }
            try replacement.receive(path: path, base64: base64)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard canContinueDebugCommand, isCurrentConnection(token) else { throw CancellationError() }
        logger.info("[\(index)/\(total)] 已暂存: \(path)")
    }

    private func fetchDebugFilePayload(path: String) async throws -> Data {
        if let fetchFilePayload { return try await fetchFilePayload(path) }
        guard let url = URL(string: "http://\(serverURL)/fetch_file"), let session = httpSession else {
            throw URLError(.badURL)
        }
        let token = connectionToken
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let requestBody = LocalDebugJSONObject(value: ["path": path])
        request.httpBody = try await Task.detached(priority: .userInitiated) { try requestBody.encoded() }.value
        guard canContinueDebugCommand, isCurrentConnection(token) else { throw CancellationError() }
        let (data, response) = try await session.securedData(for: request)
        guard canContinueDebugCommand, isCurrentConnection(token) else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// HTTP 流式上传：接收单个文件（旧方法，保留兼容）
    func handleUploadFile(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String,
              let b64Data = json["data"] as? String else {
            return ["status": "error", "message": "文件数据缺失"]
        }

        return await runDebugFileOperation { access in
            try access.upload(path: path, base64: b64Data)
            return [
                "status": "ok",
                "message": "文件已写入",
                "path": path
            ]
        }
    }

    /// 清空 Documents 目录
    func handleClearDocuments() async -> [String: Any] {
        do {
            let replacement = try await prepareDebugUpload(paths: [])
            try await commitDebugUpload(replacement)
            return ["status": "ok", "message": "目录已清空"]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    /// 批量上传（WebSocket 模式）
    func handleBatchUpload(files: [[String: Any]]) async -> [String: Any] {
        do {
            let replacement = try await prepareDebugBatch(LocalDebugJSONObject(value: ["files": files]))
            try await commitDebugUpload(replacement)
            return ["status": "ok", "message": "已覆盖 Documents 目录，共 \(files.count) 个文件"]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    func handleMkdir(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        return await runDebugFileOperation { access in
            try access.makeDirectory(path: path)
            return ["status": "ok", "path": path]
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
}
