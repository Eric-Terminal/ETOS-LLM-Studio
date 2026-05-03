// ============================================================================
// LocalDebugServerFileCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 Documents 文件浏览、下载、上传、
// 批量同步和目录管理命令。
// ============================================================================

import Foundation

extension LocalDebugServer {
    func handleList(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

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

    func handleDownload(_ json: [String: Any]) async -> [String: Any] {
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

    func handleUpload(_ json: [String: Any]) async -> [String: Any] {
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

    func handleDelete(_ json: [String: Any]) async -> [String: Any] {
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
    /// 用于让 Python 端逐个请求下载。
    func handleListAll() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            logger.info("开始扫描 Documents 目录（仅路径）...")
            var filePaths: [String] = []

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

    func handleDownloadAll() async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            logger.info("开始扫描 Documents 目录...")
            var fileList: [[String: Any]] = []

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
    func handleDownloadAllStream() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        guard httpSession != nil else {
            logger.error("httpSession 为 nil，无法执行流式下载")
            return
        }

        isTransferring = true
        addLog("开始流式下载（暂停轮询）", type: .info)

        defer {
            Task { @MainActor in
                self.isTransferring = false
                self.addLog("流式下载结束（恢复轮询）", type: .info)
            }
        }

        do {
            logger.info("开始流式下载 Documents 目录...")

            var filePaths: [String] = []
            try collectFilePaths(documentsURL, baseURL: documentsURL, filePaths: &filePaths)

            logger.info("发现 \(filePaths.count) 个文件，开始连续传输")

            var successCount = 0
            var failCount = 0

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

                    await sendHTTPResponseAsync(response)
                    successCount += 1

                    if (index + 1) % 10 == 0 || index + 1 == filePaths.count {
                        logger.info("进度: \(index + 1)/\(filePaths.count) (成功: \(successCount), 失败: \(failCount))")
                    }

                } catch {
                    failCount += 1
                    logger.error("读取文件失败: \(relativePath) - \(error.localizedDescription)")
                }
            }

            logger.info("传输统计: 成功 \(successCount), 失败 \(failCount), 总计 \(filePaths.count)")

            try? await Task.sleep(nanoseconds: 500_000_000)

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
    func collectFilePaths(_ dirURL: URL, baseURL: URL, filePaths: inout [String]) throws {
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

    func scanDirectory(_ dirURL: URL, baseURL: URL, fileList: inout [[String: Any]]) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey])

        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])

            if resourceValues.isDirectory == true {
                try scanDirectory(item, baseURL: baseURL, fileList: &fileList)
            } else {
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

    func handleUploadAll(_ json: [String: Any]) async -> [String: Any] {
        if let files = json["files"] as? [[String: Any]] {
            return await handleBatchUpload(files: files)
        } else {
            return ["status": "error", "message": "无效的上传参数"]
        }
    }

    /// HTTP 流式上传：接收文件列表，连续请求所有文件
    func handleUploadList(_ json: [String: Any]) async {
        guard let paths = json["paths"] as? [String],
              let total = json["total"] as? Int else {
            logger.error("无效的文件列表")
            return
        }

        isTransferring = true
        addLog("开始流式上传（暂停轮询）", type: .info)

        defer {
            Task { @MainActor in
                self.isTransferring = false
                self.addLog("流式上传结束（恢复轮询）", type: .info)
            }
        }

        logger.info("收到文件列表: \(total) 个文件")

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

        for (index, path) in paths.enumerated() {
            await fetchAndWriteFile(path: path, index: index + 1, total: total)
        }

        logger.info("所有文件上传完成！")
    }

    /// 请求并写入单个文件
    func fetchAndWriteFile(path: String, index: Int, total: Int) async {
        let components = serverURL.split(separator: ":").map(String.init)
        let host = components.first ?? ""
        let port = components.count > 1 ? components[1] : "7654"

        guard let url = URL(string: "http://\(host):\(port)/fetch_file") else {
            logger.error("无效的URL")
            return
        }

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
    func handleUploadFile(_ json: [String: Any]) async -> [String: Any] {
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

    /// 清空 Documents 目录
    func handleClearDocuments() async -> [String: Any] {
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

    /// 批量上传（WebSocket 模式）
    func handleBatchUpload(files: [[String: Any]]) async -> [String: Any] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default

        do {
            logger.info("清空 Documents 目录...")
            let contents = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in contents {
                try fileManager.removeItem(at: item)
            }

            logger.info("开始上传 \(files.count) 个文件...")
            for fileInfo in files {
                guard let relativePath = fileInfo["path"] as? String,
                      let base64Data = fileInfo["data"] as? String,
                      let data = Data(base64Encoded: base64Data) else {
                    continue
                }

                let targetURL = documentsURL.appendingPathComponent(relativePath)

                let parentURL = targetURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentURL.path) {
                    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }

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

    func handleMkdir(_ json: [String: Any]) async -> [String: Any] {
        guard let path = json["path"] as? String else {
            return ["status": "error", "message": "缺少 path 参数"]
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

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

    /// 格式化文件大小
    func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.2f MB", mb)
    }
}
