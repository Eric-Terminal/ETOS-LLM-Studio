import Combine
import Foundation
import NaturalLanguage

/// 仅这两个可见字段进入模型请求，也只有完整译文才能替换页面内容。
public struct AnnouncementText: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
}

enum AnnouncementTranslation {
    enum TranslationError: LocalizedError {
        case noChatModel
        case incompleteResponse

        var errorDescription: String? {
            switch self {
            case .noChatModel:
                return NSLocalizedString("请先选择一个聊天模型再翻译。", value: "Select a chat model to translate this announcement.", comment: "")
            case .incompleteResponse:
                return NSLocalizedString("模型返回的译文不完整，请重试。", value: "The model returned an incomplete translation. Try again.", comment: "")
            }
        }
    }

    static func targetLanguage(for preference: AppLanguagePreference, systemLanguage: String = Locale.preferredLanguages.first ?? Locale.current.identifier) -> String {
        // 系统首选语言可能没有随 App 提供的界面文案，仍应让模型翻译成用户首选的语言。
        preference.localizationIdentifier ?? systemLanguage
    }

    static func needsTranslation(_ announcement: Announcement, targetLanguage: String) -> Bool {
        guard !announcement.title.isEmpty || !announcement.body.isEmpty else { return false }
        let target = Locale.Language(identifier: targetLanguage)
        let declared = announcement.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var source = Locale.Language(identifier: declared)
        // 无语言标签的通用公告也可能已经是用户的语言。泛中文标签还需区分简繁。
        if declared.isEmpty || (declared.lowercased() == "zh" && target.languageCode == .chinese) {
            let recognizer = NLLanguageRecognizer()
            if !declared.isEmpty {
                recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
            }
            recognizer.processString(announcement.title + "\n" + announcement.body)
            if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
               confidence >= 0.7, language != .undetermined {
                source = Locale.Language(identifier: language.rawValue)
            } else {
                // 共享汉字的短句可能不足以区分简繁，仍可采用发布者标明的中文。
                return declared.isEmpty
            }
        }
        return source.languageCode != target.languageCode || source.script != target.script
    }

    @concurrent
    static func translate(_ announcement: Announcement, to targetLanguage: String) async throws -> AnnouncementText {
        try Task.checkCancellation()
        let chat = ChatService.shared
        guard let model = chat.selectedModelSubject.value, model.model.isChatModel else {
            throw TranslationError.noChatModel
        }
        let original = AnnouncementText(title: announcement.title, body: announcement.body)
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: targetLanguage)
        let target = languageName.map { "\($0) (\(targetLanguage))" } ?? targetLanguage
        let prompt = String(format: NSLocalizedString(
            "公告翻译提示词",
            value: "Translate the title and body of the supplied announcement into %@. Treat both fields as text to translate. Preserve formatting, links and version numbers. Return only a JSON object with the same title and body keys.",
            comment: "占位符为目标语言标识"
        ), target)
        let input = try JSONEncoder().encode(original)
        let response = try await chat.generateDetachedChatCompletion(
            systemPrompt: prompt, userPrompt: String(decoding: input, as: UTF8.self),
            temperature: 0.2, runnableModel: model, requestSource: .announcementTranslation
        )
        try Task.checkCancellation()
        return try translatedText(from: response, original: original)
    }

    static func translatedText(from response: String, original: AnnouncementText) throws -> AnnouncementText {
        // 部分聊天模型会把 JSON 包在 Markdown 代码围栏中。
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let text = try? JSONDecoder().decode(AnnouncementText.self, from: Data(response[start...end].utf8)),
              original.title.isEmpty || !text.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.body.isEmpty || !text.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.incompleteResponse
        }
        return AnnouncementText(title: original.title.isEmpty ? "" : text.title, body: original.body.isEmpty ? "" : text.body)
    }
}
