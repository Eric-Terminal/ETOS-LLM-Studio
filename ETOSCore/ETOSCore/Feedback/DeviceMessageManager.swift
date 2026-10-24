import Combine
import Foundation

public struct DeviceMessage: Decodable, Identifiable, Equatable, Sendable {
    public let key: String
    public let title: String
    public let description: String
    public let questions: [SurveyQuestion]
    public var id: String { key }
}

struct DeviceMessageAnswer: Codable, Equatable, Sendable {
    let questionID: String
    let selectedOptionIDs: [String]
    let otherText: String?

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case selectedOptionIDs = "selected_option_ids"
        case otherText = "other_text"
    }
}

struct DeviceMessageReply: Encodable, Sendable {
    let answers: [DeviceMessageAnswer]
    let dismissed: Bool
}

enum DeviceMessageError: LocalizedError {
    case identityUnavailable
    case unavailable
    case closed

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            NSLocalizedString("feedback.device.identity_error", value: "The local feedback credential could not be loaded or saved. Please try again.", comment: "反馈设备凭据错误")
        case .unavailable:
            NSLocalizedString("feedback.device.network_error", value: "Could not send your response. Your input is kept here; please try again.", comment: "私密回复失败")
        case .closed:
            NSLocalizedString("feedback.device.closed", value: "This message has already been closed. Your response was not sent.", comment: "留言已关闭")
        }
    }
}

/// 每次进程启动最多自动展示一条，不轮询、不把私密回答保存进聊天或向导历史。
@MainActor
public final class DeviceMessageManager: ObservableObject {
    public static let shared = DeviceMessageManager()
    @Published public private(set) var currentMessage: DeviceMessage?
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isClosed = false
    @Published public private(set) var hasPendingMessage = false

    private let session: URLSession
    private let baseURL: URL
    private let identityStore: FeedbackDeviceIdentityStore
    private var pendingMessage: DeviceMessage?
    private var checked = false
    private var presented = false

    public init(session: URLSession = NetworkSessionConfiguration.shared, baseURL: URL = FeedbackServiceConfig.default.baseURL) {
        self.session = session
        self.baseURL = baseURL
        self.identityStore = .shared
    }

    init(session: URLSession, baseURL: URL, identityStore: FeedbackDeviceIdentityStore) {
        self.session = session
        self.baseURL = baseURL
        self.identityStore = identityStore
    }

    public func checkMessages() async {
        guard !checked else { return }
        checked = true
        do {
            let request = try await makeRequest(path: "/v1/device-messages", method: "GET")
            let (data, response) = try await session.securedData(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let messages = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode([DeviceMessage].self, from: data)
            }.value
            pendingMessage = messages.first
            hasPendingMessage = pendingMessage != nil
        } catch {
            // 启动检查失败不打断聊天，下次启动仍可获取；禁止记录含凭据的请求。
        }
    }

    @discardableResult
    public func presentIfPossible() -> Bool {
        guard !presented, currentMessage == nil, let pendingMessage else { return false }
        presented = true
        errorMessage = nil
        isClosed = false
        currentMessage = pendingMessage
        return true
    }

    public func postpone() {
        guard !isSubmitting else { return }
        currentMessage = nil
    }

    func respond(answers: [DeviceMessageAnswer], dismissed: Bool = false) async {
        guard let message = currentMessage, !isSubmitting, !isClosed else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            var request = try await makeRequest(path: "/v1/device-messages/\(message.key)/responses", method: "POST")
            let reply = DeviceMessageReply(answers: answers, dismissed: dismissed)
            request.httpBody = try await Task.detached { try JSONEncoder().encode(reply) }.value
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.securedData(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DeviceMessageError.unavailable }
            if status == 404 || status == 410 {
                isClosed = true
                throw DeviceMessageError.closed
            }
            guard status == 200 else { throw DeviceMessageError.unavailable }
            pendingMessage = nil
            hasPendingMessage = false
            currentMessage = nil
        } catch {
            errorMessage = (error as? DeviceMessageError ?? .unavailable).localizedDescription
        }
    }

    private func makeRequest(path: String, method: String) async throws -> URLRequest {
        let identity = try await identityStore.identity()
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.deviceID, forHTTPHeaderField: "X-ELS-Device-ID")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
