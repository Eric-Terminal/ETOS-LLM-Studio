import Foundation

/// 外部目录必须先取得安全作用域，再交给文件提供者准备；路径检查不能早于协调访问。
enum LocalLinuxExternalDirectory {
    static func createBookmark(for url: URL) throws -> Data {
        let shouldStop = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStop { url.stopAccessingSecurityScopedResource() }
        }
        do {
            return try coordinateRead(at: url) { coordinatedURL in
                try coordinatedURL.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        } catch {
            recordFailure("保存目录授权", error: error, didStartAccess: shouldStop)
            throw error
        }
    }

    static func coordinateRead<Value>(
        at url: URL,
        coordinator: NSFileCoordinator = NSFileCoordinator(),
        accessor: (URL) throws -> Value
    ) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, Error> = .failure(CocoaError(.fileReadUnknown))
        coordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                // 云端占位目录可能尚无本地路径，也可能没有下载状态；由协调器完成准备，
                // 不把 .current 当作目录可访问的前提，也不沿用准备前缓存的资源属性。
                var directoryURL = coordinatedURL
                directoryURL.removeAllCachedResourceValues()
                let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    throw LocalLinuxRuntimeError.invalidPath(directoryURL.path)
                }
                return try accessor(directoryURL)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func recordFailure(_ action: String, error: Error, didStartAccess: Bool? = nil) {
        let error = error as NSError
        var payload = ["错误域": error.domain, "错误码": String(error.code)]
        if let didStartAccess {
            payload["已开启安全作用域"] = String(didStartAccess)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            payload["底层错误域"] = underlying.domain
            payload["底层错误码"] = String(underlying.code)
        }
        // 不记录书签或宿主完整路径，仍保留区分权限、占位目录与文件提供者故障的信息。
        let diagnosticPayload = payload
        Task { @MainActor in
            AppLogCenter.shared.logDeveloper(
                level: .error,
                category: "外部目录挂载",
                action: action,
                message: "外部目录访问失败。",
                payload: diagnosticPayload
            )
        }
    }
}
