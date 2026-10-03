import Foundation

/// 换凭据的预算独立于整次请求的自动恢复预算，后者仍由全局设置控制。
public enum ProviderAPIKeyRetryPolicy {
    public static let defaultMaximumRetries = 3
    public static let allowedMaximumRetries = 0...10

    static func maximumRetries(from text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(text), allowedMaximumRetries.contains(count) else { return nil }
        return count
    }

    static func maximumRetries(for provider: Provider) -> Int {
        guard provider.multiKeyEnabled,
              ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys).count > 1 else { return 0 }
        return min(allowedMaximumRetries.upperBound, max(0, provider.maximumKeyRetries))
    }

    static func isRetryable(_ error: Error) -> Bool {
        // 换 Key 不读取全局“智能判断”开关；它只处理认证和已有临时错误类别。
        if case ChatService.NetworkError.badStatusCode(let code, _) = error,
           code == 401 || code == 403 { return true }
        return ChatRequestRetryPolicy.isRetryable(error)
    }
}
