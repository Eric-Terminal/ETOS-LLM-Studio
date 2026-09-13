import Foundation
import Security

/// 可供下载进度代理继承，保留 URLSession 自身的流式、代理与上传实现。
open class NetworkSecuritySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = NetworkSecuritySessionDelegate()
    private let challengeLock = NSLock()
    private var challenges: [ObjectIdentifier: Task<Void, Never>] = [:]

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let worker = Self.handle(challenge, completionHandler: completionHandler)
        challengeLock.lock()
        challenges[ObjectIdentifier(task)] = worker
        challengeLock.unlock()
    }

    @discardableResult
    public static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Task<Void, Never>? {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = space.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = space.host.contains(":") && !space.host.hasPrefix("[") ? "[\(space.host)]" : space.host
        components.port = space.port
        guard let url = components.url, let origin = NetworkConnectionOrigin(url: url) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return nil
        }
        return Task {
            let accepted = await NetworkConnectionSecurity.shared.accepts(trust, origin: origin)
            completionHandler(
                accepted ? .useCredential : .cancelAuthenticationChallenge,
                accepted ? URLCredential(trust: trust) : nil)
        }
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        challengeLock.lock()
        let worker = challenges.removeValue(forKey: ObjectIdentifier(task))
        challengeLock.unlock()
        worker?.cancel()
    }

    open func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let worker = Task {
            do {
                try await NetworkConnectionSecurity.shared.authorizeHTTP(request.url)
                guard task.state != .canceling, task.state != .completed else {
                    completionHandler(nil)
                    return
                }
                completionHandler(request)
            } catch {
                task.cancel()
                completionHandler(nil)
            }
        }
        challengeLock.lock()
        challenges[ObjectIdentifier(task)] = worker
        challengeLock.unlock()
    }
}

extension URLSession {
    @discardableResult
    public func securedDataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else {
                completionHandler(nil, nil, CancellationError())
                return
            }
            do {
                let (data, response) = try await securedData(for: request)
                completionHandler(data, response, nil)
            } catch { completionHandler(nil, nil, error) }
        }
    }

    public func securedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        NetworkSessionConfiguration.track(self)
        try await NetworkConnectionSecurity.shared.authorizeHTTP(request.url)
        return try await data(for: request, delegate: NetworkSecuritySessionDelegate.shared)
    }

    public func securedData(from url: URL) async throws -> (Data, URLResponse) {
        try await securedData(for: URLRequest(url: url))
    }

    public func securedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        NetworkSessionConfiguration.track(self)
        try await NetworkConnectionSecurity.shared.authorizeHTTP(request.url)
        return try await bytes(for: request, delegate: NetworkSecuritySessionDelegate.shared)
    }
}
