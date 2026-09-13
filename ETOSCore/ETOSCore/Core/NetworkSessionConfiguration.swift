import Foundation

public enum NetworkSessionConfiguration {
    public static let minimumRequestTimeout: TimeInterval = 180

    public static let shared: URLSession = makeSession()
    private final class SessionRegistry: @unchecked Sendable {
        let sessions = NSHashTable<URLSession>.weakObjects()
        let lock = NSLock()
    }
    private static let registry = SessionRegistry()

    public static func makeSession(
        from baseConfiguration: URLSessionConfiguration = .default,
        minimumRequestTimeout: TimeInterval = minimumRequestTimeout
    ) -> URLSession {
        let session = URLSession(
            configuration: makeConfiguration(
                from: baseConfiguration,
                minimumRequestTimeout: minimumRequestTimeout
            ),
            delegate: NetworkSecuritySessionDelegate.shared,
            delegateQueue: nil
        )
        track(session)
        return session
    }

    public static func track(_ session: URLSession) {
        registry.lock.lock()
        registry.sessions.add(session)
        registry.lock.unlock()
    }

    static func cancelConnections(kind: NetworkConnectionExceptionKind? = nil, origin: NetworkConnectionOrigin? = nil) {
        registry.lock.lock()
        let activeSessions = registry.sessions.allObjects
        registry.lock.unlock()
        for session in activeSessions {
            session.getAllTasks { tasks in
                for task in tasks {
                    guard let url = task.currentRequest?.url, let target = NetworkConnectionOrigin(url: url) else { continue }
                    if let origin, target != origin { continue }
                    if let kind, target.scheme != (kind == .http ? "http" : "https") { continue }
                    task.cancel()
                }
                // 失效连接不能留在连接池中，否则撤销证书例外后可能跳过下一次握手。
                if kind != .http && origin?.scheme != "http" { session.reset { } }
            }
        }
    }

    public static func makeConfiguration(
        from baseConfiguration: URLSessionConfiguration = .default,
        minimumRequestTimeout: TimeInterval = minimumRequestTimeout
    ) -> URLSessionConfiguration {
        let configuration = baseConfiguration
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = max(
            configuration.timeoutIntervalForRequest,
            minimumRequestTimeout
        )
#if os(iOS)
        configuration.multipathServiceType = .handover
#endif
        return configuration
    }
}
