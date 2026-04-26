// ============================================================================
// Shared.swift
// ============================================================================
// ETOS LLM Studio 共享模块通用文件
//
// 定义内容:
// - (当前为空，可用于存放共享的扩展、辅助函数等)
// ============================================================================

import Foundation
import Combine
#if canImport(ObjectiveC)
import ObjectiveC
#endif

public enum ChatNavigationMode: String, CaseIterable, Identifiable {
    case legacyOverlay = "legacyOverlay"
    case nativeNavigation = "nativeNavigation"

    public static let storageKey = "ui.chatNavigationMode"
    public static let defaultMode: ChatNavigationMode = .legacyOverlay

    public var id: String { rawValue }

    public static func resolvedMode(rawValue: String) -> ChatNavigationMode {
        ChatNavigationMode(rawValue: rawValue) ?? defaultMode
    }
}

public enum SettingsIconAppearancePreference {
    public static let storageKey = "ui.settingsColorfulIconsEnabled"
}

public enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant-HK"
    case english = "en"
    case japanese = "ja"
    case russian = "ru"
    case french = "fr"
    case spanish = "es"
    case arabic = "ar"

    public static let storageKey = "ui.appLanguage"
    public static let defaultLanguage: AppLanguagePreference = .system

    public var id: String { rawValue }

    public var localizationIdentifier: String? {
        switch self {
        case .system:
            return nil
        default:
            return rawValue
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .system:
            return Locale.autoupdatingCurrent.identifier
        case .simplifiedChinese:
            return "zh_Hans"
        case .traditionalChinese:
            return "zh_Hant_HK"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .russian:
            return "ru"
        case .french:
            return "fr"
        case .spanish:
            return "es"
        case .arabic:
            return "ar"
        }
    }

    public var nativeDisplayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文（香港）"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        case .russian:
            return "Русский"
        case .french:
            return "Français"
        case .spanish:
            return "Español"
        case .arabic:
            return "العربية"
        }
    }

    public static func resolved(rawValue: String) -> AppLanguagePreference {
        AppLanguagePreference(rawValue: rawValue) ?? defaultLanguage
    }

    public static func preferredLocale(rawValue: String) -> Locale {
        let preference = resolved(rawValue: rawValue)
        if preference == .system {
            return .autoupdatingCurrent
        }
        return Locale(identifier: preference.localeIdentifier)
    }

    public static var storedPreference: AppLanguagePreference {
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? defaultLanguage.rawValue
        return resolved(rawValue: rawValue)
    }
}

