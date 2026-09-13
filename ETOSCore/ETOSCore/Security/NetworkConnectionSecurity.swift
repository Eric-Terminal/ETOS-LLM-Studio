import CryptoKit
import Foundation
import Security

/// 授权只匹配实际来源；路径、查询参数和凭据不参与匹配，也不进入确认界面。
public struct NetworkConnectionOrigin: Codable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    public var displayName: String { "\(scheme)://\(host):\(port)" }
    public var isAppService: Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name == "els.ericterminal.com" || name.hasSuffix(".els.ericterminal.com")
    }
}

public enum NetworkConnectionExceptionKind: String, Codable, Sendable {
    case http
    case certificate

    public var title: String {
        switch self {
        case .http: return NSLocalizedString("HTTP connection", comment: "HTTP 连接例外类型")
        case .certificate: return NSLocalizedString("Certificate exception", comment: "证书验证例外类型")
        }
    }
}

public struct NetworkConnectionException: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let origin: NetworkConnectionOrigin
    public let kind: NetworkConnectionExceptionKind
    public let createdAt: Date
    // 系统生成的不透明数据只留在本机数据库，不向页面向导或日志暴露。
    let trustExceptions: Data?
}

public struct NetworkConnectionSecurityState: Codable, Equatable, Sendable {
    public var allowsHTTPExceptions = false
    public var allowsCertificateExceptions = false
    public var exceptions: [NetworkConnectionException] = []
    var authenticationCode: Data?
}

public enum NetworkConnectionSecurityError: LocalizedError, Equatable {
    case denied
    case persistenceFailed

    public static func isRejection(_ error: Error) -> Bool {
        if let error = error as? Self { return error == .denied }
        let error = error as NSError
        return error.domain == NSURLErrorDomain
            && [NSURLErrorUserCancelledAuthentication, NSURLErrorCancelled].contains(error.code)
    }

    public var errorDescription: String? {
        switch self {
        case .denied:
            return NSLocalizedString("The connection was blocked because it has not been approved.", comment: "网络例外未授权")
        case .persistenceFailed:
            return NSLocalizedString(
                "The connection exception could not be saved. Please try again.", comment: "网络例外保存失败")
        }
    }
}

