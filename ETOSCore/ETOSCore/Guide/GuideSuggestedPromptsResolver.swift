import Foundation

enum GuideAssistantText {
    // 界面通过主词库跟随 App 内语言。只有显式指定语言的调用方才使用中英对照文案。
    static func localized(_ chinese: String, value english: String, locale: Locale?) -> String {
        if let locale {
            return locale.language.languageCode?.identifier == "zh" ? chinese : english
        }
        return NSLocalizedString(chinese, value: english, comment: "使用助手的推荐问题或接口地址提示")
    }
}

public enum GuideSuggestedPromptsResolver {
    public static func resolve(page: GuidePageDescriptor, setupState: GuideModelSetupState, locale: Locale? = nil) -> [String] {
        func text(_ chinese: String, _ english: String) -> String {
            GuideAssistantText.localized(chinese, value: english, locale: locale)
        }
        let first: String?
        switch setupState {
        case .needsProvider: first = text("我有接口地址和 Key，应该填在哪里？", "Where do I enter my API address and key?")
        case .needsCredential: first = text("提供商已经加好了，Key 填在哪里？", "Where do I enter the key for my provider?")
        case .needsModel: first = text("填好 Key 了，怎么获取或添加聊天模型？", "How do I fetch or add a chat model?")
        case .needsActivationOrSelection: first = text("模型已经加好了，怎么启用并选它来聊天？", "How do I enable a model and select it for chat?")
        case .ready: first = nil
        }
        var prompts: [String] = []
        if let first {
            prompts.append(first)
            prompts.append(text("为什么我现在还不能聊天？", "Why can't I chat yet?"))
        }
        // 页面提供的是已本地化文案，最多采用两条，给全局入口留出位置。
        var pagePrompts: [String] = []
        for prompt in page.suggestedPrompts {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !prompts.contains(text), !pagePrompts.contains(text) else { continue }
            pagePrompts.append(text)
            if pagePrompts.count == 2 { break }
        }
        if pagePrompts.isEmpty { pagePrompts.append(text("这页的设置可以帮我做什么？", "What is this page for?")) }
        prompts += pagePrompts
        for suggestion in [
            text("这个软件有哪些实用功能？", "What can I do with this app?"),
            text("怎么导入酒馆角色卡和世界书？", "How do I import a character card and worldbook?"),
            text("怎么换聊天背景和气泡样式？", "How do I change the chat wallpaper and bubbles?")
        ] where !prompts.contains(suggestion) {
            prompts.append(suggestion)
        }
        return Array(prompts.prefix(4))
    }
}
