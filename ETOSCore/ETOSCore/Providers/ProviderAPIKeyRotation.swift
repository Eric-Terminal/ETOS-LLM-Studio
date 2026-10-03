import Foundation

let providerAPIKeyControlKey = "etos.provider.selected_api_key"

/// 游标只存在于进程内；并发会话共用同一提供商的顺序，不为轮换产生数据库写入。
final class ProviderAPIKeyRotation: @unchecked Sendable {
    static let shared = ProviderAPIKeyRotation()
    private let lock = NSLock()
    private var cursors: [UUID: (keys: [String], nextIndex: Int)] = [:]

    func next(for provider: Provider, after previous: String? = nil) -> String? {
        let keys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
        guard !keys.isEmpty else { return nil }
        guard provider.multiKeyEnabled else { return keys.first }
        lock.lock()
        defer { lock.unlock() }
        let cursor = cursors[provider.id]
        let index: Int
        if let previous, let previousIndex = keys.firstIndex(of: previous) {
            index = (previousIndex + 1) % keys.count
        } else {
            index = cursor?.keys == keys ? (cursor?.nextIndex ?? 0) : 0
        }
        cursors[provider.id] = (keys, (index + 1) % keys.count)
        return keys[index]
    }
}

extension Provider {
    func nextAPIKey() -> String? {
        ProviderAPIKeyRotation.shared.next(for: self)
    }

    /// 只更新认证请求头，保留已准备的附件、工具结果与请求体。
    func rotatingAPIKey(in request: URLRequest, apiFormat: String) -> URLRequest {
        guard multiKeyEnabled else { return request }
        let previous = apiKeys.first { key in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)"
                || request.value(forHTTPHeaderField: "x-api-key") == key
                || request.value(forHTTPHeaderField: "x-goog-api-key") == key
                || headerOverrides.contains { header, template in
                    template.contains("{api_key}")
                        && request.value(forHTTPHeaderField: header) == template.replacingOccurrences(of: "{api_key}", with: key)
                }
        }
        guard let key = ProviderAPIKeyRotation.shared.next(for: self, after: previous) else { return request }
        var result = request
        switch apiFormat {
        case "gemini": result.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case "anthropic": result.setValue(key, forHTTPHeaderField: "x-api-key")
        default: result.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        applyHeaderOverrides(headerOverrides, apiKey: key, to: &result)
        return result
    }

    /// 重建正文或 Responses 回退时仍沿用本次尝试的凭据，不额外消费一次轮换。
    func preservingAuthentication(from source: URLRequest, in rebuilt: URLRequest) -> URLRequest {
        var result = rebuilt
        for header in ["Authorization", "x-api-key", "x-goog-api-key"] + Array(headerOverrides.keys) {
            result.setValue(source.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        return result
    }
}
