import Foundation

/// MCP SDK 不公开注入 URLSession 的入口，因此仅在 SDK 配置中安装这个流式转接协议。
/// 转接后的请求继续使用原生 URLSession，逐块传递 SSE，取消时立即释放连接。
final class MCPNetworkSecurityURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private var worker: Task<Void, Never>?
    private var connection: URLSession?
    private var dataTask: URLSessionDataTask?
    private var trustTask: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await NetworkConnectionSecurity.shared.authorizeHTTP(request.url)
                try Task.checkCancellation()
                beginConnection()
            } catch {
                fail(error)
            }
        }
        stateLock.lock()
        worker = task
        let cancelled = stopped
        stateLock.unlock()
        if cancelled { task.cancel() }
    }

    private func beginConnection() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return }
        // 这个配置没有安装本协议，避免转接请求再次进入自身。
        let session = URLSession(
            configuration: NetworkSessionConfiguration.makeConfiguration(), delegate: self, delegateQueue: nil)
        NetworkSessionConfiguration.track(session)
        connection = session
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let worker = worker
        let session = connection
        let trustTask = trustTask
        self.worker = nil
        connection = nil
        dataTask = nil
        self.trustTask = nil
        stateLock.unlock()
        worker?.cancel()
        trustTask?.cancel()
        session?.invalidateAndCancel()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func fail(_ error: Error) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isStopped else {
            completionHandler(.cancel)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !isStopped else { return }
        if let error { fail(error) } else { client?.urlProtocolDidFinishLoading(self) }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let worker = NetworkSecuritySessionDelegate.handle(challenge, completionHandler: completionHandler)
        stateLock.lock()
        trustTask = worker
        let cancelled = stopped
        stateLock.unlock()
        if cancelled { worker?.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 交回 SDK 的原会话，保持系统重定向与认证头处理语义；下一跳仍会经过本协议。
        stateLock.lock()
        let wasStopped = stopped
        stopped = true
        stateLock.unlock()
        completionHandler(nil)
        guard !wasStopped else { return }
        client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
    }
}
