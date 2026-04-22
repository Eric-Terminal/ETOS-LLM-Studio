import Foundation

public enum NetworkSessionConfiguration {
    public static let minimumRequestTimeout: TimeInterval = 180

    public static let shared: URLSession = makeSession()

    public static func makeSession(
        from baseConfiguration: URLSessionConfiguration = .default,
        minimumRequestTimeout: TimeInterval = minimumRequestTimeout
    ) -> URLSession {
        URLSession(
            configuration: makeConfiguration(
                from: baseConfiguration,
                minimumRequestTimeout: minimumRequestTimeout
            )
        )
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
