import Foundation
import SwiftUI
import Testing
@testable import ETOSCore

@Suite("聊天长文本布局边界")
struct ChatTextPaginationTests {
    @Test("空文本、短文本和恰好到字符边界的内容不产生空白尾页")
    func keepsShortContentIntact() throws {
        for text in ["", "短文本\n下一行", String(repeating: "字", count: 3_000)] {
            let pagination = try ChatTextPagination(text: text)
            #expect(pagination.pages.map(\.text) == [text])
        }
    }

    @Test("超长单行和大量换行都限制每次布局量，拼接后仍是完整原文")
    func boundsCharactersAndLinesWithoutLosingContent() throws {
        for text in [String(repeating: "很长的工具输出", count: 20_000),
                     String(repeating: "\n", count: 10_000),
                     String(repeating: "let value = 42\n", count: 1_000)] {
            let pagination = try ChatTextPagination(text: text)
            #expect(pagination.pages.count > 1)
            #expect(pagination.pages.map(\.text).joined() == text)
            for page in pagination.pages {
                #expect(!page.text.isEmpty)
                #expect(page.text.count <= ChatTextPagination.maximumCharactersPerPage)
                #expect(page.text.filter(\.isNewline).count <= ChatTextPagination.maximumLineBreaksPerPage)
            }
        }
    }

    @Test("分页不拆开组合字符、emoji、CRLF 和 Unicode 换行")
    func preservesUnicodeBoundaries() throws {
        for character in ["👨‍👩‍👧‍👦", "e\u{301}", "🇨🇳"] {
            let prefix = String(repeating: character, count: 3_000)
            let pagination = try ChatTextPagination(text: prefix + "尾部")
            #expect(pagination.pages.map(\.text) == [prefix, "尾部"])
        }
        for separator in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let prefix = String(repeating: "行" + separator, count: 80)
            #expect(try ChatTextPagination(text: prefix).pages.map(\.text) == [prefix])
            #expect(try ChatTextPagination(text: prefix + "尾部").pages.map(\.text) == [prefix, "尾部"])
        }
    }

    @MainActor
    @Test("追加内容保留阅读页，替换为短文本后重置页码，越界操作不影响状态")
    func updatesSelectionForStreamingAndReplacement() async {
        let model = ChatTextPaginationModel()
        let source = String(repeating: "x", count: 6_100)
        await model.prepare(text: source)
        model.selectPage(2)
        #expect(model.currentPage?.text == String(repeating: "x", count: 100))

        await model.prepare(text: source + "追加")
        #expect(model.selectedPageIndex == 2)
        #expect(model.currentPage?.text.hasSuffix("追加") == true)
        model.selectPage(-1)
        model.selectPage(model.pageCount)
        #expect(model.selectedPageIndex == 2)

        await model.prepare(text: "新结果")
        #expect(model.selectedPageIndex == 0)
        #expect(model.currentPage?.text == "新结果")
        #expect(model.pageCount == 1)
    }

    @MainActor
    @Test("取消准备保留已显示内容，重新进入后能继续准备")
    func cancelledPreparationDoesNotReplaceDisplayedText() async {
        let model = ChatTextPaginationModel()
        await model.prepare(text: "已显示")
        let cancelled = Task { await model.prepare(text: "取消的结果") }
        cancelled.cancel()
        await cancelled.value
        #expect(model.currentPage?.text == "已显示")
        await model.prepare(text: "重新进入")
        #expect(model.currentPage?.text == "重新进入")
    }

    @Test("已经取消的后台任务不继续遍历长文本")
    func checksCancellationBeforePagination() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ChatTextPagination(text: String(repeating: "输出", count: 10_000))
        }
        do {
            _ = try await task.value
            Issue.record("已取消的分页任务不应返回新页面")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @MainActor
    @Test("恢复原先内容后，先前启动的大文本任务不能覆盖当前结果")
    func returningToPreviousSourceInvalidatesPendingWork() async throws {
        let model = ChatTextPaginationModel()
        await model.prepare(text: "当前内容")
        let largeText = String(repeating: "待替换的输出\n", count: 30_000)
        var pending: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            pending = Task { @MainActor in
                started.resume()
                // 同一 actor 在 prepare 第一次挂起后才会恢复测试，确保旧请求已登记。
                await model.prepare(text: largeText)
            }
        }
        await model.prepare(text: "当前内容")
        let task = try #require(pending)
        await task.value
        #expect(model.currentPage?.text == "当前内容")
        #expect(model.pageCount == 1)
    }

    @Test("富文本分页保留跨页的字体与颜色属性，重新拼接没有内容损失")
    func preservesAttributedText() throws {
        let source = String(repeating: "字", count: 3_001) + "👨‍👩‍👧‍👦尾部"
        var attributed = AttributedString(source)
        attributed.foregroundColor = .blue
        let start = attributed.characters.index(attributed.startIndex, offsetBy: 2_999)
        attributed[start..<attributed.endIndex].foregroundColor = .red
        attributed[start..<attributed.endIndex].font = .body.bold()

        let pagination = try ChatTextPagination(attributedText: attributed)
        var restored = AttributedString()
        for page in pagination.pages { restored += page.attributedText }
        #expect(pagination.pages.count == 2)
        #expect(pagination.pages.map(\.text).joined() == source)
        #expect(restored == attributed)
    }

    @MainActor
    @Test("正文相同但样式更新时刷新当前页并保留阅读位置")
    func refreshesAttributesWithoutResettingSelection() async {
        let model = ChatTextPaginationModel()
        var text = AttributedString(String(repeating: "字", count: 3_100))
        text.foregroundColor = .red
        await model.prepare(attributedText: text)
        model.selectPage(1)

        text.foregroundColor = .blue
        await model.prepare(attributedText: text)
        #expect(model.selectedPageIndex == 1)
        #expect(model.currentPage?.attributedText.foregroundColor == .blue)
    }

    @MainActor
    @Test("离屏导出不依赖分页任务，完整原文仍传给原有文本视图")
    func exportKeepsCompleteTextWithoutWaitingForTask() {
        let source = String(repeating: "完整内容", count: 1_000)
        var exportedText: String?
        let view = ETPagedTextContent(text: source) { text in
            exportedText = text
            return Text(text).lineLimit(1)
        }
        .environment(\.etFontExportPreparation, ETFontExportPreparation())
        .frame(width: 200, height: 40)

        #expect(ImageRenderer(content: view).cgImage != nil)
        #expect(exportedText == source)
    }

    @MainActor
    @Test("代码块离屏导出使用原始渲染器而非分页占位或当前页")
    func exportUsesOriginalCodeRenderer() {
        var usedInteractivePage = false
        var usedExportContent = false
        let view = ETPagedTextContent(text: "代码原文") { _ in
            usedInteractivePage = true
            return Text(verbatim: "page")
        } exportContent: {
            usedExportContent = true
            return Text(verbatim: "export")
        }
        .environment(\.etFontExportPreparation, ETFontExportPreparation())
        .frame(width: 200, height: 40)

        #expect(ImageRenderer(content: view).cgImage != nil)
        #expect(usedExportContent)
        #expect(!usedInteractivePage)
    }
}
