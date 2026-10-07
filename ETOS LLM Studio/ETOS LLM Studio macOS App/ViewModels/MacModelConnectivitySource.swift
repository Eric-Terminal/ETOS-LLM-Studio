import ETOSCore
import Foundation

struct MacModelConnectivitySource: Identifiable {
    let id = UUID()
    let provider: Provider
    let originalProvider: Provider?
    let model: Model?

    /// 请求头单独编辑，必须在后台把文本草稿并入提供商，不能沿用旧的已保存请求头。
    static func preparedProvider(_ provider: Provider, headers: String) throws -> Provider {
        var result = provider
        result.headerOverrides = try JSONDecoder().decode([String: String].self, from: Data(headers.utf8))
        return result
    }

    func matches(_ providers: [Provider]) -> Bool {
        providers.first(where: { $0.id == provider.id }) == originalProvider
    }

    func candidates() -> [RunnableModel] {
        guard !LocalModelProviderBridge.isLocalProvider(provider) else { return [] }
        let models = model.map { [$0] } ?? provider.models.filter { $0.isActivated && $0.kind.supportsConnectivityTest }
        // 草稿控制的签名可能不同，固定默认状态避免读取时修剪已保存的聊天选择。
        return models.map { RunnableModel(provider: provider, model: $0, requestBodyControlState: $0.defaultRequestBodyControlState) }
    }
}

struct MacModelConnectivityRow: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let status: ModelConnectivityTestResult.Status
    let latency: String?
    let preview: String?
    let error: String?

    init(_ result: ModelConnectivityTestResult) {
        id = result.id; title = result.displayName; subtitle = result.modelName; status = result.status
        latency = result.latencyMilliseconds.map { String(format: NSLocalizedString("耗时 %d ms", comment: ""), $0) }
        preview = result.responsePreview; error = result.errorMessage
    }

    init(_ result: SingleModelConnectivityTestResult) {
        id = result.id; title = result.kind.localizedName; subtitle = nil; status = result.status
        latency = result.latencyMilliseconds.map { String(format: NSLocalizedString("耗时 %d ms", comment: ""), $0) }
        preview = result.responsePreview; error = result.errorMessage
    }
}
