import Foundation

/// 配置页的聊天请求体示例，使用实际适配器，但不持有真实提供商凭据、历史或网络会话。
public enum ModelChatRequestBodyPreview {
    public static func supports(model: Model, providerAPIFormat: String) -> Bool {
        model.kind == .chat && providerAPIFormat != LocalModelProviderBridge.apiFormat
            && model.effectiveAPIFormat(providerAPIFormat: providerAPIFormat) != LocalModelProviderBridge.apiFormat
    }

    /// JSON 构造及脱敏应由调用方在后台执行；返回内容只适用于示例，不用于发送请求。
    public static func body(model: Model, providerAPIFormat: String) throws -> String {
        guard supports(model: model, providerAPIFormat: providerAPIFormat) else { throw PreviewError.unavailable }
        let provider = Provider(name: "preview", baseURL: "https://example.invalid/v1", apiKeys: [], apiFormat: providerAPIFormat)
        let runnable = RunnableModel(provider: provider, model: model, requestBodyControlState: model.defaultRequestBodyControlState)
        let adapter: any APIAdapter
        switch ProviderAPIFormatFamily(apiFormat: runnable.effectiveAPIFormat) {
        case .openAICompatible: adapter = OpenAIAdapter()
        case .openAIResponses: adapter = OpenAIResponsesAdapter()
        case .anthropic: adapter = AnthropicAdapter()
        case .gemini: adapter = GeminiAdapter()
        case .geminiInteractions: adapter = GeminiInteractionsAdapter()
        }
        // 固定占位密钥绕过密钥轮换；关闭请求快照日志，示例不进入真实请求历史。
        let common: [String: Any] = [providerAPIKeyControlKey: "preview", requestLogSuppressionControlKey: true]
        guard let request = adapter.buildChatRequest(for: runnable, commonPayload: common,
                messages: [ChatMessage(role: .user, content: "<message>")], tools: nil,
                audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let data = request.httpBody else { throw PreviewError.unavailable }
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(GuideSecretRedactor.redact(body)), as: UTF8.self)
    }

    public enum PreviewError: LocalizedError {
        case unavailable
        public var errorDescription: String? {
            NSLocalizedString("无法生成聊天请求体示例。", value: "Unable to generate a sample chat request body.", comment: "请求体示例生成失败")
        }
    }
}