public enum AppLanguageRuntime {
    public static func apply(rawValue: String) {
        let preference = AppLanguagePreference.resolved(rawValue: rawValue)

        #if canImport(ObjectiveC)
        if object_getClass(Bundle.main) !== AppLanguageBundle.self {
            object_setClass(Bundle.main, AppLanguageBundle.self)
        }

        if let identifier = preference.localizationIdentifier,
           let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            objc_setAssociatedObject(Bundle.main, &appLanguageBundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else {
            objc_setAssociatedObject(Bundle.main, &appLanguageBundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        #endif
    }
}

#if canImport(ObjectiveC)
private var appLanguageBundleKey: UInt8 = 0

private final class AppLanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &appLanguageBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
#endif

public enum ToolPermissionDecision: String {
    case deny
    case allowOnce
    case allowForTool
    case allowAll
    case supplement
}

public struct ToolPermissionRequest: Identifiable, Equatable {
    public let id: UUID
    public let toolName: String
    public let displayName: String?
    public let arguments: String
    
    public init(id: UUID = UUID(), toolName: String, displayName: String?, arguments: String) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.arguments = arguments
    }
}

public struct SessionMessageJumpTarget: Equatable, Sendable {
    public let sessionID: UUID
    public let messageOrdinal: Int

    public init(sessionID: UUID, messageOrdinal: Int) {
        self.sessionID = sessionID
        self.messageOrdinal = messageOrdinal
    }
}

@MainActor
public final class ToolPermissionCenter: ObservableObject {
    public static let shared = ToolPermissionCenter()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则聊天里的工具审批弹窗与倒计时不会稳定自动刷新。
    
    @Published public private(set) var activeRequest: ToolPermissionRequest?
    @Published public private(set) var autoApproveEnabled: Bool
    @Published public private(set) var autoApproveCountdownSeconds: Int
    @Published public private(set) var autoApproveRemainingSeconds: Int?
    @Published public private(set) var disabledAutoApproveTools: [String]
    
    private var allowAll = false
    private var allowedTools: Set<String> = []
    private var disabledAutoApproveToolSet: Set<String>
    private var queuedRequests: [QueuedRequest] = []
    private var activeContinuation: CheckedContinuation<ToolPermissionDecision, Never>?
    private var autoApproveTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let autoApproveEnabled = "tool.permission.autoApproveEnabled"
        static let autoApproveCountdownSeconds = "tool.permission.autoApproveCountdownSeconds"
        static let disabledAutoApproveTools = "tool.permission.disabledAutoApproveTools"
    }

    private let autoApproveCountdownMin = 1
    private let autoApproveCountdownMax = 30

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEnabled = defaults.object(forKey: DefaultsKey.autoApproveEnabled) as? Bool
        autoApproveEnabled = storedEnabled ?? false
        let storedCountdown = defaults.integer(forKey: DefaultsKey.autoApproveCountdownSeconds)
        if storedCountdown > 0 {
            autoApproveCountdownSeconds = min(max(storedCountdown, autoApproveCountdownMin), autoApproveCountdownMax)
        } else {
            autoApproveCountdownSeconds = 8
        }
        let storedDisabledTools = defaults.stringArray(forKey: DefaultsKey.disabledAutoApproveTools) ?? []
        disabledAutoApproveToolSet = Set(storedDisabledTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        disabledAutoApproveTools = disabledAutoApproveToolSet.sorted()
    }
    
    public func requestPermission(toolName: String, displayName: String?, arguments: String) async -> ToolPermissionDecision {
        if allowAll || allowedTools.contains(toolName) {
            return .allowOnce
        }
        
        return await withCheckedContinuation { continuation in
            let request = ToolPermissionRequest(toolName: toolName, displayName: displayName, arguments: arguments)
            if activeRequest == nil {
                activeRequest = request
                activeContinuation = continuation
                scheduleAutoApproveIfNeeded(for: request)
            } else {
                queuedRequests.append(QueuedRequest(request: request, continuation: continuation))
            }
        }
    }
    
    public func resolveActiveRequest(with decision: ToolPermissionDecision) {
        guard let activeRequest else { return }
        cancelAutoApproveCountdown()
        
        switch decision {
        case .allowAll:
            allowAll = true
        case .allowForTool:
            allowedTools.insert(activeRequest.toolName)
        case .deny, .allowOnce, .supplement:
            break
        }
        
        activeContinuation?.resume(returning: decision)
        activeContinuation = nil
        self.activeRequest = nil
        advanceQueueIfNeeded()
    }

    public func setAutoApproveEnabled(_ enabled: Bool) {
        autoApproveEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autoApproveEnabled)
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        } else {
            cancelAutoApproveCountdown()
        }
    }

    public func setAutoApproveCountdownSeconds(_ seconds: Int) {
        let sanitized = min(max(seconds, autoApproveCountdownMin), autoApproveCountdownMax)
        autoApproveCountdownSeconds = sanitized
        defaults.set(sanitized, forKey: DefaultsKey.autoApproveCountdownSeconds)
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func isAutoApproveDisabled(for toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return disabledAutoApproveToolSet.contains(normalized)
    }

    public func setAutoApproveDisabled(_ disabled: Bool, for toolName: String) {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if disabled {
            disabledAutoApproveToolSet.insert(normalized)
        } else {
            disabledAutoApproveToolSet.remove(normalized)
        }
        persistDisabledAutoApproveTools()
        if let activeRequest, activeRequest.toolName == normalized {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func clearDisabledAutoApproveTools() {
        disabledAutoApproveToolSet.removeAll()
        persistDisabledAutoApproveTools()
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        }
    }

    public func disableAutoApproveForActiveTool() {
        guard let activeRequest else { return }
        setAutoApproveDisabled(true, for: activeRequest.toolName)
    }

    public func autoApproveRemainingSeconds(for request: ToolPermissionRequest) -> Int? {
        guard activeRequest?.id == request.id else { return nil }
        return autoApproveRemainingSeconds
    }
    
    private func advanceQueueIfNeeded() {
        guard self.activeRequest == nil, !queuedRequests.isEmpty else { return }
        while !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            if allowAll || allowedTools.contains(next.request.toolName) {
                next.continuation.resume(returning: .allowOnce)
                continue
            }
            self.activeRequest = next.request
            activeContinuation = next.continuation
            scheduleAutoApproveIfNeeded(for: next.request)
            break
        }
        if self.activeRequest == nil {
            cancelAutoApproveCountdown()
        }
    }

    private func scheduleAutoApproveIfNeeded(for request: ToolPermissionRequest) {
        cancelAutoApproveCountdown()
        guard autoApproveEnabled,
              !isAutoApproveDisabled(for: request.toolName),
              autoApproveCountdownSeconds > 0 else {
            return
        }

        autoApproveRemainingSeconds = autoApproveCountdownSeconds
        let requestID = request.id
        autoApproveTask = Task { [weak self] in
            guard let self else { return }
            var remaining = autoApproveCountdownSeconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled {
                    return
                }
                remaining -= 1
                await MainActor.run {
                    guard self.activeRequest?.id == requestID else { return }
                    self.autoApproveRemainingSeconds = remaining
                }
            }

            await MainActor.run {
                guard self.activeRequest?.id == requestID else { return }
                self.resolveActiveRequest(with: .allowOnce)
            }
        }
    }

    private func cancelAutoApproveCountdown() {
        autoApproveTask?.cancel()
        autoApproveTask = nil
        autoApproveRemainingSeconds = nil
    }

    private func persistDisabledAutoApproveTools() {
        disabledAutoApproveTools = disabledAutoApproveToolSet.sorted()
        defaults.set(disabledAutoApproveTools, forKey: DefaultsKey.disabledAutoApproveTools)
    }
}

