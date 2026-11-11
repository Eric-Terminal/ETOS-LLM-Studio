import Foundation
import Darwin

/// 地址只携带相对路径；会话身份由标签页注入，网页不能指定其他会话的工作区。
public enum BrowserLocalResource {
    public static let scheme = "etos"
    static let maximumBytes = 16 * 1024 * 1024

    struct Resource: Sendable {
        let data: Data
        let mimeType: String
    }

    public static func isLocalURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// 浏览器入口与工具共用协议校验，避免某个平台把本地地址当成搜索词。
    public static func validatedNavigationURL(_ url: URL) throws -> URL {
        if isLocalURL(url) {
            _ = try pathComponents(url)
        } else if !["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.host?.isEmpty != false {
            throw BrowserAgentError.invalidArguments(
                NSLocalizedString("浏览器支持 http、https 和 etos 本地网页地址。", comment: "浏览器地址协议限制")
            )
        }
        return url
    }

    /// 本地空间不能与同名的公网主机共用 Agent 的跨域授权。
    static func navigationHost(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        return isLocalURL(url) ? "\(scheme)://\(host)" : host
    }

    static func pathComponents(_ url: URL) throws -> [String] {
        guard isLocalURL(url),
              ["workspace", "sandbox"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw invalidPath()
        }
        // 逐段解码一次，拒绝编码后的斜线和穿越；查询参数、锚点不参与文件定位。
        let segments = try components.percentEncodedPath.split(separator: "/").map { raw -> String in
            guard let value = String(raw).removingPercentEncoding,
                  value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
                throw invalidPath()
            }
            return value
        }
        return segments.isEmpty || components.percentEncodedPath.hasSuffix("/")
            ? segments + ["index.html"] : segments
    }

    static func rootDirectory(for url: URL, sessionID: UUID) throws -> URL {
        if url.host?.lowercased() == "sandbox" { return StorageUtility.documentsDirectory }
        // 读取网页不创建工作区，也不启动 Linux；Mac 沿用本机工作区目录。
        guard let workspace = Persistence.loadLocalAgentWorkspaces(sessionID: sessionID).first else {
            throw BrowserAgentError.navigationFailed(
                NSLocalizedString("当前会话还没有工作区文件。", comment: "本地网页工作区不存在")
            )
        }
        return try LocalLinuxStorageManager.shared.hostURL(for: workspace)
    }

    static func read(_ url: URL, rootDirectory: URL) throws -> Resource {
        let components = try pathComponents(url)
        guard let name = components.last,
              let mime = mimeTypes[(name as NSString).pathExtension.lowercased()] else {
            throw BrowserAgentError.navigationFailed(
                NSLocalizedString("此文件类型不支持作为本地网页资源。", comment: "本地网页不支持的资源类型")
            )
        }

        // 持有目录描述符逐级打开，拒绝符号链接，避免检查后文件被替换造成越界读取。
        var descriptor = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { throw fileError() }
            close(descriptor)
            descriptor = next
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw invalidPath() }
        guard information.st_size <= maximumBytes else { throw oversizedResource() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        // 同时限制实际读取量，文件在读取期间增长也不能突破内存预算。
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw oversizedResource() }
        return Resource(data: data, mimeType: mime)
    }

    private static func invalidPath() -> BrowserAgentError {
        .invalidArguments(NSLocalizedString("本地网页地址必须位于 workspace 或 sandbox 中，且不能包含越界路径。", comment: "本地网页路径限制"))
    }

    private static func oversizedResource() -> BrowserAgentError {
        .navigationFailed(NSLocalizedString("单个本地网页资源不能超过 16 MB。", comment: "本地网页资源大小限制"))
    }

    private static func fileError() -> BrowserAgentError {
        .navigationFailed(NSLocalizedString("无法读取本地网页资源，请检查文件是否存在且不含符号链接。", comment: "本地网页文件读取失败"))
    }

    private static let mimeTypes = [
        "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "txt": "text/plain", "csv": "text/csv", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm"
    ]
}

/// 每个标签串行读取资源，磁盘与数据库访问不会占用 WebKit 的主执行器。
actor BrowserLocalResourceReader {
    func read(_ request: URLRequest, sessionID: UUID) throws -> BrowserLocalResource.Resource {
        guard let url = request.url,
              request.httpMethod == nil || request.httpMethod == "GET" || request.httpMethod == "HEAD" else {
            throw URLError(.unsupportedURL)
        }
        _ = try BrowserLocalResource.validatedNavigationURL(url)
        // 远程网页不能把此处理器当作读取 App 文件的跨源接口。
        if let mainDocument = request.mainDocumentURL,
           BrowserLocalResource.navigationHost(mainDocument) != BrowserLocalResource.navigationHost(url) {
            throw URLError(.noPermissionsToReadFile)
        }
        try Task.checkCancellation()
        let root = try BrowserLocalResource.rootDirectory(for: url, sessionID: sessionID)
        return try BrowserLocalResource.read(url, rootDirectory: root)
    }
}
