import Foundation

extension LocalDebugServer {
    func prepareDebugUpload(paths: [String]) async throws -> LocalDebugDocumentReplacement {
        let fileRoot = fileRoot
        let worker = Task.detached(priority: .userInitiated) { try LocalDebugDocumentReplacement(root: fileRoot(), paths: paths) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func prepareDebugBatch(_ files: LocalDebugJSONObject) async throws -> LocalDebugDocumentReplacement {
        let fileRoot = fileRoot
        let worker = Task.detached(priority: .userInitiated) {
            let files = files.value["files"] as? [[String: Any]] ?? []
            var uploads: [(path: String, base64: String)] = []
            for file in files {
                try Task.checkCancellation()
                guard let path = file["path"] as? String, let base64 = file["data"] as? String else {
                    throw LocalDebugFileAccessError.invalidBase64
                }
                uploads.append((path, base64))
            }
            let replacement = try LocalDebugDocumentReplacement(root: fileRoot(), paths: uploads.map { $0.path })
            do {
                for upload in uploads { try replacement.receive(path: upload.path, base64: upload.base64) }
                try replacement.validateComplete()
                return replacement
            } catch {
                replacement.discard()
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func discardDebugUpload(_ replacement: LocalDebugDocumentReplacement) async {
        // 取消后仍由原命令等待清理，不能派出无人等待的收尾任务或在主线程删除文件。
        await Task.detached(priority: .utility) { replacement.discard() }.value
    }

    func commitDebugUpload(_ replacement: LocalDebugDocumentReplacement) async throws {
        let install = installDocuments
        do {
            guard canContinueDebugCommand else { throw CancellationError() }
            if let documentReplacementCoordinator {
                try await documentReplacementCoordinator { try install(replacement) }
            } else {
                let cloud = CloudSyncManager.shared, mcp = MCPManager.shared
                guard cloud.beginLocalDataRestore() else {
                    throw NSError(domain: "LocalDebugReplacement", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "调试覆盖与同步互斥")
                    ])
                }
                var didRestore = false
                defer { cloud.endLocalDataRestore(didRestore: didRestore) }
                // 关闭配置库会使旧观察失效，成功和失败都必须重新建立 MCP 的连接与观察。
                await mcp.prepareForDatabaseRestore()
                do {
                    await AppConfigStore.shared.flushPendingWrites()
                    guard canContinueDebugCommand else { throw CancellationError() }
                    // 进入文件替换后，不把断开取消传播给提交；成功或回滚都必须等到实际结束。
                    try await Task.detached(priority: .userInitiated) { try install(replacement) }.value
                    didRestore = true
                    await AppConfigStore.shared.reloadFromPersistentStoreAndWait()
                    NotificationCenter.default.post(name: .snapshotRestoreDidFinish, object: nil)
                } catch {
                    await mcp.finishDatabaseRestore()
                    throw error
                }
                await mcp.finishDatabaseRestore()
            }
        } catch {
            await discardDebugUpload(replacement)
            throw error
        }
        await discardDebugUpload(replacement)
    }
}
