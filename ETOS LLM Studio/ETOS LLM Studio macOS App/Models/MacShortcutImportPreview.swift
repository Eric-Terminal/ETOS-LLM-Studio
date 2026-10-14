import ETOSCore
import Foundation

enum MacShortcutImportSource: Sendable {
    case text(String), file(URL)

    func readData() throws -> Data {
        switch self {
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShortcutToolError.clipboardEmpty }
            return Data(text.utf8)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }
    }
}

struct MacShortcutImportPreview: Sendable {
    let source: ShortcutPreparedImport
    let rows: [MacShortcutToolRow]
    let guideRows: JSONValue

    init(_ source: ShortcutPreparedImport) {
        self.source = source
        let prepared = MacShortcutToolsModel.prepare(tools: source.tools, enabled: true, isolated: false, query: "", enabledOnly: false)
        rows = prepared.0
        // 这是尚未保存的预览，不能把计划启用误报为当前已向聊天开放。
        guideRows = .array(rows.map { .dictionary([
            "name": .string($0.tool.name), "display_name": .string($0.title),
            "enabled_after_import": .bool($0.tool.isEnabled), "run_mode": .string($0.tool.runModeHint.rawValue)
        ]) })
    }
}
