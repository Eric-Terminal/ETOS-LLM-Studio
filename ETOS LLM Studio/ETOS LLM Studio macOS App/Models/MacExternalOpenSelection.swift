import ETOSCore
import Foundation

/// 文件保持原批次；快捷指令完成回调不进入附件队列，也不触发剪贴板导入。
struct MacExternalOpenSelection: Sendable {
    let files: [URL]
    let shortcutCompletions: [URL]
    let hasUnsupportedURLs: Bool

    init(urls: [URL]) {
        var files: [URL] = [], completions: [URL] = []
        var hasUnsupported = false
        for url in urls {
            if url.isFileURL { files.append(url) }
            else if let completion = ShortcutURLRouter.normalizedCompletionURL(url) { completions.append(completion) }
            else { hasUnsupported = true }
        }
        self.files = files; shortcutCompletions = completions; hasUnsupportedURLs = hasUnsupported
    }
}
