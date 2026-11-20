import Foundation

public enum GuideChatErrorCategory: String, Encodable, Sendable {
    case unauthorized = "http_401_unauthorized"
    case paymentRequired = "http_402_payment_required"
    case forbidden = "http_403_forbidden"
    case notFound = "http_404_not_found"
    case rateLimited = "http_429_rate_limited"
    case serverError = "http_5xx_server_error"
    case timeout = "network_timeout"
    case connectionException = "connection_exception_required"
    case connectionFailed = "connection_failed"
    case other = "other_request_error"

    static func httpStatus(_ code: Int) -> Self {
        switch code {
        case 401: .unauthorized
        case 402: .paymentRequired
        case 403: .forbidden
        case 404: .notFound
        case 408: .timeout
        case 429: .rateLimited
        case 500..<600: .serverError
        default: .other
        }
    }

    static func classify(_ error: Error) -> Self? {
        if case ChatService.NetworkError.badStatusCode(let code, _) = error { return httpStatus(code) }
        if error is CancellationError { return nil }
        if let rejection = error as? NetworkConnectionSecurityError, rejection == .denied { return .connectionException }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .other }
        switch URLError.Code(rawValue: nsError.code) {
        case .cancelled: return nil
        case .timedOut: return .timeout
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .appTransportSecurityRequiresSecureConnection, .userCancelledAuthentication:
            return .connectionException
        default: return .connectionFailed
        }
    }
}

public struct GlobalHealthSummary: Encodable, Sendable {
    public let setupState: GuideModelSetupState
    public let setupDiagnosis: String
    public let configuredProviderCount: Int
    public let activatedChatModelCount: Int
    public let selectedChatModel: String
    public let globalProxyEnabled: Bool
    public let lastChatErrorCategory: GuideChatErrorCategory?

    enum CodingKeys: String, CodingKey {
        case setupState = "setup_state", setupDiagnosis = "setup_diagnosis"
        case configuredProviderCount = "configured_provider_count", activatedChatModelCount = "activated_chat_model_count"
        case selectedChatModel = "selected_chat_model", globalProxyEnabled = "global_proxy_enabled"
        case lastChatErrorCategory = "last_chat_error_category"
    }

    public init(providers: [Provider], selectedModel: RunnableModel?, globalProxyEnabled: Bool,
                lastChatErrorCategory: GuideChatErrorCategory?, locale: Locale) {
        let state = GuideModelSetupStateResolver.resolve(providers: providers, selectedModel: selectedModel)
        setupState = state
        let zh = locale.language.languageCode?.identifier == "zh"
        switch state {
        case .needsProvider: setupDiagnosis = zh ? "还没添加提供商，可以先到模型管理填接口地址。" : "Add your provider in Model Management to get started."
        case .needsCredential: setupDiagnosis = zh ? "提供商已经加好了，还需要在提供商设置里填 API Key。" : "Your provider is there. Enter its API key in the provider settings."
        case .needsModel: setupDiagnosis = zh ? "还没有聊天模型，到模型管理里获取模型列表或手动添加一个。" : "Fetch the model list or add a chat model in Model Management."
        case .needsActivationOrSelection: setupDiagnosis = zh ? "已有聊天模型，勾选启用后再把它选为当前模型。" : "Enable a chat model, then select it as your current model."
        case .ready: setupDiagnosis = zh ? "聊天模型已经选好了，可以发一条消息试试。" : "Your chat model is selected. Try sending a message."
        }
        configuredProviderCount = providers.count
        activatedChatModelCount = providers.reduce(0) { count, provider in
            count + provider.models.lazy.filter { $0.isChatModel && $0.isActivated }.count
        }
        // 显示名可由用户自由填写；误粘地址或配置中的密钥时，整个名字留空。
        let name = selectedModel.flatMap { selected in
            providers.first { $0.id == selected.provider.id }?.models.first {
                $0.id == selected.model.id && $0.isChatModel
            }?.displayName
        } ?? ""
        let containsCredential = providers.contains { provider in
            provider.apiKeys.contains { !$0.isEmpty && name.contains($0) }
                || (!provider.baseURL.isEmpty && name.localizedCaseInsensitiveContains(provider.baseURL))
        }
        selectedChatModel = containsCredential || name.contains("://") || FeedbackTextSanitizer.redact(name) != name ? "" : name
        self.globalProxyEnabled = globalProxyEnabled
        self.lastChatErrorCategory = lastChatErrorCategory
    }
}

