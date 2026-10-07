import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacExternalOpenSelectionTests {
    @Test("混合打开保留 GGUF 批次，完成回调不作为附件")
    func separatesCompletionsAndFiles() throws {
        let model = URL(fileURLWithPath: "/models/chat.gguf")
        let projector = URL(fileURLWithPath: "/models/mmproj.gguf")
        let callback = URL(string: "etosllmstudio:/shortcuts/callback?request_id=one&status=success&result=a%2Bb")!
        let selection = MacExternalOpenSelection(urls: [projector, callback, model])
        #expect(selection.files == [projector, model])
        let completion = try #require(selection.shortcutCompletions.first)
        #expect(completion.host == "shortcuts")
        #expect(completion.path == "/callback")
        #expect(URLComponents(url: completion, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "result" }?.value == "a+b")
        #expect(!selection.hasUnsupportedURLs)
    }

    @Test("剪贴板导入、陌生 Scheme 和下载链接不能伪装成完成回调")
    func completionRoutesDoNotStartImports() {
        for raw in [
            "etosllmstudio://shortcuts/import?source=clipboard",
            "etosllmstudio://import?source=clipboard",
            "https://shortcuts/callback?status=success",
            "https://example.com/model.gguf",
            "etosllmstudio://unknown/callback"
        ] {
            let url = URL(string: raw)!
            #expect(ShortcutURLRouter.normalizedCompletionURL(url) == nil)
            let selection = MacExternalOpenSelection(urls: [url])
            #expect(selection.shortcutCompletions.isEmpty)
            #expect(selection.files.isEmpty)
            #expect(selection.hasUnsupportedURLs)
        }
    }

    @Test("旧快捷指令完成 URL 形式归一化后保留查询参数")
    func acceptsExistingCompletionForms() throws {
        for raw in [
            "etosllmstudio://shortcuts/callback?request_id=one",
            "etosllmstudio://shortcut/callback?request_id=one",
            "etosllmstudio:/shortcuts/callback?request_id=one",
            "etosllmstudio://callback?request_id=one",
            "ETOSLLMSTUDIO://SHORTCUTS/callback?request_id=one"
        ] {
            let normalized = try #require(ShortcutURLRouter.normalizedCompletionURL(URL(string: raw)!))
            #expect(normalized.host == "shortcuts")
            #expect(normalized.path == "/callback")
            #expect(normalized.query == "request_id=one")
        }
        #expect(ShortcutURLRouter.normalizedCompletionURL(URL(string: "etosllmstudio://shortcuts/template-status?status=success")!)?.path == "/template-status")
    }
}
