// ============================================================================
// GuideDisplaySettingsSupport.swift
// ============================================================================
// 双端共用的显示设置向导字段，与原生设置使用同一配置和输入范围。
// ============================================================================

import Foundation

public enum GuideDisplaySettingsSupport {
    @MainActor
    public static func userMessagePreviewCharacterLimit(appConfig: AppConfigStore) -> GuidePageSetting {
        .integer(
            "user_message_preview_character_limit",
            label: NSLocalizedString("预览字符数", comment: "长用户消息预览向导字段"),
            range: ChatUserMessagePreview.characterLimitRange,
            get: { appConfig.userMessagePreviewCharacterLimit },
            set: { appConfig.userMessagePreviewCharacterLimit = $0 }
        )
    }
}