public enum GuideGlobalContextSupport {
    public static func featureMap(platform: String, locale: Locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        let watch = platform == "watchOS"
        let mac = platform == "macOS"
        let more = zh ? "拓展功能/" : "Extensions/"
        let sync = zh ? "同步与备份/" : "Sync & Backup/"
        let models = zh ? "模型管理/" : "Model Management/"
        let feedback = zh ? "反馈助手/" : "Feedback/"
        var lines = [zh ? "软件全览见 app-features-tour。从设置进入。菜单路径（常见问法）| 跳转 ID | document_id（逗号分隔，逐篇读取）" :
                        "For a tour, read app-features-tour. From Settings: menu path (common questions) | button ID | document_id (read each comma-separated ID separately)"]
        for target in GuideNavigationDestination.allCases where target.isAvailable(on: platform) {
            var path = zh ? target.menu.key : target.menu.english
            let doc: String
            switch target {
            case .providerManagement:
                path += zh ? "（配 API、中转地址、多 Key 轮换）" : " (API, relay URL, key rotation)"
                doc = "getting-started-guide, provider-model-basics"
            case .conversationSettings:
                path += zh ? "（上下文窗口、压缩、正则）" : " (context window, compression, regex)"
                doc = "context-compression, settings-core"
            case .promptSettings:
                path += zh ? "（系统提示词、预设）" : " (system prompt, presets)"
                doc = "settings-core"
            case .outputSettings:
                path += zh ? "（采样、流式回复）" : " (sampling, streaming)"
                doc = "settings-core"
            case .appearanceSettings:
                if watch { path = zh ? "显示与外观" : "Display & Appearance" }
                path += zh ? "（背景壁纸、气泡、字体）" : " (wallpaper, bubbles, fonts)"
                doc = "settings-display"
            case .syncAndBackup:
                path += zh ? "（跨设备同步、快照备份）" : " (sync devices, backup snapshots)"
                doc = "settings-sync"
            case .dataImport:
                path = (mac ? sync : more) + path + (zh ? "（导入配置包、迁移聊天）" : " (import a backup, move chats)")
                doc = "data-import"
            case .roleplayAndTavern:
                path += zh ? "（酒馆角色卡、正则、内联网页/HTML 小剧场）" : " (character cards, regex, inline HTML scenes)"
                doc = "roleplay-beginner-guide, roleplay, inline-html-actions"
            case .worldbook: doc = "worldbooks"
            case .memorySystem:
                path += zh ? "（长期记忆、跨对话记住我）" : " (long-term memory across chats)"
                doc = "settings-memory"
            case .dailyPulse: doc = "daily-pulse"
            case .toolCenter: doc = "settings-tools"
            case .mcpTools: doc = "mcp-tools"
            case .shortcutTools: doc = "shortcut-tools"
            case .agentSkills: doc = "agent-skills"
            case .speechInput: doc = "speech-input"
            case .ttsSettings:
                if mac { path = zh ? "语音输出" : "Text to Speech" }
                else { path = (watch ? more : (zh ? "输出/" : "Output/")) + path }
                doc = "tts"
            case .localLinux: doc = "local-linux"
            case .networkProxy:
                if mac { path = (zh ? "通用/" : "General/") + path }
                else { path = models + (watch ? path : (zh ? "全局代理" : "Global Proxy")) }
                doc = "network-proxy"
            case .connectionExceptions:
                path = (mac ? (zh ? "安全/" : "Security/") : more) + path
                path += zh ? "（HTTP、证书提示）" : " (HTTP and certificate prompts)"
                doc = "network-connection-exceptions"
            case .feedbackCenter:
                path = more + path
                doc = "feedback-assistant"
            case .feedbackCompose:
                path = more + feedback + path + (zh ? "（报错排查、提交反馈）" : " (report an error or ask for help)")
                doc = "troubleshooting-faq, feedback-assistant"
            case .aboutAndLogs:
                if !watch { path = zh ? "关于 ETOS LLM Studio" : "About ETOS LLM Studio" }
                path += mac ? (zh ? "/应用日志" : "/App Logs") : (zh ? "/连点版本七次看日志" : "/tap Version 7 times for logs")
                doc = mac ? "mac-app-information" : "guide-overview"
            }
            if watch {
                switch target {
                case .roleplayAndTavern, .worldbook, .memorySystem, .mcpTools, .shortcutTools, .agentSkills, .speechInput, .localLinux:
                    path = more + path
                default: break
                }
            }
            lines.append("\(path) | \(target.rawValue) | \(doc)")
        }
        return lines.joined(separator: "\n")
    }
}