private struct QueuedRequest {
    let request: ToolPermissionRequest
    let continuation: CheckedContinuation<ToolPermissionDecision, Never>
}

public enum ModelPromptLanguage: Equatable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case english
    case japanese
    case russian
    case french
    case spanish
    case arabic

    public static var current: ModelPromptLanguage {
        let appLanguage = AppLanguagePreference.storedPreference
        if let identifier = appLanguage.localizationIdentifier,
           let language = resolve(identifier: identifier) {
            return language
        }

        let identifiers = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        return resolve(identifiers: identifiers)
    }

    public static func resolve(identifiers: [String]) -> ModelPromptLanguage {
        identifiers.lazy.compactMap { resolve(identifier: $0) }.first ?? .english
    }

    public static func resolve(identifier: String) -> ModelPromptLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-tw") {
            return .traditionalChinese
        }
        if normalized.hasPrefix("zh") {
            return .simplifiedChinese
        }
        if normalized.hasPrefix("en") {
            return .english
        }
        if normalized.hasPrefix("ja") {
            return .japanese
        }
        if normalized.hasPrefix("ru") {
            return .russian
        }
        if normalized.hasPrefix("fr") {
            return .french
        }
        if normalized.hasPrefix("es") {
            return .spanish
        }
        if normalized.hasPrefix("ar") {
            return .arabic
        }
        return nil
    }

    public var outputInstruction: String {
        switch self {
        case .simplifiedChinese:
            return "输出语言：简体中文。除非用户明确要求其它语言，所有由内置提示词生成的用户可见文本都使用简体中文。"
        case .traditionalChinese:
            return "輸出語言：繁體中文。除非使用者明確要求其他語言，所有由內建提示詞產生的使用者可見文字都使用繁體中文。"
        case .english:
            return "Output language: English. Unless the user explicitly asks for another language, use English for all user-visible text generated by built-in prompts."
        case .japanese:
            return "出力言語：日本語。ユーザーが別の言語を明示しない限り、組み込みプロンプトが生成するユーザー向けテキストは日本語で書いてください。"
        case .russian:
            return "Язык вывода: русский. Если пользователь явно не попросил другой язык, весь видимый пользователю текст, созданный встроенными подсказками, пишите по-русски."
        case .french:
            return "Langue de sortie : français. Sauf demande explicite d'une autre langue par l'utilisateur, rédigez en français tout texte visible par l'utilisateur généré par les invites intégrées."
        case .spanish:
            return "Idioma de salida: español. Salvo que el usuario pida explícitamente otro idioma, escribe en español todo texto visible para el usuario generado por indicaciones integradas."
        case .arabic:
            return "لغة الإخراج: العربية. ما لم يطلب المستخدم صراحة لغة أخرى، اكتب بالعربية كل نص ظاهر للمستخدم تولده التعليمات المدمجة."
        }
    }

    public var toolArgumentInstruction: String {
        switch self {
        case .simplifiedChinese:
            return "生成工具参数中的标题、问题、选项、说明、记忆内容等用户可见文本时，请使用简体中文，除非用户明确指定其它语言。"
        case .traditionalChinese:
            return "產生工具參數中的標題、問題、選項、說明、記憶內容等使用者可見文字時，請使用繁體中文，除非使用者明確指定其他語言。"
        case .english:
            return "When creating user-visible tool arguments such as titles, questions, options, descriptions, or memory content, use English unless the user explicitly specifies another language."
        case .japanese:
            return "タイトル、質問、選択肢、説明、記憶内容など、ユーザーに見えるツール引数を作るときは、ユーザーが別の言語を明示しない限り日本語を使用してください。"
        case .russian:
            return "Создавая видимые пользователю аргументы инструмента, например заголовки, вопросы, варианты, описания или содержимое памяти, используйте русский, если пользователь явно не указал другой язык."
        case .french:
            return "Pour les arguments d'outil visibles par l'utilisateur, comme les titres, questions, options, descriptions ou contenus de mémoire, utilisez le français sauf indication contraire explicite de l'utilisateur."
        case .spanish:
            return "Al crear argumentos de herramienta visibles para el usuario, como títulos, preguntas, opciones, descripciones o contenido de memoria, usa español salvo que el usuario indique explícitamente otro idioma."
        case .arabic:
            return "عند إنشاء وسائط أدوات ظاهرة للمستخدم، مثل العناوين أو الأسئلة أو الخيارات أو الأوصاف أو محتوى الذاكرة، استخدم العربية ما لم يحدد المستخدم لغة أخرى صراحة."
        }
    }

    public static func appendingOutputInstruction(to prompt: String, language: ModelPromptLanguage = .current) -> String {
        append(language.outputInstruction, to: prompt)
    }

    public static func appendingToolArgumentInstruction(to description: String, language: ModelPromptLanguage = .current) -> String {
        append(language.toolArgumentInstruction, to: description)
    }

    private static func append(_ instruction: String, to text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return instruction }
        return "\(trimmedText)\n\n\(instruction)"
    }
}
