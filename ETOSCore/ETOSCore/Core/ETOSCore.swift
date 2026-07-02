// ============================================================================
// ETOSCore.swift
// ============================================================================
// ETOS LLM Studio 核心模块通用文件
//
// 定义内容:
// - (当前为空，可用于存放核心层的扩展、辅助函数等)
// ============================================================================

import Foundation
import Combine
#if canImport(ObjectiveC)
import ObjectiveC
#endif

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
        let rawValue = Persistence.readAppConfigText(key: AppConfigKey.appLanguage.rawValue) ?? defaultLanguage.rawValue
        return resolved(rawValue: rawValue)
    }
}

public enum AppLanguageRuntime {
    public static func applyConfiguredLanguage() {
        let rawValue = Persistence.readAppConfigText(key: AppConfigKey.appLanguage.rawValue)
            ?? (AppConfigStore.persistentSnapshot()[AppConfigKey.appLanguage.rawValue] as? String)
        apply(rawValue: rawValue ?? AppLanguagePreference.defaultLanguage.rawValue)
    }

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
    public let sourceSessionID: UUID?
    public let toolCallID: String?
    
    public init(
        id: UUID = UUID(),
        toolName: String,
        displayName: String?,
        arguments: String,
        sourceSessionID: UUID? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.arguments = arguments
        self.sourceSessionID = sourceSessionID
        self.toolCallID = toolCallID
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
    @Published public private(set) var autoPresentationBlockerIDs: Set<String> = []
    
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

    public var canAutoPresentRequestDetails: Bool {
        autoPresentationBlockerIDs.isEmpty
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoApproveEnabled = Self.boolValue(forKey: DefaultsKey.autoApproveEnabled, defaults: defaults, defaultValue: false)
        let storedCountdown = Self.integerValue(forKey: DefaultsKey.autoApproveCountdownSeconds, defaults: defaults, defaultValue: 8)
        if storedCountdown > 0 {
            autoApproveCountdownSeconds = min(max(storedCountdown, autoApproveCountdownMin), autoApproveCountdownMax)
        } else {
            autoApproveCountdownSeconds = 8
        }
        let storedDisabledTools = Self.stringArrayValue(forKey: DefaultsKey.disabledAutoApproveTools, defaults: defaults)
        disabledAutoApproveToolSet = Set(storedDisabledTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        disabledAutoApproveTools = disabledAutoApproveToolSet.sorted()
    }
    
    public func requestPermission(
        toolName: String,
        displayName: String?,
        arguments: String,
        sourceSessionID: UUID? = nil,
        toolCallID: String? = nil
    ) async -> ToolPermissionDecision {
        if allowAll || allowedTools.contains(toolName) {
            return .allowOnce
        }
        
        return await withCheckedContinuation { continuation in
            let request = ToolPermissionRequest(
                toolName: toolName,
                displayName: displayName,
                arguments: arguments,
                sourceSessionID: sourceSessionID,
                toolCallID: toolCallID
            )
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
        Self.save(enabled, forKey: DefaultsKey.autoApproveEnabled, defaults: defaults)
        if let activeRequest {
            scheduleAutoApproveIfNeeded(for: activeRequest)
        } else {
            cancelAutoApproveCountdown()
        }
    }

    public func setAutoApproveCountdownSeconds(_ seconds: Int) {
        let sanitized = min(max(seconds, autoApproveCountdownMin), autoApproveCountdownMax)
        autoApproveCountdownSeconds = sanitized
        Self.save(sanitized, forKey: DefaultsKey.autoApproveCountdownSeconds, defaults: defaults)
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

    public func setAutoPresentationBlocked(_ blocked: Bool, reason: String) {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else { return }

        var updatedBlockers = autoPresentationBlockerIDs
        if blocked {
            updatedBlockers.insert(normalizedReason)
        } else {
            updatedBlockers.remove(normalizedReason)
        }

        guard updatedBlockers != autoPresentationBlockerIDs else { return }
        autoPresentationBlockerIDs = updatedBlockers
    }

    public func hasAutoPresentationBlockers(excluding excludedIDs: Set<String> = []) -> Bool {
        !autoPresentationBlockerIDs.subtracting(excludedIDs).isEmpty
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
        Self.save(disabledAutoApproveTools, forKey: DefaultsKey.disabledAutoApproveTools, defaults: defaults)
    }

    private static func usesDatabase(defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    private static func boolValue(forKey key: String, defaults: UserDefaults, defaultValue: Bool) -> Bool {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored != 0
        }
        return defaultValue
    }

    private static func integerValue(forKey key: String, defaults: UserDefaults, defaultValue: Int) -> Int {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Int ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored
        }
        return defaultValue
    }

    private static func stringArrayValue(forKey key: String, defaults: UserDefaults) -> [String] {
        guard usesDatabase(defaults: defaults) else {
            return defaults.stringArray(forKey: key) ?? []
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigText(key: key),
           let decoded = decodeStringArray(stored) {
            return decoded
        }
        return []
    }

    private static func save(_ value: Bool, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, integer: value ? 1 : 0, typeHint: "bool")
    }

    private static func save(_ value: Int, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, integer: value, typeHint: "integer")
    }

    private static func save(_ value: [String], forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        guard let encoded = encodeStringArray(value) else { return }
        Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text")
    }

    private static func encodeStringArray(_ value: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeStringArray(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String]
    }
}

private struct QueuedRequest {
    let request: ToolPermissionRequest
    let continuation: CheckedContinuation<ToolPermissionDecision, Never>
}
