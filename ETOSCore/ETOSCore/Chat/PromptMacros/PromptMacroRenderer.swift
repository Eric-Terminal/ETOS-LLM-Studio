// ============================================================================
// PromptMacroRenderer.swift
// ============================================================================
// 提示词与用户消息共享同一份请求快照，持久化原文不在这里改写。
// ============================================================================

import Foundation

enum PromptMacroRenderer {
    static func render(
        _ templates: PromptMacroTemplates,
        model: RunnableModel,
        sessionID: UUID,
        session: ChatSession?,
        messages: [ChatMessage],
        now: Date,
        roleplayStore: RoleplayStore
    ) async -> PromptMacroRequest {
        await Task.detached(priority: .userInitiated) {
            let userTexts = messages.filter { $0.role == .user }.map(\.content)
            let names = PromptMacroResolver.referencedNames(in: templates.texts + userTexts)
            guard !names.isEmpty else {
                return PromptMacroRequest(templates: templates, messages: messages, values: [:])
            }

            // 设置和角色库可能触发磁盘读取，模板扫描与格式化也统一留在后台。
            let preference = AppLanguagePreference.storedPreference
            let locale = AppLanguagePreference.preferredLocale(rawValue: preference.rawValue)
            let languageCode = locale.language.languageCode?.identifier ?? "en"
            let modelName = model.model.displayName.isEmpty ? model.model.modelName : model.model.displayName
            var values: [String: String] = [:]
            if !names.isDisjoint(with: PromptMacroResolver.timeNames) {
                values = PromptMacroResolver.timeValues(now: now, locale: locale, timeZone: .current)
            }
            values.merge([
                "model_id": model.model.modelName,
                "model_name": modelName,
                "provider_id": model.provider.id.uuidString,
                "provider_name": model.provider.name,
                "api_format": model.effectiveAPIFormat,
                "locale": locale.identifier.replacingOccurrences(of: "_", with: "-"),
                "language": locale.localizedString(forLanguageCode: languageCode) ?? languageCode,
                "system_locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                "chat_id": sessionID.uuidString,
                "chat_name": session?.name ?? ""
            ]) { _, new in new }
            if names.contains("message_count") {
                values["message_count"] = String(messages.lazy.filter { $0.role == .user || $0.role == .assistant }.count)
            }

            if !names.isDisjoint(with: ["nickname", "user", "char", "assistant_name"]) {
                let binding = roleplayStore.binding(sessionID: sessionID)
                let personaID = binding?.personaID ?? roleplayStore.preferredPersonaID()
                let persona = personaID.flatMap { roleplayStore.persona(id: $0) }
                let character = binding?.characterIDs.lazy.compactMap { roleplayStore.character(id: $0) }.first
                let userName = persona?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let characterName = character?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let nickname = userName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? NSLocalizedString("用户", value: "User", comment: "未设置 Persona 时的提示词宏称呼")
                let assistantName = characterName.flatMap { $0.isEmpty ? nil : $0 } ?? modelName
                values.merge([
                    "nickname": nickname, "user": nickname,
                    "char": assistantName, "assistant_name": assistantName
                ]) { _, new in new }
            }
            values.merge(await PromptMacroEnvironment.capture(referencedNames: names)) { _, new in new }
            return PromptMacroRequest(templates: templates, messages: messages, values: values)
        }.value
    }
}
