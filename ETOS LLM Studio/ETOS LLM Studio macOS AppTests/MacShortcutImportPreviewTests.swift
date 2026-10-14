import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacShortcutImportPreviewTests {
    @Test("导入预览显示名称与生成描述，但向导不读取任意元数据")
    func previewSeparatesDisplayAndGuideContent() throws {
        let first = ShortcutToolDefinition(name: "z", metadata: ["displayName": .string("A"), "token": .string("private-token")],
                                          generatedDescription: "private-description")
        let second = ShortcutToolDefinition(name: "B")
        let source = ShortcutToolManager.prepareImportCandidates([
            ShortcutToolImportPayload(name: first.name, metadata: first.metadata), ShortcutToolImportPayload(name: second.name)
        ], existing: [], describe: { _ in "private-description" })
        let preview = MacShortcutImportPreview(source)
        #expect(preview.rows.map(\.title) == ["A", "B"])
        #expect(preview.rows.first?.description == "private-description")
        let guide = String(decoding: try JSONEncoder().encode(preview.guideRows), as: UTF8.self)
        #expect(!guide.contains("private-token") && !guide.contains("private-description"))
        #expect(guide.contains("enabled_after_import") && !guide.contains("available_to_model"))
        #expect(preview.source.tools.count == 2)
    }

    @Test("手动文本与文件输入保留原始 JSON，空清单在准备前被拒绝")
    func inputReadsWithoutInstallingTools() throws {
        let text = "{\"type\":\"light\",\"data\":[\"中文工具\"]}"
        #expect(try MacShortcutImportSource.text(text).readData() == Data(text.utf8))
        #expect(throws: ShortcutToolError.self) { try MacShortcutImportSource.text(" \n ").readData() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(text.utf8).write(to: file)
        #expect(try MacShortcutImportSource.file(file).readData() == Data(text.utf8))
    }
}
