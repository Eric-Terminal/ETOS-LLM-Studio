import Foundation

public enum NetworkSessionConfiguration {
    public static let minimumRequestTimeout: TimeInterval = 180
    public static let minimumResourceTimeout: TimeInterval = 900

    public static let shared: URLSession = makeSession()

    public static func makeSession(
        from baseConfiguration: URLSessionConfiguration = .default,
        minimumRequestTimeout: TimeInterval = minimumRequestTimeout,
        minimumResourceTimeout: TimeInterval = minimumResourceTimeout
    ) -> URLSession {
        URLSession(
            configuration: makeConfiguration(
                from: baseConfiguration,
                minimumRequestTimeout: minimumRequestTimeout,
                minimumResourceTimeout: minimumResourceTimeout
            )
        )
    }

    public static func makeConfiguration(
        from baseConfiguration: URLSessionConfiguration = .default,
        minimumRequestTimeout: TimeInterval = minimumRequestTimeout,
        minimumResourceTimeout: TimeInterval = minimumResourceTimeout
    ) -> URLSessionConfiguration {
        let configuration = baseConfiguration
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = max(
            configuration.timeoutIntervalForRequest,
            minimumRequestTimeout
        )
        configuration.timeoutIntervalForResource = max(
            configuration.timeoutIntervalForResource,
            minimumResourceTimeout
        )
#if os(iOS)
        configuration.multipathServiceType = .handover
#endif
        return configuration
    }
}