/// 在独立 actor 中读取数据库和评估证书，UI 只接收已整理好的状态。
public actor NetworkConnectionSecurity {
    public static let shared = NetworkConnectionSecurity()
    private static let storageKey = "network_connection_security"
    private var state: NetworkConnectionSecurityState?
    private let persistent: Bool
    private var installationSecret = ""
    private let ask:
        @Sendable (NetworkConnectionOrigin, NetworkConnectionExceptionKind, String, String?) async ->
            NetworkConnectionDecision

    init(
        persistent: Bool = true,
        ask:
            @escaping @Sendable (NetworkConnectionOrigin, NetworkConnectionExceptionKind, String, String?) async ->
            NetworkConnectionDecision = { origin, kind, detail, identity in
                await NetworkConnectionApprovalCenter.shared.request(
                    origin: origin, kind: kind, detail: detail, certificateIdentity: identity)
            }
    ) {
        self.persistent = persistent
        self.ask = ask
    }

    public func snapshot() -> NetworkConnectionSecurityState {
        loadIfNeeded()
        return state ?? NetworkConnectionSecurityState()
    }

    public func setEnabled(_ enabled: Bool, for kind: NetworkConnectionExceptionKind) throws {
        var next = snapshot()
        switch kind {
        case .http: next.allowsHTTPExceptions = enabled
        case .certificate: next.allowsCertificateExceptions = enabled
        }
        try save(next)
        if !enabled { NetworkSessionConfiguration.cancelConnections(kind: kind) }
    }

    public func removeException(id: UUID) throws {
        var next = snapshot()
        let removed = next.exceptions.first { $0.id == id }
        next.exceptions.removeAll { $0.id == id }
        try save(next)
        if let removed { NetworkSessionConfiguration.cancelConnections(origin: removed.origin) }
    }

    public func authorizeHTTP(_ url: URL?) async throws {
        try Task.checkCancellation()
        guard let url, let origin = NetworkConnectionOrigin(url: url), origin.scheme == "http" else { return }
        guard !origin.isAppService else { throw NetworkConnectionSecurityError.denied }
        let current = snapshot()
        if current.allowsHTTPExceptions,
            current.exceptions.contains(where: { $0.origin == origin && $0.kind == .http })
        {
            return
        }
        let decision = await ask(origin, .http, "", nil)
        try Task.checkCancellation()
        guard decision != .cancel else { throw NetworkConnectionSecurityError.denied }
        if decision == .remember {
            try remember(origin: origin, kind: .http, trustExceptions: nil)
        }
    }

    /// 默认验证成功的服务器不需要例外；已有例外必须重新通过系统评估。
    func accepts(_ trust: SecTrust, origin: NetworkConnectionOrigin) async -> Bool {
        if SecTrustEvaluateWithError(trust, nil) { return true }
        guard !origin.isAppService, !Task.isCancelled else { return false }
        let current = snapshot()
        if current.allowsCertificateExceptions,
            let record = current.exceptions.first(where: { $0.origin == origin && $0.kind == .certificate }),
            let exceptions = record.trustExceptions,
            SecTrustSetExceptions(trust, exceptions as CFData),
            SecTrustEvaluateWithError(trust, nil)
        {
            return true
        }

        // 清除旧例外，让用户确认的是本次完整的验证结果。
        SecTrustSetExceptions(trust, nil)
        var evaluationError: CFError?
        _ = SecTrustEvaluateWithError(trust, &evaluationError)
        let detail = evaluationError.map { CFErrorCopyDescription($0) as String } ?? ""
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let certificateIdentity = chain.map { certificate in
            SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }.joined()
        }.joined(separator: ":")
        let decision = await ask(origin, .certificate, detail, certificateIdentity)
        guard decision != .cancel, !Task.isCancelled,
            let exceptions = SecTrustCopyExceptions(trust),
            SecTrustSetExceptions(trust, exceptions),
            SecTrustEvaluateWithError(trust, nil)
        else { return false }
        if decision == .remember {
            do {
                try remember(origin: origin, kind: .certificate, trustExceptions: exceptions as Data)
            } catch {
                await NetworkConnectionApprovalCenter.shared.reportPersistenceFailure()
                return false
            }
        }
        return true
    }

    func remember(origin: NetworkConnectionOrigin, kind: NetworkConnectionExceptionKind, trustExceptions: Data?) throws
    {
        guard !origin.isAppService else { throw NetworkConnectionSecurityError.denied }
        var next = snapshot()
        next.exceptions.removeAll { $0.origin == origin && $0.kind == kind }
        next.exceptions.append(
            NetworkConnectionException(
                id: UUID(), origin: origin, kind: kind, createdAt: Date(), trustExceptions: trustExceptions
            ))
        switch kind {
        case .http: next.allowsHTTPExceptions = true
        case .certificate: next.allowsCertificateExceptions = true
        }
        try save(next)
    }

    private func loadIfNeeded() {
        guard state == nil || (persistent && installationSecret.isEmpty) else { return }
        guard persistent else {
            state = NetworkConnectionSecurityState()
            return
        }
        guard !DatabaseEncryptionManager.shared.requiresManualUnlock else { return }
        installationSecret = Self.localInstallationID()
        if let saved = Persistence.loadAuxiliaryBlob(NetworkConnectionSecurityState.self, forKey: Self.storageKey),
            Self.isAuthentic(saved, secret: installationSecret)
        {
            state = saved
        } else {
            state = NetworkConnectionSecurityState()
        }
    }

    private func save(_ next: NetworkConnectionSecurityState) throws {
        var next = next
        if persistent {
            guard !installationSecret.isEmpty,
                let code = Self.authenticationCode(for: next, secret: installationSecret)
            else {
                throw NetworkConnectionSecurityError.persistenceFailed
            }
            next.authenticationCode = code
            guard Persistence.saveAuxiliaryBlob(next, forKey: Self.storageKey) else {
                throw NetworkConnectionSecurityError.persistenceFailed
            }
        }
        state = next
        NotificationCenter.default.post(name: .networkConnectionSecurityDidChange, object: nil)
    }

    // 数据库可能被整包导入，使用本机钥匙串密钥验证记录，不能把导入的布尔值当成用户授权。
    static func authenticationCode(for state: NetworkConnectionSecurityState, secret: String) -> Data? {
        var unsigned = state
        unsigned.authenticationCode = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(unsigned) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(secret.utf8))))
    }

    static func isAuthentic(_ state: NetworkConnectionSecurityState, secret: String) -> Bool {
        guard !secret.isEmpty, let saved = state.authenticationCode,
            let expected = authenticationCode(for: state, secret: secret)
        else { return false }
        return saved == expected
    }

    /// 设备绑定凭据不随配置数据库迁移，避免把其他设备的信任决定一起导入。
    private static func localInstallationID() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ericterminal.els.network-trust",
            kSecAttrAccount as String: "installation",
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard status == errSecItemNotFound else { return "" }
        let identifier = UUID().uuidString
        var item = query
        item[kSecValueData as String] = Data(identifier.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? identifier : ""
    }
}

extension Notification.Name {
    public static let networkConnectionSecurityDidChange = Notification.Name("networkConnectionSecurityDidChange")
}
